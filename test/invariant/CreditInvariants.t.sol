// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Fixture} from "../Fixture.sol";
import {MockB20} from "../mocks/Mocks.sol";

/// @notice Round-2 request 3: credits under stress. Twelve holders redeem (often tiny amounts)
///         while random stocks are paused, crediting the stuck legs to random accounts; the issuer
///         seizes from the vault again and again; credits are claimed in random order.
contract CreditHandler is Test {
    uint256 public constant ACTORS = 12;

    IndexVault internal vault;
    MockB20[8] internal stocks;
    address[ACTORS] public actors;

    /// Ghosts, per token: stock set aside as credit by redeems, and stock paid out by claims.
    mapping(address token => uint256) public credited;
    mapping(address token => uint256) public paid;
    uint256 public seizures;
    uint256 public claims;
    uint256 public tinyRedeems;

    constructor(IndexVault vault_, MockB20[8] memory stocks_) {
        vault = vault_;
        stocks = stocks_;
        for (uint256 k; k < ACTORS; ++k) {
            actors[k] = makeAddr(string.concat("creditor-", vm.toString(k)));
        }
    }

    function _allUnpaused() internal view returns (bool) {
        for (uint256 i; i < 8; ++i) {
            if (stocks[i].transfersPaused()) return false;
        }
        return true;
    }

    /// Mint for one holder (only possible while nothing is paused).
    function mint(uint256 who, uint256 shares) public {
        if (!_allUnpaused()) return;
        address a = actors[who % ACTORS];
        shares = bound(shares, 1e15, 20e18);
        (, uint256[] memory need) = vault.previewMint(shares);
        for (uint256 i; i < 8; ++i) {
            stocks[i].mint(a, need[i]);
            vm.prank(a);
            stocks[i].approve(address(vault), need[i]);
        }
        vm.prank(a);
        vault.mint(shares, a);
    }

    /// Pause a random set of stocks, then redeem (a third of the time a tiny amount, down to 1 wei
    /// of index token) crediting the stuck legs to a random account.
    function redeemWhilePaused(uint256 who, uint256 creditIdx, uint256 amount, uint256 pauseMask) external {
        address a = actors[who % ACTORS];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) {
            mint(who, amount);
            bal = vault.balanceOf(a);
            if (bal == 0) return;
        }
        uint256 shares;
        if (amount % 3 == 0) {
            shares = bound(amount, 1, bal < 1e9 ? bal : 1e9);
            ++tinyRedeems;
        } else {
            shares = bound(amount, 1, bal);
        }
        pauseMask = bound(pauseMask, 1, 255);
        for (uint256 i; i < 8; ++i) {
            if (pauseMask & (1 << i) != 0) stocks[i].setPaused(true);
        }
        uint256[8] memory before;
        for (uint256 i; i < 8; ++i) {
            before[i] = vault.totalOwed(address(stocks[i]));
        }
        vm.prank(a);
        vault.redeem(shares, a, actors[creditIdx % ACTORS]);
        for (uint256 i; i < 8; ++i) {
            credited[address(stocks[i])] += vault.totalOwed(address(stocks[i])) - before[i];
        }
    }

    /// Issuer seizure of 0-100% of the vault's balance of one stock, then a permissionless sync.
    function seize(uint256 i, uint256 pct) external {
        MockB20 s = stocks[i % 8];
        uint256 bal = s.balanceOf(address(vault));
        s.seize(address(vault), address(0xdead), bal * bound(pct, 0, 100) / 100);
        vault.sync(address(s));
        ++seizures;
    }

    /// Claim one credit (unpausing that stock first), in whatever order the fuzzer picks.
    function claim(uint256 who, uint256 i) external {
        address a = actors[who % ACTORS];
        MockB20 s = stocks[i % 8];
        if (vault.owed(a, address(s)) == 0) return;
        s.setPaused(false);
        vm.prank(a);
        uint256 got = vault.claimOwed(address(s), a);
        paid[address(s)] += got;
        ++claims;
    }

    function unpause(uint256 i) external {
        stocks[i % 8].setPaused(false);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 100
contract CreditInvariantsTest is Fixture {
    CreditHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CreditHandler(vault, stocks);
        for (uint256 k; k < handler.ACTORS(); ++k) {
            _mintAs(handler.actors(k), 5e18);
        }
        targetContract(address(handler));
    }

    /// THE invariant asked for: per stock, everything ever paid out on credits plus everything
    /// still owed never exceeds what redeems actually set aside as credit.
    function invariant_paidPlusOwedNeverExceedsCredited() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            assertLe(handler.paid(t) + vault.totalOwed(t), handler.credited(t));
        }
    }

    /// And the vault always holds what its books say: index backing plus credits.
    function invariant_balanceCoversBackingAndCredits() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            assertGe(stocks[i].balanceOf(address(vault)), vault.held(t) + vault.totalOwed(t));
        }
    }

    /// Individual credits add up to no more than the pool (each rounds down by under 1 unit).
    function invariant_individualCreditsAddUp() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            uint256 sum;
            for (uint256 k; k < handler.ACTORS(); ++k) {
                sum += vault.owed(handler.actors(k), t);
            }
            assertLe(sum, vault.totalOwed(t));
            assertLe(vault.totalOwed(t) - sum, handler.ACTORS());
        }
    }

    /// Solvency in practice: unpause everything, let EVERY creditor claim EVERY credit and every
    /// holder redeem everything. All of it must succeed, and only rounding dust may remain owed.
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
        for (uint256 k; k <= n; ++k) {
            address a = k == n ? safe : handler.actors(k);
            uint256 bal = vault.balanceOf(a);
            if (bal != 0) {
                vm.prank(a);
                vault.redeem(bal, a);
            }
        }
        for (uint256 i; i < N; ++i) {
            assertLe(vault.totalOwed(address(stocks[i])), n, "only rounding dust left owed");
        }
        vm.revertToState(snap);
    }

    function afterInvariant() external view {
        // Make sure the run actually exercised the stress paths.
        assertGt(handler.seizures() + handler.claims() + handler.tinyRedeems(), 0);
    }
}
