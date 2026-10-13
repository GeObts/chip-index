// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";

/// @notice Every waiting timelocked change is listed onchain (`pendingChanges`), so the deploy
///         check and anyone else can see what is coming without reading event history.
contract PendingChangesTest is Fixture {
    function test_pendingChanges_listedUntilExecutedOrCancelled() public {
        uint8 cap = vault.SET_MINT_CAP();
        uint8 fee = vault.SET_REDEEM_FEE();
        (bytes32[] memory ids,) = vault.pendingChanges();
        assertEq(ids.length, 0, "nothing queued at deploy");

        vm.startPrank(safe);
        bytes32 a = vault.queueSetting(cap, 2_000_000e18);
        bytes32 b = vault.queueSetting(fee, 150);
        bytes32 c = vault.queueRebalancer(alice);
        vm.stopPrank();

        uint256[] memory at;
        (ids, at) = vault.pendingChanges();
        assertEq(ids.length, 3);
        assertEq(ids[0], a);
        assertEq(at[0], block.timestamp + 48 hours);

        // Cancel the middle one: the last moves into its place.
        vm.prank(safe);
        vault.cancelChange(b);
        (ids,) = vault.pendingChanges();
        assertEq(ids.length, 2);
        assertEq(ids[1], c);

        // Execute one: gone from the list.
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        vault.executeSetting(cap, 2_000_000e18);
        (ids,) = vault.pendingChanges();
        assertEq(ids.length, 1);
        assertEq(ids[0], c);

        // An expired entry stays listed (it cannot execute) until cancelled.
        vm.warp(block.timestamp + 15 days);
        (ids, at) = vault.pendingChanges();
        assertEq(ids.length, 1);
        assertLt(at[0] + vault.TIMELOCK_GRACE(), block.timestamp, "expired");
        vm.prank(safe);
        vault.cancelChange(c);
        (ids,) = vault.pendingChanges();
        assertEq(ids.length, 0);
    }

    /// Re-queueing an expired change does not list it twice.
    function test_pendingChanges_requeueAfterExpiryListedOnce() public {
        uint8 fee = vault.SET_REDEEM_FEE();
        vm.prank(safe);
        vault.queueSetting(fee, 150);
        vm.warp(block.timestamp + 48 hours + 14 days + 1);
        vm.prank(safe);
        vault.queueSetting(fee, 150);
        (bytes32[] memory ids,) = vault.pendingChanges();
        assertEq(ids.length, 1);
    }
}
