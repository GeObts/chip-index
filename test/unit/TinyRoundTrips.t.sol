// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {Fixture} from "../Fixture.sol";

/// @notice Self-review item 7: 2,000 tiny mint -> redeem round trips (each at most 0.001 index
///         token, about $0.01). Rounding must always favour the vault: value per index token never
///         falls, and the user never gets more of any stock out than they put in.
contract TinyRoundTripsTest is Fixture {
    function test_2000TinyMintRedeemLoops() public {
        uint256 nps0 = vault.navUsd() * 1e18 / vault.totalSupply();
        uint256 minNps = type(uint256).max;
        uint256[N] memory paidIn;
        uint256[N] memory gotOut;
        for (uint256 r; r < 2_000; ++r) {
            uint256 shares = uint256(keccak256(abi.encode(r))) % 1e15 + 1;
            uint256[] memory need = _fundForMint(alice, shares);
            for (uint256 i; i < N; ++i) {
                paidIn[i] += need[i];
            }
            vm.prank(alice);
            vault.mint(shares, alice);
            uint256 bal = vault.balanceOf(alice);
            if (bal == 0) continue;
            uint256[N] memory before;
            for (uint256 i; i < N; ++i) {
                before[i] = stocks[i].balanceOf(alice);
            }
            vm.prank(alice);
            vault.redeem(bal, alice);
            for (uint256 i; i < N; ++i) {
                gotOut[i] += stocks[i].balanceOf(alice) - before[i];
            }
            uint256 nps = vault.navUsd() * 1e18 / vault.totalSupply();
            if (nps < minNps) minNps = nps;
        }
        for (uint256 i; i < N; ++i) {
            assertLe(gotOut[i], paidIn[i], "user got more stock out than in");
        }
        console2.log("NAV per token at start (1e18)", nps0);
        console2.log("NAV per token, lowest seen   ", minNps);
        assertGe(minNps, nps0, "NAV per token fell");
    }
}
