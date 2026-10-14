// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IndexRouter} from "../../src/IndexRouter.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {OracleLib} from "../../src/lib/OracleLib.sol";
import {ChipIndexForkBase} from "./ChipIndexFork.t.sol";

/// @notice Weekend cash mint/redeem on Base mainnet: the real Coinbase stock feeds go stale (their
///         real updatedAt, 60h later), ETH/USD stays fresh, every swap is a real Aerodrome fill.
contract WeekendCashForkTest is ChipIndexForkBase {
    uint256 internal constant WEEKEND = 60 hours;

    function _weekend() internal {
        vm.clearMockedCalls(); // the stock feeds' REAL updatedAt values
        vm.warp(block.timestamp + WEEKEND);
        _freshen(ETH_USD_FEED); // crypto keeps trading
        assertFalse(registry.allFresh(), "stock feeds must be stale");
        assertFalse(router.band(false).fresh);
        deal(USDC, alice, 10_000e6);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// The stale feed's last price becomes `num/den` of what it was (updatedAt unchanged: still stale).
    function _shiftStale(address feed, int256 num, int256 den) internal {
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(r, a * num / den, s, u, air)
        );
    }

    function _perShare() internal view returns (uint256[N] memory r) {
        uint256 supply = vault.totalSupply() + vault.pendingManagementFee();
        for (uint256 i; i < N; ++i) {
            r[i] = vault.held(tokens[i]) * 1e36 / supply;
        }
    }

    function _assertNoHolderLoss(uint256[N] memory before) internal view {
        uint256[N] memory afterR = _perShare();
        for (uint256 i; i < N; ++i) {
            assertGe(afterR[i], before[i], "holders lost stock per CHIPX");
        }
    }

    /* ---------------------- weekend mint and redeem ---------------------- */

    function test_fork_weekend_usdcMintAndRedeem() public {
        _weekend();
        uint256 dl = block.timestamp + 600;
        uint256[N] memory r0 = _perShare();
        vm.prank(alice);
        uint256 spent = router.mintWithUsdc(10e18, 200e6, alice, dl);
        console2.log("weekend: USDC spent for 10 CHIPX", spent);
        assertApproxEqRel(spent, 100e6, 1.5e16);
        assertEq(vault.balanceOf(alice), 9.9e18, "base 1% fee");
        _assertNoHolderLoss(r0);

        r0 = _perShare();
        vm.prank(alice);
        uint256 got = router.redeemToUsdc(9.9e18, 90e6, alice, dl);
        console2.log("weekend: USDC back for 9.9 CHIPX", got);
        assertApproxEqRel(got, 98.01e6, 1.5e16);
        _assertNoHolderLoss(r0);
    }

    function test_fork_weekend_ethMintAndRedeem() public {
        _weekend();
        uint256 dl = block.timestamp + 600;
        uint256[N] memory r0 = _perShare();
        vm.prank(alice);
        uint256 spent = router.mintWithEth{value: 1 ether}(10e18, alice, dl);
        console2.log("weekend: ETH spent for 10 CHIPX (wei)", spent);
        assertEq(vault.balanceOf(alice), 9.9e18);
        _assertNoHolderLoss(r0);

        r0 = _perShare();
        uint256 before = bob.balance;
        vm.prank(alice);
        uint256 got = router.redeemToEth(9.9e18, 1, bob, dl);
        console2.log("weekend: ETH back for 9.9 CHIPX (wei)", got);
        assertEq(bob.balance - before, got);
        assertApproxEqRel(got * 1e4 / spent, 9_801, 3e16); // ~98% back after both 1% fees
        _assertNoHolderLoss(r0);
    }

    /* ---------------------------- the band ---------------------------- */

    /// The pool is 15% above the last Chainlink price: a weekend mint reverts (USDC and ETH).
    function test_fork_weekend_poolFifteenPercentOff_mintReverts() public {
        _weekend();
        _shiftStale(feedAddrs[0], 100, 115); // NVDA's last price 15% under its pool
        uint256 dl = block.timestamp + 600;
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithEth{value: 1 ether}(10e18, alice, dl);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// The pool is 15% below the last Chainlink price: a weekend redeem reverts (USDC and ETH).
    function test_fork_weekend_poolFifteenPercentOff_redeemReverts() public {
        _weekend();
        uint256 dl = block.timestamp + 600;
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, dl);
        _shiftStale(feedAddrs[0], 115, 100); // NVDA's last price 15% over its pool
        vm.prank(alice);
        vm.expectRevert();
        router.redeemToUsdc(9.9e18, 1, alice, dl);
        vm.prank(alice);
        vm.expectRevert();
        router.redeemToEth(9.9e18, 1, alice, dl);
        assertEq(vault.balanceOf(alice), 9.9e18);
    }

    /// 8% off is inside the 10% band: the buyer overpays on that leg, holders lose nothing.
    function test_fork_weekend_eightPercentOffFills_holdersUntouched() public {
        _weekend();
        _shiftStale(feedAddrs[0], 100, 108);
        uint256 dl = block.timestamp + 600;
        uint256[N] memory r0 = _perShare();
        vm.prank(alice);
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
        assertEq(vault.balanceOf(alice), 9.9e18);
        _assertNoHolderLoss(r0);
    }

    /// With fresh feeds the same 8% gap still fails the tight 1% check.
    function test_fork_fresh_eightPercentOffReverts() public {
        deal(USDC, alice, 1_000e6);
        vm.prank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        (uint80 r, int256 a, uint256 s,, uint80 air) = IAggregatorV3(feedAddrs[0]).latestRoundData();
        vm.mockCall(
            feedAddrs[0],
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, a * 100 / 108, s, block.timestamp, air)
        );
        assertTrue(router.band(false).fresh);
        uint256 dl = block.timestamp + 600;
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
    }

    /* ------------------------ the user's own limits ------------------------ */

    function test_fork_weekend_userMinOutEnforced() public {
        _weekend();
        uint256 dl = block.timestamp + 600;
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, dl);

        vm.prank(alice);
        vm.expectRevert(IndexRouter.ZeroMinOut.selector);
        router.redeemToUsdc(9.9e18, 0, alice, dl);
        vm.prank(alice);
        vm.expectRevert(IndexRouter.ZeroMinOut.selector);
        router.redeemToEth(9.9e18, 0, alice, dl);

        vm.prank(alice);
        vm.expectPartialRevert(IndexRouter.OutputBelowMin.selector);
        router.redeemToUsdc(9.9e18, 120e6, alice, dl); // ~$98 is all it is worth

        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 80e6, alice, dl); // max-in below the ~$100 it costs
    }

    /* ------------------ the Rebalancer still needs fresh feeds ------------------ */

    function test_fork_weekend_rebalancerRefuses() public {
        _weekend();
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(tokens[0], tokens[1], vault.held(tokens[0]) / 100, 0);
        uint256 dl = block.timestamp + 600;
        vm.prank(KEEPER);
        vm.expectPartialRevert(OracleLib.StalePrice.selector);
        rebalancer.rebalance(t, dl);
    }
}
