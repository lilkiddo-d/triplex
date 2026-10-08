// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITriplexRegistry, IPositionAdapter} from "./interfaces/ITriplex.sol";
import {LeveragedToken} from "./LeveragedToken.sol";
import {Constants} from "./libraries/Constants.sol";

interface IFactoryProducts {
    function allProducts() external view returns (address[] memory);
}

/// @title NAVCalculator
/// @notice Read-only aggregation for frontends and keepers: NAV, real leverage, LTVs and daily performance.
///         Never reverts on oracle failure; `priceOk` reports whether values are live.
contract NAVCalculator {
    using Math for uint256;

    ITriplexRegistry public immutable registry;

    struct ProductView {
        address product;
        address adapter;
        string symbol;
        address underlying;
        string underlyingSymbol;
        bool isLong;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        bool priceOk;
        uint256 price; // underlying in quote, WAD
        uint256 navPerShare; // WAD
        uint256 leverage; // WAD, real leverage
        uint256 exposure;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 equity;
        uint256 totalSupply;
        uint256 ltv;
        uint256 lltv;
        uint256 snapshotNav;
        uint256 snapshotPrice;
        uint256 snapshotTime;
        int256 dailyReturn; // WAD, product NAV vs last close snapshot
        int256 underlyingDailyReturn; // WAD, underlying vs last close snapshot
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 mgmtFeeBps;
        uint256 supplyCapEquity;
        bool paused;
    }

    constructor(ITriplexRegistry registry_) {
        registry = registry_;
    }

    function getProduct(address product) public view returns (ProductView memory v) {
        LeveragedToken t = LeveragedToken(product);
        IPositionAdapter a = t.adapter();
        v.product = product;
        v.adapter = address(a);
        v.symbol = t.symbol();
        v.underlying = t.underlying();
        v.underlyingSymbol = IERC20Metadata(v.underlying).symbol();
        v.isLong = t.isLong();
        v.targetLeverage = t.targetLeverage();
        v.minLeverage = t.minLeverage();
        v.maxLeverage = t.maxLeverage();
        v.totalSupply = t.totalSupply();
        v.lltv = a.liquidationLtv();
        v.snapshotNav = t.snapshotNav();
        v.snapshotPrice = t.snapshotPrice();
        v.snapshotTime = t.snapshotTime();
        v.mintFeeBps = t.mintFeeBps();
        v.redeemFeeBps = t.redeemFeeBps();
        v.mgmtFeeBps = t.mgmtFeeBps();
        v.supplyCapEquity = t.supplyCapEquity();
        v.paused = t.paused();

        (bool ok, uint256 price) = registry.oracle().tryGetQuotePrice(v.underlying, t.quoteToken());
        v.priceOk = ok;
        if (!ok) return v;
        v.price = price;
        (v.exposure, v.collateralValue, v.debtValue, v.equity) = a.positionValues();
        v.navPerShare = t.navPerShare();
        v.leverage = v.equity == 0 ? (v.exposure == 0 ? 0 : type(uint256).max) : v.exposure.mulDiv(Constants.WAD, v.equity);
        v.ltv = v.collateralValue == 0 ? 0 : v.debtValue.mulDiv(Constants.WAD, v.collateralValue);
        if (v.snapshotNav != 0) v.dailyReturn = _ret(v.navPerShare, v.snapshotNav);
        if (v.snapshotPrice != 0) v.underlyingDailyReturn = _ret(price, v.snapshotPrice);
    }

    function getProducts(address[] calldata products) external view returns (ProductView[] memory out) {
        out = new ProductView[](products.length);
        for (uint256 i; i < products.length; ++i) {
            out[i] = getProduct(products[i]);
        }
    }

    /// @notice All products (view-only; the list grows only through Timelock-gated `createProduct`).
    function getAllProducts() external view returns (ProductView[] memory out) {
        address[] memory products = IFactoryProducts(address(registry)).allProducts();
        out = new ProductView[](products.length);
        for (uint256 i; i < products.length; ++i) {
            out[i] = getProduct(products[i]);
        }
    }

    function _ret(uint256 nowV, uint256 thenV) internal pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return (int256(nowV) - int256(thenV)) * 1e18 / int256(thenV);
    }
}
