// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/external/IMorpho.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/IChainlink.sol";
import {LeveragedToken} from "../../src/LeveragedToken.sol";
import {MorphoPositionAdapter} from "../../src/adapters/MorphoPositionAdapter.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {NAVCalculator} from "../../src/NAVCalculator.sol";
import {DeployBase} from "../../script/DeployBase.sol";
import {Timelock} from "../../src/Timelock.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {LeveragedTokenFactory} from "../../src/LeveragedTokenFactory.sol";
import {RobinhoodChainConfig as C} from "../../script/RobinhoodChainConfig.sol";

/// @notice Fork tests against Robinhood Chain mainnet state: real USDG, real stock tokens, real Chainlink feeds,
///         real Morpho Blue and real Uniswap v3 pools. Runs the exact production deployment code (DeployBase).
///         RPC: env ROBINHOOD_RPC_URL (defaults to the public endpoint). Skipped if the RPC is unreachable.
contract ForkTest is Test, DeployBase {
    struct Stored {
        Timelock timelock;
        OracleAdapter oracle;
        MarketClock clock;
        ComplianceRegistry compliance;
        ProjectTokenHooks hooks;
        LeveragedTokenFactory factory;
        Rebalancer rebalancer;
        NAVCalculator nav;
    }

    Stored d;
    ProductOut[] products;
    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address lender = makeAddr("lender");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            return;
        }
        assertEq(block.chainid, 4663);

        vm.startPrank(deployer);
        Deployment memory m =
            _deploy(Roles({deployer: deployer, guardian: deployer, keeper: deployer, proposer: deployer, treasury: address(0)}));
        vm.stopPrank();
        d = Stored(m.timelock, m.oracle, m.clock, m.compliance, m.hooks, m.factory, m.rebalancer, m.nav);
        for (uint256 i; i < m.products.length; ++i) products.push(m.products[i]);

        // Move to the next regular-session moment and keep feeds usable across the warp.
        uint256 t = block.timestamp;
        for (uint256 i; i < 7 * 48 && !d.clock.isMintRedeemOpenAt(t); ++i) t += 30 minutes;
        vm.warp(t + 1 hours);
        vm.startPrank(address(d.timelock));
        C.Stock[] memory s = C.stocks();
        for (uint256 i; i < s.length; ++i) d.oracle.setFeed(s[i].token, AggregatorV3Interface(s[i].feed), 7 days);
        d.oracle.setFeed(C.USDG, AggregatorV3Interface(C.USDG_USD_FEED), 7 days);
        vm.stopPrank();

        // Venue liquidity for the fresh Triplex Morpho markets (lenders are external in production).
        deal(C.USDG, lender, 10_000_000e6);
        deal(C.USDG, user, 1_000_000e6);
    }

    modifier onlyFork() {
        if (!forked) {
            console2.log("fork unavailable - skipped");
            return;
        }
        _;
    }

    function _p(string memory sym) internal view returns (LeveragedToken) {
        for (uint256 i; i < products.length; ++i) {
            if (keccak256(bytes(products[i].symbol)) == keccak256(bytes(sym))) return LeveragedToken(products[i].product);
        }
        revert("no product");
    }

    function _supplyLong(LeveragedToken t, uint256 amount) internal {
        MarketParams memory m = MorphoPositionAdapter(address(t.adapter())).marketParams();
        vm.startPrank(lender);
        IERC20(C.USDG).approve(C.MORPHO, amount);
        IMorpho(C.MORPHO).supply(m, amount, 0, lender, "");
        vm.stopPrank();
    }

    function _supplyShort(LeveragedToken t, uint256 tokens) internal {
        MarketParams memory m = MorphoPositionAdapter(address(t.adapter())).marketParams();
        deal(m.loanToken, lender, tokens);
        vm.startPrank(lender);
        IERC20(m.loanToken).approve(C.MORPHO, tokens);
        IMorpho(C.MORPHO).supply(m, tokens, 0, lender, "");
        vm.stopPrank();
    }

    function test_fork_deploymentWiring() public onlyFork {
        assertEq(products.length, 20);
        assertEq(d.factory.productCount(), 20);
        assertTrue(d.factory.hasRole(0x00, address(d.timelock)));
        assertFalse(d.factory.hasRole(0x00, deployer));
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertFalse(d.hooks.isActive());
        assertFalse(d.compliance.enabled());
        // every product prices off live Chainlink and has its Morpho market
        NAVCalculator.ProductView[] memory all = d.nav.getAllProducts();
        for (uint256 i; i < all.length; ++i) {
            assertTrue(all[i].priceOk, all[i].symbol);
            assertEq(all[i].lltv, 0.86e18);
            (,,,, uint128 lastUpdate,) = IMorpho(C.MORPHO).market(MorphoPositionAdapter(all[i].adapter).marketId());
            assertGt(lastUpdate, 0);
        }
    }

    function test_fork_oracleVsMorphoOracleConsistent() public onlyFork {
        LeveragedToken t = _p("3L-NVDA");
        MarketParams memory m = MorphoPositionAdapter(address(t.adapter())).marketParams();
        uint256 ours = d.oracle.getQuotePrice(m.collateralToken, C.USDG); // WAD USDG per NVDA
        uint256 morphoPrice = IMorphoOracleLike(m.oracle).price(); // 1e36 * 1e6 / 1e18 scale
        assertApproxEqRel(morphoPrice / 1e6, ours, 0.0001e18);
        console2.log("NVDA in USDG (WAD):", ours);
    }

    function test_fork_mintRedeem_3L_NVDA_realVenues() public onlyFork {
        LeveragedToken t = _p("3L-NVDA");
        _supplyLong(t, 1_000_000e6);
        vm.startPrank(user);
        IERC20(C.USDG).approve(address(t), type(uint256).max);
        uint256 shares = t.mint(1_000e6, 0, block.timestamp);
        assertGt(shares, 950e18);
        assertApproxEqRel(t.adapter().leverage(), 3e18, 0.05e18);
        // second mint is proportional
        t.mint(500e6, 0, block.timestamp);
        uint256 bal = IERC20(C.USDG).balanceOf(user);
        uint256 out = t.redeem(shares, 0, block.timestamp);
        vm.stopPrank();
        assertGt(out, 950e6);
        assertEq(IERC20(C.USDG).balanceOf(user), bal + out);
        console2.log("3L-NVDA round trip: in 1000 USDG, out", out);
    }

    function test_fork_mintRedeem_2S_QQQ_realVenues() public onlyFork {
        LeveragedToken t = _p("2S-QQQ");
        _supplyShort(t, 50e18); // 50 QQQ tokens available to borrow
        vm.startPrank(user);
        IERC20(C.USDG).approve(address(t), type(uint256).max);
        uint256 shares = t.mint(2_000e6, 0, block.timestamp);
        assertApproxEqRel(t.adapter().leverage(), 2e18, 0.05e18);
        uint256 out = t.redeem(shares / 2, 0, block.timestamp);
        vm.stopPrank();
        assertGt(out, 950e6);
    }

    function test_fork_allLongProductsMint() public onlyFork {
        string[5] memory syms = ["CRCL", "NVDA", "SPCX", "MU", "QQQ"];
        vm.startPrank(user);
        for (uint256 i; i < 5; ++i) {
            LeveragedToken t = _p(string.concat("2L-", syms[i]));
            vm.stopPrank();
            _supplyLong(t, 100_000e6);
            vm.startPrank(user);
            IERC20(C.USDG).approve(address(t), type(uint256).max);
            t.mint(300e6, 0, block.timestamp);
            assertApproxEqRel(t.adapter().leverage(), 2e18, 0.05e18, syms[i]);
        }
        vm.stopPrank();
    }

    function test_fork_emergencyAndDailyRebalance_realSwaps() public onlyFork {
        LeveragedToken t = _p("3L-NVDA");
        _supplyLong(t, 1_000_000e6);
        vm.startPrank(user);
        IERC20(C.USDG).approve(address(t), type(uint256).max);
        t.mint(2_000e6, 0, block.timestamp);
        vm.stopPrank();
        // Governance moves the band so the live position (3x) is "outside" it -> emergency de-leverage on real pools
        vm.prank(address(d.timelock));
        d.factory.setLeverageBand(address(t), 2e18, 1.7e18, 2.4e18);
        for (uint256 i; i < 20; ++i) {
            (Rebalancer.Mode mode,,,, bool ready) = d.rebalancer.check(address(t));
            if (mode == Rebalancer.Mode.None) break;
            if (!ready) vm.warp(block.timestamp + 121);
            d.rebalancer.rebalance(address(t));
        }
        assertApproxEqRel(t.adapter().leverage(), 2e18, 0.03e18);

        // daily close window: snapshot recorded
        uint256 day = d.clock.tradingDayId(block.timestamp);
        uint256 ts = block.timestamp;
        for (uint256 i; i < 48 && !d.clock.isDailyRebalanceWindowAt(ts); ++i) ts += 15 minutes;
        vm.warp(ts);
        d.rebalancer.rebalance(address(t));
        assertEq(t.snapshotDay(), d.clock.tradingDayId(block.timestamp));
        assertGe(t.snapshotDay(), day);
    }
}

interface IMorphoOracleLike {
    function price() external view returns (uint256);
}
