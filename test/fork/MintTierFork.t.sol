// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ISlipstreamRouter} from "../../src/interfaces/ISlipstreamRouter.sol";
import {ChipIndexForkBase} from "./ChipIndexFork.t.sol";

/**
 * @notice $10,000 and $50,000 cash mints on a Base fork, with the size-tiered mint fee.
 *
 *         For each mint the test first buys every stock leg ITSELF, through the same Aerodrome
 *         pools and path the router uses, and logs what each leg cost against its Chainlink value
 *         ("leg cost bps"). That is the number the router holds to its 1% per-leg limit
 *         (MAX_LEG_SLIPPAGE_BPS, which cannot be raised). The fork is then rolled back and the real
 *         router mint runs: it must succeed when every leg is within 1%, and revert when any is not.
 *
 *         Mint cap: these tests run on the fork base's TEST vault, deployed with a 1,000,000-token
 *         cap, so a $50k mint fits. The launch cap in script/Deploy.s.sol (5,000 tokens = $50k)
 *         is untouched; at launch (cap $50k, $1k already seeded) one $50k mint cannot fit.
 */
contract MintTierForkTest is ChipIndexForkBase {
    uint256 internal constant LIMIT_BPS = 100;

    function _ethUsd18() internal view returns (uint256) {
        (, int256 a,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        return uint256(a) * 1e10;
    }

    function _sharesFor(uint256 usd18) internal view returns (uint256) {
        return Math.mulDiv(usd18, vault.totalSupply(), vault.navUsd(), Math.Rounding.Ceil);
    }

    /// Buys every leg directly and returns the worst leg cost in bps (vs Chainlink).
    function _measureLegs(uint256 shares, bool eth) internal returns (uint256 worstBps) {
        (address[] memory list, uint256[] memory amounts) = vault.previewMint(shares);
        uint256 ethUsd = _ethUsd18();
        if (eth) {
            deal(WETH, address(this), 1_000 ether);
            IERC20(WETH).approve(SLIP_ROUTER, type(uint256).max);
        } else {
            deal(USDC, address(this), 1_000_000e6);
            IERC20(USDC).approve(SLIP_ROUTER, type(uint256).max);
        }
        for (uint256 i; i < list.length; ++i) {
            uint256 value = registry.valueUsd(list[i], amounts[i]); // 18-dec USD
            uint256 paidUsd;
            if (eth) {
                uint256 wethIn = ISlipstreamRouter(SLIP_ROUTER).exactOutput(
                    ISlipstreamRouter.ExactOutputParams({
                        path: abi.encodePacked(list[i], STOCK_TS, USDC, WETH_USDC_TS, WETH),
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountOut: amounts[i],
                        amountInMaximum: type(uint256).max
                    })
                );
                paidUsd = wethIn * ethUsd / 1e18;
            } else {
                uint256 usdcIn = ISlipstreamRouter(SLIP_ROUTER).exactOutputSingle(
                    ISlipstreamRouter.ExactOutputSingleParams({
                        tokenIn: USDC,
                        tokenOut: list[i],
                        tickSpacing: STOCK_TS,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountOut: amounts[i],
                        amountInMaximum: type(uint256).max,
                        sqrtPriceLimitX96: 0
                    })
                );
                paidUsd = usdcIn * 1e12;
            }
            // Signed cost in hundredths of a bp, so a leg that fills BETTER than Chainlink shows.
            int256 costCbps = (int256(paidUsd) - int256(value)) * 1_000_000 / int256(value);
            console2.log(TICKERS(i), "leg USD (whole)", value / 1e18);
            console2.log("   cost vs Chainlink, 1/100 bp:", costCbps);
            if (costCbps > 0 && uint256(costCbps) / 100 > worstBps) worstBps = uint256(costCbps) / 100;
        }
        console2.log("worst leg (bps, 1% limit = 100):", worstBps);
    }

    function TICKERS(uint256 i) internal pure returns (string memory) {
        string[8] memory t = ["NVDA", "MSTR", "GOOGL", "AMZN", "AAPL", "META", "TSLA", "MSFT"];
        return t[i];
    }

    function _run(uint256 usd, bool eth, uint16 expectBps) internal {
        uint256 shares = _sharesFor(usd * 1e18);
        (uint16 bps, uint256 v) = vault.mintFeeFor(shares);
        console2.log(eth ? "=== ETH mint, USD" : "=== USDC mint, USD", usd);
        console2.log("priced at NAV (whole USD):", v / 1e18);
        console2.log("fee rate (bps):", bps);
        assertEq(bps, expectBps, "tier");

        uint256 snap = vm.snapshotState();
        uint256 worst = _measureLegs(shares, eth);
        vm.revertToState(snap);

        uint256 feeBefore = vault.balanceOf(address(splitter));
        if (eth) {
            uint256 budget = usd * 1e18 * 1e18 / _ethUsd18() * 105 / 100;
            vm.deal(alice, budget);
            vm.prank(alice);
            if (worst > LIMIT_BPS) vm.expectRevert();
            uint256 spent = router.mintWithEth{value: budget}(shares, alice, block.timestamp + 600);
            if (worst > LIMIT_BPS) return;
            console2.log("ETH paid (USD, whole):", spent * _ethUsd18() / 1e36);
            assertEq(alice.balance, budget - spent, "unspent ETH refunded");
        } else {
            uint256 budget = usd * 1e6 * 105 / 100;
            deal(USDC, alice, budget);
            vm.startPrank(alice);
            IERC20(USDC).approve(address(router), type(uint256).max);
            if (worst > LIMIT_BPS) vm.expectRevert();
            uint256 spent = router.mintWithUsdc(shares, budget, alice, block.timestamp + 600);
            vm.stopPrank();
            if (worst > LIMIT_BPS) return;
            console2.log("USDC paid (whole):", spent / 1e6);
        }
        uint256 fee = shares * expectBps / 10_000;
        assertEq(vault.balanceOf(alice), shares - fee, "net to minter");
        assertEq(vault.balanceOf(address(splitter)) - feeBefore, fee, "fee to splitter");
        console2.log("mint fee (USD, whole):", fee * vault.navPerShare() / 1e36);
    }

    function test_fork_tier_usdc10k() public {
        _run(10_000, false, 75);
    }

    function test_fork_tier_usdc50k() public {
        _run(50_000, false, 50);
    }

    function test_fork_tier_eth10k() public {
        _run(10_000, true, 75);
    }

    function test_fork_tier_eth50k() public {
        _run(50_000, true, 50);
    }
}
