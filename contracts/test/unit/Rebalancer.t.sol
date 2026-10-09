// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";

contract RebalancerTest is Base {
    function setUp() public override {
        super.setUp();
        _mint(alice, l3, 100_000e6);
        _mint(alice, l2, 100_000e6);
        _mint(alice, s1, 100_000e6);
        _mint(alice, s2, 100_000e6);
    }

    function _inBand(LeveragedToken t) internal view returns (bool) {
        uint256 l = _lev(t);
        return l >= t.minLeverage() && l <= t.maxLeverage();
    }

    function test_nothingToDo_inBand_outsideWindow() public {
        (Rebalancer.Mode mode,,,,) = rebalancer.check(address(l3));
        assertEq(uint256(mode), 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        rebalancer.rebalance(address(l3));
    }

    function test_emergency_long_priceUp_increasesToBand() public {
        _setPrice(225e8); // +12.5% => 3x long drops below 2.5x
        assertFalse(_inBand(l3));
        (Rebalancer.Mode mode,, bool inc, uint256 chunk, bool ready) = rebalancer.check(address(l3));
        assertEq(uint256(mode), 2);
        assertTrue(inc);
        assertGt(chunk, 0);
        assertTrue(ready);
        uint256 steps = _rebalanceFully(l3);
        assertGt(steps, 0);
        assertTrue(_inBand(l3));
    }

    function test_emergency_long_priceDown_deleverages() public {
        _setPrice(184e8); // -8%
        assertGt(_lev(l3), 3.6e18);
        _rebalanceFully(l3);
        assertTrue(_inBand(l3));
    }

    function test_emergency_shorts_bothDirections() public {
        _setPrice(216e8); // +8% => 2S above 2.4x
        assertGt(_lev(s2), 2.4e18);
        _rebalanceFully(s2);
        assertTrue(_inBand(s2));
        _setPrice(170e8); // big drop => shorts below band
        assertLt(_lev(s2), 1.7e18);
        _rebalanceFully(s2);
        assertTrue(_inBand(s2));
        _rebalanceFully(s1);
        assertTrue(_inBand(s1));
    }

    function test_daily_walksBackToTarget_andSnapshots() public {
        _setPrice(210e8); // +5% => ~2.74x, inside band
        assertTrue(_inBand(l3));
        _toDailyWindow();
        (Rebalancer.Mode mode,,,,) = rebalancer.check(address(l3));
        assertEq(uint256(mode), 1);
        _rebalanceFully(l3);
        assertApproxEqRel(_lev(l3), 3e18, 0.02e18);
        assertEq(l3.snapshotDay(), clock.tradingDayId(block.timestamp));
        assertGt(l3.snapshotNav(), 0);
        vm.expectRevert(Rebalancer.NothingToDo.selector);
        rebalancer.rebalance(address(l3));
        // next trading day: due again (snapshot only, already at target)
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        (, , , uint256 chunk,) = rebalancer.check(address(l3));
        assertEq(chunk, 0);
        rebalancer.rebalance(address(l3));
        assertEq(l3.snapshotDay(), clock.tradingDayId(block.timestamp));
    }

    function test_twapChunks_respectInterval() public {
        vm.prank(admin);
        rebalancer.setProductConfig(
            address(l3), Rebalancer.Config({maxChunk: 5_000e18, minInterval: 300, toleranceBps: 100, set: true})
        );
        _setPrice(180e8);
        rebalancer.rebalance(address(l3));
        (,,,, bool ready) = rebalancer.check(address(l3));
        assertFalse(ready);
        vm.expectRevert();
        rebalancer.rebalance(address(l3));
        vm.warp(block.timestamp + 300);
        _refreshFeeds();
        rebalancer.rebalance(address(l3));
    }

    function test_urgent_skipsInterval() public {
        vm.prank(admin);
        rebalancer.setProductConfig(
            address(l3), Rebalancer.Config({maxChunk: 1_000e18, minInterval: 3600, toleranceBps: 100, set: true})
        );
        _setPrice(174e8); // -13% => > 4.2x
        assertGt(_lev(l3), 4.2e18);
        rebalancer.rebalance(address(l3));
        (,,,, bool ready) = rebalancer.check(address(l3));
        assertTrue(ready); // still urgent => no wait
        rebalancer.rebalance(address(l3));
    }

    function test_emergency_works24x5_whenMarketClosed() public {
        vm.warp(T_OPEN + 10 hours); // 21:00 ET, after-hours
        _setPrice(184e8);
        assertFalse(clock.isMarketOpen());
        rebalancer.rebalance(address(l3));
    }

    function test_staleOracle_noRebalance() public {
        _setPrice(184e8);
        vm.warp(block.timestamp + 27 hours);
        (Rebalancer.Mode mode,,,,) = rebalancer.check(address(l3));
        assertEq(uint256(mode), 0);
    }

    function test_nonProduct_andEmptyProduct() public {
        (Rebalancer.Mode mode,,,,) = rebalancer.check(address(0xBEEF));
        assertEq(uint256(mode), 0);
        vm.prank(admin);
        LeveragedToken fresh = _create("3L-NEW", true, 3e18, 2.5e18, 3.6e18, longMarket);
        (mode,,,,) = rebalancer.check(address(fresh));
        assertEq(uint256(mode), 0);
    }

    function test_pause_and_config_admin() public {
        vm.prank(guardian);
        rebalancer.pause();
        _setPrice(184e8);
        vm.expectRevert();
        rebalancer.rebalance(address(l3));
        vm.prank(admin);
        rebalancer.unpause();
        rebalancer.rebalance(address(l3));

        vm.startPrank(admin);
        vm.expectRevert(Rebalancer.BadConfig.selector);
        rebalancer.setDefaultConfig(Rebalancer.Config({maxChunk: 0, minInterval: 1, toleranceBps: 1, set: true}));
        vm.expectRevert(Rebalancer.BadConfig.selector);
        rebalancer.setDefaultConfig(Rebalancer.Config({maxChunk: 1, minInterval: 2 hours, toleranceBps: 1, set: true}));
        vm.expectRevert(Rebalancer.BadConfig.selector);
        rebalancer.setDefaultConfig(Rebalancer.Config({maxChunk: 1, minInterval: 1, toleranceBps: 0, set: true}));
        vm.expectRevert(Rebalancer.BadConfig.selector);
        rebalancer.setDefaultConfig(Rebalancer.Config({maxChunk: 1, minInterval: 1, toleranceBps: 3000, set: true}));
        rebalancer.setDefaultConfig(Rebalancer.Config({maxChunk: 1e24, minInterval: 60, toleranceBps: 50, set: false}));
        vm.stopPrank();
        assertEq(rebalancer.configOf(address(l2)).toleranceBps, 50);
    }

    function test_wipedOut_isNotRebalanced() public {
        _setPrice(120e8);
        (Rebalancer.Mode mode,,,,) = rebalancer.check(address(l3));
        assertEq(uint256(mode), 0);
    }

    function test_interestAccrual_raisesLeverage_andIsRebalanced() public {
        irm.setRate(uint256(0.5e18) / 365 days); // 50% APR, exaggerated
        vm.warp(block.timestamp + 120 days);
        _refreshFeeds();
        (uint256 cBefore, uint256 dView) = _raw(l3);
        assertGt(dView, 0);
        assertGt(cBefore, 0);
        assertGt(_lev(l3), 3.6e18); // debt growth pushed leverage up
        _rebalanceFully(l3);
        assertTrue(_inBand(l3));
    }

    // ------------------------------------------------------------------ adapter guards

    function test_adapter_accessControl() public {
        MorphoPositionAdapter a = MorphoPositionAdapter(address(l3.adapter()));
        vm.expectRevert(MorphoPositionAdapter.NotRebalancer.selector);
        a.increaseExposure(1e18);
        vm.expectRevert(MorphoPositionAdapter.NotRebalancer.selector);
        a.decreaseExposure(1e18);
        vm.expectRevert(MorphoPositionAdapter.NotProduct.selector);
        a.openInitial(1, 3e18);
        vm.expectRevert(MorphoPositionAdapter.NotProduct.selector);
        a.mintProportional(1, 1, alice);
        vm.expectRevert(MorphoPositionAdapter.NotProduct.selector);
        a.redeemProportional(1, alice);
        vm.expectRevert(MorphoPositionAdapter.UnexpectedCallback.selector);
        a.onMorphoFlashLoan(0, "");
        vm.prank(address(morpho));
        vm.expectRevert(MorphoPositionAdapter.UnexpectedCallback.selector);
        a.onMorphoFlashLoan(0, "");
        vm.expectRevert(MorphoPositionAdapter.NotAdmin.selector);
        a.setMaxSwapSlippage(10);
        vm.prank(admin);
        vm.expectRevert(MorphoPositionAdapter.BadConfig.selector);
        a.setMaxSwapSlippage(501);
        vm.prank(admin);
        a.setMaxSwapSlippage(200);
        assertEq(a.maxSwapSlippageBps(), 200);
    }

    function test_adapter_productOnlyChecks() public {
        MorphoPositionAdapter a = MorphoPositionAdapter(address(l3.adapter()));
        vm.startPrank(address(l3));
        vm.expectRevert(MorphoPositionAdapter.PositionExists.selector);
        a.openInitial(1e6, 3e18);
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.mintProportional(0, 1, alice);
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.redeemProportional(0, alice);
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.redeemProportional(2e18, alice);
        vm.stopPrank();
        vm.startPrank(address(rebalancer));
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.increaseExposure(0);
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.decreaseExposure(0);
        vm.stopPrank();
    }

    function test_adapter_emptyProductGuards() public {
        vm.prank(admin);
        LeveragedToken fresh = _create("2S-NEW", false, 2e18, 1.7e18, 2.4e18, shortMarket);
        MorphoPositionAdapter a = MorphoPositionAdapter(address(fresh.adapter()));
        assertFalse(a.hasPosition());
        (uint256 x, uint256 c, uint256 d, uint256 e) = a.positionValues();
        assertEq(x + c + d + e, 0);
        assertEq(a.leverage(), 0);
        assertEq(a.currentLtv(), 0);
        assertEq(a.liquidationLtv(), 0.86e18);
        assertEq(a.marketParams().lltv, 0.86e18);
        vm.startPrank(address(fresh));
        vm.expectRevert(MorphoPositionAdapter.ZeroAmount.selector);
        a.openInitial(0, 2e18);
        vm.expectRevert(MorphoPositionAdapter.BadConfig.selector);
        a.openInitial(1e6, 11e18);
        vm.expectRevert(MorphoPositionAdapter.NoPosition.selector);
        a.mintProportional(1e6, 1e16, alice);
        vm.stopPrank();
        vm.prank(address(rebalancer));
        vm.expectRevert(MorphoPositionAdapter.NoPosition.selector);
        a.decreaseExposure(1e18);
    }

    function test_adapter_slippageGuard_blocksBadExecution() public {
        swap.setSlippage(300); // venue 3% worse than oracle, adapter allows 1%
        vm.prank(bob);
        vm.expectRevert();
        l3.mint(10_000e6, 0, block.timestamp);
        _setPrice(184e8);
        vm.expectRevert();
        rebalancer.rebalance(address(l3));
    }

    function test_mint_whenMarketAboveOracle_isRefundedOrReverts() public {
        // market 0.5% above oracle: still within 1% buffer/slippage, minter pays the real cost
        swap.setMarketOffset(50);
        uint256 before = usdg.balanceOf(bob);
        uint256 shares = _mint(bob, l3, 10_000e6);
        assertGt(shares, 0);
        assertLe(before - usdg.balanceOf(bob), 10_000e6);
        // market 3% above oracle: the mint cannot be filled within maxIn and reverts (no value taken)
        swap.setMarketOffset(300);
        vm.prank(bob);
        vm.expectRevert();
        l3.mint(10_000e6, 0, block.timestamp);
    }

    function test_liquidation_reducesNav_butNeverNegative() public {
        _setPrice(152e8); // -24% on a 3x long, beyond the 0.86 LLTV
        MorphoPositionAdapter a = MorphoPositionAdapter(address(l3.adapter()));
        (uint256 c,) = a.positionRaw();
        usdg.mint(address(this), 10_000_000e6);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.liquidate(longMarket, address(a), c / 4);
        (,, uint256 dv, uint256 eq) = a.positionValues();
        assertGe(eq, 0);
        assertGt(dv, 0);
    }
}
