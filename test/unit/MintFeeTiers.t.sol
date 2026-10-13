// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IndexVault} from "../../src/IndexVault.sol";
import {Timelock} from "../../src/lib/Timelock.sol";
import {Fixture, launchMintFees} from "../Fixture.sol";

/// @notice Size-tiered mint fee: 1% under $10,000, 0.75% from $10,000, 0.5% from $50,000, priced at
///         NAV from the feeds. Redeem stays 1% at any size.
contract MintFeeTiersTest is Fixture {
    uint256 internal constant CENT = 1e16; // $0.01 in 18-dec USD
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
    }

    /// Gross shares whose NAV value is `usd18`, rounded so the vault prices them at >= usd18.
    function _sharesFor(uint256 usd18) internal view returns (uint256) {
        return Math.mulDiv(usd18, vault.totalSupply(), vault.navUsd(), Math.Rounding.Ceil);
    }

    /// Mints `shares` in kind and checks the fee charged matches `bps`.
    function _mintExpect(uint256 shares, uint16 bps) internal {
        (uint16 quoted,) = vault.mintFeeFor(shares);
        assertEq(quoted, bps, "quoted rate");
        uint256 feeBefore = vault.balanceOf(address(splitter));
        uint256 aliceBefore = vault.balanceOf(alice);
        _mintAs(alice, shares);
        uint256 fee = shares * bps / 10_000;
        assertEq(vault.balanceOf(address(splitter)) - feeBefore, fee, "fee to splitter");
        assertEq(vault.balanceOf(alice) - aliceBefore, shares - fee, "net to minter");
    }

    function _assertValue(uint256 shares, uint256 lo, uint256 hi) internal view {
        (, uint256 v) = vault.mintFeeFor(shares);
        assertGe(v, lo, "priced value low");
        assertLe(v, hi, "priced value high");
    }

    /* --------------------------- thresholds --------------------------- */

    function test_justUnder10k_pays1pct() public {
        uint256 s = _sharesFor(10_000e18 - CENT);
        _assertValue(s, 10_000e18 - CENT, 10_000e18 - 1);
        _mintExpect(s, 100);
    }

    function test_exactly10k_pays075pct() public {
        uint256 s = _sharesFor(10_000e18);
        _assertValue(s, 10_000e18, 10_000e18 + CENT);
        _mintExpect(s, 75);
    }

    function test_justOver10k_pays075pct() public {
        uint256 s = _sharesFor(10_000e18 + CENT);
        _mintExpect(s, 75);
    }

    function test_justUnder50k_pays075pct() public {
        uint256 s = _sharesFor(50_000e18 - CENT);
        _assertValue(s, 50_000e18 - CENT, 50_000e18 - 1);
        _mintExpect(s, 75);
    }

    function test_exactly50k_pays05pct() public {
        uint256 s = _sharesFor(50_000e18);
        _mintExpect(s, 50);
    }

    function test_justOver50k_pays05pct() public {
        uint256 s = _sharesFor(50_000e18 + CENT);
        _mintExpect(s, 50);
    }

    function test_smallMint_pays1pct() public {
        _mintExpect(10e18, 100); // $100
    }

    /// The tier is per mint: two $9,000 mints each pay 1%, even though $18,000 in total.
    function test_tierIsPerMint() public {
        uint256 s = _sharesFor(9_000e18);
        _mintExpect(s, 100);
        _mintExpect(_sharesFor(9_000e18), 100);
    }

    /* --------------------------- all mint paths --------------------------- */

    function test_usdcMint_getsTier() public {
        uint256 s = _sharesFor(20_000e18);
        usdc.mint(alice, 25_000e6);
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.mintWithUsdc(s, 25_000e6, alice, deadline);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), s - s * 75 / 10_000);
    }

    function test_ethMint_getsTier() public {
        uint256 s = _sharesFor(60_000e18);
        vm.deal(alice, 30 ether); // ~$78k at $2,600
        vm.deal(address(weth), 100 ether); // the mock router mints WETH unbacked
        vm.prank(alice);
        router.mintWithEth{value: 30 ether}(s, alice, deadline);
        assertEq(vault.balanceOf(alice), s - s * 50 / 10_000);
    }

    /* --------------------------- stale prices --------------------------- */

    /// No fresh price, no discount: a $60k mint with one stale feed still works, at 1%.
    function test_staleFeed_mintStillWorksAtBaseRate() public {
        uint256 s = _sharesFor(60_000e18);
        vm.warp(block.timestamp + 27 hours);
        for (uint256 i = 1; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
        (uint16 bps, uint256 v) = vault.mintFeeFor(s);
        assertEq(bps, 100);
        assertEq(v, 0);
        uint256 supplyBefore = vault.totalSupply() + vault.pendingManagementFee();
        _mintAs(alice, s);
        assertEq(vault.balanceOf(alice), s - s / 100);
        assertGt(vault.totalSupply(), supplyBefore);
    }

    /* --------------------------- redeem unchanged --------------------------- */

    function test_redeemFeeStays1pctAtAnySize() public {
        uint256 s = _sharesFor(60_000e18);
        _mintAs(alice, s);
        uint256 bal = vault.balanceOf(alice);
        (,, uint256 fee) = vault.previewRedeem(bal, alice);
        assertEq(fee, bal / 100);
    }

    /* --------------------------- owner settings --------------------------- */

    function _schedule(uint128 t1, uint128 t2, uint16 b, uint16 r1, uint16 r2)
        internal
        pure
        returns (IndexVault.MintFeeSchedule memory)
    {
        return IndexVault.MintFeeSchedule(t1, t2, b, r1, r2);
    }

    function test_launchScheduleInstalled() public view {
        IndexVault.MintFeeSchedule memory s = vault.mintFeeSchedule();
        assertEq(abi.encode(s), abi.encode(launchMintFees()));
    }

    function test_scheduleChangeIsTimelocked() public {
        IndexVault.MintFeeSchedule memory next = _schedule(5_000e18, 25_000e18, 90, 60, 0);
        vm.prank(safe);
        vault.queueMintFeeSchedule(next);

        vm.prank(safe);
        vm.expectRevert();
        vault.executeMintFeeSchedule(next); // too early

        vm.warp(block.timestamp + 48 hours);

        // Something other than what was queued cannot be executed.
        IndexVault.MintFeeSchedule memory other = _schedule(5_000e18, 25_000e18, 90, 60, 1);
        bytes32 otherId = vault.changeId(vault.ACTION_MINT_FEE_SCHEDULE(), abi.encode(other));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, otherId));
        vault.executeMintFeeSchedule(other);

        vm.prank(safe);
        vault.executeMintFeeSchedule(next);
        assertEq(abi.encode(vault.mintFeeSchedule()), abi.encode(next));
    }

    function test_scheduleOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.queueMintFeeSchedule(launchMintFees());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.executeMintFeeSchedule(launchMintFees());
    }

    function test_scheduleHardCaps() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 101, 100));
        vault.queueMintFeeSchedule(_schedule(10_000e18, 50_000e18, 101, 75, 50));
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 101, 100));
        vault.queueMintFeeSchedule(_schedule(10_000e18, 50_000e18, 100, 101, 50));
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 101, 100));
        vault.queueMintFeeSchedule(_schedule(10_000e18, 50_000e18, 100, 75, 101));
        vm.expectRevert(abi.encodeWithSelector(IndexVault.BadTierThresholds.selector, 0, 50_000e18));
        vault.queueMintFeeSchedule(_schedule(0, 50_000e18, 100, 75, 50));
        vm.expectRevert(abi.encodeWithSelector(IndexVault.BadTierThresholds.selector, 50_000e18, 50_000e18));
        vault.queueMintFeeSchedule(_schedule(50_000e18, 50_000e18, 100, 75, 50));
        // 0% is the floor and is allowed; 1% is the ceiling and is allowed.
        vault.queueMintFeeSchedule(_schedule(1e18, 2e18, 100, 0, 0));
        vm.stopPrank();
    }

    function test_constructorEnforcesCaps() public {
        vm.expectRevert(abi.encodeWithSelector(IndexVault.FeeAboveCap.selector, 200, 100));
        new IndexVault(
            safe, registry, address(policies), "x", "x", _schedule(10_000e18, 50_000e18, 200, 75, 50), 100, 300, 1e30
        );
    }
}
