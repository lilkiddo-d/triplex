// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/IChainlink.sol";
import {IPriceSource} from "../../src/interfaces/ITriplex.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {UniswapV3TwapPriceSource} from "../../src/adapters/UniswapV3TwapPriceSource.sol";
import {MockAggregator, MockPriceSource, MockERC20} from "../mocks/Mocks.sol";

contract MockPool {
    address public token0;
    address public token1;
    int56 public cumDelta;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setTick(int24 tick, uint32 window) external {
        cumDelta = int56(tick) * int56(uint56(window));
    }

    function observe(uint32[] calldata) external view returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](2);
        s = new uint160[](2);
        c[0] = 1_000_000;
        c[1] = 1_000_000 + cumDelta;
    }
}

contract OracleAdapterTest is Test {
    OracleAdapter oracle;
    MockAggregator stkAgg;
    MockAggregator usdAgg;
    MockERC20 stk;
    MockERC20 usd;
    address admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_800_000_000);
        stk = new MockERC20("S", "S", 18);
        usd = new MockERC20("U", "U", 6);
        stkAgg = new MockAggregator(8, 250e8);
        usdAgg = new MockAggregator(8, 0.99e8);
        oracle = new OracleAdapter(admin);
        vm.startPrank(admin);
        oracle.setFeed(address(stk), AggregatorV3Interface(address(stkAgg)), 1 hours);
        oracle.setFeed(address(usd), AggregatorV3Interface(address(usdAgg)), 1 hours);
        vm.stopPrank();
    }

    function test_prices() public view {
        assertEq(oracle.getPrice(address(stk)), 250e18);
        assertApproxEqAbs(oracle.getQuotePrice(address(stk), address(usd)), uint256(250e18) * 100 / 99, 1);
        (bool ok, uint256 p) = oracle.tryGetQuotePrice(address(stk), address(usd));
        assertTrue(ok);
        assertGt(p, 0);
    }

    function test_decimalsAbove18() public {
        MockAggregator a = new MockAggregator(20, 5e20);
        vm.prank(admin);
        oracle.setFeed(address(0xBEEF), AggregatorV3Interface(address(a)), 1 hours);
        assertEq(oracle.getPrice(address(0xBEEF)), 5e18);
    }

    function test_reverts_stale_invalid_unset() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert();
        oracle.getPrice(address(stk));
        (bool ok,) = oracle.tryGetQuotePrice(address(stk), address(usd));
        assertFalse(ok);

        stkAgg.set(0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(stk), int256(0)));
        oracle.getPrice(address(stk));

        stkAgg.set(1e8);
        stkAgg.setRounds(5, 4);
        vm.expectRevert();
        oracle.getPrice(address(stk));

        stkAgg.setRounds(5, 5);
        stkAgg.setUpdatedAt(block.timestamp + 10); // future timestamp
        vm.expectRevert();
        oracle.getPrice(address(stk));

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedNotSet.selector, address(1)));
        oracle.getPrice(address(1));
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.prank(admin);
        oracle.setSequencerUptimeFeed(AggregatorV3Interface(address(seq)), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerGracePeriod.selector);
        oracle.getPrice(address(stk));
        seq.setStartedAt(block.timestamp - 2 hours);
        assertEq(oracle.getPrice(address(stk)), 250e18);
        seq.set(1);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(stk));
        vm.prank(admin);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setSequencerUptimeFeed(AggregatorV3Interface(address(seq)), 2 days);
    }

    function test_deviation() public {
        MockPriceSource src = new MockPriceSource();
        uint256 primary = oracle.getQuotePrice(address(stk), address(usd));
        src.set(primary * 102 / 100, false);
        vm.prank(admin);
        oracle.setDeviation(address(stk), address(usd), IPriceSource(address(src)), 300, false);
        assertEq(oracle.getQuotePrice(address(stk), address(usd)), primary); // 2% < 3%
        src.set(primary * 105 / 100, false);
        vm.expectRevert();
        oracle.getQuotePrice(address(stk), address(usd));
        // unavailable secondary: lenient passes, strict fails
        src.set(0, true);
        assertEq(oracle.getQuotePrice(address(stk), address(usd)), primary);
        src.set(0, false);
        assertEq(oracle.getQuotePrice(address(stk), address(usd)), primary);
        vm.prank(admin);
        oracle.setDeviation(address(stk), address(usd), IPriceSource(address(src)), 300, true);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.SecondaryUnavailable.selector, address(stk)));
        oracle.getQuotePrice(address(stk), address(usd));
        src.set(0, true);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.SecondaryUnavailable.selector, address(stk)));
        oracle.getQuotePrice(address(stk), address(usd));
    }

    function test_configValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setFeed(address(0), AggregatorV3Interface(address(stkAgg)), 1 hours);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setFeed(address(stk), AggregatorV3Interface(address(stkAgg)), 10);
        MockAggregator big = new MockAggregator(40, 1);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setFeed(address(stk), AggregatorV3Interface(address(big)), 1 hours);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setDeviation(address(stk), address(usd), IPriceSource(address(1)), 3_000, false);
        vm.expectRevert(OracleAdapter.BadConfig.selector);
        oracle.setDeviation(address(stk), address(usd), IPriceSource(address(1)), 0, false);
        vm.stopPrank();
        vm.expectRevert();
        oracle.setFeed(address(stk), AggregatorV3Interface(address(stkAgg)), 1 hours);
    }

    // ------------------------------------------------------------------ TWAP source

    function test_twap_tickMath() public {
        UniswapV3TwapPriceSource t = new UniswapV3TwapPriceSource(admin);
        assertEq(t.tickToPriceQ36(0), 1e36);
        assertEq(t.tickToPriceQ36(1), 1.0001e36);
        assertApproxEqRel(t.tickToPriceQ36(-1), 0.99990000999900009999e36, 1e6);
        assertApproxEqRel(t.tickToPriceQ36(23_028), 10e36, 0.0001e18); // 1.0001^23028 ~ 10
        assertApproxEqRel(t.tickToPriceQ36(-23_028), 0.1e36, 0.0001e18);
        t.tickToPriceQ36(887_272);
        vm.expectRevert(UniswapV3TwapPriceSource.BadConfig.selector);
        t.tickToPriceQ36(887_273);
    }

    function test_twap_quotePrice_bothOrientations() public {
        UniswapV3TwapPriceSource t = new UniswapV3TwapPriceSource(admin);
        // price 250 quote per asset: raw = 250e6 / 1e18 = 2.5e-10 -> tick = ln(2.5e-10)/ln(1.0001) ~ -221,108
        MockPool pool = new MockPool(address(stk), address(usd));
        pool.setTick(-221_108, 1800);
        vm.prank(admin);
        t.setPool(address(stk), address(usd), IUniswapV3Pool(address(pool)), 1800);
        assertApproxEqRel(t.getQuotePrice(address(stk), address(usd)), 250e18, 0.001e18);

        MockPool pool2 = new MockPool(address(usd), address(stk));
        pool2.setTick(221_108, 1800);
        vm.prank(admin);
        t.setPool(address(stk), address(usd), IUniswapV3Pool(address(pool2)), 1800);
        assertApproxEqRel(t.getQuotePrice(address(stk), address(usd)), 250e18, 0.001e18);

        // negative non-divisible cumulative rounds down
        pool.setTick(-3, 7);
        vm.prank(admin);
        t.setPool(address(stk), address(usd), IUniswapV3Pool(address(pool)), 1800);
        t.getQuotePrice(address(stk), address(usd));

        vm.startPrank(admin);
        vm.expectRevert(UniswapV3TwapPriceSource.BadConfig.selector);
        t.setPool(address(stk), address(usd), IUniswapV3Pool(address(pool)), 10);
        MockPool wrong = new MockPool(address(1), address(2));
        vm.expectRevert(UniswapV3TwapPriceSource.BadConfig.selector);
        t.setPool(address(stk), address(usd), IUniswapV3Pool(address(wrong)), 1800);
        vm.stopPrank();
        vm.expectRevert(UniswapV3TwapPriceSource.PoolNotSet.selector);
        t.getQuotePrice(address(usd), address(stk));
    }
}
