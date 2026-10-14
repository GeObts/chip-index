// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IB20} from "base-std/interfaces/IB20.sol";

import {IndexVault, IRebalanceCallback} from "../../src/IndexVault.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {ChipIndexForkBase} from "./ChipIndexFork.t.sol";

/**
 * @notice F-01 (ChatGPT final review) on a Base mainnet fork with the real B20 stocks, feeds and
 *         Aerodrome pools. NO test here calls `sync`.
 *
 *         The live precompile rejects the seize entry points (see test_fork_seizureWithOutstandingCredit),
 *         so a seizure is simulated the same way: a transfer out of the vault, pranked as the vault.
 *         The vault's balance drops exactly as it would under a real seizure.
 */
contract SeizureNoSyncForkTest is ChipIndexForkBase, IRebalanceCallback {
    address internal carol = makeAddr("chip-index-test-carol");

    /// When this test contract is installed as the vault's Rebalancer: 0 = pay back fair value,
    /// 1 = keep everything.
    uint8 internal callbackMode;

    function _seize(uint256 i, uint256 amount) internal {
        vm.prank(address(vault));
        IERC20(tokens[i]).transfer(address(0xdead), amount);
    }

    function _bal(uint256 i) internal view returns (uint256) {
        return IERC20(tokens[i]).balanceOf(address(vault));
    }

    function _supply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingManagementFee();
    }

    function _holdersPart(uint256 i) internal view returns (uint256) {
        uint256 h = vault.held(tokens[i]);
        uint256 o = vault.totalOwed(tokens[i]);
        uint256 b = _bal(i);
        return b >= h + o ? h : h * b / (h + o);
    }

    function _realNav() internal view returns (uint256 nav) {
        for (uint256 i; i < N; ++i) {
            nav += registry.valueUsd(tokens[i], _holdersPart(i));
        }
    }

    function _net(uint256 shares) internal view returns (uint256) {
        return shares - shares * vault.redeemFeeBps() / 10_000;
    }

    function _mintAs(address who, uint256 shares) internal returns (uint256[] memory paid) {
        (, uint256[] memory need) = vault.previewMint(shares);
        for (uint256 i; i < N; ++i) {
            _give(tokens[i], who, need[i]);
            vm.prank(who);
            IERC20(tokens[i]).approve(address(vault), need[i]);
        }
        vm.prank(who);
        paid = vault.mint(shares, who);
    }

    function _assertBooksMatch() internal view {
        for (uint256 i; i < N; ++i) {
            assertLe(vault.held(tokens[i]) + vault.totalOwed(tokens[i]), _bal(i), "books <= real balance");
        }
    }

    /* 1 */
    function test_fork_f01_seizeThenRedeem() public {
        _mintAs(alice, 100e18);
        uint256 staleHeld = vault.held(tokens[0]);
        _seize(0, _bal(0) / 2);

        uint256 S = _supply();
        uint256 aShares = vault.balanceOf(alice);
        uint256[N] memory fair;
        for (uint256 i; i < N; ++i) {
            fair[i] = _holdersPart(i) * _net(aShares) / S;
        }
        vm.prank(alice);
        vault.redeem(aShares, alice);
        for (uint256 i; i < N; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(alice), fair[i], "true share of the real balance");
        }
        assertLt(fair[0], staleHeld * _net(aShares) / S);
        console2.log("NVDA paid / stale-book amount", fair[0], staleHeld * _net(aShares) / S);

        // The Safe, last out, is paid its share too.
        uint256 sShares = vault.balanceOf(SAFE);
        uint256 sFair = _holdersPart(0) * _net(sShares) / _supply();
        vm.prank(SAFE);
        vault.redeem(sShares, SAFE);
        assertEq(IERC20(tokens[0]).balanceOf(SAFE), sFair);
        _assertBooksMatch();
    }

    /* 2 */
    function test_fork_f01_seizeThenMint() public {
        _seize(0, _bal(0) / 2);
        uint256 S = _supply();
        uint256 shares = 20e18;
        (uint16 bps, uint256 valueUsd) = vault.mintFeeFor(shares);
        assertEq(valueUsd, _realNav() * shares / S, "fee tier priced on the real NAV");
        assertEq(bps, 100);

        uint256 perShare = _realNav() * 1e18 / S;
        uint256[N] memory expected;
        for (uint256 i; i < N; ++i) {
            expected[i] = (_holdersPart(i) * shares + S - 1) / S; // pro-rata of the real balance, rounded up
        }
        assertLt(expected[0], (vault.held(tokens[0]) * shares + S - 1) / S, "less than the stale book asks");
        uint256[] memory paid = _mintAs(bob, shares);
        for (uint256 i; i < N; ++i) {
            assertEq(paid[i], expected[i]);
        }
        assertEq(vault.held(tokens[0]), _bal(0));
        assertGe(vault.navPerShare(), perShare, "holders not diluted");
        _assertBooksMatch();
    }

    /* 3a */
    function test_fork_f01_seizeThenRebalance_normal() public {
        _seize(0, _bal(0) / 2);
        uint256 nav = _realNav();
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](N - 1);
        for (uint256 j = 1; j < N; ++j) {
            uint256 over = registry.valueUsd(tokens[j], _bal(j)) - nav * 1_250 / 10_000;
            t[j - 1] = Rebalancer.Trade(tokens[j], tokens[0], registry.amountForUsd(tokens[j], over / 2), 0);
        }
        vm.prank(KEEPER);
        rebalancer.rebalance(t, block.timestamp + 600);
        for (uint256 i; i < N; ++i) {
            assertEq(vault.held(tokens[i]), _bal(i), "books match the balance");
        }
        assertEq(vault.windowNavUsd(), nav, "daily caps measured on the real NAV");
        console2.log("NAV real before / after (USD)", nav / 1e18, vault.navUsd() / 1e18);
    }

    /* 3b: this test contract is installed as a hostile Rebalancer. */
    function test_fork_f01_seizeThenRebalance_hostile() public {
        vm.prank(SAFE);
        vault.queueRebalancer(address(this));
        vm.warp(block.timestamp + 48 hours);
        _freshenFeeds();
        vm.prank(SAFE);
        vault.executeRebalancer(address(this));

        uint256 staleHeld = vault.held(tokens[0]);
        _seize(0, _bal(0) / 2);
        uint256 realHeld = _bal(0);

        // Cannot sell NVDA that is only on the stale book.
        vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientHeld.selector, tokens[0], staleHeld, realHeld));
        vault.executeTrade(tokens[0], staleHeld, tokens[7], 0, "");

        // Keeping what it was sent still fails.
        uint256 amt = _bal(7) / 20;
        callbackMode = 1;
        vm.expectRevert();
        vault.executeTrade(tokens[7], amt, tokens[0], 0, "");

        // A fair trade works, and the day's caps are on the real NAV.
        callbackMode = 0;
        uint256 nav = _realNav();
        vault.executeTrade(tokens[7], amt, tokens[0], 0, "");
        assertEq(vault.windowNavUsd(), nav);
        assertEq(vault.held(tokens[0]), _bal(0));
    }

    function onRebalanceTrade(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata) external {
        require(msg.sender == address(vault), "only vault");
        if (callbackMode == 1) return;
        uint256 out = registry.amountForUsd(tokenOut, registry.valueUsd(tokenIn, amountIn));
        _give(tokenOut, address(vault), out);
    }

    /* 4 */
    struct Payouts {
        uint256 alice;
        uint256 bob;
        uint256 redeemer;
    }

    function test_fork_f01_seizeWithCredits_bothOrders() public {
        IB20 nvda = IB20(tokens[0]);
        _grantRole(tokens[0], nvda.PAUSE_ROLE(), address(this));
        _grantRole(tokens[0], nvda.UNPAUSE_ROLE(), address(this));
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        nvda.pause(f);
        vm.startPrank(SAFE);
        uint256 a = vault.redeem(30e18, alice)[0];
        uint256 b = vault.redeem(20e18, bob)[0];
        vm.stopPrank();
        nvda.unpause(f);

        Payouts memory F = _fairAfterHalf(a, b);

        uint256 snap = vm.snapshotState();
        Payouts memory A;
        A.alice = _claim(alice);
        A.bob = _claim(bob);
        A.redeemer = _redeemAllNvda(SAFE);
        vm.revertToState(snap);
        _freshenFeeds(); // mockCall survives the revert; keep the feeds fresh regardless
        Payouts memory B;
        B.redeemer = _redeemAllNvda(SAFE);
        B.bob = _claim(bob);
        B.alice = _claim(alice);

        _assertFair(A, F);
        _assertFair(B, F);
        _assertBooksMatch();
        console2.log("credit alice: booked / paid", a, B.alice);
    }

    function _fairAfterHalf(uint256 a, uint256 b) internal returns (Payouts memory F) {
        uint256 h = vault.held(tokens[0]);
        uint256 total = _bal(0);
        assertEq(total, h + a + b);
        _seize(0, total / 2);
        uint256 left = _bal(0);
        F.alice = a * left / total;
        F.bob = b * left / total;
        F.redeemer = (h * left / total) * _net(vault.balanceOf(SAFE)) / _supply();
    }

    function _claim(address who) internal returns (uint256 got) {
        vm.prank(who);
        got = vault.claimOwed(tokens[0], who);
    }

    function _redeemAllNvda(address who) internal returns (uint256) {
        uint256 s = vault.balanceOf(who);
        vm.prank(who);
        return vault.redeem(s, who)[0];
    }

    function _assertFair(Payouts memory P, Payouts memory F) internal pure {
        assertLe(P.alice, F.alice + 1);
        assertLe(P.bob, F.bob + 1);
        assertLe(P.redeemer, F.redeemer);
        assertApproxEqAbs(P.alice, F.alice, 2);
        assertApproxEqAbs(P.bob, F.bob, 2);
        assertApproxEqAbs(P.redeemer, F.redeemer, 2);
    }

    /* 5 */
    function test_fork_f01_donationThenMintAndRedeem() public {
        uint256 shares = 20e18;
        (, uint256[] memory mintBefore) = vault.previewMint(shares);
        (uint16 bpsBefore, uint256 valBefore) = vault.mintFeeFor(shares);
        (, uint256[] memory redeemBefore,) = vault.previewRedeem(10e18, SAFE);

        _give(tokens[0], address(vault), _bal(0) * 20); // donate 20x the NVDA holding, no sync

        (uint16 bpsAfter, uint256 valAfter) = vault.mintFeeFor(shares);
        assertEq(bpsAfter, bpsBefore, "fee tier unchanged");
        assertEq(valAfter, valBefore);
        uint256[] memory paid = _mintAs(bob, shares);
        for (uint256 i; i < N; ++i) {
            assertEq(paid[i], mintBefore[i], "mint costs what it did before the donation");
        }
        // Redeem right after: the earlier preview, scaled for the supply bob's mint added.
        vm.prank(SAFE);
        uint256[] memory got = vault.redeem(10e18, SAFE);
        for (uint256 i; i < N; ++i) {
            assertApproxEqAbs(got[i], redeemBefore[i], 1, "donation not paid out");
        }
    }

    /* gas */
    function test_fork_f01_gas() public {
        (, uint256[] memory need) = vault.previewMint(10e18);
        for (uint256 i; i < N; ++i) {
            _give(tokens[i], bob, need[i]);
            vm.prank(bob);
            IERC20(tokens[i]).approve(address(vault), need[i]);
        }
        uint256 g = gasleft();
        vm.prank(bob);
        vault.mint(10e18, bob);
        console2.log("fork gas mint (8 real B20s)", g - gasleft());
        g = gasleft();
        vm.prank(bob);
        vault.redeem(5e18, bob);
        console2.log("fork gas redeem (8 real B20s)", g - gasleft());
    }
}
