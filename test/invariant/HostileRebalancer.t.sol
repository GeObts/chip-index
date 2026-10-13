// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {IndexVault, IRebalanceCallback} from "../../src/IndexVault.sol";
import {Fixture} from "../Fixture.sol";
import {MockAggregator, MockB20} from "../mocks/Mocks.sol";

/**
 * @notice Round-2 request 4: a deliberately hostile Rebalancer CONTRACT (not just a bad keeper),
 *         installed through the 48h timelock, trying every kind of trade it can make. It holds its
 *         own stash of every stock, so it can pay the vault back anything from nothing to more
 *         than fair, and it tries to re-enter the vault from inside the trade callback.
 *
 *         The only things that may stop it are the vault's own checks: value in vs out per trade
 *         (0.75%) and the 24h caps (15% of NAV traded, 0.10% of NAV lost, per window).
 */
contract HostileRebalancer is IRebalanceCallback {
    IndexVault internal immutable vault;
    BasketRegistry internal immutable registry;

    uint8 internal mode;
    uint16 internal returnBps;
    address internal backDoorToken;
    bool public reentrySucceeded;

    constructor(IndexVault v) {
        vault = v;
        registry = v.registry();
    }

    /// @param mode_ 0 pay back `returnBps` of fair value; 1 also try to re-enter the vault;
    ///              2 pay back AND hand some tokenIn back; 3 keep everything; 4 pay in a third,
    ///              unrelated stock.
    function attack(address tokenIn, uint256 amountIn, address tokenOut, uint8 mode_, uint16 returnBps_, address other)
        external
        returns (uint256)
    {
        mode = mode_;
        returnBps = returnBps_;
        backDoorToken = other;
        return vault.executeTrade(tokenIn, amountIn, tokenOut, 0, "");
    }

    function onRebalanceTrade(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata) external {
        uint256 fairOut = registry.amountForUsd(tokenOut, registry.valueUsd(tokenIn, amountIn));
        uint256 out = fairOut * returnBps / 10_000;
        if (mode == 1) _tryReenter(tokenIn, tokenOut);
        if (mode == 3) return;
        address payToken = mode == 4 ? backDoorToken : tokenOut;
        MockB20(payToken).mint(address(vault), out);
        if (mode == 2) IERC20(tokenIn).transfer(address(vault), amountIn / 2);
    }

    function _tryReenter(address tokenIn, address tokenOut) internal {
        bool ok;
        (ok,) = address(vault).call(abi.encodeCall(IndexVault.sync, (tokenIn)));
        if (ok) reentrySucceeded = true;
        (ok,) = address(vault).call(abi.encodeCall(IndexVault.executeTrade, (tokenOut, 1, tokenIn, 0, "")));
        if (ok) reentrySucceeded = true;
        (ok,) = address(vault).call(abi.encodeWithSignature("redeem(uint256,address)", 1, address(this)));
        if (ok) reentrySucceeded = true;
        (ok,) = address(vault).call(abi.encodeCall(IndexVault.claimOwed, (tokenIn, address(this))));
        if (ok) reentrySucceeded = true;
        (ok,) = address(vault).call(abi.encodeCall(IndexVault.accrue, ()));
        if (ok) reentrySucceeded = true;
    }
}

contract HostileHandler is Test {
    uint256 internal constant BPS = 10_000;

    IndexVault internal vault;
    BasketRegistry internal registry;
    HostileRebalancer public hostile;
    MockB20[8] internal stocks;
    MockAggregator[8] internal feeds;

    struct Loss {
        uint64 at;
        uint256 usd;
    }

    Loss[] internal losses;
    uint256 public trades;
    uint256 public refused;
    /// Worst Chainlink-value loss in one vault window, and in any 24h span, in bps of the
    /// window's opening NAV (1e4 = 100%), scaled by 1e6 for precision.
    uint256 public worstWindowLossPpm;
    uint256 public worstDayLossPpm;
    uint256 public totalLossUsd;
    uint64 internal lastWindow;
    uint256 internal windowLoss;

    constructor(IndexVault v, HostileRebalancer h, MockB20[8] memory s, MockAggregator[8] memory f) {
        vault = v;
        registry = v.registry();
        hostile = h;
        stocks = s;
        feeds = f;
    }

    function trade(uint256 inIdx, uint256 outIdx, uint256 pctOfHeld, uint8 mode, uint16 returnBps, uint256 otherIdx)
        external
    {
        address tin = address(stocks[inIdx % 8]);
        address tout = address(stocks[outIdx % 8]);
        // Mostly small trades (0.01% .. 20% of the vault's holding), one in four up to 100%.
        uint256 amountIn = vault.held(tin) * bound(pctOfHeld, 1, pctOfHeld % 4 == 0 ? 10_000 : 2_000) / BPS;
        // Mostly "pay back properly" (mode 0) so trades land and press on the 24h caps; the
        // other modes are the outright cheats.
        mode = mode % 2 == 0 ? 0 : uint8(bound(mode, 1, 4));
        // Pay back anything from nothing to 101% of fair; three in four just inside the 0.75% limit.
        returnBps = uint16(returnBps % 4 != 0 ? bound(returnBps, 9_926, 10_100) : bound(returnBps, 0, 10_100));
        uint256 valueIn = amountIn == 0 ? 0 : registry.valueUsd(tin, amountIn);
        uint256 navBefore = vault.navUsd();
        try hostile.attack(tin, amountIn, tout, mode, returnBps, address(stocks[otherIdx % 8])) returns (uint256 got) {
            ++trades;
            uint256 valueOut = registry.valueUsd(tout, got);
            uint256 lost = valueIn > valueOut ? valueIn - valueOut : 0;
            // Cross-check against NAV itself (prices do not move inside one call).
            uint256 navAfter = vault.navUsd();
            assertApproxEqAbs(navBefore > navAfter ? navBefore - navAfter : 0, lost, 16, "NAV loss == trade loss");
            _record(lost);
        } catch {
            ++refused;
        }
    }

    function _record(uint256 lost) internal {
        if (vault.tradeWindowStart() != lastWindow) {
            lastWindow = vault.tradeWindowStart();
            windowLoss = 0;
        }
        windowLoss += lost;
        totalLossUsd += lost;
        uint256 nav0 = vault.windowNavUsd();
        uint256 w = windowLoss * BPS * 1e6 / nav0;
        if (w > worstWindowLossPpm) worstWindowLossPpm = w;
        if (lost == 0) return;
        losses.push(Loss(uint64(block.timestamp), lost));
        uint256 day;
        for (uint256 k = losses.length; k > 0; --k) {
            if (losses[k - 1].at + 1 days <= block.timestamp) break;
            day += losses[k - 1].usd;
        }
        uint256 d = day * BPS * 1e6 / nav0;
        if (d > worstDayLossPpm) worstDayLossPpm = d;
    }

    /// Time passes (keeping feeds fresh), anywhere from a second to three days.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
        for (uint256 i; i < 8; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
    }

    /// A stock's price moves up to +/-5%.
    function movePrice(uint256 i, uint256 pct) external {
        MockAggregator f = feeds[i % 8];
        (, int256 a,,,) = f.latestRoundData();
        f.set(a * int256(bound(pct, 95, 105)) / 100);
    }
}

contract HostileRebalancerTest is Fixture {
    HostileHandler internal handler;
    HostileRebalancer internal hostile;

    function setUp() public override {
        super.setUp();
        hostile = _install();
        handler = new HostileHandler(vault, hostile, stocks, feeds);
        targetContract(address(handler));
    }

    function _install() internal returns (HostileRebalancer h) {
        h = new HostileRebalancer(vault);
        vm.startPrank(safe);
        vault.queueRebalancer(address(h));
        vm.warp(block.timestamp + 48 hours);
        vault.executeRebalancer(address(h));
        vm.stopPrank();
        _warpFresh(0);
    }

    /// Within one vault window, Chainlink value lost never exceeds 0.10% of the window's NAV.
    function invariant_windowLossCapped() public view {
        assertLe(handler.worstWindowLossPpm(), 10 * 1e6);
    }

    /// Over ANY 24h span (which can touch two back-to-back windows) at most 0.20%.
    function invariant_anyDayLossCapped() public view {
        assertLe(handler.worstDayLossPpm(), 20 * 1e6);
    }

    /// Re-entering the vault from the trade callback never works.
    function invariant_noReentry() public view {
        assertFalse(hostile.reentrySucceeded());
    }

    /// The books still match the balances.
    function invariant_booksCovered() public view {
        for (uint256 i; i < N; ++i) {
            address t = address(stocks[i]);
            assertGe(stocks[i].balanceOf(address(vault)), vault.held(t) + vault.totalOwed(t));
        }
    }

    function afterInvariant() external view {
        console2.log("hostile trades accepted / refused", handler.trades(), handler.refused());
        console2.log("worst window loss, millionths of a bp of NAV", handler.worstWindowLossPpm());
        console2.log("worst 24h loss, millionths of a bp of NAV", handler.worstDayLossPpm());
    }

    /* ------------------------------------------------------------------ */
    /*        Worst case in dollars, at the $25k and $50k NAV marks          */
    /* ------------------------------------------------------------------ */

    /// The best strategy for the hostile contract: every trade loses as close to the 0.75%
    /// per-trade limit as allowed, as many times as the caps let it, then waits for the next
    /// window, timed so two windows fall inside one 24h span.
    function test_hostile_worstCaseDollars() public {
        for (uint256 navTarget = 25_000; navTarget <= 50_000; navTarget += 25_000) {
            uint256 snap = vm.snapshotState();
            // Grow the vault to the target NAV ($10 per token, so target/10 tokens in total).
            _mintAs(alice, navTarget * 1e18 / 10 - SEED_SHARES);
            uint256 nav0 = vault.navUsd();

            uint256 lost1 = _drainWindow();
            uint256 tFirst = vault.tradeWindowStart();
            assertGt(tFirst, 0, "window 1 opened");
            vm.warp(tFirst + 1 days); // the earliest moment the next window opens
            _warpFresh(0);
            uint256 lost2 = _drainWindow();

            console2.log("NAV (dollars)", nav0 / 1e18);
            console2.log("  window 1 loss (cents)", lost1 / 1e16);
            console2.log("  window 2 loss (cents), opened exactly 24h later", lost2 / 1e16);
            assertLe(lost1, nav0 * 10 / 10_000 + 1e18, "<= 0.10% (+$1 for price rounding)");
            assertLe(lost1 + lost2, nav0 * 20 / 10_000 + 2e18, "two windows in one 24h span <= 0.20%");
            assertGt(lost1, nav0 * 9 / 10_000, "the attack does reach the cap");
            vm.revertToState(snap);
        }
    }

    /// One window's worth of maximal-loss trades: back and forth between two stocks, each trade
    /// sized to the most the remaining caps allow, paying back 99.26% of fair value (99.25% rounds
    /// past the limit and is refused).
    function _drainWindow() internal returns (uint256 lost) {
        uint256 nav0 = vault.navUsd();
        for (uint256 r; r < 400; ++r) {
            address a = address(stocks[r % 2]);
            address b = address(stocks[1 - r % 2]);
            uint256 lossRoom = vault.tradeWindowStart() + 1 days > block.timestamp
                ? vault.windowNavUsd() * vault.dailyLossCapBps() / 10_000 - vault.windowLostUsd()
                : nav0 * vault.dailyLossCapBps() / 10_000;
            // value whose 0.75% loss uses the remaining room, capped by holdings
            uint256 v = lossRoom * 10_000 / 74;
            uint256 amt = registry.amountForUsd(a, v);
            if (amt > vault.held(a)) amt = vault.held(a);
            if (amt == 0) continue; // sold out of this one: trade the other way
            uint256 navBefore = vault.navUsd();
            try hostile.attack(a, amt, b, 0, 9_926, a) {
                lost += navBefore - vault.navUsd();
            } catch {
                // shrink once, then stop: the caps are hit
                try hostile.attack(a, amt / 2, b, 0, 9_926, a) {
                    lost += navBefore - vault.navUsd();
                } catch {
                    break;
                }
            }
        }
    }
}
