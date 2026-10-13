// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Aerodrome Slipstream SwapRouter (0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F on Base).
/// @dev Same shape as Uniswap v3's original SwapRouter, except pools are keyed by tick spacing
///      (int24, 3 bytes in a path) instead of fee tier. All four selectors were checked against
///      the deployed bytecode on 2026-10-12.
///
///      Path encoding: exactInput paths run tokenIn -> tokenOut; exactOutput paths are REVERSED
///      (tokenOut first). Each hop is `token (20) | tickSpacing (3) | token (20)`.
interface ISlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
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
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function factory() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

/// @notice Aerodrome Slipstream CL factory.
interface ISlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}
