// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02, IUniswapV3Factory} from "../interfaces/external/IUniswapV3.sol";
import {ISwapAdapter} from "../interfaces/ITriplex.sol";

/// @title UniswapV3SwapAdapter
/// @notice Stateless swap venue adapter over Uniswap v3 SwapRouter02. Routes are fixed by governance (fee tier per
///         pair) so keepers and users cannot choose a malicious path. Holds no funds between calls.
contract UniswapV3SwapAdapter is ISwapAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    IUniswapV3Factory public immutable uniFactory;

    mapping(bytes32 pairKey => uint24 fee) public poolFee;

    event PoolFeeSet(address indexed tokenA, address indexed tokenB, uint24 fee);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error RouteNotSet(address tokenIn, address tokenOut);
    error PoolMissing();
    error ZeroAmount();

    constructor(address admin, ISwapRouter02 router_, IUniswapV3Factory factory_) {
        router = router_;
        uniFactory = factory_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function pairKey(address a, address b) public pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function setPoolFee(address tokenA, address tokenB, uint24 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (uniFactory.getPool(tokenA, tokenB, fee) == address(0)) revert PoolMissing();
        poolFee[pairKey(tokenA, tokenB)] = fee;
        emit PoolFeeSet(tokenA, tokenB, fee);
    }

    /// @inheritdoc ISwapAdapter
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        uint24 fee = _fee(tokenIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc ISwapAdapter
    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, address recipient)
        external
        nonReentrant
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert ZeroAmount();
        uint24 fee = _fee(tokenIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxAmountIn);
        IERC20(tokenIn).forceApprove(address(router), maxAmountIn);
        amountIn = router.exactOutputSingle(
            ISwapRouter02.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountOut: amountOut,
                amountInMaximum: maxAmountIn,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        if (maxAmountIn > amountIn) IERC20(tokenIn).safeTransfer(msg.sender, maxAmountIn - amountIn);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _fee(address tokenIn, address tokenOut) internal view returns (uint24 fee) {
        fee = poolFee[pairKey(tokenIn, tokenOut)];
        if (fee == 0) revert RouteNotSet(tokenIn, tokenOut);
    }
}
