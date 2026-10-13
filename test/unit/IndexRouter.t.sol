// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IndexRouter} from "../../src/IndexRouter.sol";
import {Fixture} from "../Fixture.sol";

contract IndexRouterTest is Fixture {
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
        usdc.mint(alice, 10_000e6);
        vm.deal(alice, 10 ether);
        // The mock router mints WETH without ETH behind it; back it so unwraps work.
        vm.deal(address(weth), 100 ether);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(alice);
        vault.approve(address(router), type(uint256).max);
    }

    /* --------------------------- USDC mint --------------------------- */

    function test_mintWithUsdc() public {
        // 10 index tokens at $10 = ~$100.
        vm.prank(alice);
        uint256 spent = router.mintWithUsdc(10e18, 200e6, alice, deadline);
        assertApproxEqRel(spent, 100e6, 1e15);
        assertEq(vault.balanceOf(alice), 9.9e18);
        assertEq(usdc.balanceOf(alice), 10_000e6 - spent, "unspent USDC refunded");
        _assertRouterEmpty();
    }

    function test_mintWithUsdc_userMaxEnforced() public {
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 90e6, alice, deadline); // needs ~$100
    }

    function test_mintWithUsdc_legAboveOnePercentReverts() public {
        swap.setSkewBps(101); // every leg fills 1.01% worse than Chainlink
        vm.prank(alice);
        vm.expectRevert("Too much requested");
        router.mintWithUsdc(10e18, 1_000e6, alice, deadline);

        swap.setSkewBps(90); // within 1%
        vm.prank(alice);
        router.mintWithUsdc(10e18, 1_000e6, alice, deadline);
    }

    function test_mintWithUsdc_blockedWhenAnyFeedStale() public {
        vm.warp(block.timestamp + 27 hours);
        for (uint256 i = 1; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 1_000e6, alice, block.timestamp + 1);
    }

    function test_mintWithUsdc_expired() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexRouter.Expired.selector, block.timestamp - 1));
        router.mintWithUsdc(10e18, 1_000e6, alice, block.timestamp - 1);
    }

    /* ---------------------------- ETH mint --------------------------- */

    function test_mintWithEth() public {
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 spent = router.mintWithEth{value: 1 ether}(10e18, alice, deadline);
        // ~$100 at $2,600/ETH
        assertApproxEqRel(spent, uint256(100e18) / 2_600, 1e15);
        assertEq(alice.balance, balBefore - spent, "unspent ETH refunded");
        assertEq(vault.balanceOf(alice), 9.9e18);
        _assertRouterEmpty();
    }

    function test_mintWithEth_staleEthFeed() public {
        vm.warp(block.timestamp + 2 hours);
        for (uint256 i; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithEth{value: 1 ether}(10e18, alice, block.timestamp + 1);
    }

    /* ----------------------------- redeem ---------------------------- */

    function test_redeemToUsdc() public {
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, deadline);
        uint256 shares = vault.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 out = router.redeemToUsdc(shares, 90e6, alice, deadline);
        // 9.9 tokens less 1% redeem fee at ~$10.
        assertApproxEqRel(out, 98.01e6, 2e15);
        assertEq(usdc.balanceOf(alice), usdcBefore + out);
        _assertRouterEmpty();
    }

    function test_redeemToUsdc_minOutEnforced() public {
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, deadline);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.redeemToUsdc(shares, 99e6, alice, deadline);
    }

    function test_redeemToEth() public {
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, deadline);
        uint256 shares = vault.balanceOf(alice);
        uint256 ethBefore = bob.balance;
        vm.prank(alice);
        uint256 out = router.redeemToEth(shares, 0.03 ether, bob, deadline);
        assertEq(bob.balance - ethBefore, out);
        assertApproxEqRel(out, uint256(98.01e18) / 2_600, 2e15);
        _assertRouterEmpty();
    }

    /// A leg the vault cannot deliver during a cash redeem is credited to the USER, not the router.
    function test_redeemToUsdc_failedLegCreditedToUser() public {
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, deadline);
        uint256 shares = vault.balanceOf(alice);
        stocks[3].setPaused(true);
        vm.prank(alice);
        router.redeemToUsdc(shares, 0, alice, deadline);
        assertGt(vault.owed(alice, address(stocks[3])), 0);
        assertEq(vault.owed(address(router), address(stocks[3])), 0);
    }

    /* ----------------------------- pause ----------------------------- */

    function test_pause_keeperCanPauseOnlyOwnerUnpauses() public {
        vm.prank(keeper);
        router.pauseCashRedeem();
        vm.prank(keeper);
        router.pauseCashMint();

        vm.prank(alice);
        vm.expectRevert(IndexRouter.CashMintIsPaused.selector);
        router.mintWithUsdc(1e18, 100e6, alice, deadline);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        router.unpauseCashMint();

        vm.prank(alice);
        vm.expectRevert(IndexRouter.NotOwnerOrKeeper.selector);
        router.pauseCashMint();

        vm.prank(safe);
        router.unpauseCashMint();
        vm.prank(alice);
        router.mintWithUsdc(1e18, 100e6, alice, deadline);
    }

    /// Cash redeem paused: the user can still redeem in kind straight from the vault.
    function test_pause_cashRedeemPausedInKindStillWorks() public {
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, deadline);
        vm.prank(safe);
        router.pauseCashRedeem();
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(IndexRouter.CashRedeemIsPaused.selector);
        router.redeemToUsdc(shares, 0, alice, deadline);

        vm.prank(alice);
        vault.redeem(shares, alice);
        assertGt(stocks[0].balanceOf(alice), 0);
    }

    function test_slippageCap() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexRouter.SlippageAboveCap.selector, uint16(101)));
        router.setLegSlippageBps(101);
    }

    function test_onlyWethMaySendEth() public {
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok);
    }

    function _assertRouterEmpty() internal view {
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC");
        assertEq(weth.balanceOf(address(router)), 0, "router WETH");
        assertEq(address(router).balance, 0, "router ETH");
        assertEq(vault.balanceOf(address(router)), 0, "router index");
        for (uint256 i; i < N; ++i) {
            assertEq(stocks[i].balanceOf(address(router)), 0, "router stock");
        }
    }
}
