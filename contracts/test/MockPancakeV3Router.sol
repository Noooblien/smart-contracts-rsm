// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    uint256 public exactOutputAmountIn;
    uint256 public exactInputAmountOut;

    function setExactOutputAmountIn(uint256 amount) external {
        exactOutputAmountIn = amount;
    }

    function setExactInputAmountOut(uint256 amount) external {
        exactInputAmountOut = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        _safeTransferFrom(p.tokenIn, msg.sender, address(this), p.amountIn);
        return exactInputAmountOut == 0 ? p.amountOutMinimum : exactInputAmountOut;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256) {
        address tokenIn = address(bytes20(p.path[:20]));
        _safeTransferFrom(tokenIn, msg.sender, address(this), p.amountIn);
        return exactInputAmountOut == 0 ? p.amountOutMinimum : exactInputAmountOut;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256) {
        uint256 amountIn = exactOutputAmountIn == 0 ? p.amountInMaximum : exactOutputAmountIn;
        _safeTransferFrom(p.tokenIn, msg.sender, address(this), amountIn);
        return amountIn;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}
