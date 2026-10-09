// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMorpho, MarketParams, IMorphoChainlinkOracleV2Factory} from "../src/interfaces/external/IMorpho.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/IChainlink.sol";
import {ISwapRouter02, IUniswapV3Factory, IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3.sol";
import {
    IOracleAdapter,
    IMarketClock,
    ISwapAdapter,
    IProjectTokenHooks,
    IComplianceRegistry,
    IPriceSource
} from "../src/interfaces/ITriplex.sol";
import {Timelock} from "../src/Timelock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {LeveragedToken} from "../src/LeveragedToken.sol";
import {LeveragedTokenFactory} from "../src/LeveragedTokenFactory.sol";
import {MorphoPositionAdapter} from "../src/adapters/MorphoPositionAdapter.sol";
import {UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {UniswapV3TwapPriceSource} from "../src/adapters/UniswapV3TwapPriceSource.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {NAVCalculator} from "../src/NAVCalculator.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {RobinhoodChainConfig as C} from "./RobinhoodChainConfig.sol";

/// @notice Deployment logic shared by `Deploy.s.sol` (broadcast) and the fork tests (prank). Contains no cheatcodes.
abstract contract DeployBase {
    struct Roles {
        address deployer; // temporary admin; renounces everything at the end
        address guardian; // can pause, halt the clock, manage holidays / allowlist
        address keeper; // FeeCollector operator (harvest)
        address proposer; // Timelock proposer/canceller
        address treasury; // fee recipient (default: the Timelock itself)
    }

    struct ProductOut {
        string symbol;
        string underlyingSymbol;
        address product;
        address adapter;
        address underlying;
        bool isLong;
        uint256 targetLeverage;
    }

    struct Deployment {
        Timelock timelock;
        OracleAdapter oracle;
        MarketClock clock;
        ComplianceRegistry compliance;
        ProjectTokenHooks hooks;
        UniswapV3SwapAdapter swapAdapter;
        UniswapV3TwapPriceSource twap;
        LeveragedTokenFactory factory;
        FeeCollector feeCollector;
        Rebalancer rebalancer;
        NAVCalculator nav;
        address tokenImpl;
        address adapterImpl;
        ProductOut[] products;
    }

    uint32 internal constant FEED_MAX_AGE = 26 hours; // 24h heartbeat + 2h margin
    uint256 internal constant SUPPLY_CAP = 250_000e18; // per-product equity cap at launch (USDG, WAD)

    function _deploy(Roles memory r) internal returns (Deployment memory d) {
        // ---------------------------------------------------------------- governance
        address[] memory proposers = new address[](1);
        proposers[0] = r.proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured operation
        d.timelock = new Timelock(48 hours, proposers, executors);
        if (r.treasury == address(0)) r.treasury = address(d.timelock);

        // ---------------------------------------------------------------- modules
        d.oracle = new OracleAdapter(r.deployer);
        d.clock = new MarketClock(r.deployer, r.guardian, _holidays(), _earlyCloses());
        d.compliance = new ComplianceRegistry(r.deployer, r.guardian);
        d.hooks = new ProjectTokenHooks(r.deployer, r.guardian, IERC20(C.USDG));
        d.swapAdapter = new UniswapV3SwapAdapter(
            r.deployer, ISwapRouter02(C.UNI_SWAP_ROUTER_02), IUniswapV3Factory(C.UNI_V3_FACTORY)
        );
        d.twap = new UniswapV3TwapPriceSource(r.deployer);

        d.tokenImpl = address(new LeveragedToken());
        d.adapterImpl = address(new MorphoPositionAdapter(IMorpho(C.MORPHO)));
        d.factory = new LeveragedTokenFactory(r.deployer, r.guardian, C.USDG, d.tokenImpl, d.adapterImpl);
        d.feeCollector = new FeeCollector(r.deployer, r.keeper, d.factory, IERC20(C.USDG), r.treasury);
        d.rebalancer = new Rebalancer(
            r.deployer,
            r.guardian,
            d.factory,
            Rebalancer.Config({maxChunk: 10_000e18, minInterval: 120, toleranceBps: 200, set: true})
        );
        d.nav = new NAVCalculator(d.factory);

        d.factory.setOracle(IOracleAdapter(address(d.oracle)));
        d.factory.setMarketClock(IMarketClock(address(d.clock)));
        d.factory.setSwapAdapter(ISwapAdapter(address(d.swapAdapter)));
        d.factory.setRebalancer(address(d.rebalancer));
        d.factory.setFeeCollector(address(d.feeCollector));
        d.factory.setProjectTokenHooks(IProjectTokenHooks(address(d.hooks)));
        d.factory.setComplianceRegistry(IComplianceRegistry(address(d.compliance))); // deployed, but disabled
        d.hooks.setFeeCollector(address(d.feeCollector));
        d.hooks.setTiers(10_000e18, 2_500, 100_000e18, 5_000); // inert until setProjectToken

        d.oracle.setFeed(C.USDG, AggregatorV3Interface(C.USDG_USD_FEED), FEED_MAX_AGE);

        // ---------------------------------------------------------------- products
        C.Stock[] memory stocks = C.stocks();
        d.products = new ProductOut[](stocks.length * 4);
        for (uint256 i; i < stocks.length; ++i) {
            _wireStock(d, stocks[i]);
            (MarketParams memory longM, MarketParams memory shortM) = _markets(stocks[i]);
            d.products[i * 4] = _product(d, stocks[i], Spec("3L-", true, 3e18, 2.5e18, 3.6e18, 300), longM);
            d.products[i * 4 + 1] = _product(d, stocks[i], Spec("2L-", true, 2e18, 1.7e18, 2.4e18, 200), longM);
            d.products[i * 4 + 2] = _product(d, stocks[i], Spec("1S-", false, 1e18, 0.8e18, 1.25e18, 150), shortM);
            d.products[i * 4 + 3] = _product(d, stocks[i], Spec("2S-", false, 2e18, 1.7e18, 2.4e18, 250), shortM);
        }

        // ---------------------------------------------------------------- hand admin to the Timelock
        _handover(AccessControl(address(d.oracle)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.clock)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.compliance)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.hooks)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.swapAdapter)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.twap)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.factory)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.feeCollector)), address(d.timelock), r.deployer);
        _handover(AccessControl(address(d.rebalancer)), address(d.timelock), r.deployer);
    }

    function _wireStock(Deployment memory d, C.Stock memory s) internal {
        d.oracle.setFeed(s.token, AggregatorV3Interface(s.feed), FEED_MAX_AGE);
        d.swapAdapter.setPoolFee(s.token, C.USDG, s.uniFee);
        address pool = IUniswapV3Factory(C.UNI_V3_FACTORY).getPool(s.token, C.USDG, s.uniFee);
        d.twap.setPool(s.token, C.USDG, IUniswapV3Pool(pool), 10 minutes);
        // lenient: a pool without enough observation history is skipped instead of blocking the protocol
        d.oracle.setDeviation(s.token, C.USDG, IPriceSource(address(d.twap)), 500, false);
    }

    /// @dev Dedicated Morpho Blue markets (LLTV 0.86, AdaptiveCurveIRM) with Morpho's audited Chainlink oracle.
    function _markets(C.Stock memory s) internal returns (MarketParams memory longM, MarketParams memory shortM) {
        // LONG market: collateral = stock (18 dec), loan = USDG (6 dec)
        address longOracle = _morphoOracle(s.feed, 18, C.USDG_USD_FEED, 6, keccak256(abi.encode("triplex.long", s.token)));
        // SHORT market: collateral = USDG, loan = stock
        address shortOracle =
            _morphoOracle(C.USDG_USD_FEED, 6, s.feed, 18, keccak256(abi.encode("triplex.short", s.token)));
        longM = MarketParams(C.USDG, s.token, longOracle, C.MORPHO_ADAPTIVE_CURVE_IRM, C.MORPHO_LLTV);
        shortM = MarketParams(s.token, C.USDG, shortOracle, C.MORPHO_ADAPTIVE_CURVE_IRM, C.MORPHO_LLTV);
    }

    /// @dev Morpho's audited ChainlinkOracleV2 (collateral priced in loan token), created via the official factory.
    function _morphoOracle(address baseFeed, uint256 baseDec, address quoteFeed, uint256 quoteDec, bytes32 salt)
        internal
        returns (address)
    {
        return IMorphoChainlinkOracleV2Factory(C.MORPHO_CHAINLINK_ORACLE_V2_FACTORY).createMorphoChainlinkOracleV2(
            address(0), 1, baseFeed, address(0), baseDec, address(0), 1, quoteFeed, address(0), quoteDec, salt
        );
    }

    struct Spec {
        string prefix;
        bool isLong;
        uint256 target;
        uint256 minL;
        uint256 maxL;
        uint256 bufferBps;
    }

    function _product(Deployment memory d, C.Stock memory s, Spec memory sp, MarketParams memory m)
        internal
        returns (ProductOut memory out)
    {
        string memory sym = string.concat(sp.prefix, s.symbol);
        (address p, address a) = d.factory.createProduct(_createParams(s, sp, m, sym));
        out = ProductOut(sym, s.symbol, p, a, s.token, sp.isLong, sp.target);
    }

    function _createParams(C.Stock memory s, Spec memory sp, MarketParams memory m, string memory sym)
        internal
        pure
        returns (LeveragedTokenFactory.CreateParams memory)
    {
        string memory lev = sp.target == 3e18 ? "3x" : (sp.target == 2e18 ? "2x" : "1x");
        return LeveragedTokenFactory.CreateParams({
            name: string.concat("Triplex ", lev, sp.isLong ? " Long " : " Short ", s.symbol),
            symbol: sym,
            underlying: s.token,
            isLong: sp.isLong,
            targetLeverage: sp.target,
            minLeverage: sp.minL,
            maxLeverage: sp.maxL,
            market: m,
            maxSwapSlippageBps: 150,
            mintFeeBps: 10,
            redeemFeeBps: 10,
            mgmtFeeBps: 95,
            supplyCapEquity: SUPPLY_CAP,
            minMintQuote: 10e6,
            mintBufferBps: sp.bufferBps
        });
    }

    function _handover(AccessControl c, address timelock, address deployer) internal {
        c.grantRole(0x00, timelock);
        c.renounceRole(0x00, deployer);
    }

    // ---------------------------------------------------------------- NYSE calendar (nyse.com/markets/hours-calendars)

    function _holidays() internal pure returns (uint256[] memory h) {
        uint16[3][] memory dates = new uint16[3][](29);
        uint16[3][29] memory list = [
            [uint16(2026), 1, 1], [uint16(2026), 1, 19], [uint16(2026), 2, 16], [uint16(2026), 4, 3],
            [uint16(2026), 5, 25], [uint16(2026), 6, 19], [uint16(2026), 7, 3], [uint16(2026), 9, 7],
            [uint16(2026), 11, 26], [uint16(2026), 12, 25],
            [uint16(2027), 1, 1], [uint16(2027), 1, 18], [uint16(2027), 2, 15], [uint16(2027), 3, 26],
            [uint16(2027), 5, 31], [uint16(2027), 6, 18], [uint16(2027), 7, 5], [uint16(2027), 9, 6],
            [uint16(2027), 11, 25], [uint16(2027), 12, 24],
            [uint16(2028), 1, 17], [uint16(2028), 2, 21], [uint16(2028), 4, 14], [uint16(2028), 5, 29],
            [uint16(2028), 6, 19], [uint16(2028), 7, 4], [uint16(2028), 9, 4], [uint16(2028), 11, 23],
            [uint16(2028), 12, 25]
        ];
        for (uint256 i; i < 29; ++i) dates[i] = list[i];
        h = _toDays(dates);
    }

    function _earlyCloses() internal pure returns (uint256[] memory e) {
        uint16[3][] memory dates = new uint16[3][](5);
        dates[0] = [uint16(2026), 11, 27];
        dates[1] = [uint16(2026), 12, 24];
        dates[2] = [uint16(2027), 11, 26];
        dates[3] = [uint16(2028), 7, 3];
        dates[4] = [uint16(2028), 11, 24];
        e = _toDays(dates);
    }

    function _toDays(uint16[3][] memory dates) internal pure returns (uint256[] memory out) {
        out = new uint256[](dates.length);
        for (uint256 i; i < dates.length; ++i) out[i] = _daysFromCivil(dates[i][0], dates[i][1], dates[i][2]);
    }

    /// @dev Same algorithm as MarketClock.daysFromCivil.
    function _daysFromCivil(uint256 y, uint256 m, uint256 dd) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + dd - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }
}
