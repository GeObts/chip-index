// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Minimal Uniswap v4 surface for one exact-input swap. Copied in shape from
 * chipworks-contracts/src/interfaces/IUniswapV4.sol, which was proven against the live
 * $CHIP pool there (test/fork/V4SignConvention.t.sol).
 */

/// @notice A v4 pool's identity. `fee` carries the dynamic-fee flag 0x800000 for the
///         hook-priced $CHIP pool.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev FIELD ORDER IS LOAD-BEARING: v4-core declares `zeroForOne` first. Swapping the order
///      changes the `swap` selector and the PoolManager reverts with no reason.
///      `amountSpecified`: NEGATIVE = exact input, POSITIVE = exact output.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @return swapDelta packed (int128 amount0, int128 amount1), caller's view:
    ///         negative = owed TO the pool, positive = owed BY it.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @dev Settle pattern is sync -> transfer -> settle; skipping sync credits nothing.
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
