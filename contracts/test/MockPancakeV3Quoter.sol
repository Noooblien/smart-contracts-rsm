// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPancakeV3Quoter {
    uint256 public amountOut = 1 ether;

    function setAmountOut(uint256 value) external {
        amountOut = value;
    }

    function quoteExactInputSingle(
        address,
        address,
        uint256,
        uint24,
        uint160
    ) external returns (uint256, uint160, uint32, uint256) {
        return (amountOut, 0, 0, 0);
    }

    function quoteExactInput(bytes memory, uint256) external returns (uint256, uint160[] memory, uint32[] memory, uint256) {
        uint160[] memory sqrtPrices = new uint160[](0);
        uint32[] memory ticks = new uint32[](0);
        return (amountOut, sqrtPrices, ticks, 0);
    }
}
