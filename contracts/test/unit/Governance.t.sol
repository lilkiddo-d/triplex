// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {LeveragedTokenFactory} from "../../src/LeveragedTokenFactory.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {Timelock} from "../../src/Timelock.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {NAVCalculator} from "../../src/NAVCalculator.sol";
import {MarketParams} from "../../src/interfaces/external/IMorpho.sol";
import {
    IOracleAdapter, IMarketClock, ISwapAdapter, IProjectTokenHooks
} from "../../src/interfaces/ITriplex.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract GovernanceTest is Base {
    MockERC20 trpx;

    function setUp() public override {
        super.setUp();
        trpx = new MockERC20("Triplex", "TRPX", 18); // test-only mock of the externally launched token
        trpx.mint(alice, 1_000_000e18);
        trpx.mint(bob, 1_000_000e18);
        vm.prank(alice);
        trpx.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        trpx.approve(address(hooks), type(uint256).max);
    }

    // ------------------------------------------------------------------ project token hooks

    function test_tokenFeaturesDisabledUntilSet() public {
        assertFalse(hooks.isActive());
        assertEq(hooks.feeDiscountBps(alice), 0);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.NotActive.selector);
        hooks.stake(1e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.NotActive.selector);
        hooks.requestUnstake(1e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.NotActive.selector);
        hooks.withdraw();
        // protocol fully works without token: fees all go to treasury
        _mint(alice, l3, 10_000e6);
        (uint256 toStakers, uint256 toTreasury) = feeCollector.distribute();
        assertEq(toStakers, 0);
        assertGt(toTreasury, 0);
        assertEq(usdg.balanceOf(treasury), toTreasury);
    }

    function test_setProjectToken_onceOnlyAdmin_validates() public {
        vm.expectRevert();
        hooks.setProjectToken(address(trpx));
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setProjectToken(alice); // EOA
        hooks.setProjectToken(address(trpx));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        hooks.setProjectToken(address(usdg));
        vm.stopPrank();
        assertTrue(hooks.isActive());
        assertEq(address(hooks.projectToken()), address(trpx));
    }

    function test_setProjectToken_viaTimelock_48h() public {
        address[] memory props = new address[](1);
        props[0] = admin;
        address[] memory execs = new address[](1);
        execs[0] = address(0);
        Timelock tl = new Timelock(48 hours, props, execs);
        vm.startPrank(admin);
        hooks.grantRole(0x00, address(tl));
        hooks.renounceRole(0x00, admin);
        vm.stopPrank();

        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(trpx)));
        vm.prank(admin);
        vm.expectRevert(); // below 48h
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32("trpx"), 47 hours);
        vm.prank(admin);
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32("trpx"), 48 hours);
        vm.expectRevert();
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32("trpx"));
        vm.warp(block.timestamp + 48 hours);
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32("trpx")); // open executor
        assertTrue(hooks.isActive());
    }

    function test_timelock_constructorRejectsShortDelay() public {
        address[] memory a = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayBelowFloor.selector, uint256(1 hours)));
        new Timelock(1 hours, a, a);
    }

    function test_timelock_floorCannotBeUndercut() public {
        address[] memory a = new address[](0);
        Timelock tl = new Timelock(72 hours, a, a);
        assertEq(tl.getMinDelay(), 72 hours);
        // a self-governed delay reduction still cannot undercut the 48h floor
        vm.prank(address(tl));
        tl.updateDelay(1);
        assertEq(tl.getMinDelay(), 48 hours);
    }

    function test_staking_rewards_cooldown_discounts() public {
        vm.startPrank(admin);
        hooks.setProjectToken(address(trpx));
        hooks.setTiers(1_000e18, 2_500, 10_000e18, 5_000);
        vm.stopPrank();

        vm.prank(alice);
        hooks.stake(30_000e18);
        vm.prank(bob);
        hooks.stake(10_000e18);
        assertEq(hooks.totalStaked(), 40_000e18);
        assertEq(hooks.feeDiscountBps(alice), 5_000);
        assertEq(hooks.feeDiscountBps(carol), 0);

        _mint(carol, l3, 100_000e6);
        uint256 fees = usdg.balanceOf(address(feeCollector));
        (uint256 toStakers, uint256 toTreasury) = feeCollector.distribute();
        assertEq(toStakers, fees / 2);
        assertEq(toTreasury, fees - fees / 2);
        assertApproxEqAbs(hooks.earned(alice), toStakers * 3 / 4, 2);
        assertApproxEqAbs(hooks.earned(bob), toStakers / 4, 2);

        vm.prank(alice);
        uint256 claimed = hooks.claim();
        assertEq(usdg.balanceOf(alice), 10_000_000e6 + claimed);
        vm.prank(alice);
        assertEq(hooks.claim(), 0);

        // unstake: stops discount immediately, locked for cooldown
        vm.prank(bob);
        hooks.requestUnstake(9_500e18);
        assertEq(hooks.feeDiscountBps(bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        hooks.withdraw();
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        hooks.withdraw();
        assertEq(trpx.balanceOf(bob), 1_000_000e18 - 500e18);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.withdraw();
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.requestUnstake(1_000e18);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
    }

    function test_hooks_adminAndGuards() public {
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setTiers(1, 8_000, 2, 9_000);
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setTiers(10, 100, 5, 200);
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setUnstakeCooldown(31 days);
        hooks.setUnstakeCooldown(1 days);
        vm.expectRevert(ProjectTokenHooks.BadConfig.selector);
        hooks.setFeeCollector(address(0));
        hooks.setProjectToken(address(trpx));
        vm.stopPrank();

        vm.expectRevert(ProjectTokenHooks.NotFeeCollector.selector);
        hooks.notifyReward(1);
        vm.prank(address(feeCollector));
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        hooks.notifyReward(1);
        vm.prank(alice);
        hooks.stake(1e18);
        vm.prank(address(feeCollector));
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.notifyReward(0);

        vm.prank(guardian);
        hooks.pause();
        vm.prank(alice);
        vm.expectRevert();
        hooks.stake(1e18);
        vm.prank(admin);
        hooks.unpause();
        vm.prank(alice);
        hooks.stake(1e18);
        assertEq(hooks.stakedBalance(alice), 2e18);
    }

    // ------------------------------------------------------------------ fee collector

    function test_feeCollector_admin() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.BadConfig.selector);
        feeCollector.setTreasury(address(0));
        feeCollector.setTreasury(bob);
        vm.expectRevert(FeeCollector.BadConfig.selector);
        feeCollector.setStakerShareBps(10_001);
        feeCollector.setStakerShareBps(10_000);
        vm.stopPrank();
        (uint256 a, uint256 b) = feeCollector.distribute();
        assertEq(a + b, 0);
        vm.expectRevert();
        feeCollector.harvest(address(l3), 0, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(FeeCollector.BadConfig.selector);
        feeCollector.harvest(address(0xBEEF), 0, block.timestamp);
        vm.prank(keeper);
        assertEq(feeCollector.harvest(address(l3), 0, block.timestamp), 0);
        vm.expectRevert(FeeCollector.BadConfig.selector);
        new FeeCollector(admin, keeper, factory, IERC20(address(usdg)), address(0));
    }

    // ------------------------------------------------------------------ factory

    function test_validateBand() public view {
        factory.validateBand(true, 3e18, 2.5e18, 3.6e18, 0.86e18);
        factory.validateBand(false, 2e18, 1.7e18, 2.4e18, 0.86e18);
        factory.validateBand(false, 1e18, 0.8e18, 1.25e18, 0.625e18);
    }

    function test_validateBand_reverts() public {
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(true, 3e18, 2.5e18, 3.6e18, 0.625e18); // 3x long needs > 0.77 LLTV
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(false, 2e18, 1.7e18, 2.4e18, 0.625e18); // 2x short needs > 0.756
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(true, 3e18, 3e18, 3.6e18, 0.86e18);
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(true, 6e18, 5e18, 7e18, 0.99e18);
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(true, 1.5e18, 1e18, 2e18, 0.86e18); // long min <= 1x
        vm.expectRevert(LeveragedTokenFactory.BadBand.selector);
        factory.validateBand(false, 1e18, 0.4e18, 1.2e18, 0.86e18);
    }

    function test_factory_modulesAndRoles() public {
        vm.startPrank(admin);
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.setOracle(IOracleAdapter(address(0)));
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.setMarketClock(IMarketClock(address(0)));
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.setSwapAdapter(ISwapAdapter(address(0)));
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.setRebalancer(address(0));
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
        factory.setProjectTokenHooks(IProjectTokenHooks(address(0)));
        vm.expectRevert(LeveragedTokenFactory.NotProduct.selector);
        factory.setLeverageBand(alice, 3e18, 2.5e18, 3.6e18);
        vm.stopPrank();
        assertEq(factory.productCount(), 4);
        assertEq(factory.productAt(0), address(l3));
        assertEq(factory.allProducts().length, 4);
        assertTrue(factory.isProduct(address(s2)));
        assertTrue(factory.hasRole(Constants.GUARDIAN_ROLE, guardian));

        // with hooks removed, fees are plain and distribute sends all to treasury
        _mint(alice, l3, 1_000e6);
        (uint256 st,) = feeCollector.distribute();
        assertEq(st, 0);

        vm.expectRevert();
        factory.createProduct(_params("X", longMarket));
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        new LeveragedTokenFactory(address(0), guardian, address(usdg), address(1), address(1));
    }

    function test_factory_rejectsMismatchedMarket() public {
        vm.prank(admin);
        vm.expectRevert(MorphoPositionAdapter.BadMarket.selector);
        factory.createProduct(_params("BAD", shortMarket)); // long product on a short market
        LeveragedTokenFactory.CreateParams memory p = _params("BAD2", longMarket);
        p.maxSwapSlippageBps = 600;
        vm.prank(admin);
        vm.expectRevert(MorphoPositionAdapter.BadConfig.selector);
        factory.createProduct(p);
        p = _params("BAD3", longMarket);
        p.mgmtFeeBps = 301;
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        factory.createProduct(p);
        p = _params("BAD4", longMarket);
        p.mintFeeBps = 101;
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        factory.createProduct(p);
        p = _params("BAD5", longMarket);
        p.mintBufferBps = 501;
        vm.prank(admin);
        vm.expectRevert(LeveragedToken.BadConfig.selector);
        factory.createProduct(p);
        p = _params("BAD6", longMarket);
        p.underlying = address(0);
        vm.prank(admin);
        vm.expectRevert(LeveragedTokenFactory.ZeroAddress.selector);
        factory.createProduct(p);
        // the market is created by the first adapter if missing
        MarketParams memory fresh = longMarket;
        fresh.lltv = 0.625e18;
        p = _params("2L-625", fresh);
        p.targetLeverage = 2e18;
        p.minLeverage = 1.5e18;
        p.maxLeverage = 2.2e18;
        vm.prank(admin);
        factory.createProduct(p);
    }

    function _params(string memory sym, MarketParams memory m)
        internal
        view
        returns (LeveragedTokenFactory.CreateParams memory)
    {
        return LeveragedTokenFactory.CreateParams({
            name: sym,
            symbol: sym,
            underlying: address(stk),
            isLong: true,
            targetLeverage: 3e18,
            minLeverage: 2.5e18,
            maxLeverage: 3.6e18,
            market: m,
            maxSwapSlippageBps: 100,
            mintFeeBps: 10,
            redeemFeeBps: 10,
            mgmtFeeBps: 100,
            supplyCapEquity: 0,
            minMintQuote: 1e6,
            mintBufferBps: 300
        });
    }

    // ------------------------------------------------------------------ compliance

    function test_compliance_unit() public {
        assertTrue(compliance.isAllowed(alice, Constants.ACTION_MINT));
        vm.prank(admin);
        compliance.setEnabled(true, false);
        assertFalse(compliance.isAllowed(alice, Constants.ACTION_MINT));
        assertTrue(compliance.isAllowed(alice, Constants.ACTION_REDEEM));
        vm.prank(admin);
        compliance.setAllowed(alice, true);
        assertTrue(compliance.isAllowed(alice, Constants.ACTION_MINT));
        vm.expectRevert();
        compliance.setAllowed(bob, true);
    }

    // ------------------------------------------------------------------ NAV calculator

    function test_navCalculator_views() public {
        _mint(alice, l3, 10_000e6);
        _mint(alice, s2, 10_000e6);
        NAVCalculator.ProductView memory v = nav.getProduct(address(l3));
        assertTrue(v.priceOk);
        assertEq(v.symbol, "3L-TSTK");
        assertEq(v.underlyingSymbol, "TSTK");
        assertApproxEqRel(v.leverage, 3e18, 0.02e18);
        assertApproxEqRel(v.ltv, 0.6667e18, 0.02e18);
        assertEq(v.lltv, 0.86e18);
        assertEq(v.dailyReturn, 0);

        // daily performance after a close snapshot and a +1% move
        _toDailyWindow();
        _rebalanceFully(l3);
        _setPrice(202e8);
        v = nav.getProduct(address(l3));
        assertApproxEqRel(uint256(v.underlyingDailyReturn), 0.01e18, 0.01e18);
        assertApproxEqRel(uint256(v.dailyReturn), 0.03e18, 0.05e18);

        NAVCalculator.ProductView[] memory all = nav.getAllProducts();
        assertEq(all.length, 4);
        address[] memory ps = new address[](2);
        ps[0] = address(l2);
        ps[1] = address(s1);
        assertEq(nav.getProducts(ps).length, 2);
        // empty product: leverage 0
        assertEq(all[1].leverage, 0);

        // oracle down: no revert, priceOk=false
        vm.warp(block.timestamp + 30 hours);
        v = nav.getProduct(address(l3));
        assertFalse(v.priceOk);
        assertEq(v.navPerShare, 0);
    }
}
