// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    Id, MarketParams, Market, IIrm, IMorphoOracle, IMorphoFlashLoanCallback
} from "../../src/interfaces/external/IMorpho.sol";
import {MockAggregator} from "./Mocks.sol";

/// @dev Faithful-enough Morpho Blue for unit tests: same share math (virtual shares/assets), health check against
///      the market oracle and LLTV, liquidity check, IRM-driven interest, free flash loans, authorization by
///      msg.sender == onBehalf, and a simplified liquidation.
contract MockMorpho {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 constant WAD = 1e18;
    uint256 constant ORACLE_SCALE = 1e36;
    uint256 constant VS = 1e6;
    uint256 constant VA = 1;

    struct Pos {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    mapping(Id => Market) public mkt;
    mapping(Id => MarketParams) public prm;
    mapping(Id => mapping(address => Pos)) public pos;
    mapping(uint256 => bool) public isLltvEnabled;
    mapping(address => bool) public isIrmEnabled;

    constructor() {
        isLltvEnabled[0.86e18] = true;
        isLltvEnabled[0.625e18] = true;
        isLltvEnabled[0] = true;
    }

    function enableIrm(address irm) external {
        isIrmEnabled[irm] = true;
    }

    function enableLltv(uint256 l) external {
        isLltvEnabled[l] = true;
    }

    function _id(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }

    function createMarket(MarketParams memory p) external {
        Id id = _id(p);
        require(isIrmEnabled[p.irm] && isLltvEnabled[p.lltv], "not enabled");
        require(mkt[id].lastUpdate == 0, "market already created");
        prm[id] = p;
        mkt[id].lastUpdate = uint128(block.timestamp);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Market memory m = mkt[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function position(Id id, address u) external view returns (uint256, uint128, uint128) {
        Pos memory p = pos[id][u];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function idToMarketParams(Id id) external view returns (address, address, address, address, uint256) {
        MarketParams memory p = prm[id];
        return (p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv);
    }

    function accrueInterest(MarketParams memory p) public {
        Id id = _id(p);
        Market storage m = mkt[id];
        require(m.lastUpdate != 0, "market not created");
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        if (p.irm != address(0) && m.totalBorrowAssets != 0) {
            uint256 rate = IIrm(p.irm).borrowRateView(p, m);
            uint256 x = rate * elapsed;
            uint256 interest = uint256(m.totalBorrowAssets).mulDiv(x + x * x / (2 * WAD) + (x * x / (2 * WAD)) * x / (3 * WAD), WAD);
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
        }
        m.lastUpdate = uint128(block.timestamp);
    }

    function supply(MarketParams memory p, uint256 assets, uint256, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = _id(p);
        accrueInterest(p);
        Market storage m = mkt[id];
        uint256 shares = assets.mulDiv(m.totalSupplyShares + VS, m.totalSupplyAssets + VA);
        pos[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes memory) external {
        Id id = _id(p);
        require(mkt[id].lastUpdate != 0, "market not created");
        require(assets != 0, "zero assets");
        pos[id][onBehalf].collateral += uint128(assets);
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets, address onBehalf, address receiver) external {
        Id id = _id(p);
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(p);
        pos[id][onBehalf].collateral -= uint128(assets);
        require(_healthy(p, id, onBehalf), "insufficient collateral");
        IERC20(p.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        Id id = _id(p);
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(p);
        Market storage m = mkt[id];
        if (assets > 0) shares = assets.mulDiv(m.totalBorrowShares + VS, m.totalBorrowAssets + VA, Math.Rounding.Ceil);
        else assets = shares.mulDiv(m.totalBorrowAssets + VA, m.totalBorrowShares + VS);
        pos[id][onBehalf].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);
        require(_healthy(p, id, onBehalf), "insufficient collateral");
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function repay(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = _id(p);
        accrueInterest(p);
        Market storage m = mkt[id];
        if (assets > 0) shares = assets.mulDiv(m.totalBorrowShares + VS, m.totalBorrowAssets + VA);
        else assets = shares.mulDiv(m.totalBorrowAssets + VA, m.totalBorrowShares + VS, Math.Rounding.Ceil);
        pos[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = m.totalBorrowAssets > assets ? m.totalBorrowAssets - uint128(assets) : 0;
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, "zero assets");
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @dev Simplified liquidation: seize `seized` collateral, repay its value / 1.05 of debt.
    function liquidate(MarketParams memory p, address borrower, uint256 seized) external {
        Id id = _id(p);
        accrueInterest(p);
        require(!_healthy(p, id, borrower), "position is healthy");
        Market storage m = mkt[id];
        uint256 price = IMorphoOracle(p.oracle).price();
        uint256 repaid = seized.mulDiv(price, ORACLE_SCALE).mulDiv(100, 105);
        uint256 shares = repaid.mulDiv(m.totalBorrowShares + VS, m.totalBorrowAssets + VA);
        Pos storage b = pos[id][borrower];
        if (shares > b.borrowShares) shares = b.borrowShares;
        b.borrowShares -= uint128(shares);
        b.collateral -= uint128(seized);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = m.totalBorrowAssets > repaid ? m.totalBorrowAssets - uint128(repaid) : 0;
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), repaid);
        IERC20(p.collateralToken).safeTransfer(msg.sender, seized);
    }

    function _healthy(MarketParams memory p, Id id, address u) internal view returns (bool) {
        Pos memory b = pos[id][u];
        if (b.borrowShares == 0) return true;
        Market memory m = mkt[id];
        uint256 borrowed = uint256(b.borrowShares).mulDiv(m.totalBorrowAssets + VA, m.totalBorrowShares + VS, Math.Rounding.Ceil);
        uint256 maxBorrow = uint256(b.collateral).mulDiv(IMorphoOracle(p.oracle).price(), ORACLE_SCALE).mulDiv(p.lltv, WAD);
        return maxBorrow >= borrowed;
    }
}

/// @dev Fixed borrow rate IRM (per-second WAD rate).
contract MockIrm {
    uint256 public rate;

    function setRate(uint256 r) external {
        rate = r;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return rate;
    }
}

/// @dev Morpho-style oracle from two Chainlink mocks: price of 1 collateral in loan units, scaled per Morpho spec.
contract MockMorphoOracle is IMorphoOracle {
    MockAggregator public immutable collAgg;
    MockAggregator public immutable loanAgg;
    uint256 public immutable scale;

    constructor(MockAggregator coll, MockAggregator loan, uint8 collDec, uint8 loanDec) {
        collAgg = coll;
        loanAgg = loan;
        scale = 10 ** (36 + loanDec + loan.decimals() - collDec - coll.decimals());
    }

    function price() external view returns (uint256) {
        return uint256(collAgg.answer()) * scale / uint256(loanAgg.answer());
    }
}
