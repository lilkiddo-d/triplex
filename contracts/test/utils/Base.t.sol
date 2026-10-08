// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/external/IMorpho.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/IChainlink.sol";
import {
    IOracleAdapter, IMarketClock, ISwapAdapter, IProjectTokenHooks, IComplianceRegistry
} from "../../src/interfaces/ITriplex.sol";
import {LeveragedTokenFactory} from "../../src/LeveragedTokenFactory.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {NAVCalculator} from "../../src/NAVCalculator.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {Timelock} from "../../src/Timelock.sol";
import {MockERC20, MockAggregator, MockSwapAdapter} from "../mocks/Mocks.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../mocks/MockMorpho.sol";

abstract contract Base is Test {
    // Tue 2026-10-06 15:00 UTC = 11:00 EDT (regular session)
    uint256 internal constant T_OPEN = 1_791_298_800;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lender = makeAddr("lender");

    MockERC20 internal usdg;
    MockERC20 internal stk;
    MockAggregator internal usdgAgg;
    MockAggregator internal stkAgg;
    MockMorpho internal morpho;
    MockIrm internal irm;
    MockMorphoOracle internal longOracle;
    MockMorphoOracle internal shortOracle;
    MockSwapAdapter internal swap;

    OracleAdapter internal oracle;
    MarketClock internal clock;
    ComplianceRegistry internal compliance;
    ProjectTokenHooks internal hooks;
    LeveragedTokenFactory internal factory;
    Rebalancer internal rebalancer;
    FeeCollector internal feeCollector;
    NAVCalculator internal nav;

    LeveragedToken internal l3;
    LeveragedToken internal l2;
    LeveragedToken internal s1;
    LeveragedToken internal s2;

    MarketParams internal longMarket;
    MarketParams internal shortMarket;

    function setUp() public virtual {
        vm.warp(T_OPEN);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stk = new MockERC20("Test Stock", "TSTK", 18);
        usdgAgg = new MockAggregator(8, 1e8);
        stkAgg = new MockAggregator(8, 200e8);

        morpho = new MockMorpho();
        irm = new MockIrm();
        morpho.enableIrm(address(irm));
        longOracle = new MockMorphoOracle(stkAgg, usdgAgg, 18, 6);
        shortOracle = new MockMorphoOracle(usdgAgg, stkAgg, 6, 18);
        longMarket = MarketParams(address(usdg), address(stk), address(longOracle), address(irm), 0.86e18);
        shortMarket = MarketParams(address(stk), address(usdg), address(shortOracle), address(irm), 0.86e18);

        swap = new MockSwapAdapter();
        swap.setToken(address(usdg), usdgAgg, 6);
        swap.setToken(address(stk), stkAgg, 18);

        oracle = new OracleAdapter(admin);
        vm.startPrank(admin);
        oracle.setFeed(address(usdg), AggregatorV3Interface(address(usdgAgg)), 26 hours);
        oracle.setFeed(address(stk), AggregatorV3Interface(address(stkAgg)), 26 hours);
        vm.stopPrank();

        clock = new MarketClock(admin, guardian, new uint256[](0), new uint256[](0));
        compliance = new ComplianceRegistry(admin, admin);
        hooks = new ProjectTokenHooks(admin, guardian, IERC20(address(usdg)));

        LeveragedToken tokenImpl = new LeveragedToken();
        MorphoPositionAdapter adapterImpl = new MorphoPositionAdapter(IMorpho(address(morpho)));
        factory = new LeveragedTokenFactory(admin, guardian, address(usdg), address(tokenImpl), address(adapterImpl));
        feeCollector = new FeeCollector(admin, keeper, factory, IERC20(address(usdg)), treasury);
        rebalancer = new Rebalancer(
            admin, guardian, factory, Rebalancer.Config({maxChunk: 50_000e18, minInterval: 120, toleranceBps: 200, set: true})
        );
        nav = new NAVCalculator(factory);

        vm.startPrank(admin);
        factory.setOracle(IOracleAdapter(address(oracle)));
        factory.setMarketClock(IMarketClock(address(clock)));
        factory.setSwapAdapter(ISwapAdapter(address(swap)));
        factory.setRebalancer(address(rebalancer));
        factory.setFeeCollector(address(feeCollector));
        factory.setProjectTokenHooks(IProjectTokenHooks(address(hooks)));
        factory.setComplianceRegistry(IComplianceRegistry(address(compliance)));
        hooks.setFeeCollector(address(feeCollector));

        l3 = _create("3L-TSTK", true, 3e18, 2.5e18, 3.6e18, longMarket);
        l2 = _create("2L-TSTK", true, 2e18, 1.7e18, 2.4e18, longMarket);
        s1 = _create("1S-TSTK", false, 1e18, 0.8e18, 1.25e18, shortMarket);
        s2 = _create("2S-TSTK", false, 2e18, 1.7e18, 2.4e18, shortMarket);
        vm.stopPrank();

        // venue liquidity
        usdg.mint(lender, 100_000_000e6);
        stk.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        usdg.approve(address(morpho), type(uint256).max);
        stk.approve(address(morpho), type(uint256).max);
        morpho.supply(longMarket, 50_000_000e6, 0, lender, "");
        morpho.supply(shortMarket, 500_000e18, 0, lender, "");
        vm.stopPrank();
        // flash-loan float (Morpho holds all markets' tokens in one contract)
        usdg.mint(address(morpho), 50_000_000e6);

        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, carol][i];
            usdg.mint(u, 10_000_000e6);
            vm.startPrank(u);
            usdg.approve(address(l3), type(uint256).max);
            usdg.approve(address(l2), type(uint256).max);
            usdg.approve(address(s1), type(uint256).max);
            usdg.approve(address(s2), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _create(string memory sym, bool isLong, uint256 t, uint256 mn, uint256 mx, MarketParams memory m)
        internal
        returns (LeveragedToken)
    {
        (address p,) = factory.createProduct(
            LeveragedTokenFactory.CreateParams({
                name: string.concat("Triplex ", sym),
                symbol: sym,
                underlying: address(stk),
                isLong: isLong,
                targetLeverage: t,
                minLeverage: mn,
                maxLeverage: mx,
                market: m,
                maxSwapSlippageBps: 100,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                mgmtFeeBps: 100,
                supplyCapEquity: 0,
                minMintQuote: 1e6,
                mintBufferBps: 100
            })
        );
        return LeveragedToken(p);
    }

    // ------------------------------------------------------------------ helpers

    function _mint(address u, LeveragedToken t, uint256 amount) internal returns (uint256 shares) {
        vm.prank(u);
        shares = t.mint(amount, 0, block.timestamp);
    }

    function _redeem(address u, LeveragedToken t, uint256 shares) internal returns (uint256 out) {
        vm.prank(u);
        out = t.redeem(shares, 0, block.timestamp);
    }

    /// @dev sets the stock price in USD (8-dec Chainlink units) and refreshes the feed timestamp
    function _setPrice(int256 p8) internal {
        stkAgg.set(p8);
        usdgAgg.set(usdgAgg.answer());
    }

    function _lev(LeveragedToken t) internal view returns (uint256) {
        return t.adapter().leverage();
    }

    function _equity(LeveragedToken t) internal view returns (uint256 e) {
        (,,, e) = t.adapter().positionValues();
    }

    function _raw(LeveragedToken t) internal view returns (uint256 c, uint256 d) {
        return MorphoPositionAdapter(address(t.adapter())).positionRaw();
    }

    /// @dev warps into the daily rebalance window of the current ET day (15:50 EDT = 19:50 UTC on T_OPEN's day)
    function _toDailyWindow() internal {
        uint256 dayStartUtc = (block.timestamp / 1 days) * 1 days;
        vm.warp(dayStartUtc + 19 hours + 50 minutes);
        _refreshFeeds();
    }

    function _refreshFeeds() internal {
        stkAgg.set(stkAgg.answer());
        usdgAgg.set(usdgAgg.answer());
    }

    /// @dev runs the rebalancer until it reports nothing to do (bounded)
    function _rebalanceFully(LeveragedToken t) internal returns (uint256 steps) {
        for (uint256 i; i < 200; ++i) {
            (Rebalancer.Mode mode,,,, bool ready) = rebalancer.check(address(t));
            if (mode == Rebalancer.Mode.None) return steps;
            if (!ready) {
                vm.warp(block.timestamp + 121);
                _refreshFeeds();
            }
            rebalancer.rebalance(address(t));
            steps++;
        }
    }
}
