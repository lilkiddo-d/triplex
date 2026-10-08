// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3.sol";
import {IPriceSource} from "../interfaces/ITriplex.sol";

/// @title UniswapV3TwapPriceSource
/// @notice Secondary price source for OracleAdapter deviation checks: time-weighted average tick of a Uniswap v3 pool.
contract UniswapV3TwapPriceSource is IPriceSource, AccessControl {
    struct PoolConfig {
        IUniswapV3Pool pool;
        uint32 window;
    }

    uint256 private constant Q36 = 1e36;
    uint256 private constant BASE_Q36 = 1.0001e36; // 1.0001 in Q36
    int24 private constant MAX_TICK = 887_272;

    mapping(address asset => mapping(address quote => PoolConfig)) public pools;

    event PoolSet(address indexed asset, address indexed quote, address pool, uint32 window);

    error PoolNotSet();
    error BadConfig();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setPool(address asset, address quote, IUniswapV3Pool pool, uint32 window)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (window < 60 || window > 1 days) revert BadConfig();
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == asset && t1 == quote) || (t0 == quote && t1 == asset))) revert BadConfig();
        pools[asset][quote] = PoolConfig({pool: pool, window: window});
        emit PoolSet(asset, quote, address(pool), window);
    }

    /// @inheritdoc IPriceSource
    function getQuotePrice(address asset, address quote) external view returns (uint256) {
        PoolConfig memory cfg = pools[asset][quote];
        if (address(cfg.pool) == address(0)) revert PoolNotSet();

        uint32[] memory ago = new uint32[](2);
        ago[0] = cfg.window;
        (int56[] memory cum,) = cfg.pool.observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 w = int56(uint56(cfg.window));
        int24 tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) tick--; // round toward negative infinity

        // raw price of token0 in token1 units (Q36)
        uint256 p01 = tickToPriceQ36(tick);
        bool assetIs0 = cfg.pool.token0() == asset;
        uint256 aDec = IERC20Metadata(asset).decimals();
        uint256 qDec = IERC20Metadata(quote).decimals();
        // raw quote per raw asset (Q36)
        uint256 rawQ36 = assetIs0 ? p01 : Math.mulDiv(Q36, Q36, p01);
        // whole quote per whole asset, WAD: raw * 10^aDec / 10^qDec / 1e18
        return Math.mulDiv(rawQ36, 10 ** aDec, 10 ** qDec * 1e18);
    }

    /// @notice 1.0001^tick in Q36 fixed point, via binary exponentiation.
    function tickToPriceQ36(int24 tick) public pure returns (uint256) {
        if (tick > MAX_TICK || tick < -MAX_TICK) revert BadConfig();
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        uint256 result = Q36;
        uint256 base = BASE_Q36;
        while (absTick != 0) {
            if (absTick & 1 == 1) result = Math.mulDiv(result, base, Q36);
            absTick >>= 1;
            if (absTick != 0) base = Math.mulDiv(base, base, Q36);
        }
        return tick < 0 ? Math.mulDiv(Q36, Q36, result) : result;
    }
}
