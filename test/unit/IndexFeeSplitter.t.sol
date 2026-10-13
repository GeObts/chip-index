// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IndexFeeSplitter} from "../../src/IndexFeeSplitter.sol";
import {Settings} from "../../src/lib/Settings.sol";
import {Fixture} from "../Fixture.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract IndexFeeSplitterTest is Fixture {
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        // A year of management fees plus a mint's fee.
        _mintAs(alice, 100e18);
        _warpFresh(365 days);
        deadline = block.timestamp + 1 hours;
    }

    function _sellAll() internal {
        for (uint256 i; i < N; ++i) {
            uint256 bal = stocks[i].balanceOf(address(splitter));
            if (bal == 0) continue;
            vm.prank(keeper);
            splitter.sellForUsdc(address(stocks[i]), bal, 0, deadline);
        }
    }

    function test_redeemFees_noRedeemFeeForRecipient() public {
        vault.accrue();
        uint256 shares = vault.balanceOf(address(splitter));
        // 1 index token mint fee + 3% of ~200 supply for a year.
        assertApproxEqRel(shares, 1e18 + 6e18, 1e16);
        (,, uint256 fee) = vault.previewRedeem(shares, address(splitter));
        assertEq(fee, 0);
        splitter.redeemFees();
        assertEq(vault.balanceOf(address(splitter)), 0);
        for (uint256 i; i < N; ++i) {
            assertGt(stocks[i].balanceOf(address(splitter)), 0);
        }
    }

    function test_sellAndDistribute_fiftyFifty() public {
        vault.accrue();
        // Fee tokens are worth NAV per share, which a year of 3% fees has diluted below $10.
        uint256 feeUsd6 = vault.balanceOf(address(splitter)) * vault.navPerShare() / 1e18 / 1e12;
        splitter.redeemFees();
        _sellAll();
        uint256 toPot = usdc.balanceOf(pot);
        assertGt(toPot, 0);
        assertEq(splitter.chipBudget(), usdc.balanceOf(address(splitter)));
        // Odd-wei rounding goes to the $CHIP side.
        assertApproxEqAbs(toPot, splitter.chipBudget(), N);
        assertApproxEqRel(toPot + splitter.chipBudget(), feeUsd6, 1e14);
    }

    function test_sell_oracleFloorAppliesEvenIfKeeperAsksForLess() public {
        splitter.redeemFees();
        swap.setSkewBps(150); // 1.5% worse than Chainlink: beyond the 1% floor
        uint256 bal = stocks[0].balanceOf(address(splitter));
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        splitter.sellForUsdc(address(stocks[0]), bal, 0, deadline);
    }

    function test_buyAndBurn() public {
        splitter.redeemFees();
        _sellAll();
        uint256 budget = splitter.chipBudget();
        uint256 supplyBefore = chip.totalSupply();

        vm.prank(keeper);
        uint256 chipOut = splitter.buyAndBurn(budget, 1, deadline);

        // budget USDC -> WETH at $2,600 -> 1M CHIP per WETH
        uint256 expected = budget * 1e12 * 1e6 / 2_600; // 18-dec CHIP
        assertApproxEqRel(chipOut, expected, 1e14);
        assertEq(burner.totalBurned(), chipOut);
        assertEq(chip.totalSupply(), supplyBefore, "bought then burned: net zero in the mock");
        assertEq(chip.balanceOf(address(splitter)), 0);
        assertEq(splitter.chipBudget(), 0);
        assertEq(weth.balanceOf(address(splitter)), 0, "no WETH left behind");
    }

    function test_buyAndBurn_limits() public {
        splitter.redeemFees();
        _sellAll();
        uint256 budget = splitter.chipBudget();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.OverBudget.selector, budget + 1, budget));
        splitter.buyAndBurn(budget + 1, 1, deadline);

        uint8 capKey = splitter.SET_MAX_CHIP_BUY();
        vm.prank(safe);
        splitter.tighten(capKey, 1e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.OverCap.selector, 2e6, 1e6));
        splitter.buyAndBurn(2e6, 1, deadline);

        vm.prank(keeper);
        vm.expectRevert();
        splitter.buyAndBurn(1e6, type(uint256).max, deadline); // keeper's min CHIP out

        // A zero floor is refused outright, whatever the keeper script does.
        vm.prank(keeper);
        vm.expectRevert(IndexFeeSplitter.ZeroMinChipOut.selector);
        splitter.buyAndBurn(1e6, 0, deadline);

        vm.prank(alice);
        vm.expectRevert(IndexFeeSplitter.NotKeeper.selector);
        splitter.buyAndBurn(1e6, 1, deadline);
    }

    /// The per-call cap has a hard limit of $500; raising it waits 48h, lowering is instant.
    function test_chipBuyCap_hardLimitAndTimelock() public {
        uint8 k = splitter.SET_MAX_CHIP_BUY();
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.OverCap.selector, 500e6 + 1, 500e6));
        splitter.queueSetting(k, 500e6 + 1);
        splitter.tighten(k, 100e6);
        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, k, 200e6));
        splitter.tighten(k, 200e6);
        splitter.queueSetting(k, 200e6);
        vm.warp(block.timestamp + 48 hours);
        splitter.executeSetting(k, 200e6);
        vm.stopPrank();
        assertEq(splitter.maxChipBuyUsdc(), 200e6);
    }

    /// At most dailyChipBuyUsdc of $CHIP buys per 24h, however the calls are split.
    function test_chipBuy_dailyCap() public {
        splitter.redeemFees();
        _sellAll();
        uint8 perCall = splitter.SET_MAX_CHIP_BUY();
        uint8 daily = splitter.SET_DAILY_CHIP_BUY();
        vm.startPrank(safe);
        splitter.tighten(perCall, 5e6);
        splitter.tighten(daily, 12e6);
        vm.stopPrank();
        assertGe(splitter.chipBudget(), 20e6);

        vm.startPrank(keeper);
        splitter.buyAndBurn(5e6, 1, deadline);
        splitter.buyAndBurn(5e6, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.OverDailyCap.selector, 15e6, 12e6));
        splitter.buyAndBurn(5e6, 1, deadline);
        splitter.buyAndBurn(2e6, 1, deadline); // exactly up to the cap
        vm.stopPrank();

        _warpFresh(1 days);
        vm.prank(keeper);
        splitter.buyAndBurn(5e6, 1, block.timestamp + 1 hours); // a new day
    }

    /// Removing a keeper is instant; installing one waits 48h.
    function test_keeper_removeInstantAddTimelocked() public {
        uint8 k = splitter.SET_KEEPER();
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, k, uint256(uint160(bob))));
        splitter.tighten(k, uint160(bob));
        splitter.tighten(k, 0);
        assertEq(splitter.keeper(), address(0));
        splitter.queueSetting(k, uint160(bob));
        vm.warp(block.timestamp + 48 hours);
        splitter.executeSetting(k, uint160(bob));
        vm.stopPrank();
        assertEq(splitter.keeper(), bob);
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(IndexFeeSplitter.NotPoolManager.selector);
        splitter.unlockCallback(abi.encode(uint256(1)));
    }

    function test_sweep_cannotTouchFeeFlowTokens() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.CannotSweep.selector, address(usdc)));
        splitter.sweep(address(usdc), safe);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.CannotSweep.selector, address(stocks[0])));
        splitter.sweep(address(stocks[0]), safe);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.CannotSweep.selector, address(vault)));
        splitter.sweep(address(vault), safe);

        MockERC20 junk = new MockERC20("Junk", "J", 18);
        junk.mint(address(splitter), 5);
        splitter.sweep(address(junk), safe);
        vm.stopPrank();
        assertEq(junk.balanceOf(safe), 5);
    }

    function test_distribute_isIdempotent() public {
        usdc.mint(address(splitter), 100e6);
        splitter.distribute();
        splitter.distribute();
        assertEq(usdc.balanceOf(pot), 50e6);
        assertEq(splitter.chipBudget(), 50e6);
    }
}
