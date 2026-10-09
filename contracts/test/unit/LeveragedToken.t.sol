// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IComplianceRegistry, IPositionAdapter} from "../../src/interfaces/ITriplex.sol";

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
        assertEq(usdg.balanceOf(address(feeCollector)), 9.99e6); // 10 bps of the 9,990 used (budget = 10,000 - max fee)
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
        assertGt(paid, 4_800e6); // ~3% buffer for a 3x product is refunded
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

    // ------------------------------------------------------------------ gating

    function test_mintRedeem_blockedWhenMarketClosed() public {
        uint256 shares = _mint(alice, l3, 1_000e6);
        vm.warp(T_OPEN + 4 days); // Saturday
        _refreshFeeds();
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.MarketClosed.selector);
        l3.mint(1_000e6, 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.MarketClosed.selector);
        l3.redeem(shares, 0, block.timestamp);
    }

    function test_deadline() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.Expired.selector);
        l3.mint(1_000e6, 0, block.timestamp - 1);
    }

    function test_slippage_minShares_minOut() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.Slippage.selector);
        l3.mint(1_000e6, 2_000e18, block.timestamp);
        uint256 shares = _mint(alice, l3, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.Slippage.selector);
        l3.redeem(shares, 2_000e6, block.timestamp);
    }

    function test_zeroAndMinimums() public {
        vm.startPrank(alice);
        vm.expectRevert(LeveragedToken.ZeroAmount.selector);
        l3.mint(0, 0, block.timestamp);
        vm.expectRevert(LeveragedToken.ZeroAmount.selector);
        l3.mint(0.5e6, 0, block.timestamp); // below minMintQuote
        vm.expectRevert(LeveragedToken.ZeroAmount.selector);
        l3.redeem(0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_pause_guardianOnly_unpause_adminOnly() public {
        vm.expectRevert(LeveragedToken.NotGuardian.selector);
        l3.pause();
        vm.prank(guardian);
        l3.pause();
        vm.prank(alice);
        vm.expectRevert();
        l3.mint(1_000e6, 0, block.timestamp);
        vm.prank(guardian);
        vm.expectRevert(LeveragedToken.NotAdmin.selector);
        l3.unpause();
        vm.prank(admin);
        l3.unpause();
        _mint(alice, l3, 1_000e6);
    }

    function test_compliance_offByDefault_thenGates() public {
        _mint(alice, l3, 1_000e6);
        vm.prank(admin);
        compliance.setEnabled(true, false);
        vm.prank(bob);
        vm.expectRevert(LeveragedToken.NotAllowed.selector);
        l3.mint(1_000e6, 0, block.timestamp);
        // redeem not gated unless gateRedeem
        uint256 sh = l3.balanceOf(alice);
        vm.prank(alice);
        l3.redeem(sh / 2, 0, block.timestamp);
        vm.prank(admin);
        compliance.setAllowed(bob, true);
        _mint(bob, l3, 1_000e6);
        vm.prank(admin);
        compliance.setEnabled(true, true);
        vm.prank(alice);
        vm.expectRevert(LeveragedToken.NotAllowed.selector);
        l3.redeem(sh / 4, 0, block.timestamp);
        // registry removed entirely => open
        vm.prank(admin);
        factory.setComplianceRegistry(IComplianceRegistry(address(0)));
        vm.prank(alice);
        l3.redeem(sh / 4, 0, block.timestamp);
    }

    function test_supplyCap() public {
        vm.prank(admin);
        l3.setLimits(5_000e18, 1e6, 100);
        _mint(alice, l3, 4_000e6);
        vm.prank(bob);
        vm.expectRevert(LeveragedToken.CapExceeded.selector);
        l3.mint(2_000e6, 0, block.timestamp);
    }

    // ------------------------------------------------------------------ fees

    function test_mgmtFee_streamsAtRate_andCapIsEnforced() public {
        _mint(alice, l3, 10_000e6);
        uint256 supply0 = l3.totalSupply();
        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        assertGt(l3.pendingFeeShares(), 0);
        uint256 minted = l3.accrueManagementFee();
        // fee shares / new supply == 1% (100 bps)
        assertApproxEqRel(minted * 1e18 / (supply0 + minted), 0.01e18, 0.0001e18);
        assertEq(l3.balanceOf(address(feeCollector)), minted);
        assertEq(l3.accrueManagementFee(), 0); // same block
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        l3.setFees(10, 10, 301);
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        l3.setFees(101, 10, 100);
        vm.prank(admin);
        l3.setFees(0, 0, 300);
        assertEq(l3.mgmtFeeBps(), 300);
        vm.expectRevert(LeveragedToken.NotAdmin.selector);
        l3.setFees(0, 0, 0);
    }

    function test_mgmtFee_extremeElapsedIsBounded() public {
        _mint(alice, l3, 10_000e6);
        vm.prank(admin);
        l3.setFees(10, 10, 300);
        vm.warp(block.timestamp + 40 * 365 days); // > 1/rate years: clamps instead of overflowing
        assertGt(l3.pendingFeeShares(), 0);
    }

    function test_navPerShare_emptyIsOne() public view {
        assertEq(l3.navPerShare(), 1e18);
        assertEq(l3.pendingFeeShares(), 0);
    }

    function test_stakerDiscount() public {
        MockERC20 trpx = new MockERC20("Triplex", "TRPX", 18);
        vm.startPrank(admin);
        hooks.setProjectToken(address(trpx));
        hooks.setTiers(1_000e18, 2_500, 10_000e18, 5_000);
        vm.stopPrank();
        trpx.mint(alice, 20_000e18);
        vm.startPrank(alice);
        trpx.approve(address(hooks), type(uint256).max);
        hooks.stake(10_000e18);
        vm.stopPrank();
        _mint(alice, l3, 10_000e6);
        uint256 f1 = usdg.balanceOf(address(feeCollector));
        assertApproxEqAbs(f1, 5e6, 0.01e6); // 50% off 10 bps
        _mint(bob, l3, 10_000e6);
        assertApproxEqRel(usdg.balanceOf(address(feeCollector)) - f1, 2 * f1, 0.04e18); // full fee, ~97% used
    }

    function test_feeCollectorRedeemIsFeeFree() public {
        _mint(alice, l3, 10_000e6);
        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();
        l3.accrueManagementFee();
        uint256 feeBefore = usdg.balanceOf(address(feeCollector));
        vm.prank(keeper);
        uint256 out = feeCollector.harvest(address(l3), 0, block.timestamp);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(address(feeCollector)), feeBefore + out);
        assertEq(l3.balanceOf(address(feeCollector)), 0);
    }

    function test_productDead_afterWipeout() public {
        _mint(alice, l3, 10_000e6);
        _setPrice(120e8); // -40% => 3x long equity gone, Morpho position underwater
        assertEq(_equity(l3), 0);
        assertEq(_lev(l3), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(LeveragedToken.ProductDead.selector);
        l3.mint(1_000e6, 0, block.timestamp);
        assertEq(l3.navPerShare(), 0);
    }

    function test_setLeverageBand_onlyFactory() public {
        vm.expectRevert(LeveragedToken.NotAdmin.selector);
        l3.setLeverageBand(3e18, 2e18, 4e18);
        vm.prank(admin);
        factory.setLeverageBand(address(l3), 3e18, 2.6e18, 3.5e18);
        assertEq(l3.minLeverage(), 2.6e18);
    }

    function test_setLimits_validation() public {
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        l3.setLimits(0, 0, 501);
    }

    function test_initialize_cannotReinit() public {
        LeveragedToken.InitParams memory p;
        IPositionAdapter a = l3.adapter();
        vm.expectRevert();
        l3.initialize(factory, a, p);
    }
}
