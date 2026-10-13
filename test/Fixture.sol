// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BasketRegistry} from "../src/BasketRegistry.sol";
import {IndexFeeSplitter} from "../src/IndexFeeSplitter.sol";
import {IndexRouter} from "../src/IndexRouter.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";

import {
    MockAggregator,
    MockB20,
    MockChipBurner,
    MockERC20,
    MockPolicyRegistry,
    MockPoolManager,
    MockSlipstreamFactory,
    MockSlipstreamRouter,
    MockWETH
} from "./mocks/Mocks.sol";

/// @notice Full system on mocks: 8 stocks at the 2026-10-12 Chainlink prices, equal weight.
abstract contract Fixture is Test {
    uint256 internal constant N = 8;
    int24 internal constant TS = 10;

    address internal safe = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal pot = makeAddr("pot");

    MockB20[N] internal stocks;
    MockAggregator[N] internal feeds;
    int256[N] internal prices8 =
        [int256(225_47e6), 150_25e6, 353_59e6, 259_32e6, 340_75e6, 741_53e6, 378_59e6, 539_60e6];
    string[N] internal tickers = ["NVDA", "MSTR", "GOOGL", "AMZN", "AAPL", "META", "TSLA", "MSFT"];

    MockERC20 internal usdc;
    MockWETH internal weth;
    MockERC20 internal chip;
    MockAggregator internal ethFeed;
    MockAggregator internal sequencer;
    MockSlipstreamFactory internal factory;
    MockSlipstreamRouter internal swap;
    MockPoolManager internal poolManager;
    MockChipBurner internal burner;
    MockPolicyRegistry internal policies;

    BasketRegistry internal registry;
    IndexVault internal vault;
    IndexRouter internal router;
    Rebalancer internal rebalancer;
    IndexFeeSplitter internal splitter;

    uint256 internal constant SEED_SHARES = 100e18; // $1,000 seed -> $10 per index token

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH();
        chip = new MockERC20("Chip", "CHIP", 18);
        ethFeed = new MockAggregator(8, 2_600e8);
        sequencer = new MockAggregator(0, 0);
        sequencer.setStartedAt(block.timestamp - 2 hours);
        factory = new MockSlipstreamFactory();
        swap = new MockSlipstreamRouter(address(factory));
        poolManager = new MockPoolManager(1_000_000e18); // 1 WETH = 1M CHIP
        burner = new MockChipBurner(chip);
        policies = new MockPolicyRegistry();

        swap.setPrice(address(usdc), 1e18);
        swap.setPrice(address(weth), 2_600e18);
        factory.setPool(address(weth), address(usdc), TS);

        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](N);
        int24[] memory ts = new int24[](N);
        for (uint256 i; i < N; ++i) {
            // Each mock stock has its own policy id (i + 1) so tests can block on one stock only.
            stocks[i] = new MockB20(tickers[i], string.concat(tickers[i], "c"), policies, uint64(i + 1));
            feeds[i] = new MockAggregator(8, prices8[i]);
            factory.setPool(address(stocks[i]), address(usdc), TS);
            swap.setPrice(address(stocks[i]), uint256(prices8[i]) * 1e10);
            cfg[i] = BasketRegistry.AssetConfig(address(stocks[i]), address(feeds[i]), 1_250);
            ts[i] = TS;
        }

        registry = new BasketRegistry(safe, address(sequencer), address(factory), address(usdc), cfg, ts);
        vault = new IndexVault(safe, registry, address(policies), "Chip Index", "CHIDX", 100, 100, 300, 1_000_000e18);
        rebalancer = new Rebalancer(safe, vault, ISlipstreamRouter(address(swap)), address(usdc), keeper);
        router = new IndexRouter(
            safe,
            vault,
            ISlipstreamRouter(address(swap)),
            address(usdc),
            address(weth),
            address(ethFeed),
            TS,
            keeper
        );
        splitter = new IndexFeeSplitter(
            IndexFeeSplitter.Config({
                owner: safe,
                vault: vault,
                swapRouter: ISlipstreamRouter(address(swap)),
                usdc: address(usdc),
                weth: address(weth),
                chip: address(chip),
                burner: address(burner),
                pot: pot,
                poolManager: address(poolManager),
                ethUsdFeed: address(ethFeed),
                chipPoolKey: PoolKey(address(weth), address(chip), 0x800000, 200, address(0xB00C)),
                wethUsdcTickSpacing: TS,
                keeper: keeper,
                maxChipBuyUsdc: 10_000e6
            })
        );
        registry.wireVault(address(vault));
        vault.wire(address(splitter), address(rebalancer));

        _seed();
    }

    /// @dev $125 of each stock from the Safe, for 100 index tokens.
    function _seed() internal {
        uint256[] memory amounts = new uint256[](N);
        vm.startPrank(safe);
        for (uint256 i; i < N; ++i) {
            amounts[i] = _amountForUsd(i, 125e18);
            stocks[i].mint(safe, amounts[i]);
            stocks[i].approve(address(vault), amounts[i]);
        }
        vault.seed(amounts, SEED_SHARES, safe);
        vm.stopPrank();
    }

    function _amountForUsd(uint256 i, uint256 usd18) internal view returns (uint256) {
        return usd18 * 1e8 / (uint256(prices8[i]) * 1e10);
    }

    /// @dev Give `who` exactly what minting `shares` needs, approved to the vault.
    function _fundForMint(address who, uint256 shares) internal returns (uint256[] memory amounts) {
        (, amounts) = vault.previewMint(shares);
        vm.startPrank(who);
        for (uint256 i; i < N; ++i) {
            stocks[i].mint(who, amounts[i]);
            stocks[i].approve(address(vault), amounts[i]);
        }
        vm.stopPrank();
    }

    function _mintAs(address who, uint256 shares) internal {
        _fundForMint(who, shares);
        vm.prank(who);
        vault.mint(shares, who);
    }

    /// @dev Move time and keep every feed fresh (as if markets were open).
    function _warpFresh(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        for (uint256 i; i < N; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
        ethFeed.setUpdatedAt(block.timestamp);
    }

    function _basket() internal view returns (BasketRegistry.AssetConfig[] memory cfg) {
        BasketRegistry.Asset[] memory a = registry.assets();
        cfg = new BasketRegistry.AssetConfig[](a.length);
        for (uint256 i; i < a.length; ++i) {
            cfg[i] = BasketRegistry.AssetConfig(a[i].token, a[i].feed, a[i].weightBps);
        }
    }
}
