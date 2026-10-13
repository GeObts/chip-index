// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Fixture} from "../Fixture.sol";
import {MockB20} from "../mocks/Mocks.sol";

/// @notice Random mints, redeems, issuer pauses, credits and time jumps.
contract Handler is Test {
    IndexVault internal vault;
    MockB20[8] internal stocks;
    address[3] public actors;

    constructor(IndexVault vault_, MockB20[8] memory stocks_) {
        vault = vault_;
        stocks = stocks_;
        actors = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
    }

    function mint(uint256 who, uint256 shares) external {
        address a = actors[who % 3];
        shares = bound(shares, 1, 50e18);
        if (vault.totalSupply() + shares > vault.mintCap()) return;
        // Mint is refused outright while any stock is paused (IndexVault._requireMintable).
        for (uint256 i; i < 8; ++i) {
            if (stocks[i].transfersPaused()) return;
        }
        (, uint256[] memory need) = vault.previewMint(shares);
        vm.startPrank(a);
        for (uint256 i; i < 8; ++i) {
            stocks[i].mint(a, need[i]);
            stocks[i].approve(address(vault), need[i]);
        }
        vault.mint(shares, a);
        vm.stopPrank();
    }

    function redeem(uint256 who, uint256 pct) external {
        address a = actors[who % 3];
        uint256 shares = vault.balanceOf(a) * bound(pct, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(a);
        vault.redeem(shares, a);
    }

    function togglePause(uint256 i) external {
        MockB20 s = stocks[i % 8];
        s.setPaused(!s.transfersPaused());
    }

    function claim(uint256 who, uint256 i) external {
        address a = actors[who % 3];
        address t = address(stocks[i % 8]);
        if (vault.owed(a, t) == 0 || stocks[i % 8].transfersPaused()) return;
        vm.prank(a);
        vault.claimOwed(t, a);
    }

    /// @dev An issuer seizure of up to 100% of the vault's balance, then anyone's sync.
    ///      (Between the two the books are briefly ahead of the balance; sync is what fixes that.)
    function seize(uint256 i, uint256 pct) external {
        MockB20 s = stocks[i % 8];
        uint256 bal = s.balanceOf(address(vault));
        s.seize(address(vault), address(0xdead), bal * bound(pct, 0, 100) / 100);
        vault.sync(address(s));
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    function accrue() external {
        vault.accrue();
    }
}

contract IndexInvariantsTest is Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(vault, stocks);
        targetContract(address(handler));
    }

    /// The vault always owns at least what its books say: backing plus credits.
    function invariant_balancesCoverBooks() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            assertGe(stocks[i].balanceOf(address(vault)), vault.held(t) + vault.totalOwed(t));
        }
    }

    /// Per-account credits never add up to more than the per-token total, and the gap is only
    /// rounding (each account rounds down by under one unit).
    function invariant_creditsAddUp() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            uint256 sum = vault.owed(safe, t) + vault.owed(address(splitter), t);
            for (uint256 k; k < 3; ++k) {
                sum += vault.owed(handler.actors(k), t);
            }
            assertLe(sum, vault.totalOwed(t));
            assertLe(vault.totalOwed(t) - sum, 5);
        }
    }

    /// Whatever has happened, the biggest holder can always redeem everything in kind.
    function invariant_fullRedeemAlwaysWorks() public {
        uint256 snap = vm.snapshotState();
        uint256 shares = vault.balanceOf(safe);
        if (shares != 0) {
            vm.prank(safe);
            vault.redeem(shares, safe);
            assertEq(vault.balanceOf(safe), 0);
        }
        vm.revertToState(snap);
    }
}
