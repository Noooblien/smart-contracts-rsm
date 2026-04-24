// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISwapperQuote {
    function quoteSingleHop(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 slippageBps
    ) external returns (uint256 expectedOut, uint256 minOut, uint256 feeAmt);
}

contract QuoteCaller {
    function callQuote(address swapper, address tokenIn, address tokenOut) external {
        ISwapperQuote(swapper).quoteSingleHop(tokenIn, tokenOut, 2500, 1 ether, 0);
    }
}
