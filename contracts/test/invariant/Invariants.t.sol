// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "../utils/Base.t.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {MockAggregator, MockSwapAdapter, MockERC20} from "../mocks/Mocks.sol";
import {MarketClock} from "../../src/MarketClock.sol";

contract Handler is Test {
    LeveragedToken[4] public products;
    Rebalancer public rebalancer;
    MockAggregator public stkAgg;
    MockAggregator public usdgAgg;
    MockSwapAdapter public swap;
    MockERC20 public usdg;
    address[3] public actors;

    event BandViolation(address product, uint256 leverage, int256 price);
    event RebalanceFailed(address product, bytes reason);

    // ghosts
    uint256 public bandViolations;
    uint256 public fairnessViolations;
    uint256 public calls;
    uint256 public rebalances;
    uint256 public mints;
    uint256 public redeems;

    constructor(
        LeveragedToken[4] memory ps,
        Rebalancer r,
        MockAggregator s,
        MockAggregator u,
        MockSwapAdapter sw,
        MockERC20 q,
        address[3] memory a
    ) {
        products = ps;
        rebalancer = r;
        stkAgg = s;
        usdgAgg = u;
        swap = sw;
        usdg = q;
        actors = a;
    }

    function _refresh() internal {
        stkAgg.set(stkAgg.answer());
        usdgAgg.set(usdgAgg.answer());
    }

    function _snap(LeveragedToken t) internal view returns (uint256 c, uint256 d, uint256 s) {
        (c, d) = MorphoPositionAdapter(address(t.adapter())).positionRaw();
        s = t.totalSupply();
    }

    function _fair(LeveragedToken t, uint256 c0, uint256 d0, uint256 s0) internal {
        (uint256 c1, uint256 d1, uint256 s1) = _snap(t);
        if (s0 == 0 || c0 == 0) return;
        if ((c1 + 2) * s0 < c0 * s1 || d1 * c0 > d0 * c1 + 2 * c0) fairnessViolations++;
    }

    /// @dev Keepers react: run the rebalancer until it reports nothing to do, then check the band.
    function _keepers() internal {
        for (uint256 p; p < 4; ++p) {
            LeveragedToken t = products[p];
            for (uint256 i; i < 100; ++i) {
                (Rebalancer.Mode mode,,,, bool ready) = rebalancer.check(address(t));
                if (mode == Rebalancer.Mode.None) break;
                if (!ready) {
                    vm.warp(block.timestamp + 121);
                    _refresh();
                }
                try rebalancer.rebalance(address(t)) {
                    rebalances++;
                } catch (bytes memory reason) {
                    emit RebalanceFailed(address(t), reason);
                    break;
                }
            }
            if (!t.adapter().hasPosition()) continue;
            (,,, uint256 eq) = t.adapter().positionValues();
            if (eq < rebalancer.MIN_EQUITY()) continue; // dust is intentionally not traded
            uint256 l = t.adapter().leverage();
            if (l < t.minLeverage() || l > t.maxLeverage()) {
                bandViolations++;
                emit BandViolation(address(t), l, stkAgg.answer());
            }
        }
    }

    function mint(uint256 actorSeed, uint256 productSeed, uint256 amount) external {
        calls++;
        address a = actors[actorSeed % 3];
        LeveragedToken t = products[productSeed % 4];
        t.accrueManagementFee(); // the streaming fee is a disclosed dilution, not a mint side effect
        (uint256 c0, uint256 d0, uint256 s0) = _snap(t);
        vm.prank(a);
        try t.mint(bound(amount, 2e6, 500_000e6), 0, block.timestamp) {
            mints++;
        } catch {}
        _fair(t, c0, d0, s0);
    }

    function redeem(uint256 actorSeed, uint256 productSeed, uint256 pct) external {
        calls++;
        address a = actors[actorSeed % 3];
        LeveragedToken t = products[productSeed % 4];
        uint256 bal = t.balanceOf(a);
        if (bal == 0) return;
        t.accrueManagementFee();
        (uint256 c0, uint256 d0, uint256 s0) = _snap(t);
        vm.prank(a);
        try t.redeem(bal * bound(pct, 1, 100) / 100, 0, block.timestamp) {
            redeems++;
        } catch {}
        _fair(t, c0, d0, s0);
    }

    /// @dev Price shock of up to +/-12% (within one keeper reaction), then keepers rebalance.
    function shock(int256 pctSeed) external {
        calls++;
        int256 pct = bound(pctSeed, -12, 12);
        int256 p = stkAgg.answer() * (100 + pct) / 100;
        if (p < 50e8) p = 50e8;
        if (p > 400e8) p = 400e8;
        stkAgg.set(p);
        usdgAgg.set(usdgAgg.answer());
        _keepers();
    }

    function passTime(uint256 secs) external {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
        _refresh();
        _keepers();
        // stay within a session-ish timeframe so mint/redeem paths are exercised
        if (!MarketClock(address(rebalancer.registry().marketClock())).isMintRedeemOpen()) {
            vm.warp(_nextSessionOpen());
            _refresh();
        }
    }

    function dailyClose() external {
        calls++;
        uint256 dayStart = (block.timestamp / 1 days) * 1 days;
        vm.warp(dayStart + 19 hours + 50 minutes);
        _refresh();
        _keepers();
        vm.warp(_nextSessionOpen());
        _refresh();
    }

    function _nextSessionOpen() internal view returns (uint256 t) {
        MarketClock clock = MarketClock(address(rebalancer.registry().marketClock()));
        t = (block.timestamp / 1 days) * 1 days + 15 hours; // 11:00 EDT
        if (t <= block.timestamp) t += 1 days;
        for (uint256 i; i < 7 && !clock.isMintRedeemOpenAt(t); ++i) t += 1 days;
    }
}

contract InvariantsTest is Base {
    Handler handler;

    function setUp() public override {
        super.setUp();
        _mint(alice, l3, 100_000e6);
        _mint(alice, l2, 100_000e6);
        _mint(alice, s1, 100_000e6);
        _mint(alice, s2, 100_000e6);
        handler = new Handler([l3, l2, s1, s2], rebalancer, stkAgg, usdgAgg, swap, usdg, [alice, bob, carol]);
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, carol][i];
            usdg.mint(u, 100_000_000e6);
        }
        targetContract(address(handler));
    }

    /// @notice NAV never negative: every live product keeps collateral value >= debt value (keepers deleverage
    ///         before equity can be exhausted by a single bounded shock).
    function invariant_equityNeverNegative() public view {
        LeveragedToken[4] memory ps = [l3, l2, s1, s2];
        for (uint256 i; i < 4; ++i) {
            if (!ps[i].adapter().hasPosition()) continue;
            (bool ok,) = oracle.tryGetQuotePrice(address(stk), address(usdg));
            if (!ok) continue;
            (, uint256 cv, uint256 dv, uint256 eq) = ps[i].adapter().positionValues();
            assertGe(cv, dv, "collateral < debt");
            assertGt(eq, 0, "equity exhausted");
        }
    }

    /// @notice Leverage is back inside [min, max] after every keeper rebalance sequence.
    function invariant_leverageInsideBandAfterRebalance() public view {
        assertEq(handler.bandViolations(), 0);
    }

    /// @notice Mint/redeem never worsen other holders' per-share position.
    function invariant_mintRedeemFair() public view {
        assertEq(handler.fairnessViolations(), 0);
    }

    /// @notice Shares are fully backed: nobody holds shares of a product without a position.
    function invariant_sharesBacked() public view {
        LeveragedToken[4] memory ps = [l3, l2, s1, s2];
        for (uint256 i; i < 4; ++i) {
            if (ps[i].totalSupply() > ps[i].DEAD_SHARES()) assertTrue(ps[i].adapter().hasPosition());
        }
    }

    function invariant_callSummary() public view {
        handler.calls();
    }
}
