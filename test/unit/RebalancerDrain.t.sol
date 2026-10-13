// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IndexVault, IRebalanceCallback} from "../../src/IndexVault.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {ISlipstreamRouter} from "../../src/interfaces/ISlipstreamRouter.sol";
import {Fixture} from "../Fixture.sol";

/**
 * @notice Self-review item 4: can a stolen keeper key (or a rogue Rebalancer installed through the
 *         timelock) drain the vault by trading back and forth at a loss?
 *
 *         Before the fix, one rebalance of 48 NVDA<->MSTR ping-pong trades lost $101.77 (9.7%) of a
 *         $1,049 test vault and left it eligible to do it again. These tests keep that attack
 *         permanently in the suite: it must FAIL, and whatever a keeper or a rogue Rebalancer can
 *         still do is bounded by the vault's 24h loss cap (0.10% of NAV at launch).
 */
contract RebalancerDrainTest is Fixture {
    uint256 internal constant SKEW = 74; // every fill 0.74% below Chainlink: just inside the 0.75% limit

    function setUp() public override {
        super.setUp();
        // NVDA rallies 40%: about 4 points overweight, so a rebalance is allowed.
        int256 p = prices8[0] * 140 / 100;
        feeds[0].set(p);
        swap.setPrice(address(stocks[0]), uint256(p) * 1e10);
        swap.setSkewBps(SKEW);
    }

    /// The exact attack measured in the self-review: 48 ping-pong trades selling 95% of the
    /// seller's holding each time, then one trade toward target. It now reverts outright.
    function test_drain_48TradePingPongFails() public {
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](49);
        uint256 a = registry.valueUsd(address(stocks[0]), vault.held(address(stocks[0])));
        uint256 b = registry.valueUsd(address(stocks[1]), vault.held(address(stocks[1])));
        bool aSells = true;
        for (uint256 j; j < 48; ++j) {
            uint256 s = aSells ? 0 : 1;
            uint256 v = (aSells ? a : b) * 95 / 100;
            t[j] = Rebalancer.Trade(address(stocks[s]), address(stocks[1 - s]), registry.amountForUsd(address(stocks[s]), v), 0);
            uint256 got = v * (10_000 - SKEW) / 10_000;
            if (aSells) (a, b) = (a - v, b + got);
            else (b, a) = (b - v, a + got);
            aSells = !aSells;
        }
        t[48] = Rebalancer.Trade(address(stocks[0]), address(stocks[1]), 1e6, 0);

        uint256 navBefore = vault.navUsd();
        vm.prank(keeper);
        vm.expectPartialRevert(Rebalancer.OverTradeBudget.selector); // 95% of NVDA is far beyond its overweight
        rebalancer.rebalance(t, block.timestamp + 1);
        assertEq(vault.navUsd(), navBefore, "nothing traded");
    }

    /// Even small ping-pong, each leg within budget, fails: after selling NVDA into MSTR, MSTR is
    /// still at or under target, so it can never be sold back.
    function test_drain_smallPingPongFails() public {
        (, int256[] memory d) = rebalancer.drifts();
        uint256 mstrGap = uint256(-d[1]) * vault.navUsd() / 1e18;
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](2);
        t[0] = Rebalancer.Trade(address(stocks[0]), address(stocks[1]), registry.amountForUsd(address(stocks[0]), mstrGap / 2), 0);
        t[1] = Rebalancer.Trade(address(stocks[1]), address(stocks[0]), registry.amountForUsd(address(stocks[1]), mstrGap / 4), 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotOverweight.selector, address(stocks[1])));
        rebalancer.rebalance(t, block.timestamp + 1);
    }

    /// A stolen keeper key, playing by the Rebalancer's rules with the worst fills allowed, as
    /// often as it can for a whole day. Every sale moves the basket toward target, so the loss is
    /// at most 0.75% of the overweight, and the vault becomes ineligible quickly.
    function test_drain_stolenKeeperBestEffortForADay() public {
        uint256 navBefore = vault.navUsd();
        uint256 calls;
        for (uint256 r; r < 50; ++r) {
            (bool ok,,) = rebalancer.eligible();
            if (!ok) break;
            (, int256[] memory d) = rebalancer.drifts();
            uint256 nav = vault.navUsd();
            uint256 over = uint256(d[0]) * nav / 1e18;
            Rebalancer.Trade[] memory t = new Rebalancer.Trade[](7);
            for (uint256 j = 1; j < 8; ++j) {
                uint256 under = d[j] < 0 ? uint256(-d[j]) * nav / 1e18 : 0;
                uint256 usd = (under < over / 7 ? under : over / 7) * 99 / 100;
                t[j - 1] = Rebalancer.Trade(address(stocks[0]), address(stocks[j]), registry.amountForUsd(address(stocks[0]), usd), 0);
            }
            vm.prank(keeper);
            try rebalancer.rebalance(t, block.timestamp + 1) {
                ++calls;
            } catch {
                break;
            }
            vm.warp(block.timestamp + 10 minutes);
            for (uint256 i; i < N; ++i) {
                feeds[i].setUpdatedAt(block.timestamp);
            }
        }
        uint256 lost = navBefore - vault.navUsd();
        console2.log("keeper-rule attack: rebalances that went through", calls);
        console2.log("NAV lost (cents) on a vault of (dollars)", lost / 1e16, navBefore / 1e18);
        console2.log("  = bps of NAV x100", lost * 1e6 / navBefore);
        assertLe(lost, navBefore * vault.dailyLossCapBps() / 10_000, "within the 24h loss cap");
        (bool again,,) = rebalancer.eligible();
        assertFalse(again, "and the vault is no longer eligible");
    }

    /// A rogue Rebalancer installed through the 48h timelock ignores every Rebalancer rule and
    /// trades back and forth directly. The VAULT's 24h caps stop it at 0.10% of NAV per day.
    function test_drain_rogueRebalancerStoppedByVaultCaps() public {
        RogueRebalancer rogue = new RogueRebalancer(vault, address(swap), address(usdc));
        vm.startPrank(safe);
        vault.queueRebalancer(address(rogue));
        vm.warp(block.timestamp + 48 hours);
        vault.executeRebalancer(address(rogue));
        vm.stopPrank();
        _fresh();

        uint256 nav0 = vault.navUsd();
        uint256 trades = rogue.drain(address(stocks[0]), address(stocks[1]), 200);
        uint256 lost1 = nav0 - vault.navUsd();
        console2.log("rogue rebalancer day 1: trades before the vault stopped it", trades);
        console2.log("  NAV lost (cents) on a vault of (dollars)", lost1 / 1e16, nav0 / 1e18);
        assertGt(trades, 0);
        assertLe(lost1, nav0 * 10 / 10_000, "<= 0.10% of NAV in the first 24h");
        assertGt(lost1, 0);

        // Same day: nothing more.
        assertEq(rogue.drain(address(stocks[0]), address(stocks[1]), 10), 0, "capped for the rest of the day");

        // Next day: another day's allowance, no more.
        vm.warp(block.timestamp + 1 days);
        _fresh();
        uint256 nav1 = vault.navUsd();
        rogue.drain(address(stocks[0]), address(stocks[1]), 200);
        assertLe(nav1 - vault.navUsd(), nav1 * 10 / 10_000, "<= 0.10% of NAV in the second 24h");
    }

    function _fresh() internal {
        for (uint256 i; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
    }
}

/// @notice A Rebalancer written by an attacker: trades A->B->A->... at the worst fill allowed.
contract RogueRebalancer is IRebalanceCallback {
    IndexVault internal immutable vault;
    ISlipstreamRouter internal immutable swap;
    address internal immutable usdc;

    constructor(IndexVault v, address s, address u) {
        vault = v;
        swap = ISlipstreamRouter(s);
        usdc = u;
    }

    /// Ping-pong 30% of the seller's holding each time until the vault refuses. Returns trades done.
    function drain(address a, address b, uint256 rounds) external returns (uint256 done) {
        for (uint256 r; r < rounds; ++r) {
            (address sell, address buy) = r % 2 == 0 ? (a, b) : (b, a);
            uint256 amt = vault.held(sell) * 30 / 100;
            try vault.executeTrade(sell, amt, buy, 0, "") {
                ++done;
            } catch {
                break;
            }
        }
    }

    function onRebalanceTrade(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata) external {
        IERC20(tokenIn).approve(address(swap), amountIn);
        swap.exactInput(
            ISlipstreamRouter.ExactInputParams({
                path: abi.encodePacked(tokenIn, int24(10), usdc, int24(10), tokenOut),
                recipient: address(vault),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            })
        );
    }
}
