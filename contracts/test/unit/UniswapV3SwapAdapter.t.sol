// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02, IUniswapV3Factory} from "../../src/interfaces/external/IUniswapV3.sol";
import {UniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @dev 1 tokenA = 2 tokenB, pulls input via allowance like SwapRouter02.
contract MockRouter {
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external returns (uint256 out) {
        out = p.amountIn * 2;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }

    function exactOutputSingle(ISwapRouter02.ExactOutputSingleParams calldata p) external returns (uint256 amountIn) {
        amountIn = (p.amountOut + 1) / 2;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, p.amountOut);
    }
}

contract MockUniFactory {
    mapping(bytes32 => address) public pools;

    function set(address a, address b, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(a, b, fee))] = pool;
        pools[keccak256(abi.encode(b, a, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a, b, fee))];
    }
}

contract UniswapV3SwapAdapterTest is Test {
    UniswapV3SwapAdapter sa;
    MockRouter router;
    MockUniFactory uf;
    MockERC20 a;
    MockERC20 b;
    address admin = makeAddr("admin");

    function setUp() public {
        router = new MockRouter();
        uf = new MockUniFactory();
        sa = new UniswapV3SwapAdapter(admin, ISwapRouter02(address(router)), IUniswapV3Factory(address(uf)));
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 6);
        uf.set(address(a), address(b), 500, address(0x9001));
        a.mint(address(this), 1_000e18);
        a.approve(address(sa), type(uint256).max);
    }

    function test_routeRequired_andPoolMustExist() public {
        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapAdapter.RouteNotSet.selector, address(a), address(b)));
        sa.swapExactIn(address(a), address(b), 1e18, 0, address(this));
        vm.prank(admin);
        vm.expectRevert(UniswapV3SwapAdapter.PoolMissing.selector);
        sa.setPoolFee(address(a), address(b), 3000);
        vm.expectRevert();
        sa.setPoolFee(address(a), address(b), 500); // not admin
        vm.prank(admin);
        sa.setPoolFee(address(b), address(a), 500);
        assertEq(sa.poolFee(sa.pairKey(address(a), address(b))), 500);
    }

    function test_swaps() public {
        vm.prank(admin);
        sa.setPoolFee(address(a), address(b), 500);
        uint256 out = sa.swapExactIn(address(a), address(b), 10e18, 20e18, address(this));
        assertEq(out, 20e18);
        assertEq(b.balanceOf(address(this)), 20e18);
        uint256 balBefore = a.balanceOf(address(this));
        uint256 spent = sa.swapExactOut(address(a), address(b), 4e18, 5e18, address(this));
        assertEq(spent, 2e18);
        assertEq(balBefore - a.balanceOf(address(this)), 2e18); // unused max refunded
        assertEq(a.balanceOf(address(sa)), 0);
        assertEq(a.allowance(address(sa), address(router)), 0);
        vm.expectRevert(UniswapV3SwapAdapter.ZeroAmount.selector);
        sa.swapExactIn(address(a), address(b), 0, 0, address(this));
        vm.expectRevert(UniswapV3SwapAdapter.ZeroAmount.selector);
        sa.swapExactOut(address(a), address(b), 0, 1, address(this));
        vm.expectRevert("Too little received");
        sa.swapExactIn(address(a), address(b), 1e18, 3e18, address(this));
    }
}
