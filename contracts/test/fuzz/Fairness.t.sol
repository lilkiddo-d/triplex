// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";

/// @notice "Mint/redeem never extracts value from other holders."
/// Checked in token terms (oracle-independent): for existing holders, collateral-per-share must not fall and
/// debt-per-share must not rise when someone else mints or redeems — under any price, oracle/market offset,
/// venue slippage and size.
contract FairnessFuzzTest is Base {
    struct Snap {
        uint256 c;
        uint256 d;
        uint256 s;
    }

    function _snap(LeveragedToken t) internal view returns (Snap memory x) {
        (x.c, x.d) = _raw(t);
        x.s = t.totalSupply();
    }

    /// @dev Holders are not worse off at ANY price iff there is a lambda >= 1 with c1 >= lambda*c0 and
    ///      d1 <= lambda*d0 (per share), i.e. collateral/share does not fall and debt/collateral does not rise.
    ///      Checked in raw token units with a 2-wei allowance for Morpho share-math rounding.
    function _assertNotWorse(LeveragedToken t, Snap memory a) internal view {
        Snap memory b = _snap(t);
        // C1/S1 >= C0/S0
        assertGe((b.c + 2) * a.s, a.c * b.s, "collateral per share decreased");
        // D1/C1 <= D0/C0
        assertLe(b.d * a.c, a.d * b.c + 2 * a.c, "debt/collateral worsened"); // D1 may carry +2 wei
    }

    function _product(uint256 i) internal view returns (LeveragedToken) {
        LeveragedToken[4] memory ps = [l3, l2, s1, s2];
        return ps[i % 4];
    }

    function testFuzz_mintNeverDilutesHolders(
        uint256 which,
        uint256 seed,
        uint256 amount,
        int256 priceMovePct,
        int256 offsetBps,
        uint256 slippageBps
    ) public {
        LeveragedToken t = _product(which);
        _mint(alice, t, bound(seed, 1_000e6, 1_000_000e6));
        _setPrice(int256(200e8) * (100 + bound(priceMovePct, -10, 10)) / 100);
        swap.setMarketOffset(bound(offsetBps, -100, 100));
        swap.setSlippage(bound(slippageBps, 0, 50));

        Snap memory a = _snap(t);
        vm.prank(bob);
        try t.mint(bound(amount, 2e6, 2_000_000e6), 0, block.timestamp) {
            _assertNotWorse(t, a);
        } catch {
            // a reverted mint changes nothing
            _assertNotWorse(t, a);
        }
    }

    function testFuzz_redeemNeverDilutesHolders(
        uint256 which,
        uint256 seed,
        uint256 bobAmt,
        uint256 redeemPct,
        int256 priceMovePct,
        int256 offsetBps,
        uint256 slippageBps
    ) public {
        LeveragedToken t = _product(which);
        _mint(alice, t, bound(seed, 1_000e6, 1_000_000e6));
        uint256 bobShares = _mint(bob, t, bound(bobAmt, 10e6, 1_000_000e6));
        _setPrice(int256(200e8) * (100 + bound(priceMovePct, -10, 10)) / 100);
        swap.setMarketOffset(bound(offsetBps, -100, 100));
        swap.setSlippage(bound(slippageBps, 0, 50));

        Snap memory a = _snap(t);
        uint256 shares = bobShares * bound(redeemPct, 1, 100) / 100;
        vm.prank(bob);
        try t.redeem(shares, 0, block.timestamp) {
            _assertNotWorse(t, a);
        } catch {
            _assertNotWorse(t, a);
        }
    }

    /// @notice A round trip (mint then immediately redeem) can never return more than was paid.
    function testFuzz_roundTripNoProfit(uint256 which, uint256 seed, uint256 amount, int256 offsetBps) public {
        LeveragedToken t = _product(which);
        _mint(alice, t, bound(seed, 1_000e6, 1_000_000e6));
        swap.setMarketOffset(bound(offsetBps, -100, 100));
        uint256 before = usdg.balanceOf(bob);
        vm.startPrank(bob);
        try t.mint(bound(amount, 2e6, 1_000_000e6), 0, block.timestamp) returns (uint256 sh) {
            // the redeem leg may revert on the oracle-bounded slippage guard; then bob still holds shares
            try t.redeem(sh, 0, block.timestamp) {} catch {}
        } catch {}
        vm.stopPrank();
        assertLe(usdg.balanceOf(bob), before, "round trip profit");
    }

    /// @notice NAV per share is unchanged (up to rounding) by third-party mints/redeems at a fixed price.
    function testFuzz_navStableAcrossFlows(uint256 which, uint256 a1, uint256 a2) public {
        LeveragedToken t = _product(which);
        _mint(alice, t, bound(a1, 1_000e6, 1_000_000e6));
        uint256 nav0 = t.navPerShare();
        uint256 sh = _mint(bob, t, bound(a2, 2e6, 1_000_000e6));
        assertGe(t.navPerShare() + 1e9, nav0);
        _redeem(bob, t, sh);
        assertGe(t.navPerShare() + 1e9, nav0);
    }
}
