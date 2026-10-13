// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chipworks ChipBurner (0x7Bc1C03e843C37845d89B54667382b4577Ead5C0). Permissionless:
///         burns its whole $CHIP balance and checks the supply actually fell.
interface IChipBurner {
    function burnAll() external returns (uint256 burned);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
