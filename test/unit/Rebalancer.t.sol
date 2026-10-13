// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IndexVault} from "../../src/IndexVault.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {Fixture} from "../Fixture.sol";

contract RebalancerTest is Fixture {
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
    }

    /// NVDA rallies `pct`%; feed and pool move together.
    function _rally(uint256 i, uint256 pct) internal {
        int256 p = prices8[i] * int256(100 + pct) / 100;
        feeds[i].set(p);
        swap.setPrice(address(stocks[i]), uint256(p) * 1e10);
    }

    function _trade(uint256 sell, uint256 buy, uint256 usd18) internal view returns (Rebalancer.Trade[] memory t) {
        t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade({
            sell: address(stocks[sell]),
            buy: address(stocks[buy]),
            amountIn: registry.amountForUsd(address(stocks[sell]), usd18),
            minOut: 0
        });
    }

    /// Dollars by which `i` is over (+) or under (-) its target right now.
    function _gapUsd(uint256 i) internal view returns (int256) {
        (, int256[] memory d) = rebalancer.drifts();
        return d[i] * int256(vault.navUsd()) / 1e18;
    }

    /// A trade a careful keeper would send: `pct`% of the smaller of the seller's overweight and
    /// the buyer's underweight, so neither crosses its target.
    function _fair(uint256 sell, uint256 buy, uint256 pct) internal view returns (Rebalancer.Trade[] memory) {
        uint256 over = uint256(_gapUsd(sell));
        uint256 under = uint256(-_gapUsd(buy));
        return _trade(sell, buy, (over < under ? over : under) * pct / 100);
    }

    function test_notEligible_smallDriftWithin30Days() public {
        _rally(0, 10); // NVDA ~13.6%: drift ~1.1 points
        (bool ok, uint256 maxDrift,) = rebalancer.eligible();
        assertFalse(ok);
        assertLt(maxDrift, 3e16);
        Rebalancer.Trade[] memory t = _trade(0, 1, 10e18);
        vm.prank(keeper);
        vm.expectRevert();
        rebalancer.rebalance(t, deadline);
    }

    function test_eligible_after30DaysEvenWithSmallDrift() public {
        _rally(0, 10);
        _warpFresh(30 days);
        Rebalancer.Trade[] memory t = _fair(0, 1, 90);
        vm.prank(keeper);
        rebalancer.rebalance(t, block.timestamp + 1);
        assertEq(rebalancer.lastRebalanceAt(), block.timestamp);
    }

    function test_rebalance_onDriftAboveThreePoints() public {
        _rally(0, 40); // NVDA ~16.7%: drift ~4.2 points
        (bool ok, uint256 maxDrift,) = rebalancer.eligible();
        assertTrue(ok);
        assertGt(maxDrift, 3e16);

        uint256 nvdaBefore = vault.held(address(stocks[0]));
        uint256 mstrBefore = vault.held(address(stocks[1]));
        uint256 navBefore = vault.navUsd();

        // Sell NVDA's overweight into the seven underweight stocks, none past its target.
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](7);
        for (uint256 j = 1; j < 8; ++j) {
            t[j - 1] = _fair(0, j, 95)[0];
        }
        vm.prank(keeper);
        rebalancer.rebalance(t, deadline);

        assertLt(vault.held(address(stocks[0])), nvdaBefore);
        assertGt(vault.held(address(stocks[1])), mstrBefore);
        assertApproxEqRel(vault.navUsd(), navBefore, 1e14, "NAV preserved (no-skew pool)");
        (, uint256 maxAfter,) = rebalancer.eligible();
        assertLt(maxAfter, maxDrift);
        // The vault's books match its balances.
        assertEq(vault.held(address(stocks[1])), stocks[1].balanceOf(address(vault)));
    }

    function test_rebalance_mustSellOverweightAndBuyUnderweight() public {
        _rally(0, 40);
        Rebalancer.Trade[] memory t = _trade(1, 2, 10e18); // MSTR is underweight
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotOverweight.selector, address(stocks[1])));
        rebalancer.rebalance(t, deadline);

        t = _trade(0, 0, 10e18); // buying NVDA, which is overweight
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotUnderweight.selector, address(stocks[0])));
        rebalancer.rebalance(t, deadline);
    }

    /// Buying more MSTR than it is short of pushes it past its target: refused.
    function test_rebalance_buyerOvershootRejected() public {
        _rally(0, 40);
        assertGt(uint256(_gapUsd(0)), 3 * uint256(-_gapUsd(1)), "NVDA's overweight dwarfs MSTR's gap");
        Rebalancer.Trade[] memory t = _trade(0, 1, uint256(-_gapUsd(1)) * 2);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.Overshoot.selector, address(stocks[1])));
        rebalancer.rebalance(t, deadline);
    }

    /// Selling more than the whole basket's overweight in one rebalance: refused before trading.
    function test_rebalance_overTradeBudgetRejected() public {
        _rally(0, 40);
        Rebalancer.Trade[] memory t = _trade(0, 1, 140e18);
        vm.prank(keeper);
        vm.expectPartialRevert(Rebalancer.OverTradeBudget.selector);
        rebalancer.rebalance(t, deadline);
    }

    function test_rebalance_vaultEnforcesSlippage() public {
        _rally(0, 40);
        swap.setSkewBps(150); // pool fills 1.5% below Chainlink
        Rebalancer.Trade[] memory t = _fair(0, 1, 90);
        vm.prank(keeper);
        vm.expectRevert();
        rebalancer.rebalance(t, deadline);
    }

    /// The swap itself now carries a Chainlink minimum (value in minus maxTradeSlippageBps), so a
    /// bad fill is refused inside the swap router, before the vault's own check even runs.
    function test_rebalance_swapCarriesChainlinkMinimum() public {
        _rally(0, 40);
        Rebalancer.Trade[] memory t = _fair(0, 1, 90);
        uint256 expectedMin = registry.amountForUsd(
            address(stocks[1]),
            registry.valueUsd(address(stocks[0]), t[0].amountIn) * (10_000 - vault.maxTradeSlippageBps()) / 10_000
        );
        assertGt(expectedMin, 0);
        vm.prank(keeper);
        rebalancer.rebalance(t, deadline);
        assertEq(swap.lastAmountOutMinimum(), expectedMin, "min-out sent to the swap");

        // A fill 1% under Chainlink (limit 0.75%) now fails in the swap router itself.
        swap.setSkewBps(100);
        t = _fair(0, 2, 90);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        rebalancer.rebalance(t, deadline);

        // Within the limit (0.7%) it fills.
        swap.setSkewBps(70);
        vm.prank(keeper);
        rebalancer.rebalance(t, deadline);
    }

    function test_rebalance_keeperMinOutEnforced() public {
        _rally(0, 40);
        Rebalancer.Trade[] memory t = _fair(0, 1, 90);
        t[0].minOut = type(uint256).max;
        vm.prank(keeper);
        vm.expectRevert();
        rebalancer.rebalance(t, deadline);
    }

    function test_rebalance_onlyKeeper() public {
        _rally(0, 40);
        Rebalancer.Trade[] memory t = _trade(0, 1, 40e18);
        vm.prank(safe);
        vm.expectRevert(Rebalancer.NotKeeper.selector);
        rebalancer.rebalance(t, deadline);
    }

    function test_rebalance_staleFeedBlocks() public {
        _rally(0, 40);
        vm.warp(block.timestamp + 27 hours);
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(address(stocks[0]), address(stocks[1]), 1e7, 0);
        vm.prank(keeper);
        vm.expectRevert();
        rebalancer.rebalance(t, block.timestamp + 1);
    }

    function test_callbackOnlyFromVault() public {
        vm.expectRevert(Rebalancer.NotVault.selector);
        rebalancer.onRebalanceTrade(address(stocks[0]), 1, address(stocks[1]), "");
    }

    /// A ticker removed from the basket (weight 0) is overweight and gets sold down.
    function test_rebalance_sellsRemovedTicker() public {
        BasketRegistry.AssetConfig[] memory full = _basket();
        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](7);
        for (uint256 i; i < 7; ++i) {
            cfg[i] = full[i];
        }
        cfg[1].weightBps = 2_500; // MSFT's 12.5% moves to MSTR
        vm.prank(safe);
        registry.queueBasket(cfg);
        _warpFresh(48 hours);
        vm.prank(safe);
        registry.executeBasket(cfg);

        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(address(stocks[7]), address(stocks[1]), vault.held(address(stocks[7])), 0);
        vm.prank(keeper);
        rebalancer.rebalance(t, block.timestamp + 1);
        assertLt(vault.held(address(stocks[7])), 1e5);
    }
}
