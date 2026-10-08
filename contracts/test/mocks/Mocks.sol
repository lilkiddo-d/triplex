// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/IChainlink.sol";
import {ISwapAdapter, IPriceSource} from "../../src/interfaces/ITriplex.sol";

/// @dev Test-only ERC-20 (also used as the mock $TRPX project token — never deployed outside tests).
contract MockERC20 is ERC20 {
    uint8 internal _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAggregator is AggregatorV3Interface {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setRounds(uint80 r, uint80 a) external {
        roundId = r;
        answeredInRound = a;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract MockPriceSource is IPriceSource {
    uint256 public price;
    bool public fail;

    function set(uint256 p, bool f) external {
        price = p;
        fail = f;
    }

    function getQuotePrice(address, address) external view returns (uint256) {
        require(!fail, "fail");
        return price;
    }
}

/// @dev Simulated DEX: executes at the Chainlink mock price, worsened by `slippageBps`, optionally offset from the
///      oracle by `marketOffsetBps` (positive = market above oracle). Mints output, burns input.
contract MockSwapAdapter is ISwapAdapter {
    mapping(address token => MockAggregator) public aggOf;
    mapping(address token => uint8) public decOf;
    uint256 public slippageBps;
    int256 public marketOffsetBps;
    address public stableToken; // priced at its own aggregator

    function setToken(address token, MockAggregator agg, uint8 dec) external {
        aggOf[token] = agg;
        decOf[token] = dec;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function setMarketOffset(int256 bps) external {
        marketOffsetBps = bps;
    }

    /// @dev USD (1e18) value of one whole token at the simulated market price.
    function _px(address token) internal view returns (uint256) {
        MockAggregator a = aggOf[token];
        uint256 p = uint256(a.answer()) * 10 ** (18 - a.decimals());
        // offset applies to the non-stable leg (decimals 18 tokens are the stocks in tests)
        if (decOf[token] == 18 && marketOffsetBps != 0) {
            p = uint256(int256(p) * (10_000 + marketOffsetBps) / 10_000);
        }
        return p;
    }

    function quoteOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 v = Math.mulDiv(amountIn, _px(tokenIn), 10 ** decOf[tokenIn]);
        uint256 out = Math.mulDiv(v, 10 ** decOf[tokenOut], _px(tokenOut));
        return out * (10_000 - slippageBps) / 10_000;
    }

    function quoteIn(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        uint256 v = Math.mulDiv(amountOut, _px(tokenOut), 10 ** decOf[tokenOut]);
        uint256 inAmt = Math.mulDiv(v, 10 ** decOf[tokenIn], _px(tokenIn), Math.Rounding.Ceil);
        return Math.mulDiv(inAmt, 10_000, 10_000 - slippageBps, Math.Rounding.Ceil);
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 out)
    {
        out = quoteOut(tokenIn, tokenOut, amountIn);
        require(out >= minAmountOut, "Too little received");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenIn).burn(address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, out);
    }

    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, address recipient)
        external
        returns (uint256 amountIn)
    {
        amountIn = quoteIn(tokenIn, tokenOut, amountOut);
        require(amountIn <= maxAmountIn, "Too much requested");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenIn).burn(address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, amountOut);
    }
}
