// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Fixture} from "../Fixture.sol";
import {MockB20} from "../mocks/Mocks.sol";

/// @notice F-01 (ChatGPT final review). The issuer seizes and people donate at random, and NOBODY
///         ever calls `sync`. Around every mint, redeem and claim the handler works out, from the
///         vault's ACTUAL balances (not its books), the most that action may fairly pay, and
///         counts every payout above it.
contract SeizureHandler is Test {
    uint256 public constant ACTORS = 6;
    uint256 internal constant BPS = 10_000;

    IndexVault internal vault;
    MockB20[8] internal stocks;
    address internal feeRecipient;
    address[ACTORS] public actors;

    /// Payouts above the true share (redeem, claim), and mints that paid less, or more, than
    /// the pro-rata share of what is really in the vault.
    uint256 public overpaid;
    uint256 public underpaidMints;
    uint256 public overchargedMints;
    uint256 public seizures;
    uint256 public donations;
    uint256 public redeems;
    uint256 public claims;
    uint256 public mints;

    constructor(IndexVault vault_, MockB20[8] memory stocks_, address feeRecipient_) {
        vault = vault_;
        stocks = stocks_;
        feeRecipient = feeRecipient_;
        for (uint256 k; k < ACTORS; ++k) {
            actors[k] = makeAddr(string.concat("seizure-actor-", vm.toString(k)));
        }
    }

    /* ---------- what each party truly owns of the ACTUAL balance ---------- */

    function _bal(uint256 i) internal view returns (uint256) {
        return stocks[i].balanceOf(address(vault));
    }

    /// Index holders' part of the real balance. If the balance covers the books, it is `held`
    /// (a surplus belongs to nobody until someone syncs it in); otherwise `held`'s pro-rata slice.
    function holdersPart(uint256 i) public view returns (uint256) {
        address t = address(stocks[i]);
        uint256 h = vault.held(t);
        uint256 o = vault.totalOwed(t);
        uint256 b = _bal(i);
        return b >= h + o ? h : h * b / (h + o);
    }

    /// Credit holders' part (the whole credit pool) of the real balance.
    function creditPart(uint256 i) public view returns (uint256) {
        address t = address(stocks[i]);
        uint256 h = vault.held(t);
        uint256 o = vault.totalOwed(t);
        uint256 b = _bal(i);
        return b >= h + o ? o : o * b / (h + o);
    }

    function _paused() internal view returns (bool) {
        for (uint256 i; i < 8; ++i) {
            if (stocks[i].transfersPaused()) return true;
        }
        return false;
    }

    /* ------------------------------ actions ------------------------------ */

    function mint(uint256 who, uint256 shares) public {
        if (_paused()) return;
        address a = actors[who % ACTORS];
        shares = bound(shares, 1e12, 30e18);
        uint256 S = vault.totalSupply() + vault.pendingManagementFee();
        (, uint256[] memory need) = vault.previewMint(shares);
        uint256[8] memory fairMin;
        uint256[8] memory fairMax;
        for (uint256 i; i < 8; ++i) {
            fairMin[i] = holdersPart(i) * shares / S; // the true share, rounded down...
            fairMax[i] = (holdersPart(i) * shares + S - 1) / S; // ...and rounded up
            stocks[i].mint(a, need[i]);
            vm.prank(a);
            stocks[i].approve(address(vault), need[i]);
        }
        vm.prank(a);
        uint256[] memory paid = vault.mint(shares, a);
        for (uint256 i; i < 8; ++i) {
            if (paid[i] < fairMin[i]) ++underpaidMints;
            if (paid[i] > fairMax[i]) ++overchargedMints;
        }
        ++mints;
    }

    function redeem(uint256 who, uint256 creditIdx, uint256 amount, uint256 pauseMask) external {
        address a = actors[who % ACTORS];
        address creditTo = actors[creditIdx % ACTORS];
        uint256 have = vault.balanceOf(a);
        if (have == 0) return;
        uint256 shares = bound(amount, 1, have);
        // A third of the time, pause some stocks so legs are credited.
        if (pauseMask % 3 == 0) {
            for (uint256 i; i < 8; ++i) {
                if ((pauseMask >> (i + 2)) & 1 != 0) stocks[i].setPaused(true);
            }
        }
        uint256 S = vault.totalSupply() + vault.pendingManagementFee();
        uint256 net = a == feeRecipient ? shares : shares - shares * vault.redeemFeeBps() / BPS;
        uint256[8] memory fair;
        uint256[8] memory rcv;
        uint256[8] memory cred;
        for (uint256 i; i < 8; ++i) {
            fair[i] = holdersPart(i) * net / S;
            rcv[i] = stocks[i].balanceOf(a);
            cred[i] = vault.owed(creditTo, address(stocks[i]));
        }
        vm.prank(a);
        vault.redeem(shares, a, creditTo);
        for (uint256 i; i < 8; ++i) {
            uint256 delivered = stocks[i].balanceOf(a) - rcv[i];
            uint256 credited = vault.owed(creditTo, address(stocks[i])) - cred[i];
            // A new credit is pool shares rounded down; its value may read 1 unit either way.
            uint256 slack = credited == 0 ? 0 : 1;
            if (delivered + credited > fair[i] + slack) ++overpaid;
        }
        ++redeems;
    }

    /// A claim may pay no more than the account's credit, and the credits of ALL accounts
    /// together may never exceed the credit pool's slice of the ACTUAL balance (computed here
    /// from the balance, independently of the vault's own write-down).
    function claim(uint256 who, uint256 i) external {
        address a = actors[who % ACTORS];
        MockB20 s = stocks[i % 8];
        uint256 promised = vault.owed(a, address(s));
        if (promised == 0) return;
        s.setPaused(false);
        uint256 sum;
        for (uint256 k; k < ACTORS; ++k) {
            sum += vault.owed(actors[k], address(s));
        }
        if (sum > creditPart(i % 8)) ++overpaid;
        vm.prank(a);
        uint256 got = vault.claimOwed(address(s), a);
        if (got > promised) ++overpaid;
        ++claims;
    }

    /// Issuer seizure of 0-100% of one stock. NO sync.
    function seize(uint256 i, uint256 pct) external {
        MockB20 s = stocks[i % 8];
        s.seize(address(vault), address(0xdead), s.balanceOf(address(vault)) * bound(pct, 0, 100) / 100);
        ++seizures;
    }

    /// Anyone sends stock straight to the vault. NO sync.
    function donate(uint256 i, uint256 pct) external {
        MockB20 s = stocks[i % 8];
        s.mint(address(vault), s.balanceOf(address(vault)) * bound(pct, 0, 200) / 100 + 1);
        ++donations;
    }

    function unpause(uint256 i) external {
        stocks[i % 8].setPaused(false);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract SeizureInvariantsTest is Fixture {
    SeizureHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SeizureHandler(vault, stocks, address(splitter));
        for (uint256 k; k < handler.ACTORS(); ++k) {
            _mintAs(handler.actors(k), 10e18);
        }
        targetContract(address(handler));
    }

    /// THE invariant asked for: after any action, no payout (redeem leg delivered or credited,
    /// or a claim) exceeded that user's pro-rata share of the vault's ACTUAL balances.
    function invariant_noPayoutAboveTrueShare() public view {
        assertEq(handler.overpaid(), 0);
    }

    /// And every minter paid exactly the pro-rata share of what is really there (rounded up):
    /// never less (diluting holders), never more (paying into a seized hole).
    function invariant_mintPaysExactlyTrueShare() public view {
        assertEq(handler.underpaidMints(), 0, "underpaid");
        assertEq(handler.overchargedMints(), 0, "overcharged");
    }

    /// Whatever has been seized, the next action leaves the books covered by real balances.
    function invariant_booksCoveredAfterAnyAction() public {
        uint256 snap = vm.snapshotState();
        vault.reconcile();
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            assertLe(vault.held(t) + vault.totalOwed(t), stocks[i].balanceOf(address(vault)));
        }
        vm.revertToState(snap);
    }

    /// Everyone can still get out: unpause, every creditor claims, every holder redeems,
    /// without a single revert, and without anyone calling sync.
    function invariant_everyoneCanExit() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < N; ++i) {
            stocks[i].setPaused(false);
        }
        uint256 n = handler.ACTORS();
        for (uint256 k; k < n; ++k) {
            address a = handler.actors(k);
            for (uint256 i; i < N; ++i) {
                if (vault.owed(a, address(stocks[i])) != 0) {
                    vm.prank(a);
                    vault.claimOwed(address(stocks[i]), a);
                }
            }
        }
        for (uint256 k; k <= n + 1; ++k) {
            address a = k == n ? safe : k == n + 1 ? address(splitter) : handler.actors(k);
            uint256 bal = vault.balanceOf(a);
            if (bal != 0) {
                vm.prank(a);
                vault.redeem(bal, a);
            }
        }
        assertEq(vault.totalSupply(), 0);
        vm.revertToState(snap);
    }
}
