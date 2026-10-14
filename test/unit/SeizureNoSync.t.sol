// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {Fixture} from "../Fixture.sol";
import {HostileRebalancer} from "../invariant/HostileRebalancer.t.sol";
import {MockB20} from "../mocks/Mocks.sol";

/**
 * @notice ChatGPT final review F-01: after an issuer seizure, and BEFORE anyone calls `sync`,
 *         every paying path must use the vault's real balances, not the stale (too high) book.
 *         No test in this file calls `sync`.
 */
contract SeizureNoSyncTest is Fixture {
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _mintAs(alice, 100e18); // two real holders: the Safe (seed) and alice
    }

    /* ------------------------------ helpers ------------------------------ */

    /// The issuer takes `amount` out of the vault. Deliberately NO sync afterwards.
    function _seize(uint256 i, uint256 amount) internal {
        stocks[i].seize(address(vault), address(0xdead), amount);
    }

    function _bal(uint256 i) internal view returns (uint256) {
        return stocks[i].balanceOf(address(vault));
    }

    function _supply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingManagementFee();
    }

    /// Index holders' part of the ACTUAL balance: all of `held` if it is covered, otherwise
    /// `held`'s pro-rata slice of what is left (credit holders get the rest).
    function _holdersPart(uint256 i) internal view returns (uint256) {
        address t = address(stocks[i]);
        uint256 h = vault.held(t);
        uint256 o = vault.totalOwed(t);
        uint256 b = _bal(i);
        return b >= h + o ? h : h * b / (h + o);
    }

    /// NAV priced from actual balances (no credits outstanding in the callers).
    function _realNav() internal view returns (uint256 nav) {
        for (uint256 i; i < N; ++i) {
            nav += registry.valueUsd(address(stocks[i]), _holdersPart(i));
        }
    }

    function _netOf(address who, uint256 shares) internal view returns (uint256) {
        return who == address(splitter) ? shares : shares - shares * vault.redeemFeeBps() / 10_000;
    }

    /* --------------------- 1. seize, then redeem ------------------------- */

    /// Half of NVDA is seized. alice redeems everything first: she gets exactly her slice of
    /// what is really there, not her slice of the old book. The Safe, redeeming last, gets the
    /// same per-token rate, so nobody was drained.
    function test_f01_seizeThenRedeem_nobodyGetsMoreThanTrueShare() public {
        uint256 staleHeld = vault.held(address(stocks[0]));
        _seize(0, _bal(0) / 2);

        uint256 S = _supply();
        uint256 aShares = vault.balanceOf(alice);
        uint256 aNet = _netOf(alice, aShares);
        uint256[N] memory fair;
        for (uint256 i; i < N; ++i) {
            fair[i] = _holdersPart(i) * aNet / S;
        }

        vm.prank(alice);
        vault.redeem(aShares, alice);
        for (uint256 i; i < N; ++i) {
            assertEq(stocks[i].balanceOf(alice), fair[i], "alice paid her true share");
        }
        assertLt(stocks[0].balanceOf(alice), staleHeld * aNet / S, "not the stale-book amount");

        // The Safe (last out) gets the same NVDA per index token as alice did.
        uint256 S2 = _supply();
        uint256 sShares = vault.balanceOf(safe);
        uint256 sNet = _netOf(safe, sShares);
        uint256 sFair = _holdersPart(0) * sNet / S2;
        vm.prank(safe);
        vault.redeem(sShares, safe);
        assertEq(stocks[0].balanceOf(safe), sFair);
        assertApproxEqRel(stocks[0].balanceOf(safe) * 1e18 / sNet, stocks[0].balanceOf(alice) * 1e18 / aNet, 1e12);

        // The books never promised more than the vault holds.
        for (uint256 i; i < N; ++i) {
            assertLe(vault.held(address(stocks[i])) + vault.totalOwed(address(stocks[i])), _bal(i));
        }
    }

    /// The drain the review describes: 90% seized, then a holder of half the supply redeems.
    /// Before the fix they took (almost) everything left; now the remaining holders keep theirs.
    function test_f01_seizeThenRedeem_cannotDrainTheRest() public {
        _seize(0, _bal(0) * 9 / 10);
        uint256 left = _bal(0);
        uint256 S = _supply();
        uint256 aShares = vault.balanceOf(alice);
        uint256 aNet = _netOf(alice, aShares);

        vm.prank(alice);
        vault.redeem(aShares, alice);
        assertEq(stocks[0].balanceOf(alice), left * aNet / S);
        assertGe(_bal(0), left - left * aNet / S, "the others' share is still in the vault");
        assertEq(vault.held(address(stocks[0])), _bal(0), "books match the balance");
    }

    /// Seizing EVERYTHING of one stock: redeem still works (pays 0 of it) and does not revert.
    function test_f01_seizeEverything_redeemStillWorks() public {
        _seize(0, _bal(0));
        vm.prank(alice);
        uint256[] memory got = vault.redeem(10e18, alice);
        assertEq(got[0], 0);
        assertGt(got[1], 0);
        assertEq(vault.held(address(stocks[0])), 0);
    }

    /* ---------------------- 2. seize, then mint -------------------------- */

    /// The minter pays the pro-rata slice of what is REALLY there (no overpaying into a hole),
    /// and existing holders are not diluted.
    function test_f01_seizeThenMint_minterPaysCorrectAmount() public {
        uint256 staleHeld = vault.held(address(stocks[0]));
        _seize(0, _bal(0) / 2);
        uint256 S = _supply();
        uint256 shares = 10e18;
        uint256 perShareBefore = _realNav() * 1e18 / S;

        (, uint256[] memory need) = vault.previewMint(shares);
        for (uint256 i; i < N; ++i) {
            uint256 h = _holdersPart(i);
            assertEq(need[i], (h * shares + S - 1) / S, "pro-rata of the real balance, rounded up");
        }
        assertLt(need[0], staleHeld * shares / S, "not the stale-book amount");

        uint256[] memory funded = _fundForMint(bob, shares);
        vm.prank(bob);
        uint256[] memory paid = vault.mint(shares, bob);
        for (uint256 i; i < N; ++i) {
            assertEq(paid[i], funded[i]);
            assertEq(stocks[i].balanceOf(bob), 0, "pulled exactly the previewed amount");
            assertEq(vault.held(address(stocks[i])), _bal(i), "books match the balance");
        }
        assertGe(vault.navPerShare(), perShareBefore, "existing holders not diluted");
    }

    /// The fee tier is priced on the REAL NAV. With half of every stock seized, a mint that the
    /// stale book would value at $15k (tier 1, 0.75%) is really $7.5k and pays the base 1%.
    function test_f01_seizeThenMint_feeTierUsesRealNav() public {
        for (uint256 i; i < N; ++i) {
            _seize(i, _bal(i) / 2);
        }
        uint256 shares = 750e18; // stale: $15k, real: $7.5k
        (uint16 bps, uint256 valueUsd) = vault.mintFeeFor(shares);
        assertEq(valueUsd, _realNav() * shares / _supply());
        assertLt(valueUsd, 10_000e18);
        assertEq(bps, 100, "base rate, not the discount");

        uint256 feeBefore = vault.balanceOf(address(splitter));
        _mintAs(bob, shares);
        assertEq(vault.balanceOf(address(splitter)) - feeBefore, shares / 100);
    }

    /* -------------------- 3. seize, then rebalance ----------------------- */

    /// Normal Rebalancer: it reconciles before measuring, so the seizure itself shows up as
    /// drift (NVDA underweight) and the keeper's trades are sized on the real balances.
    function test_f01_seizeThenRebalance_normal() public {
        _seize(0, _bal(0) / 2); // NVDA ~6.7% vs 12.5% target
        uint256 nav = _realNav();
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](N - 1);
        for (uint256 j = 1; j < N; ++j) {
            uint256 value = registry.valueUsd(address(stocks[j]), _bal(j));
            uint256 over = value - nav * 1_250 / 10_000;
            t[j - 1] = Rebalancer.Trade(
                address(stocks[j]), address(stocks[0]), registry.amountForUsd(address(stocks[j]), over / 2), 0
            );
        }
        vm.prank(keeper);
        rebalancer.rebalance(t, block.timestamp + 1 hours);

        for (uint256 i; i < N; ++i) {
            assertEq(vault.held(address(stocks[i])), _bal(i), "books match the balance");
        }
        assertApproxEqRel(vault.navUsd(), nav, 1e14, "NAV preserved (no-skew pool)");
        assertEq(vault.windowNavUsd(), nav, "daily caps measured on the real NAV");
    }

    function _installHostile() internal returns (HostileRebalancer h) {
        h = new HostileRebalancer(vault);
        vm.startPrank(safe);
        vault.queueRebalancer(address(h));
        vm.warp(block.timestamp + 48 hours);
        vault.executeRebalancer(address(h));
        vm.stopPrank();
        _warpFresh(0);
    }

    /// Hostile Rebalancer: it cannot sell seized stock that is only on the stale book, its daily
    /// caps are measured on the real NAV, and keeping the stock still fails.
    function test_f01_seizeThenRebalance_hostile() public {
        HostileRebalancer h = _installHostile();
        address nvda = address(stocks[0]);
        uint256 staleHeld = vault.held(nvda);
        _seize(0, _bal(0) / 2);
        uint256 realHeld = _bal(0);

        vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientHeld.selector, nvda, staleHeld, realHeld));
        h.attack(nvda, staleHeld, address(stocks[1]), 0, 10_000, address(0));

        vm.expectRevert();
        h.attack(nvda, realHeld / 10, address(stocks[1]), 3, 0, address(0)); // keeps everything

        uint256 nav = _realNav();
        h.attack(address(stocks[1]), _bal(1) / 20, nvda, 0, 10_000, address(0));
        assertEq(vault.windowNavUsd(), nav, "caps measured on the real NAV");
        assertEq(vault.held(nvda), _bal(0), "books match the balance");
    }

    /* ------------- 4. seize with outstanding credits, both orders --------- */

    struct Payouts {
        uint256 carol;
        uint256 bob;
        uint256 redeemer;
    }

    /// Stock 2 paused; carol and bob are credited from two Safe redeems; then unpaused.
    function _credits() internal returns (address t, uint256 c, uint256 b) {
        t = address(stocks[2]);
        stocks[2].setPaused(true);
        vm.startPrank(safe);
        c = vault.redeem(30e18, carol)[2];
        b = vault.redeem(20e18, bob)[2];
        vm.stopPrank();
        stocks[2].setPaused(false);
    }

    function _claim(address who, address t) internal returns (uint256 got) {
        vm.prank(who);
        got = vault.claimOwed(t, who);
    }

    function _redeemAll(address who) internal returns (uint256 got2) {
        uint256 s = vault.balanceOf(who);
        vm.prank(who);
        got2 = vault.redeem(s, who)[2];
    }

    function test_f01_seizeWithCredits_claimAndRedeemInBothOrders() public {
        (address t, uint256 c, uint256 b) = _credits();
        Payouts memory F = _fairAfterHalfSeized(t, c, b);

        uint256 snap = vm.snapshotState();
        // Order A: claims first, then the redeem.
        Payouts memory A;
        A.carol = _claim(carol, t);
        A.bob = _claim(bob, t);
        A.redeemer = _redeemAll(alice);
        vm.revertToState(snap);
        // Order B: the redeem first, then the claims.
        Payouts memory B;
        B.redeemer = _redeemAll(alice);
        B.bob = _claim(bob, t);
        B.carol = _claim(carol, t);

        _assertPaidFair(A, F);
        _assertPaidFair(B, F);
        assertLe(vault.held(t) + vault.totalOwed(t), _bal(2));

        // And the last index holder still gets paid.
        assertGt(_redeemAll(safe), 0);
        assertLe(vault.held(t) + vault.totalOwed(t), _bal(2));
    }

    /// Seize half the vault's stock 2 (no sync) and work out everyone's true share of what is
    /// left: every credit and the index backing are written down by the same fraction.
    function _fairAfterHalfSeized(address t, uint256 c, uint256 b) internal returns (Payouts memory F) {
        uint256 h = vault.held(t);
        uint256 total = _bal(2);
        assertEq(total, h + c + b);
        _seize(2, total / 2);
        uint256 left = _bal(2);
        F.carol = c * left / total;
        F.bob = b * left / total;
        F.redeemer = (h * left / total) * _netOf(alice, vault.balanceOf(alice)) / _supply();
    }

    /// Never above the true share (credits may round 1 unit either way), and within rounding of it.
    function _assertPaidFair(Payouts memory P, Payouts memory F) internal pure {
        assertLe(P.carol, F.carol + 1, "carol <= true share");
        assertLe(P.bob, F.bob + 1, "bob <= true share");
        assertLe(P.redeemer, F.redeemer, "redeemer <= true share");
        assertApproxEqAbs(P.carol, F.carol, 2);
        assertApproxEqAbs(P.bob, F.bob, 2);
        assertApproxEqAbs(P.redeemer, F.redeemer, 2);
    }

    /// A seizure of everything wipes the credits out; claims then revert NothingOwed (the view
    /// already shows 0) while redeem keeps working.
    function test_f01_seizeEverythingWithCredits() public {
        (address t,,) = _credits();
        _seize(2, _bal(2));
        assertEq(vault.owed(carol, t), 0, "view already written down");
        vm.prank(carol);
        vm.expectRevert(IndexVault.NothingOwed.selector);
        vault.claimOwed(t, carol);
        assertEq(_redeemAll(alice), 0);
        assertEq(vault.totalOwed(t), 0);
    }

    /* ------------------- 5. donation, then mint / redeem ------------------ */

    /// A donation is NOT folded in automatically: a mint right after it costs exactly what it
    /// did before, at the same fee tier.
    function test_f01_donationThenMint_unchanged() public {
        uint256 shares = 50e18;
        (, uint256[] memory before) = vault.previewMint(shares);
        (uint16 bpsBefore, uint256 valBefore) = vault.mintFeeFor(shares);
        uint256 heldBefore = vault.held(address(stocks[0]));

        stocks[0].mint(address(vault), _bal(0) * 50); // a huge donation (50x the holding)
        (, uint256[] memory afterDon) = vault.previewMint(shares);
        (uint16 bpsAfter, uint256 valAfter) = vault.mintFeeFor(shares);
        assertEq(bpsAfter, bpsBefore);
        assertEq(valAfter, valBefore);
        for (uint256 i; i < N; ++i) {
            assertEq(afterDon[i], before[i]);
        }
        _mintAs(bob, shares);
        assertEq(vault.held(address(stocks[0])), heldBefore + before[0], "donation not in the books");
    }

    /// And a redeem right after a donation pays exactly what it did before.
    function test_f01_donationThenRedeem_unchanged() public {
        (, uint256[] memory before,) = vault.previewRedeem(10e18, alice);
        stocks[0].mint(address(vault), 1e8);
        vm.prank(alice);
        uint256[] memory got = vault.redeem(10e18, alice);
        for (uint256 i; i < N; ++i) {
            assertEq(got[i], before[i]);
        }
    }

    /// Even when someone DOES `sync` a donation in (the only way it enters the books), the fee
    /// tier stays honest: the minter really deposits stock worth the value the tier was priced at.
    /// The donor gave the donation away to every holder; nobody else lost anything.
    function test_f01_syncedDonation_feeTierStaysHonest() public {
        stocks[0].mint(address(vault), _bal(0) * 9); // NVDA x10
        vault.sync(address(stocks[0]));
        uint256 shares = 600e18;
        (uint16 bps, uint256 valueUsd) = vault.mintFeeFor(shares);
        (, uint256[] memory need) = vault.previewMint(shares);
        uint256 deposited;
        for (uint256 i; i < N; ++i) {
            deposited += registry.valueUsd(address(stocks[i]), need[i]);
        }
        assertGe(deposited, valueUsd - 1e12, "tier priced at what is really deposited");
        console2.log("tier bps / priced at / deposited", bps, valueUsd / 1e18, deposited / 1e18);
    }

    /// Seizure and donation on the same stock: the donation covers the hole first; only the
    /// remaining shortfall is written down.
    function test_f01_seizureAndDonationNet() public {
        uint256 h = vault.held(address(stocks[0]));
        _seize(0, h / 2);
        stocks[0].mint(address(vault), h / 4);
        uint256 aShares = vault.balanceOf(alice);
        (, uint256[] memory r,) = vault.previewRedeem(aShares, alice);
        vm.prank(alice);
        uint256 got = vault.redeem(aShares, alice)[0];
        assertEq(got, r[0]);
        assertLe(vault.held(address(stocks[0])), _bal(0));
    }

    /* --------------------------- gas (reported) --------------------------- */

    /// Logged so the extra gas from reconciling can be compared with the previous commit.
    function test_f01_gas_mintAndRedeem() public {
        _fundForMint(bob, 10e18);
        uint256 g = gasleft();
        vm.prank(bob);
        vault.mint(10e18, bob);
        console2.log("gas mint (8 stocks)", g - gasleft());

        g = gasleft();
        vm.prank(bob);
        vault.redeem(5e18, bob);
        console2.log("gas redeem (8 stocks)", g - gasleft());
    }
}
