// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IndexRouter} from "../../src/IndexRouter.sol";
import {OracleLib} from "../../src/lib/OracleLib.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {Settings} from "../../src/lib/Settings.sol";
import {Fixture} from "../Fixture.sol";

/// @notice Cash mint/redeem while the Chainlink stock feeds are frozen (nights, weekends, holidays).
///         Fresh feeds: each leg within 1% of Chainlink. Stale feeds: each leg within 10% of the LAST
///         Chainlink price, plus the user's own limit (a redeem must name a nonzero min-out).
contract WeekendCashTest is Fixture {
    uint256 internal constant WEEKEND = 60 hours; // Friday close to Monday open

    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 100_000e6);
        vm.deal(alice, 100 ether);
        vm.deal(address(weth), 1_000 ether); // the mock router mints WETH; back it so unwraps work
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /* ------------------------------ helpers ------------------------------ */

    /// Stock feeds freeze; ETH/USD keeps updating (crypto trades 24/7).
    function _weekend() internal {
        vm.warp(block.timestamp + WEEKEND);
        ethFeed.setUpdatedAt(block.timestamp);
    }

    function _dl() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// Alice mints 10 CHIPX with USDC while feeds are fresh (her position for the redeem tests).
    function _aliceHolds() internal returns (uint256 shares) {
        uint256 dl = _dl();
        vm.prank(alice);
        router.mintWithUsdc(10e18, 200e6, alice, dl);
        shares = vault.balanceOf(alice);
    }

    /// Every stock held per CHIPX (the vault's own supply notion, so fee accrual is neutral).
    function _perShare() internal view returns (uint256[N] memory r) {
        uint256 supply = vault.totalSupply() + vault.pendingManagementFee();
        for (uint256 i; i < N; ++i) {
            r[i] = vault.held(address(stocks[i])) * 1e36 / supply;
        }
    }

    function _assertNoHolderLoss(uint256[N] memory before, string memory what) internal view {
        uint256[N] memory afterR = _perShare();
        for (uint256 i; i < N; ++i) {
            assertGe(afterR[i], before[i], what);
        }
    }

    /* --------------------- 1. weekend cash mint/redeem --------------------- */

    function test_weekend_mintWithUsdc() public {
        _weekend();
        assertFalse(registry.allFresh());
        uint256 dl = _dl();
        vm.prank(alice);
        uint256 spent = router.mintWithUsdc(10e18, 200e6, alice, dl);
        assertApproxEqRel(spent, 100e6, 1e15);
        assertEq(vault.balanceOf(alice), 9.9e18, "base 1% fee");
    }

    function test_weekend_mintWithEth() public {
        _weekend();
        uint256 dl = _dl();
        vm.prank(alice);
        uint256 spent = router.mintWithEth{value: 1 ether}(10e18, alice, dl);
        assertApproxEqRel(spent, uint256(100e18) / 2_600, 1e15);
        assertEq(vault.balanceOf(alice), 9.9e18);
    }

    function test_weekend_redeemToUsdc() public {
        uint256 shares = _aliceHolds();
        _weekend();
        uint256 dl = _dl();
        vm.prank(alice);
        uint256 out = router.redeemToUsdc(shares, 90e6, alice, dl);
        assertApproxEqRel(out, 98.01e6, 2e15);
    }

    function test_weekend_redeemToEth() public {
        uint256 shares = _aliceHolds();
        _weekend();
        uint256 dl = _dl();
        uint256 before = bob.balance;
        vm.prank(alice);
        uint256 out = router.redeemToEth(shares, 0.03 ether, bob, dl);
        assertEq(bob.balance - before, out);
        assertApproxEqRel(out, uint256(98.01e18) / 2_600, 2e15);
    }

    /// The fee tier needs a NAV; with frozen feeds every mint pays the base 1%.
    function test_weekend_feeTierFallsBackToBase() public {
        (uint16 fresh,) = vault.mintFeeFor(2_000e18); // ~$20,000
        assertEq(fresh, 75);
        _weekend();
        (uint16 stale,) = vault.mintFeeFor(2_000e18);
        assertEq(stale, 100);
    }

    /* ------------------------- 2. the wide band ------------------------- */

    function test_weekend_poolFifteenPercentOff_mintUsdcReverts() public {
        _weekend();
        swap.setSkewBps(1_500);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert("Too much requested");
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
    }

    function test_weekend_poolFifteenPercentOff_mintEthReverts() public {
        _weekend();
        swap.setSkewBps(1_500);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert("Too much requested");
        router.mintWithEth{value: 1 ether}(10e18, alice, dl);
    }

    function test_weekend_poolFifteenPercentOff_redeemsRevert() public {
        uint256 shares = _aliceHolds();
        _weekend();
        swap.setSkewBps(1_500);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert("Too little received");
        router.redeemToUsdc(shares, 1, alice, dl);
        vm.prank(alice);
        vm.expectRevert("Too little received");
        router.redeemToEth(shares, 1, alice, dl);
    }

    /// Inside the 10% band a worse fill goes through (the user's choice), and holders lose nothing.
    function test_weekend_ninePercentOffFills_holdersUntouched() public {
        uint256 shares = _aliceHolds();
        _weekend();
        swap.setSkewBps(900);
        uint256 dl = _dl();

        uint256[N] memory r0 = _perShare();
        vm.prank(alice);
        uint256 spent = router.mintWithUsdc(10e18, 200e6, alice, dl);
        assertApproxEqRel(spent, 109e6, 2e15, "the buyer paid ~9% over");
        _assertNoHolderLoss(r0, "bad-price cash mint");

        r0 = _perShare();
        vm.prank(alice);
        router.redeemToUsdc(shares, 1, alice, dl);
        _assertNoHolderLoss(r0, "bad-price cash redeem");

        r0 = _perShare();
        vm.prank(alice);
        router.mintWithEth{value: 1 ether}(5e18, alice, dl);
        _assertNoHolderLoss(r0, "bad-price ETH mint");

        uint256 rest = vault.balanceOf(alice);
        r0 = _perShare();
        vm.prank(alice);
        router.redeemToEth(rest, 1, alice, dl);
        _assertNoHolderLoss(r0, "bad-price ETH redeem");
    }

    /// Fresh feeds keep the tight 1% check; the same 1.01% fill passes only while feeds are frozen.
    function test_freshKeepsOnePercent_staleWidens() public {
        swap.setSkewBps(101);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert("Too much requested");
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);

        _weekend();
        dl = _dl();
        vm.prank(alice);
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
        assertEq(vault.balanceOf(alice), 9.9e18);
    }

    function test_band_view() public {
        IndexRouter.Band memory b = router.band(false);
        assertTrue(b.fresh);
        assertEq(b.bps, 100);
        _weekend();
        b = router.band(false);
        assertFalse(b.fresh);
        assertEq(b.bps, 1_000);
        assertEq(b.stockAge, 7 days);
    }

    /* ------------------------ 3. the user's limits ------------------------ */

    function test_weekend_redeemNeedsNonzeroMinOut() public {
        uint256 shares = _aliceHolds();
        _weekend();
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert(IndexRouter.ZeroMinOut.selector);
        router.redeemToUsdc(shares, 0, alice, dl);
        vm.prank(alice);
        vm.expectRevert(IndexRouter.ZeroMinOut.selector);
        router.redeemToEth(shares, 0, alice, dl);
    }

    function test_weekend_userMinOutEnforced() public {
        uint256 shares = _aliceHolds(); // worth ~$98 after the redeem fee
        _weekend();
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert();
        router.redeemToUsdc(shares, 99e6, alice, dl);
        vm.prank(alice);
        vm.expectRevert();
        router.redeemToEth(shares, uint256(99e18) / 2_600, alice, dl);
        vm.prank(alice);
        router.redeemToUsdc(shares, 97e6, alice, dl);
    }

    function test_weekend_userMaxInEnforced() public {
        _weekend();
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 95e6, alice, dl); // needs ~$100
        vm.prank(alice);
        vm.expectRevert();
        router.mintWithEth{value: uint256(95e18) / 2_600}(10e18, alice, dl);
    }

    /* ------------------------------ 4. limits ------------------------------ */

    /// The wide band leans on the last price only while it is at most 7 days old.
    function test_lastPriceOlderThanSevenDays_reverts() public {
        vm.warp(block.timestamp + 7 days + 1);
        ethFeed.setUpdatedAt(block.timestamp);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectPartialRevert(OracleLib.StalePrice.selector);
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
    }

    function test_weekend_sequencerDownStillBlocks() public {
        _weekend();
        sequencer.set(1);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert(OracleLib.SequencerDown.selector);
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
    }

    /// Only the ETH feed frozen: ETH calls go wide, USDC calls stay at 1%.
    function test_onlyEthFeedStale_widensEthCallsOnly() public {
        _warpFresh(2 hours);
        ethFeed.setUpdatedAt(block.timestamp - 2 hours);
        swap.setSkewBps(200);
        uint256 dl = _dl();
        vm.prank(alice);
        vm.expectRevert("Too much requested");
        router.mintWithUsdc(10e18, 1_000e6, alice, dl);
        vm.prank(alice);
        router.mintWithEth{value: 1 ether}(10e18, alice, dl);
        assertEq(vault.balanceOf(alice), 9.9e18);
    }

    /// Band: tighter is instant, looser waits 48h, never above 10%; 0 switches stale cash off.
    function test_staleBand_settings() public {
        uint8 k = router.SET_STALE_BAND();
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexRouter.SlippageAboveCap.selector, uint16(1_001)));
        router.queueSetting(k, 1_001);
        router.tighten(k, 500);
        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, k, 1_000));
        router.tighten(k, 1_000);
        router.tighten(k, 0);
        vm.stopPrank();
        assertEq(router.staleBandBps(), 0);

        uint256 dl = _dl();
        vm.prank(alice);
        router.mintWithUsdc(1e18, 100e6, alice, dl); // fresh: unaffected

        _weekend();
        dl = _dl();
        vm.prank(alice);
        vm.expectRevert(IndexRouter.StaleCashOff.selector);
        router.mintWithUsdc(1e18, 100e6, alice, dl);
    }

    /* --------------- 5. the Rebalancer still needs fresh feeds --------------- */

    function test_weekend_rebalancerStillBlocked_routerWorks() public {
        _weekend();
        uint256 dl = _dl();
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(address(stocks[0]), address(stocks[1]), 1e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(OracleLib.StalePrice.selector);
        rebalancer.rebalance(t, dl);

        vm.prank(alice);
        router.mintWithUsdc(1e18, 100e6, alice, dl);
        assertEq(vault.balanceOf(alice), 0.99e18);
    }
}
