// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MarketParams} from "./interfaces/external/IMorpho.sol";
import {
    ITriplexRegistry,
    IOracleAdapter,
    IMarketClock,
    ISwapAdapter,
    IProjectTokenHooks,
    IComplianceRegistry,
    IPositionAdapter
} from "./interfaces/ITriplex.sol";
import {LeveragedToken} from "./LeveragedToken.sol";
import {MorphoPositionAdapter} from "./adapters/MorphoPositionAdapter.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title LeveragedTokenFactory
/// @notice Deploys one LeveragedToken + one position adapter (EIP-1167 clones) per product, and acts as the protocol
///         registry: every product reads the oracle, clock, swap venue, rebalancer, fee collector, token hooks and
///         compliance hook from here, so each module is swappable by the Timelock in one place.
contract LeveragedTokenFactory is ITriplexRegistry, AccessControl {
    /// @notice The leverage band's worst-case LTV must stay this far below the venue liquidation LTV.
    uint256 public constant LTV_SAFETY_BUFFER = 0.05e18;
    uint256 public constant MAX_TARGET_LEVERAGE = 5e18;

    address public immutable tokenImplementation;
    address public immutable adapterImplementation;
    address public immutable quoteToken;

    IOracleAdapter public oracle;
    IMarketClock public marketClock;
    ISwapAdapter public swapAdapter;
    address public rebalancer;
    address public feeCollector;
    IProjectTokenHooks public projectTokenHooks;
    IComplianceRegistry public complianceRegistry;

    mapping(address product => bool) public isProduct;
    address[] internal _products;

    struct CreateParams {
        string name;
        string symbol;
        address underlying;
        bool isLong;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        MarketParams market;
        uint256 maxSwapSlippageBps;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 mgmtFeeBps;
        uint256 supplyCapEquity;
        uint256 minMintQuote;
        uint256 mintBufferBps;
    }

    event ProductCreated(
        address indexed product,
        address indexed adapter,
        address indexed underlying,
        bool isLong,
        uint256 targetLeverage,
        string symbol
    );
    event ModuleSet(bytes32 indexed module, address value);
    event LeverageBandUpdated(address indexed product, uint256 target, uint256 min, uint256 max);

    error BadBand();
    error NotProduct();
    error ZeroAddress();

    constructor(address admin, address guardian, address quoteToken_, address tokenImpl, address adapterImpl) {
        if (admin == address(0) || quoteToken_ == address(0) || tokenImpl == address(0) || adapterImpl == address(0)) {
            revert ZeroAddress();
        }
        quoteToken = quoteToken_;
        tokenImplementation = tokenImpl;
        adapterImplementation = adapterImpl;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.GUARDIAN_ROLE, guardian);
    }

    // ------------------------------------------------------------------ products

    function createProduct(CreateParams calldata p)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address product, address adapter)
    {
        validateBand(p.isLong, p.targetLeverage, p.minLeverage, p.maxLeverage, p.market.lltv);
        if (p.underlying == address(0)) revert ZeroAddress();

        product = Clones.clone(tokenImplementation);
        adapter = Clones.clone(adapterImplementation);
        isProduct[product] = true;
        _products.push(product);

        MorphoPositionAdapter(adapter).initialize(
            this, product, p.underlying, quoteToken, p.isLong, p.market, p.maxSwapSlippageBps
        );
        LeveragedToken(product).initialize(
            this,
            IPositionAdapter(adapter),
            LeveragedToken.InitParams({
                name: p.name,
                symbol: p.symbol,
                underlying: p.underlying,
                quoteToken: quoteToken,
                isLong: p.isLong,
                targetLeverage: p.targetLeverage,
                minLeverage: p.minLeverage,
                maxLeverage: p.maxLeverage,
                mintFeeBps: p.mintFeeBps,
                redeemFeeBps: p.redeemFeeBps,
                mgmtFeeBps: p.mgmtFeeBps,
                supplyCapEquity: p.supplyCapEquity,
                minMintQuote: p.minMintQuote,
                mintBufferBps: p.mintBufferBps
            })
        );
        emit ProductCreated(product, adapter, p.underlying, p.isLong, p.targetLeverage, p.symbol);
    }

    function setLeverageBand(address product, uint256 target, uint256 min, uint256 max)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isProduct[product]) revert NotProduct();
        LeveragedToken t = LeveragedToken(product);
        validateBand(t.isLong(), target, min, max, t.adapter().liquidationLtv());
        t.setLeverageBand(target, min, max);
        emit LeverageBandUpdated(product, target, min, max);
    }

    /// @notice Band rules: 0.5x <= min < target < max, target <= 5x, and the LTV at `max` leverage plus a 5% safety
    ///         buffer must be below the venue's liquidation LTV.
    ///         LONG  LTV(L) = (L-1)/L      SHORT LTV(L) = L/(L+1)
    function validateBand(bool isLong, uint256 target, uint256 min, uint256 max, uint256 lltv) public pure {
        if (min < Constants.WAD / 2 || !(min < target && target < max) || target > MAX_TARGET_LEVERAGE) {
            revert BadBand();
        }
        if (isLong && min <= Constants.WAD) revert BadBand(); // a long needs leverage > 1x to hold debt
        uint256 maxLtv = isLong
            ? (max - Constants.WAD) * Constants.WAD / max
            : max * Constants.WAD / (max + Constants.WAD);
        if (maxLtv + LTV_SAFETY_BUFFER > lltv) revert BadBand();
    }

    // ------------------------------------------------------------------ modules (Timelock)

    function setOracle(IOracleAdapter v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(v));
        oracle = v;
        emit ModuleSet("oracle", address(v));
    }

    function setMarketClock(IMarketClock v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(v));
        marketClock = v;
        emit ModuleSet("marketClock", address(v));
    }

    function setSwapAdapter(ISwapAdapter v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(v));
        swapAdapter = v;
        emit ModuleSet("swapAdapter", address(v));
    }

    function setRebalancer(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(v);
        rebalancer = v;
        emit ModuleSet("rebalancer", v);
    }

    function setFeeCollector(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(v);
        feeCollector = v;
        emit ModuleSet("feeCollector", v);
    }

    /// @dev address(0) allowed: disables token features entirely.
    function setProjectTokenHooks(IProjectTokenHooks v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        projectTokenHooks = v;
        emit ModuleSet("projectTokenHooks", address(v));
    }

    /// @dev address(0) allowed: compliance gate off.
    function setComplianceRegistry(IComplianceRegistry v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceRegistry = v;
        emit ModuleSet("complianceRegistry", address(v));
    }

    // ------------------------------------------------------------------ views

    function allProducts() external view returns (address[] memory) {
        return _products;
    }

    function productCount() external view returns (uint256) {
        return _products.length;
    }

    function productAt(uint256 i) external view returns (address) {
        return _products[i];
    }

    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, ITriplexRegistry)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    function _nonZero(address a) internal pure {
        if (a == address(0)) revert ZeroAddress();
    }
}
