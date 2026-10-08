// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IMorpho, IMorphoFlashLoanCallback, IIrm, Id, MarketParams, Market
} from "../interfaces/external/IMorpho.sol";
import {IPositionAdapter, ITriplexRegistry, ISwapAdapter} from "../interfaces/ITriplex.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title MorphoPositionAdapter
/// @notice Holds one product's leveraged position in an isolated Morpho Blue market and trades through the
///         registry's swap adapter.
///         LONG  : collateral = stock token, debt = quote stablecoin (borrow USDG, buy stock).
///         SHORT : collateral = quote stablecoin, debt = stock token (borrow stock, sell for USDG).
/// @dev Deployed as EIP-1167 clones by LeveragedTokenFactory. `morpho` is an implementation immutable shared by all
///      clones. Mints and redeems scale collateral AND debt by the same fraction, so share pricing is independent of
///      the oracle and the minter/redeemer bears their own execution cost.
contract MorphoPositionAdapter is IPositionAdapter, IMorphoFlashLoanCallback, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    enum Op {
        None,
        OpenLong,
        OpenShort,
        MintLong,
        MintShort,
        RedeemLong,
        RedeemShort,
        DecreaseLong,
        DecreaseShort
    }

    uint256 private constant VIRTUAL_SHARES = 1e6; // Morpho SharesMathLib
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 500;

    IMorpho public immutable morpho;

    ITriplexRegistry public registry;
    address public product;
    address public asset;
    address public quote;
    bool public isLong;
    MarketParams internal _params;
    Id public marketId;
    uint256 public maxSwapSlippageBps;
    uint256 internal _assetUnit;
    uint256 internal _quoteUnit;
    Op internal _activeOp;

    event Opened(uint256 quoteIn, uint256 targetLeverage, uint256 collateral, uint256 debt);
    event MintExecuted(uint256 fractionWad, uint256 quoteUsed, uint256 collateralAdded, uint256 debtAdded);
    event RedeemExecuted(uint256 fractionWad, uint256 quoteOut, uint256 collateralRemoved, uint256 debtRepaid);
    event ExposureIncreased(uint256 valueWad, uint256 collateralAdded, uint256 debtAdded);
    event ExposureDecreased(uint256 valueWad, uint256 collateralRemoved, uint256 debtRepaid);
    event MaxSwapSlippageSet(uint256 bps);

    error NotProduct();
    error NotRebalancer();
    error NotAdmin();
    error BadMarket();
    error BadConfig();
    error UnexpectedCallback();
    error PositionExists();
    error NoPosition();
    error InsufficientQuote();
    error ZeroAmount();

    constructor(IMorpho morpho_) {
        morpho = morpho_;
        _disableInitializers();
    }

    function initialize(
        ITriplexRegistry registry_,
        address product_,
        address asset_,
        address quote_,
        bool isLong_,
        MarketParams calldata params,
        uint256 maxSwapSlippageBps_
    ) external initializer {
        __ReentrancyGuard_init();
        if (maxSwapSlippageBps_ > MAX_SWAP_SLIPPAGE_BPS) revert BadConfig();
        if (isLong_) {
            if (params.loanToken != quote_ || params.collateralToken != asset_) revert BadMarket();
        } else {
            if (params.loanToken != asset_ || params.collateralToken != quote_) revert BadMarket();
        }
        registry = registry_;
        product = product_;
        asset = asset_;
        quote = quote_;
        isLong = isLong_;
        _params = params;
        Id id = Id.wrap(keccak256(abi.encode(params)));
        marketId = id;
        maxSwapSlippageBps = maxSwapSlippageBps_;
        _assetUnit = 10 ** IERC20Metadata(asset_).decimals();
        _quoteUnit = 10 ** IERC20Metadata(quote_).decimals();

        (,,,, uint128 lastUpdate,) = morpho.market(id);
        if (lastUpdate == 0) morpho.createMarket(params);

        IERC20(asset_).forceApprove(address(morpho), type(uint256).max);
        IERC20(quote_).forceApprove(address(morpho), type(uint256).max);
    }

    modifier onlyProduct() {
        if (msg.sender != product) revert NotProduct();
        _;
    }

    modifier onlyRebalancer() {
        if (msg.sender != registry.rebalancer()) revert NotRebalancer();
        _;
    }

    function setMaxSwapSlippage(uint256 bps) external {
        if (!registry.hasRole(0x00, msg.sender)) revert NotAdmin();
        if (bps > MAX_SWAP_SLIPPAGE_BPS) revert BadConfig();
        maxSwapSlippageBps = bps;
        emit MaxSwapSlippageSet(bps);
    }

    // ================================================================== views

    function marketParams() external view returns (MarketParams memory) {
        return _params;
    }

    /// @inheritdoc IPositionAdapter
    function assetPrice() public view returns (uint256) {
        return registry.oracle().getQuotePrice(asset, quote);
    }

    /// @return collateral raw collateral token amount
    /// @return debt raw debt token amount including interest accrued since the last market update
    function positionRaw() public view returns (uint256 collateral, uint256 debt) {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        collateral = coll;
        if (borrowShares != 0) {
            Market memory m = _expectedMarket();
            debt = _toAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        }
    }

    /// @inheritdoc IPositionAdapter
    function positionValues()
        public
        view
        returns (uint256 exposure, uint256 collateralValue, uint256 debtValue, uint256 equity)
    {
        (uint256 c, uint256 d) = positionRaw();
        if (c == 0 && d == 0) return (0, 0, 0, 0);
        uint256 p = assetPrice();
        if (isLong) {
            collateralValue = _assetToWad(c, p);
            debtValue = _quoteToWad(d);
            exposure = collateralValue;
        } else {
            collateralValue = _quoteToWad(c);
            debtValue = _assetToWad(d, p);
            exposure = debtValue;
        }
        equity = collateralValue > debtValue ? collateralValue - debtValue : 0;
    }

    /// @inheritdoc IPositionAdapter
    function leverage() external view returns (uint256) {
        (uint256 exposure,,, uint256 equity) = positionValues();
        if (equity == 0) return exposure == 0 ? 0 : type(uint256).max;
        return exposure.mulDiv(Constants.WAD, equity);
    }

    /// @inheritdoc IPositionAdapter
    function currentLtv() external view returns (uint256) {
        (, uint256 cv, uint256 dv,) = positionValues();
        if (cv == 0) return dv == 0 ? 0 : type(uint256).max;
        return dv.mulDiv(Constants.WAD, cv);
    }

    /// @inheritdoc IPositionAdapter
    function liquidationLtv() external view returns (uint256) {
        return _params.lltv;
    }

    /// @inheritdoc IPositionAdapter
    function hasPosition() public view returns (bool) {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        return coll != 0 || borrowShares != 0;
    }

    // ================================================================== product actions

    /// @inheritdoc IPositionAdapter
    function openInitial(uint256 quoteIn, uint256 targetLeverageWad) external onlyProduct nonReentrant {
        if (hasPosition()) revert PositionExists();
        if (quoteIn == 0) revert ZeroAmount();
        if (targetLeverageWad < Constants.WAD / 2 || targetLeverageWad > 10 * Constants.WAD) revert BadConfig();
        morpho.accrueInterest(_params);
        uint256 p = assetPrice();
        if (isLong) {
            uint256 flash = quoteIn.mulDiv(targetLeverageWad - Math.min(targetLeverageWad, Constants.WAD), Constants.WAD);
            _flash(quote, flash, Op.OpenLong, abi.encode(quoteIn, flash, p));
        } else {
            uint256 notional = quoteIn.mulDiv(targetLeverageWad, Constants.WAD);
            _flash(quote, notional, Op.OpenShort, abi.encode(quoteIn, notional, p));
        }
        (uint256 c, uint256 d) = positionRaw();
        emit Opened(quoteIn, targetLeverageWad, c, d);
    }

    /// @inheritdoc IPositionAdapter
    function mintProportional(uint256 quoteIn, uint256 fractionWad, address refundTo)
        external
        onlyProduct
        nonReentrant
        returns (uint256 used)
    {
        if (fractionWad == 0 || quoteIn == 0) revert ZeroAmount();
        morpho.accrueInterest(_params);
        (uint256 c, uint256 d) = positionRaw();
        if (c == 0) revert NoPosition();
        // round against the minter: more collateral, less debt
        uint256 addColl = c.mulDiv(fractionWad, Constants.WAD, Math.Rounding.Ceil);
        uint256 addDebt = d.mulDiv(fractionWad, Constants.WAD);
        uint256 p = assetPrice();
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));

        if (isLong) {
            _flash(quote, addDebt, Op.MintLong, abi.encode(quoteIn, addColl, addDebt, p));
        } else {
            uint256 flash = addColl > quoteIn ? addColl - quoteIn : 0;
            _flash(quote, flash, Op.MintShort, abi.encode(addColl, addDebt, flash, p));
        }

        // quoteBefore includes quoteIn (sent by the product before this call); anything above the pre-existing idle
        // balance belongs to the minter and is refunded.
        uint256 idle = quoteBefore - quoteIn;
        uint256 quoteAfter = IERC20(quote).balanceOf(address(this));
        if (quoteAfter < idle) revert InsufficientQuote();
        uint256 refund = quoteAfter - idle;
        if (refund > quoteIn) refund = quoteIn;
        used = quoteIn - refund;
        if (refund != 0) IERC20(quote).safeTransfer(refundTo, refund);
        emit MintExecuted(fractionWad, used, addColl, addDebt);
    }

    /// @inheritdoc IPositionAdapter
    function redeemProportional(uint256 fractionWad, address to)
        external
        onlyProduct
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (fractionWad == 0 || fractionWad > Constants.WAD) revert ZeroAmount();
        morpho.accrueInterest(_params);
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        // round against the redeemer: repay more debt, withdraw less collateral
        uint256 repayShares = uint256(borrowShares).mulDiv(fractionWad, Constants.WAD, Math.Rounding.Ceil);
        uint256 removeColl = uint256(coll).mulDiv(fractionWad, Constants.WAD);
        (,, uint128 tba, uint128 tbs,,) = morpho.market(marketId);
        uint256 debtAssets = _toAssetsUp(repayShares, tba, tbs);
        uint256 p = assetPrice();
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));

        if (isLong) {
            _flash(quote, debtAssets, Op.RedeemLong, abi.encode(repayShares, debtAssets, removeColl, p));
        } else {
            _flash(quote, removeColl, Op.RedeemShort, abi.encode(repayShares, debtAssets, removeColl, p));
        }

        uint256 quoteAfter = IERC20(quote).balanceOf(address(this));
        quoteOut = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        if (quoteOut != 0) IERC20(quote).safeTransfer(to, quoteOut);
        emit RedeemExecuted(fractionWad, quoteOut, removeColl, debtAssets);
    }

    // ================================================================== rebalancer actions

    /// @inheritdoc IPositionAdapter
    function increaseExposure(uint256 valueWad) external onlyRebalancer nonReentrant {
        if (valueWad == 0) revert ZeroAmount();
        morpho.accrueInterest(_params);
        uint256 p = assetPrice();
        uint256 q = _wadToQuote(valueWad);
        uint256 s = maxSwapSlippageBps;
        if (isLong) {
            morpho.borrow(_params, q, 0, address(this), address(this));
            uint256 minOut = _quoteToAsset(q, p).mulDiv(Constants.BPS - s, Constants.BPS);
            uint256 out = _swapExactIn(quote, asset, q, minOut);
            morpho.supplyCollateral(_params, out, address(this), "");
            emit ExposureIncreased(valueWad, out, q);
        } else {
            uint256 a = _quoteToAsset(q, p);
            if (a == 0) revert ZeroAmount();
            morpho.borrow(_params, a, 0, address(this), address(this));
            uint256 minOut = _assetToQuote(a, p).mulDiv(Constants.BPS - s, Constants.BPS);
            uint256 out = _swapExactIn(asset, quote, a, minOut);
            morpho.supplyCollateral(_params, out, address(this), "");
            emit ExposureIncreased(valueWad, out, a);
        }
    }

    /// @inheritdoc IPositionAdapter
    function decreaseExposure(uint256 valueWad) external onlyRebalancer nonReentrant {
        if (valueWad == 0) revert ZeroAmount();
        morpho.accrueInterest(_params);
        uint256 p = assetPrice();
        (uint256 c, uint256 d) = positionRaw();
        if (d == 0) revert NoPosition();
        uint256 s = maxSwapSlippageBps;
        if (isLong) {
            uint256 q = Math.min(_wadToQuote(valueWad), d);
            uint256 maxAssetIn = Math.min(_quoteToAsset(q, p).mulDiv(Constants.BPS + s, Constants.BPS), c);
            _flash(quote, q, Op.DecreaseLong, abi.encode(q, d, maxAssetIn));
            emit ExposureDecreased(valueWad, maxAssetIn, q);
        } else {
            uint256 a = Math.min(_quoteToAsset(_wadToQuote(valueWad), p), d);
            if (a == 0) revert ZeroAmount();
            uint256 maxQuoteIn = Math.min(_assetToQuote(a, p).mulDiv(Constants.BPS + s, Constants.BPS), c);
            _flash(quote, maxQuoteIn, Op.DecreaseShort, abi.encode(a, d, maxQuoteIn));
            emit ExposureDecreased(valueWad, maxQuoteIn, a);
        }
    }

    // ================================================================== flash-loan callback

    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        if (msg.sender != address(morpho) || _activeOp == Op.None) revert UnexpectedCallback();
        _execute(_activeOp, data);
    }

    function _flash(address token, uint256 amount, Op op, bytes memory data) internal {
        _activeOp = op;
        if (amount == 0) {
            _execute(op, data);
        } else {
            morpho.flashLoan(token, amount, data);
        }
        _activeOp = Op.None;
    }

    function _execute(Op op, bytes memory data) internal {
        uint256 s = maxSwapSlippageBps;
        if (op == Op.OpenLong) {
            (uint256 quoteIn, uint256 flash, uint256 p) = abi.decode(data, (uint256, uint256, uint256));
            uint256 total = quoteIn + flash;
            uint256 minOut = _quoteToAsset(total, p).mulDiv(Constants.BPS - s, Constants.BPS);
            uint256 out = _swapExactIn(quote, asset, total, minOut);
            morpho.supplyCollateral(_params, out, address(this), "");
            if (flash != 0) morpho.borrow(_params, flash, 0, address(this), address(this));
        } else if (op == Op.OpenShort) {
            (uint256 quoteIn, uint256 notional, uint256 p) = abi.decode(data, (uint256, uint256, uint256));
            morpho.supplyCollateral(_params, quoteIn + notional, address(this), "");
            uint256 borrowAmt = _quoteToAsset(notional, p).mulDiv(Constants.BPS + s, Constants.BPS);
            morpho.borrow(_params, borrowAmt, 0, address(this), address(this));
            uint256 spent = _swapExactOut(asset, quote, notional, borrowAmt);
            if (borrowAmt > spent) morpho.repay(_params, borrowAmt - spent, 0, address(this), "");
        } else if (op == Op.MintLong) {
            (uint256 quoteIn, uint256 addColl, uint256 addDebt, uint256 p) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            uint256 maxIn =
                Math.min(quoteIn + addDebt, _assetToQuote(addColl, p).mulDiv(Constants.BPS + s, Constants.BPS) + 1);
            _swapExactOut(quote, asset, addColl, maxIn);
            morpho.supplyCollateral(_params, addColl, address(this), "");
            if (addDebt != 0) morpho.borrow(_params, addDebt, 0, address(this), address(this));
        } else if (op == Op.MintShort) {
            (uint256 addColl, uint256 addDebt, uint256 flash, uint256 p) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            morpho.supplyCollateral(_params, addColl, address(this), "");
            if (addDebt != 0) {
                morpho.borrow(_params, addDebt, 0, address(this), address(this));
                uint256 minOut = _assetToQuote(addDebt, p).mulDiv(Constants.BPS - s, Constants.BPS);
                uint256 out = _swapExactIn(asset, quote, addDebt, minOut);
                if (out < flash) revert InsufficientQuote();
            } else if (flash != 0) {
                revert InsufficientQuote();
            }
        } else if (op == Op.RedeemLong) {
            (uint256 repayShares, uint256 debtAssets, uint256 removeColl, uint256 p) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            if (repayShares != 0) morpho.repay(_params, 0, repayShares, address(this), "");
            if (removeColl != 0) {
                morpho.withdrawCollateral(_params, removeColl, address(this), address(this));
                uint256 minOut = Math.max(_assetToQuote(removeColl, p).mulDiv(Constants.BPS - s, Constants.BPS), debtAssets);
                _swapExactIn(asset, quote, removeColl, minOut);
            }
        } else if (op == Op.RedeemShort) {
            (uint256 repayShares, uint256 debtAssets, uint256 removeColl, uint256 p) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            if (debtAssets != 0) {
                uint256 maxIn =
                    Math.min(removeColl, _assetToQuote(debtAssets, p).mulDiv(Constants.BPS + s, Constants.BPS) + 1);
                _swapExactOut(quote, asset, debtAssets, maxIn);
                morpho.repay(_params, 0, repayShares, address(this), "");
            }
            if (removeColl != 0) morpho.withdrawCollateral(_params, removeColl, address(this), address(this));
        } else if (op == Op.DecreaseLong) {
            (uint256 q, uint256 d, uint256 maxAssetIn) = abi.decode(data, (uint256, uint256, uint256));
            _repay(q, d);
            morpho.withdrawCollateral(_params, maxAssetIn, address(this), address(this));
            uint256 spent = _swapExactOut(asset, quote, q, maxAssetIn);
            if (maxAssetIn > spent) morpho.supplyCollateral(_params, maxAssetIn - spent, address(this), "");
        } else if (op == Op.DecreaseShort) {
            (uint256 a, uint256 d, uint256 maxQuoteIn) = abi.decode(data, (uint256, uint256, uint256));
            uint256 spent = _swapExactOut(quote, asset, a, maxQuoteIn);
            _repay(a, d);
            morpho.withdrawCollateral(_params, spent, address(this), address(this));
        } else {
            revert UnexpectedCallback();
        }
    }

    // ================================================================== helpers

    /// @dev Repays `amount` debt assets; when `amount` covers the whole debt, repays by shares to avoid dust.
    function _repay(uint256 amount, uint256 totalDebt) internal {
        if (amount >= totalDebt) {
            (, uint128 borrowShares,) = morpho.position(marketId, address(this));
            morpho.repay(_params, 0, borrowShares, address(this), "");
        } else {
            morpho.repay(_params, amount, 0, address(this), "");
        }
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        ISwapAdapter sa = registry.swapAdapter();
        IERC20(tokenIn).forceApprove(address(sa), amountIn);
        uint256 out = sa.swapExactIn(tokenIn, tokenOut, amountIn, minOut, address(this));
        IERC20(tokenIn).forceApprove(address(sa), 0);
        return out;
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        returns (uint256)
    {
        ISwapAdapter sa = registry.swapAdapter();
        IERC20(tokenIn).forceApprove(address(sa), maxIn);
        uint256 spent = sa.swapExactOut(tokenIn, tokenOut, amountOut, maxIn, address(this));
        IERC20(tokenIn).forceApprove(address(sa), 0);
        return spent;
    }

    function _expectedMarket() internal view returns (Market memory m) {
        (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee) =
            morpho.market(marketId);
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed != 0 && m.totalBorrowAssets != 0 && _params.irm != address(0)) {
            uint256 rate = IIrm(_params.irm).borrowRateView(_params, m);
            uint256 interest = uint256(m.totalBorrowAssets).mulDiv(_wTaylorCompounded(rate, elapsed), Constants.WAD);
            m.totalBorrowAssets += uint128(interest);
        }
    }

    function _wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 first = x * n;
        uint256 second = first.mulDiv(first, 2 * Constants.WAD);
        uint256 third = second.mulDiv(first, 3 * Constants.WAD);
        return first + second + third;
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDiv(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function _assetToWad(uint256 a, uint256 p) internal view returns (uint256) {
        return a.mulDiv(p, _assetUnit);
    }

    function _quoteToWad(uint256 q) internal view returns (uint256) {
        return q.mulDiv(Constants.WAD, _quoteUnit);
    }

    function _wadToQuote(uint256 w) internal view returns (uint256) {
        return w.mulDiv(_quoteUnit, Constants.WAD);
    }

    function _assetToQuote(uint256 a, uint256 p) internal view returns (uint256) {
        return a.mulDiv(p * _quoteUnit, Constants.WAD * _assetUnit);
    }

    function _quoteToAsset(uint256 q, uint256 p) internal view returns (uint256) {
        return q.mulDiv(Constants.WAD * _assetUnit, p * _quoteUnit);
    }
}
