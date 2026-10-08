// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract LeveragedTokenTest is Base {
    function test_firstMint_opensAtTargetLeverage_allProducts() public {
        LeveragedToken[4] memory ps = [l3, l2, s1, s2];
        uint256[4] memory targets = [uint256(3e18), 2e18, 1e18, 2e18];
        for (uint256 i; i < 4; ++i) {
            uint256 shares = _mint(alice, ps[i], 10_000e6);
            assertGt(shares, 9_900e18, "shares ~ equity");
            assertApproxEqRel(_lev(ps[i]), targets[i], 0.02e18, "leverage at target");
            assertApproxEqRel(ps[i].navPerShare(), 1e18, 0.02e18, "nav ~ 1");
            assertEq(ps[i].balanceOf(ps[i].DEAD()), ps[i].DEAD_SHARES());
        }
    }

    function test_mintFee_goesToFeeCollector() public {
        _mint(alice, l3, 10_000e6);
        assertEq(usdg.balanceOf(address(feeCollector)), 10e6); // 10 bps
    }

    function test_secondMint_isProportional_andRefundsBuffer() public {
        _mint(alice, l3, 10_000e6);
        (uint256 c0, uint256 d0) = _raw(l3);
        uint256 s0 = l3.totalSupply();
        uint256 balBefore = usdg.balanceOf(bob);
        uint256 shares = _mint(bob, l3, 5_000e6);
        (uint256 c1, uint256 d1) = _raw(l3);
        uint256 s1_ = l3.totalSupply();
        // per-share collateral not lower, per-share debt not higher for existing holders
        assertGe(c1 * 1e18 / s1_, c0 * 1e18 / s0 - 1);
        assertLe(d1 * 1e18 / s1_, d0 * 1e18 / s0 + 1);
        // bob paid less than 5000 because of the 1% buffer refund
        uint256 paid = balBefore - usdg.balanceOf(bob);
        assertLt(paid, 5_000e6);
        assertGt(paid, 4_900e6);
        assertGt(shares, 0);
        assertApproxEqRel(_lev(l3), 3e18, 0.02e18);
    }

    function test_redeem_returnsProRata_andKeepsLeverage() public {
        uint256 shares = _mint(alice, l3, 10_000e6);
        _mint(bob, l3, 10_000e6);
        uint256 levBefore = _lev(l3);
        uint256 out = _redeem(alice, l3, shares);
        assertApproxEqRel(out, 9_960e6, 0.01e18); // minus fees & slippage
        assertApproxEqRel(_lev(l3), levBefore, 0.001e18);
        assertEq(l3.balanceOf(alice), 0);
    }

    function test_short_mintRedeem_roundtrip() public {
        uint256 shares = _mint(alice, s2, 10_000e6);
        _mint(bob, s2, 3_000e6);
        uint256 out = _redeem(alice, s2, shares);
        assertApproxEqRel(out, 9_950e6, 0.01e18);
        assertApproxEqRel(_lev(s2), 2e18, 0.03e18);
    }

    function test_longGainsLeveraged_whenPriceRises() public {
        _mint(alice, l3, 10_000e6);
        uint256 nav0 = l3.navPerShare();
        _setPrice(202e8); // +1%
        uint256 nav1 = l3.navPerShare();
        assertApproxEqRel((nav1 - nav0) * 1e18 / nav0, 0.03e18, 0.02e18);
    }

    function test_shortGains_whenPriceFalls() public {
        _mint(alice, s2, 10_000e6);
        uint256 nav0 = s2.navPerShare();
        _setPrice(198e8); // -1%
        uint256 nav1 = s2.navPerShare();
        assertApproxEqRel((nav1 - nav0) * 1e18 / nav0, 0.02e18, 0.02e18);
    }
}
