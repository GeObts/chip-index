// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {OracleLib} from "../../src/lib/OracleLib.sol";
import {Timelock} from "../../src/lib/Timelock.sol";
import {Fixture} from "../Fixture.sol";
import {MockAggregator, MockB20} from "../mocks/Mocks.sol";

contract BasketRegistryTest is Fixture {
    function test_launchBasket() public view {
        assertEq(registry.assetCount(), 8);
        uint256 sum;
        for (uint256 i; i < N; ++i) {
            BasketRegistry.Asset memory a = registry.assetAt(i);
            assertEq(a.token, address(stocks[i]));
            assertEq(a.feed, address(feeds[i]));
            assertEq(a.tokenDecimals, 8);
            assertEq(a.feedDecimals, 8);
            assertEq(registry.usdcTickSpacing(address(stocks[i])), TS);
            sum += a.weightBps;
        }
        assertEq(sum, 10_000);
        assertEq(registry.owner(), safe);
    }

    function test_priceAndValue() public view {
        // NVDA $225.47 -> 2 NVDA = $450.94
        assertEq(registry.priceUsd(address(stocks[0])), 225.47e18);
        assertEq(registry.valueUsd(address(stocks[0]), 2e8), 450.94e18);
        assertEq(registry.amountForUsd(address(stocks[0]), 450.94e18), 2e8);
    }

    function test_rejectsBadBaskets() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[0].weightBps = 1_000; // sums to 9,750
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.WeightsMustSum.selector, 9_750));
        registry.queueBasket(cfg);

        cfg = _basket();
        cfg[1].token = cfg[0].token;
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.DuplicateToken.selector, cfg[0].token));
        registry.queueBasket(cfg);

        cfg = _basket();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.queueBasket(cfg);
    }

    function test_timelock_48hThenExecuteWithin14Days() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[0].weightBps = 1_500;
        cfg[1].weightBps = 1_000;

        vm.prank(safe);
        registry.queueBasket(cfg);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(safe);
        vm.expectRevert();
        registry.executeBasket(cfg);

        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        registry.executeBasket(cfg);
        assertEq(registry.assetAt(0).weightBps, 1_500);
        assertEq(registry.assetAt(1).weightBps, 1_000);
    }

    function test_timelock_expiresAfterGrace() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        vm.prank(safe);
        registry.queueBasket(cfg);
        vm.warp(block.timestamp + 48 hours + 14 days + 1);
        vm.prank(safe);
        vm.expectRevert();
        registry.executeBasket(cfg);
    }

    function test_timelock_executeMustMatchQueuedData() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        vm.prank(safe);
        registry.queueBasket(cfg);
        vm.warp(block.timestamp + 48 hours);
        cfg[0].weightBps = 1_500;
        cfg[1].weightBps = 1_000;
        bytes32 id = registry.changeId(registry.ACTION_BASKET(), abi.encode(cfg));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        registry.executeBasket(cfg);
    }

    function test_cancel() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        vm.prank(safe);
        bytes32 id = registry.queueBasket(cfg);
        vm.prank(safe);
        registry.cancelBasket(id);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        registry.executeBasket(cfg);
    }

    /// Removing a held stock keeps it listed at weight 0 until the vault holds none; adding a new
    /// one lists it at its target with nothing held yet.
    function test_removeAndAddTicker() public {
        MockB20 coin = new MockB20("COIN", "COINc", policies, 99);
        MockAggregator coinFeed = new MockAggregator(8, 300e8);
        factory.setPool(address(coin), address(usdc), TS);

        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[7] = BasketRegistry.AssetConfig(address(coin), address(coinFeed), 1_250); // MSFT -> COIN
        vm.prank(safe);
        registry.queueBasket(cfg);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        registry.executeBasket(cfg);

        assertEq(registry.assetCount(), 9);
        assertTrue(registry.isListed(address(coin)));
        BasketRegistry.Asset memory msft = registry.asset(address(stocks[7]));
        assertEq(msft.weightBps, 0, "MSFT kept at weight 0");

        // Cannot prune while held.
        uint256 held = vault.held(address(stocks[7]));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.StillHeld.selector, address(stocks[7]), held));
        registry.prune(address(stocks[7]));
        // Cannot prune a targeted token.
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.StillTargeted.selector, address(coin)));
        registry.prune(address(coin));
    }

    function test_pruneOnceVaultHoldsNone() public {
        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](7);
        BasketRegistry.AssetConfig[] memory full = _basket();
        for (uint256 i; i < 7; ++i) {
            cfg[i] = full[i];
        }
        cfg[0].weightBps = 2_500; // keep sum at 10,000 without MSFT
        vm.prank(safe);
        registry.queueBasket(cfg);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        registry.executeBasket(cfg);
        assertEq(registry.assetCount(), 8);

        // Holders redeem everything; the vault's MSFT goes to zero.
        uint256 safeShares = vault.balanceOf(safe);
        vm.prank(safe);
        vault.redeem(safeShares, safe);
        // Fee recipient still holds index tokens from the redeem fee; redeem those too.
        uint256 feeShares = vault.balanceOf(address(splitter));
        vm.prank(address(splitter));
        vault.redeem(feeShares, address(splitter));
        assertEq(vault.held(address(stocks[7])), 0);

        registry.prune(address(stocks[7]));
        assertEq(registry.assetCount(), 7);
        assertFalse(registry.isListed(address(stocks[7])));
    }

    function test_staleFeed() public {
        vm.warp(block.timestamp + 26 hours + 1);
        for (uint256 i = 1; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
        assertFalse(registry.allFresh());
        vm.expectRevert();
        registry.requireAllFresh();
        vm.expectRevert();
        registry.priceUsd(address(stocks[0]));
        // The other stocks still price.
        registry.priceUsd(address(stocks[1]));
    }

    function test_badAndBrokenFeeds() public {
        feeds[0].set(0);
        vm.expectRevert(abi.encodeWithSelector(OracleLib.BadPrice.selector, address(feeds[0]), int256(0)));
        registry.priceUsd(address(stocks[0]));
        feeds[1].setBroken(true);
        assertFalse(registry.allFresh());
    }

    function test_sequencerDownOrJustRestarted() public {
        sequencer.set(1);
        vm.expectRevert(OracleLib.SequencerDown.selector);
        registry.priceUsd(address(stocks[0]));
        assertFalse(registry.allFresh());

        sequencer.set(0);
        sequencer.setStartedAt(block.timestamp - 30 minutes);
        vm.expectRevert();
        registry.priceUsd(address(stocks[0]));
    }

    function test_maxFeedAgeBounds() public {
        vm.startPrank(safe);
        vm.expectRevert();
        registry.setMaxFeedAge(59 minutes);
        vm.expectRevert();
        registry.setMaxFeedAge(72 hours + 1);
        registry.setMaxFeedAge(72 hours);
        vm.stopPrank();
        assertEq(registry.maxFeedAge(), 72 hours);
    }

    function test_tickSpacingNeedsRealPool() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NoSuchPool.selector, address(stocks[0]), int24(50)));
        registry.setUsdcTickSpacing(address(stocks[0]), 50);
    }

    function test_wireOnlyOnceByDeployer() public {
        vm.expectRevert(BasketRegistry.AlreadyWired.selector);
        registry.wireVault(address(1));
        vm.prank(safe);
        vm.expectRevert(BasketRegistry.NotDeployer.selector);
        registry.wireVault(address(1));
    }
}
