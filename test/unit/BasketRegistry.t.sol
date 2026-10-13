// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {OracleLib} from "../../src/lib/OracleLib.sol";
import {Settings} from "../../src/lib/Settings.sol";
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
        b20Factory.setB20(address(coin), true);
        issuers.setRegistered(address(coin), true);
        coinFeed.setDescription("Coinbase COIN");

        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[7] = BasketRegistry.AssetConfig(address(coin), address(coinFeed), 1_250, TS); // MSFT -> COIN
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

    /// A dropped token nobody holds any more but someone is still owed cannot be pruned, and a
    /// basket change keeps it listed, so `sync` can still write those credits down.
    function test_pruneRefusedWhileCreditsOutstanding() public {
        // MSFT paused: the safe's redeem credits its MSFT leg instead of paying it.
        stocks[7].setPaused(true);
        uint256 safeShares = vault.balanceOf(safe);
        vm.prank(safe);
        vault.redeem(safeShares, safe);
        uint256 feeShares = vault.balanceOf(address(splitter));
        vm.prank(address(splitter));
        vault.redeem(feeShares, address(splitter));
        assertEq(vault.held(address(stocks[7])), 0);
        uint256 owedMsft = vault.totalOwed(address(stocks[7]));
        assertGt(owedMsft, 0);

        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](7);
        BasketRegistry.AssetConfig[] memory full = _basket();
        for (uint256 i; i < 7; ++i) {
            cfg[i] = full[i];
        }
        cfg[0].weightBps = 2_500;
        vm.prank(safe);
        registry.queueBasket(cfg);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        registry.executeBasket(cfg);
        assertTrue(registry.isListed(address(stocks[7])), "kept listed: still owed");

        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.StillOwed.selector, address(stocks[7]), owedMsft));
        registry.prune(address(stocks[7]));

        // Once every credit is claimed it can go.
        stocks[7].setPaused(false);
        vm.prank(safe);
        vault.claimOwed(address(stocks[7]), safe);
        vm.prank(address(splitter));
        vault.claimOwed(address(stocks[7]), address(splitter));
        assertEq(vault.totalOwed(address(stocks[7])), 0);
        registry.prune(address(stocks[7]));
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

    /// Shorter max feed age is instant (it only stops cash paths); longer waits 48h.
    function test_maxFeedAge_shorterInstantLongerTimelocked() public {
        uint8 k = registry.SET_MAX_FEED_AGE();
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.FeedAgeOutOfBounds.selector, 59 minutes));
        registry.tighten(k, 59 minutes);
        registry.tighten(k, 2 hours);
        assertEq(registry.maxFeedAge(), 2 hours);

        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, k, 72 hours));
        registry.tighten(k, 72 hours);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.FeedAgeOutOfBounds.selector, 72 hours + 1));
        registry.queueSetting(k, 72 hours + 1);
        registry.queueSetting(k, 72 hours);
        vm.expectRevert();
        registry.executeSetting(k, 72 hours);
        vm.warp(block.timestamp + 48 hours);
        registry.executeSetting(k, 72 hours);
        vm.stopPrank();
        assertEq(registry.maxFeedAge(), 72 hours);
    }

    /// The pool is part of the basket: a new pool waits 48h and must exist on the factory.
    function test_poolChangeIsABasketChange() public {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[0].usdcTickSpacing = 50;
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NoSuchPool.selector, address(stocks[0]), int24(50)));
        registry.queueBasket(cfg);

        factory.setPool(address(stocks[0]), address(usdc), 50);
        vm.prank(safe);
        registry.queueBasket(cfg);
        assertEq(registry.usdcTickSpacing(address(stocks[0])), TS, "unchanged until executed");
        vm.warp(block.timestamp + 48 hours);
        _freshFeeds();
        vm.prank(safe);
        registry.executeBasket(cfg);
        assertEq(registry.usdcTickSpacing(address(stocks[0])), 50);
    }

    /* ------------------------- authenticity -------------------------- */

    function _queueWithLast(address token, address feed) internal {
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[7] = BasketRegistry.AssetConfig(token, feed, 1_250, TS);
        vm.prank(safe);
        registry.queueBasket(cfg);
    }

    function _newFeed(string memory desc) internal returns (MockAggregator f) {
        f = new MockAggregator(8, 300e8);
        f.setDescription(desc);
    }

    function _newStock(string memory symbol, bool isB20) internal returns (MockB20 t) {
        t = new MockB20(symbol, symbol, policies, 99);
        factory.setPool(address(t), address(usdc), TS);
        b20Factory.setB20(address(t), isB20);
        issuers.setRegistered(address(t), isB20);
    }

    /// A plain ERC-20 (not created by Base's B20 factory) is refused, even when the Safe queues it.
    function test_authenticity_fakeTokenRejected() public {
        MockB20 fake = _newStock("COINc", false);
        address feed = address(_newFeed("Coinbase COIN"));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NotB20.selector, address(fake)));
        this.queueWithLast(address(fake), feed);
    }

    /// A genuine B20 with a copied symbol ("COINc", matching feed, real pool) that Coinbase's
    /// TokenSupplyManager has not registered is refused: anyone can create a B20, only Coinbase
    /// can register one.
    function test_authenticity_unregisteredB20Rejected() public {
        MockB20 copycat = _newStock("COINc", true);
        issuers.setRegistered(address(copycat), false);
        address feed = address(_newFeed("Coinbase COIN"));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NotCoinbaseIssued.selector, address(copycat)));
        this.queueWithLast(address(copycat), feed);

        // Registered when queued but deregistered by Coinbase before execute: refused at execute.
        issuers.setRegistered(address(copycat), true);
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[7] = BasketRegistry.AssetConfig(address(copycat), feed, 1_250, TS);
        vm.prank(safe);
        registry.queueBasket(cfg);
        issuers.setRegistered(address(copycat), false);
        vm.warp(block.timestamp + 48 hours);
        _freshFeeds();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NotCoinbaseIssued.selector, address(copycat)));
        registry.executeBasket(cfg);
    }

    /// Moving the issuer register is a 48h change only, never instant.
    function test_issuerRegistry_timelockOnly() public {
        uint8 key = registry.SET_ISSUER_REGISTRY();
        assertEq(registry.issuerRegistry(), address(issuers));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, key, uint256(uint160(alice))));
        registry.tighten(key, uint160(alice));
        vm.prank(safe);
        registry.queueSetting(key, uint160(alice));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        registry.executeSetting(key, uint160(alice));
        assertEq(registry.issuerRegistry(), alice);
    }

    /// A feed that is not one of Chainlink's (different code, or a different owner) is refused.
    function test_authenticity_untrustedFeedRejected() public {
        MockB20 coin = _newStock("COINc", true);
        MockAggregator f = _newFeed("Coinbase COIN");
        f.setOwner(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UntrustedFeed.selector, address(f)));
        this.queueWithLast(address(coin), address(f));

        // Same owner but different code: a look-alike contract.
        LookAlikeFeed look = new LookAlikeFeed(address(this));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UntrustedFeed.selector, address(look)));
        this.queueWithLast(address(coin), address(look));
    }

    /// The feed must be "Coinbase <TICKER>" for a token whose symbol is "<TICKER>c".
    function test_authenticity_feedMustMatchTicker() public {
        MockB20 coin = _newStock("COINc", true);
        // NVDA's real feed paired with a COIN token.
        vm.expectRevert(
            abi.encodeWithSelector(BasketRegistry.FeedDoesNotMatchToken.selector, address(coin), address(feeds[0]))
        );
        this.queueWithLast(address(coin), address(feeds[0]));

        // A symbol that does not follow Coinbase's "<TICKER>c" naming.
        MockB20 odd = _newStock("COIN", true);
        address feed = address(_newFeed("Coinbase COI"));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.FeedDoesNotMatchToken.selector, address(odd), feed));
        this.queueWithLast(address(odd), feed);

        // The right pairing is accepted.
        this.queueWithLast(address(coin), address(_newFeed("Coinbase COIN")));
    }

    /// Checked again at execute: a token that stops passing during the 48h is refused then.
    function test_authenticity_recheckedAtExecute() public {
        MockB20 coin = _newStock("COINc", true);
        MockAggregator f = _newFeed("Coinbase COIN");
        BasketRegistry.AssetConfig[] memory cfg = _basket();
        cfg[7] = BasketRegistry.AssetConfig(address(coin), address(f), 1_250, TS);
        vm.prank(safe);
        registry.queueBasket(cfg);
        f.setDescription("Coinbase NVDA");
        vm.warp(block.timestamp + 48 hours);
        _freshFeeds();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.FeedDoesNotMatchToken.selector, address(coin), address(f)));
        registry.executeBasket(cfg);
    }

    /// The trusted feed owner can only change through the 48h timelock (for a Chainlink migration).
    function test_trustedFeedOwner_timelockOnly() public {
        uint8 k = registry.SET_TRUSTED_FEED_OWNER();
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(Settings.NotATightening.selector, k, uint256(uint160(alice))));
        registry.tighten(k, uint160(alice));
        registry.queueSetting(k, uint160(alice));
        vm.warp(block.timestamp + 48 hours);
        registry.executeSetting(k, uint160(alice));
        vm.stopPrank();
        assertEq(registry.trustedFeedOwner(), alice);
    }

    function queueWithLast(address token, address feed) external {
        _queueWithLast(token, feed);
    }

    function _freshFeeds() internal {
        for (uint256 i; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
    }

    function test_wireOnlyOnceByDeployer() public {
        vm.expectRevert(BasketRegistry.AlreadyWired.selector);
        registry.wireVault(address(1));
        vm.prank(safe);
        vm.expectRevert(BasketRegistry.NotDeployer.selector);
        registry.wireVault(address(1));
    }
}

/// @notice Same answers as a Chainlink proxy, different code.
contract LookAlikeFeed {
    address public owner;

    constructor(address o) {
        owner = o;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Coinbase COIN";
    }
}
