// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Timelock} from "../../src/lib/Timelock.sol";
import {Fixture} from "../Fixture.sol";

contract IndexVaultTest is Fixture {
    /* ----------------------------- seed ----------------------------- */

    function test_seed() public view {
        assertEq(vault.totalSupply(), SEED_SHARES);
        assertEq(vault.balanceOf(safe), SEED_SHARES);
        // $1,000 of stock for 100 tokens = $10 each (within rounding of the seed amounts).
        assertApproxEqRel(vault.navPerShare(), 10e18, 1e14);
        for (uint256 i; i < N; ++i) {
            assertEq(vault.held(address(stocks[i])), stocks[i].balanceOf(address(vault)));
        }
    }

    function test_seedOnlyOwnerAndOnlyOnce() public {
        uint256[] memory amounts = new uint256[](N);
        vm.prank(safe);
        vm.expectRevert(IndexVault.AlreadySeeded.selector);
        vault.seed(amounts, 1, safe);
    }

    /* ----------------------------- mint ----------------------------- */

    function test_mint_proRataWithFee() public {
        uint256[] memory need = _fundForMint(alice, 10e18);
        vm.prank(alice);
        uint256[] memory paid = vault.mint(10e18, alice);
        for (uint256 i; i < N; ++i) {
            assertEq(paid[i], need[i]);
            // 10 tokens is 10% of supply, so 10% of each holding (rounded up).
            assertApproxEqAbs(paid[i], (vault.held(address(stocks[i])) - paid[i]) / 10, 1);
        }
        assertEq(vault.balanceOf(alice), 9.9e18, "1% mint fee");
        assertEq(vault.balanceOf(address(splitter)), 0.1e18, "fee to the splitter");
    }

    /// Mint never NEEDS a price: it still works with every feed stale and the sequencer down
    /// (the size discount then does not apply; see MintFeeTiers.t.sol).
    function test_mint_needsNoOracle() public {
        vm.warp(block.timestamp + 30 days);
        sequencer.set(1);
        _mintAs(alice, 5e18);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_mint_capPauseAndZero() public {
        vm.prank(safe);
        vault.setMintCap(105e18);
        _fundForMint(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.MintCapExceeded.selector, 110e18, 105e18));
        vault.mint(10e18, alice);

        vm.prank(safe);
        vault.setMintPaused(true);
        vm.prank(alice);
        vm.expectRevert(IndexVault.MintIsPaused.selector);
        vault.mint(1e18, alice);

        vm.prank(safe);
        vault.setMintPaused(false);
        vm.prank(alice);
        vm.expectRevert(IndexVault.ZeroShares.selector);
        vault.mint(0, alice);
    }

    function test_mint_revertsWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(1e18, alice);
    }

    /* ---------------------------- redeem ---------------------------- */

    function test_redeem_proRataWithFee() public {
        _mintAs(alice, 10e18); // alice holds 9.9
        uint256 supply = vault.totalSupply();
        uint256[] memory heldBefore = new uint256[](N);
        for (uint256 i; i < N; ++i) {
            heldBefore[i] = vault.held(address(stocks[i]));
        }
        uint256 shares = vault.balanceOf(alice);
        uint256 feeBefore = vault.balanceOf(address(splitter));

        vm.prank(alice);
        uint256[] memory out = vault.redeem(shares, alice);

        uint256 fee = shares / 100;
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(splitter)) - feeBefore, fee);
        for (uint256 i; i < N; ++i) {
            assertEq(out[i], heldBefore[i] * (shares - fee) / supply);
            assertEq(stocks[i].balanceOf(alice), out[i]);
        }
    }

    /// The core promise: in-kind redeem works with mint paused, every feed stale, the sequencer
    /// down and the cash router paused.
    function test_redeem_neverBlockedByAdminOrOracles() public {
        vm.startPrank(safe);
        vault.setMintPaused(true);
        router.pauseCashRedeem();
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        sequencer.set(1);
        for (uint256 i; i < N; ++i) {
            feeds[i].setBroken(true);
        }
        uint256 shares = vault.balanceOf(safe);
        vm.prank(safe);
        vault.redeem(shares, safe);
        for (uint256 i; i < N; ++i) {
            assertGt(stocks[i].balanceOf(safe), 0);
        }
    }

    /// One stock paused by its issuer: the other 7 legs pay out, the paused leg is credited.
    function test_redeem_pausedTokenIsCreditedThenClaimed() public {
        stocks[2].setPaused(true);
        uint256 shares = 10e18;
        vm.prank(safe);
        uint256[] memory out = vault.redeem(shares, alice, alice);

        assertEq(stocks[2].balanceOf(alice), 0);
        assertEq(vault.owed(alice, address(stocks[2])), out[2]);
        assertEq(vault.totalOwed(address(stocks[2])), out[2]);
        for (uint256 i; i < N; ++i) {
            if (i != 2) assertEq(stocks[i].balanceOf(alice), out[i]);
        }

        // Still paused: the claim reverts and the credit stays.
        vm.prank(alice);
        vm.expectRevert();
        vault.claimOwed(address(stocks[2]), alice);

        stocks[2].setPaused(false);
        vm.prank(alice);
        vault.claimOwed(address(stocks[2]), alice);
        assertEq(stocks[2].balanceOf(alice), out[2]);
        assertEq(vault.owed(alice, address(stocks[2])), 0);
        assertEq(vault.totalOwed(address(stocks[2])), 0);
    }

    /* --------------------------- blocklist ---------------------------- */

    /// Blocked on even ONE stock is enough to refuse the whole redeem.
    function test_blocklist_receiverRefused() public {
        stocks[3].setBlocked(bob, true);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, address(stocks[3])));
        vault.redeem(10e18, bob);
    }

    /// A blocklisted holder cannot redeem, not even to a clean address.
    function test_blocklist_callerRefused() public {
        vm.prank(safe);
        vault.transfer(bob, 10e18);
        stocks[0].setBlocked(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, address(stocks[0])));
        vault.redeem(10e18, alice);
        assertEq(vault.balanceOf(bob), 10e18, "nothing burned");
    }

    /// Nor can a clean caller name a blocklisted account to hold the credits.
    function test_blocklist_creditHolderRefused() public {
        stocks[7].setBlocked(bob, true);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, address(stocks[7])));
        vault.redeem(10e18, alice, bob);
    }

    /// Credits earned while clean cannot be claimed once blocklisted, or sent to a blocked address.
    function test_blocklist_claimRefused() public {
        stocks[2].setPaused(true);
        vm.prank(safe);
        uint256[] memory out = vault.redeem(10e18, alice);
        stocks[2].setPaused(false);

        stocks[2].setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, alice, address(stocks[2])));
        vault.claimOwed(address(stocks[2]), bob);

        stocks[2].setBlocked(alice, false);
        stocks[2].setBlocked(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, address(stocks[2])));
        vault.claimOwed(address(stocks[2]), bob);

        vm.prank(alice);
        vault.claimOwed(address(stocks[2]), alice);
        assertEq(stocks[2].balanceOf(alice), out[2]);
    }

    /// Lifting the block restores redeem.
    function test_blocklist_unblockRestoresRedeem() public {
        stocks[0].setBlocked(alice, true);
        assertEq(vault.blockedOn(alice), address(stocks[0]));
        stocks[0].setBlocked(alice, false);
        assertEq(vault.blockedOn(alice), address(0));
        vm.prank(safe);
        vault.redeem(10e18, alice);
        assertGt(stocks[0].balanceOf(alice), 0);
    }

    /// The vault itself blocklisted on one stock: that stock is frozen, everything else works.
    function test_redeem_vaultBlocklistedOnOneStock() public {
        stocks[5].setBlocked(address(vault), true);
        vm.prank(safe);
        uint256[] memory out = vault.redeem(10e18, alice);
        assertEq(vault.owed(alice, address(stocks[5])), out[5]);
        assertEq(stocks[0].balanceOf(alice), out[0]);

        // Mint now fails (the vault cannot receive META) until the issuer lifts it.
        _fundForMint(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.mint(1e18, bob);
    }

    /// Credited stock is not index backing: later redeemers are not paid out of it.
    function test_redeem_creditsAreNotBacking() public {
        stocks[0].setPaused(true);
        vm.prank(safe);
        uint256[] memory first = vault.redeem(50e18, alice);
        stocks[0].setPaused(false);
        uint256 heldNow = vault.held(address(stocks[0]));
        assertEq(stocks[0].balanceOf(address(vault)), heldNow + first[0]);
        vm.prank(address(vault));
        vault.sync(address(stocks[0]));
        assertEq(vault.held(address(stocks[0])), heldNow, "sync excludes credits");
    }

    function test_redeem_tooLittleGasRevertsInsteadOfCrediting() public {
        vm.prank(safe);
        vm.expectRevert();
        vault.redeem{gas: 200_000}(1e18, safe);
    }

    /* ------------------------- management fee ------------------------ */

    function test_managementFee_threePercentAYear() public {
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.pendingManagementFee(), supply * 300 / 10_000);
        vault.accrue();
        assertEq(vault.balanceOf(address(splitter)), supply * 3 / 100);
        assertEq(vault.pendingManagementFee(), 0);
    }

    function test_managementFee_accruesEveryBlock() public {
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 2); // one Base block
        assertEq(vault.pendingManagementFee(), supply * 300 * 2 / (10_000 * 365 days));
        assertGt(vault.pendingManagementFee(), 0);
    }

    /// Fee shares minted later do not dilute what a mint costs: preview includes pending fees.
    function test_managementFee_previewMintMatchesMint() public {
        vm.warp(block.timestamp + 90 days);
        uint256[] memory need = _fundForMint(alice, 10e18);
        vm.prank(alice);
        uint256[] memory paid = vault.mint(10e18, alice);
        for (uint256 i; i < N; ++i) {
            assertEq(paid[i], need[i]);
        }
    }

    /* --------------------------- fee caps ---------------------------- */

    function test_feeCaps() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 201, 200));
        vault.setFees(201, 300);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 501, 500));
        vault.setFees(100, 501);
        vault.setFees(200, 500);
        vm.stopPrank();
        assertEq(vault.redeemFeeBps(), 200);
        assertEq(vault.mgmtFeeBps(), 500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setFees(0, 0);
    }

    function test_setFees_accruesAtOldRateFirst() public {
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 365 days);
        vm.prank(safe);
        vault.setFees(100, 0);
        assertEq(vault.balanceOf(address(splitter)), supply * 3 / 100);
    }

    /* ----------------------------- sync ------------------------------ */

    function test_sync_donationGoesToHolders() public {
        uint256 before = vault.held(address(stocks[0]));
        stocks[0].mint(address(vault), 1e8);
        vault.sync(address(stocks[0]));
        assertEq(vault.held(address(stocks[0])), before + 1e8);
    }

    function test_sync_seizureIsWrittenDown() public {
        uint256 before = vault.held(address(stocks[0]));
        // Issuer seizes half (simulated by moving tokens out of the vault).
        vm.prank(address(vault));
        stocks[0].transfer(address(0xdead), before / 2);
        vault.sync(address(stocks[0]));
        assertEq(vault.held(address(stocks[0])), before - before / 2);
    }

    function test_sync_onlyListed() public {
        vm.expectRevert(abi.encodeWithSelector(IndexVault.NotListed.selector, address(usdc)));
        vault.sync(address(usdc));
    }

    /* ---------------------- trades and timelocks --------------------- */

    function test_executeTrade_onlyRebalancer() public {
        vm.prank(keeper);
        vm.expectRevert(IndexVault.NotRebalancer.selector);
        vault.executeTrade(address(stocks[0]), 1, address(stocks[1]), 0, "");
    }

    function test_rebalancerChangeIsTimelocked() public {
        address next = makeAddr("nextRebalancer");
        vm.prank(safe);
        vault.queueRebalancer(next);
        vm.prank(safe);
        vm.expectRevert();
        vault.executeRebalancer(next);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        vault.executeRebalancer(next);
        assertEq(vault.rebalancer(), next);
    }

    function test_feeRecipientChangeIsTimelocked() public {
        address next = makeAddr("nextSplitter");
        vm.prank(safe);
        vault.queueFeeRecipient(next);
        vm.warp(block.timestamp + 48 hours);
        uint256 pending = vault.pendingManagementFee();
        vm.prank(safe);
        vault.executeFeeRecipient(next);
        assertEq(vault.feeRecipient(), next);
        assertEq(vault.balanceOf(address(splitter)), pending, "fees so far go to the old recipient");
    }

    function test_wireOnlyOnce() public {
        vm.expectRevert(IndexVault.AlreadyWired.selector);
        vault.wire(alice, alice);
    }

    function test_trade_slippageCap() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 201, 200));
        vault.setMaxTradeSlippageBps(201);
    }

    /* ----------------------------- fuzz ------------------------------ */

    /// Minting then immediately redeeming never returns more than was put in.
    function testFuzz_mintRedeemRoundTripNeverProfits(uint256 shares) public {
        shares = bound(shares, 1, 500e18);
        uint256[] memory paid = _fundForMint(alice, shares);
        vm.startPrank(alice);
        vault.mint(shares, alice);
        uint256 got = vault.balanceOf(alice);
        if (got == 0) return;
        uint256[] memory back = vault.redeem(got, alice);
        vm.stopPrank();
        for (uint256 i; i < N; ++i) {
            assertLe(back[i], paid[i]);
        }
    }

    /// Dust mints cannot be used to round value out of the vault.
    function testFuzz_tinyMintsPayAtLeastProRata(uint256 shares) public {
        shares = bound(shares, 1, 1e12);
        (, uint256[] memory need) = vault.previewMint(shares);
        uint256 supply = vault.totalSupply();
        for (uint256 i; i < N; ++i) {
            uint256 h = vault.held(address(stocks[i]));
            assertGe(need[i] * supply, h * shares);
        }
    }
}
