// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ILeveragedToken,
    IPositionAdapter,
    ITriplexRegistry,
    IComplianceRegistry,
    IProjectTokenHooks
} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title LeveragedToken
/// @notice One ERC-20 per product (e.g. "3L-NVDA"). Shares are minted/redeemed against the product's position:
///         - first mint opens the position at target leverage; 1 share = 1 quote token of equity at inception;
///         - later mints add the SAME fraction k to collateral and debt and receive k * supply shares;
///         - redeems remove the same fraction from collateral and debt.
///         Because both legs scale together, existing holders' per-share position is unchanged by any mint/redeem
///         regardless of the oracle, and the minter/redeemer pays their own swap costs.
///         Mint/redeem only run during the US regular session (MarketClock) and can be gated by ComplianceRegistry.
contract LeveragedToken is
    ILeveragedToken,
    Initializable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant DEAD_SHARES = 1e12; // locked forever on first mint (anti share-inflation)
    uint256 public constant MAX_MINT_BUFFER_BPS = 500;

    ITriplexRegistry public registry;
    IPositionAdapter public adapter;
    address public underlying;
    address public quoteToken;
    bool public isLong;

    uint256 public targetLeverage;
    uint256 public minLeverage;
    uint256 public maxLeverage;

    uint256 public mintFeeBps;
    uint256 public redeemFeeBps;
    uint256 public mgmtFeeBps;
    uint256 public lastFeeAccrual;

    uint256 public supplyCapEquity; // max product equity in quote WAD (0 = uncapped)
    uint256 public minMintQuote; // raw quote units
    uint256 public mintBufferBps; // headroom left for price movement during a mint; unused quote is refunded

    // daily close snapshot (for "daily performance vs underlying")
    uint256 public snapshotDay;
    uint256 public snapshotNav;
    uint256 public snapshotPrice;
    uint256 public snapshotTime;

    struct InitParams {
        string name;
        string symbol;
        address underlying;
        address quoteToken;
        bool isLong;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 mgmtFeeBps;
        uint256 supplyCapEquity;
        uint256 minMintQuote;
        uint256 mintBufferBps;
    }

    event Minted(address indexed account, uint256 quoteIn, uint256 quoteUsed, uint256 fee, uint256 shares);
    event Redeemed(address indexed account, uint256 shares, uint256 quoteOut, uint256 fee);
    event ManagementFeeAccrued(uint256 feeShares, uint256 elapsed);
    event DailySnapshot(uint256 indexed day, uint256 navPerShare, uint256 underlyingPrice, uint256 timestamp);
    event FeesSet(uint256 mintFeeBps, uint256 redeemFeeBps, uint256 mgmtFeeBps);
    event LimitsSet(uint256 supplyCapEquity, uint256 minMintQuote, uint256 mintBufferBps);
    event LeverageBandSet(uint256 target, uint256 min, uint256 max);

    error Expired();
    error MarketClosed();
    error NotAllowed();
    error NotAdmin();
    error NotGuardian();
    error NotRebalancer();
    error Slippage();
    error CapExceeded();
    error BadConfig();
    error ProductDead();
    error ZeroAmount();

    constructor() {
        _disableInitializers();
    }

    function initialize(ITriplexRegistry registry_, IPositionAdapter adapter_, InitParams calldata p)
        external
        initializer
    {
        __ERC20_init(p.name, p.symbol);
        __ReentrancyGuard_init();
        __Pausable_init();
        if (p.mgmtFeeBps > Constants.MAX_MGMT_FEE_BPS) revert BadConfig();
        if (p.mintFeeBps > Constants.MAX_MINT_REDEEM_FEE_BPS || p.redeemFeeBps > Constants.MAX_MINT_REDEEM_FEE_BPS) {
            revert BadConfig();
        }
        if (p.mintBufferBps > MAX_MINT_BUFFER_BPS) revert BadConfig();
        registry = registry_;
        adapter = adapter_;
        underlying = p.underlying;
        quoteToken = p.quoteToken;
        isLong = p.isLong;
        targetLeverage = p.targetLeverage;
        minLeverage = p.minLeverage;
        maxLeverage = p.maxLeverage;
        mintFeeBps = p.mintFeeBps;
        redeemFeeBps = p.redeemFeeBps;
        mgmtFeeBps = p.mgmtFeeBps;
        supplyCapEquity = p.supplyCapEquity;
        minMintQuote = p.minMintQuote;
        mintBufferBps = p.mintBufferBps;
        lastFeeAccrual = block.timestamp;
    }

    // ================================================================== modifiers

    modifier onlyAdmin() {
        if (!registry.hasRole(0x00, msg.sender)) revert NotAdmin();
        _;
    }

    // ================================================================== user actions

    /// @notice Mint shares with `quoteIn` quote tokens at NAV. Unused quote (mint buffer) is refunded.
    function mint(uint256 quoteIn, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _checkAction(deadline, Constants.ACTION_MINT);
        if (quoteIn == 0) revert ZeroAmount();
        accrueManagementFee();

        // Budget the position with the worst-case fee; the fee is finally charged on the quote actually used.
        uint256 net = quoteIn - _fee(msg.sender, quoteIn, mintFeeBps);
        if (net < minMintQuote) revert ZeroAmount();

        IERC20 q = IERC20(quoteToken);
        q.safeTransferFrom(msg.sender, address(this), quoteIn);
        q.safeTransfer(address(adapter), net);

        uint256 supply = totalSupply();
        uint256 used;
        if (supply == 0) {
            if (adapter.hasPosition()) revert ProductDead();
            adapter.openInitial(net, targetLeverage);
            (,,, uint256 equity) = adapter.positionValues();
            if (equity <= DEAD_SHARES) revert ZeroAmount();
            used = net;
            shares = equity - DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        } else {
            (,,, uint256 equity0) = adapter.positionValues();
            if (equity0 == 0 || !adapter.hasPosition()) revert ProductDead();
            uint256 netWad = net.mulDiv(Constants.WAD, 10 ** _quoteDecimals());
            uint256 k = netWad.mulDiv(Constants.BPS - mintBufferBps, Constants.BPS).mulDiv(Constants.WAD, equity0);
            if (k == 0) revert ZeroAmount();
            used = adapter.mintProportional(net, k, address(this));
            shares = supply.mulDiv(k, Constants.WAD);
        }

        uint256 fee = _fee(msg.sender, used, mintFeeBps);
        if (fee != 0) q.safeTransfer(registry.feeCollector(), fee);
        uint256 refund = quoteIn - used - fee;
        if (refund != 0) q.safeTransfer(msg.sender, refund);

        if (shares == 0 || shares < minSharesOut) revert Slippage();
        if (supplyCapEquity != 0) {
            (,,, uint256 equityAfter) = adapter.positionValues();
            if (equityAfter > supplyCapEquity) revert CapExceeded();
        }
        _mint(msg.sender, shares);
        emit Minted(msg.sender, quoteIn, used, fee, shares);
    }

    /// @notice Burn `shares` and receive the proportional slice of the position, unwound to quote, minus fees.
    function redeem(uint256 shares, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 quoteOut)
    {
        _checkAction(deadline, Constants.ACTION_REDEEM);
        if (shares == 0) revert ZeroAmount();
        accrueManagementFee();

        uint256 fraction = shares.mulDiv(Constants.WAD, totalSupply());
        _burn(msg.sender, shares); // effects before interactions

        uint256 gross = adapter.redeemProportional(fraction, address(this));
        uint256 fee = _fee(msg.sender, gross, redeemFeeBps);
        quoteOut = gross - fee;
        if (quoteOut < minQuoteOut) revert Slippage();

        IERC20 q = IERC20(quoteToken);
        if (fee != 0) q.safeTransfer(registry.feeCollector(), fee);
        if (quoteOut != 0) q.safeTransfer(msg.sender, quoteOut);
        emit Redeemed(msg.sender, shares, quoteOut, fee);
    }

    /// @notice Streams the management fee to the FeeCollector by minting dilutive shares. Anyone may call.
    function accrueManagementFee() public returns (uint256 feeShares) {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0) return 0;
        lastFeeAccrual = block.timestamp;
        feeShares = _pendingFeeShares(elapsed);
        if (feeShares != 0) {
            _mint(registry.feeCollector(), feeShares);
            emit ManagementFeeAccrued(feeShares, elapsed);
        }
    }

    /// @notice Rebalancer records the end-of-day NAV once per trading day.
    function recordDailySnapshot() external {
        if (msg.sender != registry.rebalancer()) revert NotRebalancer();
        accrueManagementFee();
        uint256 nav = navPerShare();
        uint256 price = adapter.assetPrice();
        uint256 day = registry.marketClock().tradingDayId(block.timestamp);
        snapshotDay = day;
        snapshotNav = nav;
        snapshotPrice = price;
        snapshotTime = block.timestamp;
        emit DailySnapshot(day, nav, price, block.timestamp);
    }

    // ================================================================== views

    function pendingFeeShares() public view returns (uint256) {
        return _pendingFeeShares(block.timestamp - lastFeeAccrual);
    }

    /// @notice Net asset value per share (WAD, quote units), including not-yet-minted management fee shares.
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply() + pendingFeeShares();
        if (supply == 0) return Constants.WAD;
        (,,, uint256 equity) = adapter.positionValues();
        return equity.mulDiv(Constants.WAD, supply);
    }

    function totalSupply() public view override(ERC20Upgradeable, ILeveragedToken) returns (uint256) {
        return super.totalSupply();
    }

    // ================================================================== admin / guardian

    function setFees(uint256 mintBps, uint256 redeemBps, uint256 mgmtBps) external onlyAdmin {
        if (mgmtBps > Constants.MAX_MGMT_FEE_BPS) revert BadConfig();
        if (mintBps > Constants.MAX_MINT_REDEEM_FEE_BPS || redeemBps > Constants.MAX_MINT_REDEEM_FEE_BPS) {
            revert BadConfig();
        }
        accrueManagementFee();
        mintFeeBps = mintBps;
        redeemFeeBps = redeemBps;
        mgmtFeeBps = mgmtBps;
        emit FeesSet(mintBps, redeemBps, mgmtBps);
    }

    function setLimits(uint256 cap, uint256 minMint, uint256 bufferBps) external onlyAdmin {
        if (bufferBps > MAX_MINT_BUFFER_BPS) revert BadConfig();
        supplyCapEquity = cap;
        minMintQuote = minMint;
        mintBufferBps = bufferBps;
        emit LimitsSet(cap, minMint, bufferBps);
    }

    /// @notice Band changes are validated by the factory against the venue's liquidation LTV.
    function setLeverageBand(uint256 target, uint256 min, uint256 max) external {
        if (msg.sender != address(_factory())) revert NotAdmin();
        targetLeverage = target;
        minLeverage = min;
        maxLeverage = max;
        emit LeverageBandSet(target, min, max);
    }

    function pause() external {
        if (!registry.hasRole(Constants.GUARDIAN_ROLE, msg.sender)) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    // ================================================================== internals

    function _factory() internal view returns (ITriplexRegistry) {
        return registry;
    }

    function _checkAction(uint256 deadline, bytes32 action) internal view {
        if (block.timestamp > deadline) revert Expired();
        if (!registry.marketClock().isMintRedeemOpen()) revert MarketClosed();
        if (msg.sender == registry.feeCollector()) return;
        IComplianceRegistry c = registry.complianceRegistry();
        if (address(c) != address(0) && !c.isAllowed(msg.sender, action)) revert NotAllowed();
    }

    function _fee(address account, uint256 amount, uint256 bps) internal view returns (uint256) {
        if (bps == 0 || account == registry.feeCollector()) return 0;
        uint256 discount;
        IProjectTokenHooks hooks = registry.projectTokenHooks();
        if (address(hooks) != address(0)) discount = hooks.feeDiscountBps(account);
        if (discount >= Constants.BPS) return 0;
        return amount.mulDiv(bps * (Constants.BPS - discount), Constants.BPS * Constants.BPS, Math.Rounding.Ceil);
    }

    function _pendingFeeShares(uint256 elapsed) internal view returns (uint256) {
        uint256 supply = super.totalSupply();
        uint256 rate = mgmtFeeBps;
        if (supply == 0 || rate == 0 || elapsed == 0) return 0;
        // shares such that newShares / (supply + newShares) = rate * elapsed / (BPS * YEAR)
        uint256 num = rate * elapsed;
        uint256 den = Constants.BPS * Constants.YEAR;
        if (num >= den) num = den - 1;
        return supply.mulDiv(num, den - num);
    }

    function _quoteDecimals() internal view returns (uint8) {
        return ERC20Upgradeable(quoteToken).decimals();
    }
}
