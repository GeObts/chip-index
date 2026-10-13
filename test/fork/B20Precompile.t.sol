// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IB20} from "base-std/interfaces/IB20.sol";

/// @notice Canary: proves the real B20 precompiles execute in this test runner.
/// Run with `base-forge test --fork-url $BASE_RPC_URL --match-contract B20PrecompileFork`.
/// Under stock `forge` the token code is a single 0xef byte and every call fails.
contract B20PrecompileForkTest is Test {
    IB20 constant NVDA = IB20(0xb20000000000000000000078ee7ce2fE4908108C);
    // Aerodrome Slipstream NVDA/USDC pool (tick spacing 10), holds most NVDAc liquidity.
    address constant NVDA_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    function test_readsRealState() public view {
        assertEq(NVDA.decimals(), 8);
        assertEq(keccak256(bytes(NVDA.symbol())), keccak256("NVDAc"));
        assertGt(NVDA.balanceOf(NVDA_POOL), 0);
        assertGt(NVDA.totalSupply(), 0);
    }

    function test_realTransferMovesBalances() public {
        address to = makeAddr("receiver");
        uint256 amount = 1e8;
        uint256 poolBefore = NVDA.balanceOf(NVDA_POOL);

        vm.prank(NVDA_POOL);
        assertTrue(NVDA.transfer(to, amount));

        assertEq(NVDA.balanceOf(to), amount);
        assertEq(NVDA.balanceOf(NVDA_POOL), poolBefore - amount);
    }

    function test_multiplierReadable() public view {
        (bool ok, bytes memory ret) = address(NVDA).staticcall(abi.encodeWithSignature("multiplier()"));
        assertTrue(ok, "multiplier() not available in this runner");
        console2.log("NVDA multiplier", abi.decode(ret, (uint256)));
    }
}
