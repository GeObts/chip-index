// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IndexFeeSplitter} from "../../src/IndexFeeSplitter.sol";
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
        splitter.buyAndBurn(budget + 1, 0, deadline);

        vm.prank(safe);
        splitter.setMaxChipBuyUsdc(1e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IndexFeeSplitter.OverCap.selector, 2e6, 1e6));
        splitter.buyAndBurn(2e6, 0, deadline);

        vm.prank(keeper);
        vm.expectRevert();
        splitter.buyAndBurn(1e6, type(uint256).max, deadline); // keeper's min CHIP out

        vm.prank(alice);
        vm.expectRevert(IndexFeeSplitter.NotKeeper.selector);
        splitter.buyAndBurn(1e6, 0, deadline);
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
