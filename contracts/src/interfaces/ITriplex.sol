// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price oracle. All prices are 18-decimal fixed point.
interface IOracleAdapter {
    /// @return priceWad USD price of one whole `asset` token. Reverts if stale/invalid.
    function getPrice(address asset) external view returns (uint256 priceWad);
    /// @return priceWad price of one whole `asset` expressed in whole `quote` tokens, with deviation checks.
    function getQuotePrice(address asset, address quote) external view returns (uint256 priceWad);
    /// @return ok false instead of reverting when the price is unusable.
    function tryGetQuotePrice(address asset, address quote) external view returns (bool ok, uint256 priceWad);
}

/// @notice Optional secondary price source used for deviation checks.
interface IPriceSource {
    /// @return priceWad price of one whole `asset` in whole `quote` tokens.
    function getQuotePrice(address asset, address quote) external view returns (uint256 priceWad);
}

/// @notice Swap venue abstraction (keeps the DEX swappable).
interface ISwapAdapter {
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut);
    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, address recipient)
        external
        returns (uint256 amountIn);
}

/// @notice US equity market calendar.
interface IMarketClock {
    function isMarketOpen() external view returns (bool);
    function isMintRedeemOpen() external view returns (bool);
    function isDailyRebalanceWindow() external view returns (bool);
    function tradingDayId(uint256 timestamp) external view returns (uint256);
}

/// @notice Pluggable allowlist hook. Off by default (returns true for everyone).
interface IComplianceRegistry {
    function isAllowed(address account, bytes32 action) external view returns (bool);
}

/// @notice Project-token ($TRPX) integration. Inactive until `setProjectToken` is executed via the Timelock.
interface IProjectTokenHooks {
    function isActive() external view returns (bool);
    /// @return discountBps fraction of the mint/redeem fee waived for `account` (0 when inactive).
    function feeDiscountBps(address account) external view returns (uint256 discountBps);
    function totalStaked() external view returns (uint256);
    function notifyReward(uint256 amount) external;
}

/// @notice Leveraged position on an external venue. One adapter instance per product.
interface IPositionAdapter {
    function product() external view returns (address);
    function asset() external view returns (address);
    function quote() external view returns (address);
    function isLong() external view returns (bool);
    /// @return price asset price in quote (WAD) from the OracleAdapter.
    function assetPrice() external view returns (uint256 price);
    /// @return exposure notional of the underlying (WAD, quote units)
    /// @return collateralValue collateral value (WAD, quote units)
    /// @return debtValue debt value (WAD, quote units)
    /// @return equity max(collateralValue - debtValue, 0)
    function positionValues()
        external
        view
        returns (uint256 exposure, uint256 collateralValue, uint256 debtValue, uint256 equity);
    function leverage() external view returns (uint256 leverageWad);
    function currentLtv() external view returns (uint256 ltvWad);
    function liquidationLtv() external view returns (uint256 lltvWad);
    function hasPosition() external view returns (bool);

    // ---- product only ----
    function openInitial(uint256 quoteIn, uint256 targetLeverageWad) external;
    function mintProportional(uint256 quoteIn, uint256 fractionWad, address refundTo) external returns (uint256 used);
    function redeemProportional(uint256 fractionWad, address to) external returns (uint256 quoteOut);

    // ---- rebalancer only ----
    function increaseExposure(uint256 quoteValueWad) external;
    function decreaseExposure(uint256 quoteValueWad) external;
}

/// @notice Leveraged product share token.
interface ILeveragedToken {
    function adapter() external view returns (IPositionAdapter);
    function underlying() external view returns (address);
    function quoteToken() external view returns (address);
    function isLong() external view returns (bool);
    function targetLeverage() external view returns (uint256);
    function minLeverage() external view returns (uint256);
    function maxLeverage() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function mgmtFeeBps() external view returns (uint256);
    function lastFeeAccrual() external view returns (uint256);
    function accrueManagementFee() external returns (uint256 feeShares);
    function recordDailySnapshot() external;
    function pendingFeeShares() external view returns (uint256);
    function redeem(uint256 shares, uint256 minQuoteOut, uint256 deadline) external returns (uint256 quoteOut);
}

/// @notice Protocol registry (implemented by LeveragedTokenFactory).
interface ITriplexRegistry {
    function oracle() external view returns (IOracleAdapter);
    function marketClock() external view returns (IMarketClock);
    function swapAdapter() external view returns (ISwapAdapter);
    function rebalancer() external view returns (address);
    function feeCollector() external view returns (address);
    function projectTokenHooks() external view returns (IProjectTokenHooks);
    function complianceRegistry() external view returns (IComplianceRegistry);
    function isProduct(address product) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}
