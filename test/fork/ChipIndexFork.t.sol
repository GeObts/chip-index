// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IPolicyRegistry} from "base-std/interfaces/IPolicyRegistry.sol";
import {MockB20Storage} from "base-std-test/lib/mocks/MockB20Storage.sol";

import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {IndexFeeSplitter} from "../../src/IndexFeeSplitter.sol";
import {IndexRouter} from "../../src/IndexRouter.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ISlipstreamFactory, ISlipstreamRouter} from "../../src/interfaces/ISlipstreamRouter.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";

interface IB20AssetLike {
    function OPERATOR_ROLE() external view returns (bytes32);
    function multiplier() external view returns (uint256);
    function updateMultiplier(uint256 newMultiplier) external;
}

/**
 * @notice Base mainnet fork with the REAL B20 stocks, Chainlink feeds, Aerodrome pools, $CHIP v4
 *         pool and ChipBurner. Needs Base's forge, which runs the B20 precompiles:
 *
 *             BASE_RPC_URL=<rpc> base-forge test --match-path "test/fork/*"
 *
 *         Stock `forge` cannot run these (a B20's code is the single byte 0xef there).
 *
 *         Feed timestamps are refreshed with vm.mockCall (the PRICE stays the real one), so the
 *         suite gives the same answer on a weekend. The stale-feed test removes that override.
 */
contract ChipIndexForkTest is Test {
    // ---- Base mainnet ------------------------------------------------------
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant CHIP_BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;
    address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant KEEPER = 0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9;
    address constant SLIP_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address constant SLIP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant CHIP_HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    address constant POLICY_ADMIN = 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812;
    uint64 constant COINBASE_BLOCKLIST = 5;
    int24 constant STOCK_TS = 10;
    int24 constant WETH_USDC_TS = 50;

    uint256 constant N = 8;
    address[N] internal tokens = [
        0xb20000000000000000000078ee7ce2fE4908108C, // NVDA
        0xb2000000000000000000004884b426556b92883d, // MSTR
        0xb2000000000000000000002D0BA3164cc74f58B7, // GOOGL
        0xb200000000000000000000d9192b6B456483C2E8, // AMZN
        0xb200000000000000000000C2e324d24d7eEcd1fb, // AAPL
        0xb2000000000000000000008bC8786B856E61707C, // META
        0xb2000000000000000000001e800a7f5189430cD0, // TSLA
        0xB200000000000000000000Ab99cFa739E253872B // MSFT
    ];
    address[N] internal feedAddrs = [
        0x04689a41629776563E6822F76f2e57D148d28513,
        0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a,
        0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
        0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
        0x787f13dEa48Db0897CbCDD985de77809D837F988,
        0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
        0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4,
        0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c
    ];

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    BasketRegistry internal registry;
    IndexVault internal vault;
    IndexRouter internal router;
    Rebalancer internal rebalancer;
    IndexFeeSplitter internal splitter;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        _freshenFeeds();

        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](N);
        int24[] memory ts = new int24[](N);
        for (uint256 i; i < N; ++i) {
            cfg[i] = BasketRegistry.AssetConfig(tokens[i], feedAddrs[i], 1_250);
            ts[i] = STOCK_TS;
        }
        registry = new BasketRegistry(SAFE, SEQUENCER_FEED, SLIP_FACTORY, USDC, cfg, ts);
        vault = new IndexVault(SAFE, registry, "Chip Index", "CHIDX", 100, 100, 300, 1_000_000e18);
        rebalancer = new Rebalancer(SAFE, vault, ISlipstreamRouter(SLIP_ROUTER), USDC, KEEPER);
        router = new IndexRouter(
            SAFE, vault, ISlipstreamRouter(SLIP_ROUTER), USDC, WETH, ETH_USD_FEED, WETH_USDC_TS, KEEPER
        );
        splitter = new IndexFeeSplitter(
            IndexFeeSplitter.Config({
                owner: SAFE,
                vault: vault,
                swapRouter: ISlipstreamRouter(SLIP_ROUTER),
                usdc: USDC,
                weth: WETH,
                chip: CHIP,
                burner: CHIP_BURNER,
                pot: POT,
                poolManager: POOL_MANAGER,
                ethUsdFeed: ETH_USD_FEED,
                chipPoolKey: PoolKey(WETH, CHIP, 0x800000, 200, CHIP_HOOK),
                wethUsdcTickSpacing: WETH_USDC_TS,
                keeper: KEEPER,
                maxChipBuyUsdc: 10_000e6
            })
        );
        registry.wireVault(address(vault));
        vault.wire(address(splitter), address(rebalancer));

        // Seed: $125 of each real stock from the Safe, for 100 index tokens.
        uint256[] memory amounts = new uint256[](N);
        for (uint256 i; i < N; ++i) {
            amounts[i] = registry.amountForUsd(tokens[i], 125e18);
            _give(tokens[i], SAFE, amounts[i]);
            vm.prank(SAFE);
            IERC20(tokens[i]).approve(address(vault), amounts[i]);
        }
        vm.prank(SAFE);
        vault.seed(amounts, 100e18, SAFE);
    }

    /* ------------------------------------------------------------------ */
    /*                                tests                                */
    /* ------------------------------------------------------------------ */

    function test_fork_seedIsRealStock() public view {
        for (uint256 i; i < N; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(vault)), vault.held(tokens[i]));
        }
        uint256 nps = vault.navPerShare();
        console2.log("NAV per index token (USD, 18 dec)", nps);
        assertApproxEqRel(nps, 10e18, 1e15);
    }

    function test_fork_mintAndRedeemInKind() public {
        (, uint256[] memory need) = vault.previewMint(10e18);
        vm.startPrank(alice);
        for (uint256 i; i < N; ++i) {
            vm.stopPrank();
            _give(tokens[i], alice, need[i]);
            vm.startPrank(alice);
            IERC20(tokens[i]).approve(address(vault), need[i]);
        }
        vault.mint(10e18, alice);
        assertEq(vault.balanceOf(alice), 9.9e18);

        uint256[] memory out = vault.redeem(9.9e18, alice);
        vm.stopPrank();
        for (uint256 i; i < N; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(alice), out[i], "real B20 delivered");
            assertLe(out[i], need[i]);
        }
    }

    function test_fork_cashMintAndRedeemUsdc() public {
        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 spent = router.mintWithUsdc(10e18, 200e6, alice, block.timestamp + 600);
        console2.log("USDC spent for 10 index tokens", spent);
        assertApproxEqRel(spent, 100e6, 1.5e16); // ~$100 plus pool fees, within 1.5%
        assertEq(vault.balanceOf(alice), 9.9e18);

        vault.approve(address(router), type(uint256).max);
        uint256 got = router.redeemToUsdc(9.9e18, 90e6, alice, block.timestamp + 600);
        vm.stopPrank();
        console2.log("USDC back for 9.9 index tokens", got);
        assertApproxEqRel(got, 98.01e6, 1.5e16);
    }

    function test_fork_cashMintWithEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 spent = router.mintWithEth{value: 1 ether}(10e18, alice, block.timestamp + 600);
        console2.log("ETH spent for 10 index tokens (wei)", spent);
        assertEq(vault.balanceOf(alice), 9.9e18);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    /// Stale feeds stop cash mints; in-kind redeem keeps working.
    function test_fork_staleFeed() public {
        vm.clearMockedCalls(); // back to the real updatedAt values
        vm.warp(block.timestamp + 27 hours);
        assertFalse(registry.allFresh());

        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.mintWithUsdc(10e18, 200e6, alice, block.timestamp + 600);
        vm.stopPrank();

        vm.prank(SAFE);
        vault.redeem(10e18, SAFE);
        assertGt(IERC20(tokens[0]).balanceOf(SAFE), 0);
    }

    /// Coinbase blocklists a receiver: every leg is credited (all 8 stocks share policy 5),
    /// and it is claimable once lifted.
    function test_fork_blocklistedReceiver() public {
        _setBlocked(bob, true);
        vm.prank(SAFE);
        uint256[] memory out = vault.redeem(10e18, bob);
        for (uint256 i; i < N; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(bob), 0);
            assertEq(vault.owed(bob, tokens[i]), out[i]);
        }
        _setBlocked(bob, false);
        vm.prank(bob);
        vault.claimOwed(tokens[0], bob);
        assertEq(IERC20(tokens[0]).balanceOf(bob), out[0]);
    }

    /// Coinbase blocklists the VAULT: nothing can move, but redeem still burns and credits.
    function test_fork_blocklistedVault() public {
        _setBlocked(address(vault), true);
        vm.prank(SAFE);
        uint256[] memory out = vault.redeem(10e18, SAFE);
        for (uint256 i; i < N; ++i) {
            assertEq(vault.owed(SAFE, tokens[i]), out[i]);
        }
        assertEq(vault.balanceOf(SAFE), 90e18);
    }

    /// The issuer pauses NVDA transfers: 7 legs pay, NVDA is credited, claimable after unpause.
    function test_fork_pausedToken() public {
        IB20 nvda = IB20(tokens[0]);
        _grantRole(tokens[0], nvda.PAUSE_ROLE(), address(this));
        _grantRole(tokens[0], nvda.UNPAUSE_ROLE(), address(this));
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        nvda.pause(f);
        assertTrue(nvda.isPaused(IB20.PausableFeature.TRANSFER));

        vm.prank(SAFE);
        uint256[] memory out = vault.redeem(10e18, alice);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(vault.owed(alice, tokens[0]), out[0]);
        for (uint256 i = 1; i < N; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(alice), out[i]);
        }

        nvda.unpause(f);
        vm.prank(alice);
        vault.claimOwed(tokens[0], alice);
        assertEq(nvda.balanceOf(alice), out[0]);
    }

    /// A corporate action changes NVDA's multiplier. Raw balances, the vault's books, NAV
    /// (the feed is total-return) and redeem amounts are all unchanged.
    function test_fork_multiplierChange() public {
        IB20AssetLike nvda = IB20AssetLike(tokens[0]);
        uint256 navBefore = vault.navUsd();
        uint256 balBefore = IERC20(tokens[0]).balanceOf(address(vault));
        (, uint256[] memory before,) = vault.previewRedeem(10e18, SAFE);

        _grantRole(tokens[0], nvda.OPERATOR_ROLE(), address(this));
        uint256 m = nvda.multiplier();
        nvda.updateMultiplier(m * 10); // a 10-for-1 split, applied instantly
        assertEq(nvda.multiplier(), m * 10);

        assertEq(IERC20(tokens[0]).balanceOf(address(vault)), balBefore);
        assertEq(vault.held(tokens[0]), balBefore);
        assertEq(vault.navUsd(), navBefore);
        (, uint256[] memory afterAmts,) = vault.previewRedeem(10e18, SAFE);
        assertEq(afterAmts[0], before[0]);
        vm.prank(SAFE);
        vault.redeem(10e18, SAFE);
    }

    /// Someone donates NVDA: after `sync` NVDA is >3 points overweight and the keeper
    /// rebalances through the real Aerodrome pools.
    function test_fork_rebalance() public {
        _give(tokens[0], address(vault), registry.amountForUsd(tokens[0], 60e18));
        vault.sync(tokens[0]);
        (bool ok, uint256 maxDrift,) = rebalancer.eligible();
        console2.log("max drift before (1e18 = 100 points)", maxDrift);
        assertTrue(ok);

        uint256 navBefore = vault.navUsd();
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(tokens[0], tokens[1], registry.amountForUsd(tokens[0], 50e18), 0);
        vm.prank(KEEPER);
        rebalancer.rebalance(t, block.timestamp + 600);

        (, uint256 maxAfter,) = rebalancer.eligible();
        console2.log("max drift after", maxAfter);
        console2.log("NAV before / after", navBefore, vault.navUsd());
        assertLt(maxAfter, maxDrift);
        assertEq(IERC20(tokens[1]).balanceOf(address(vault)), vault.held(tokens[1]));
    }

    /// A year of 3% management fee, then the whole fee pipeline on real venues:
    /// redeem -> sell to USDC -> 50% to the Pot -> 50% buys $CHIP on v4 -> ChipBurner burns it.
    function test_fork_feeAccrualToPotAndBurn() public {
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 365 days);
        _freshenFeeds();
        vault.accrue();
        assertEq(vault.balanceOf(address(splitter)), supply * 3 / 100);

        splitter.redeemFees();
        uint256 potBefore = IERC20(USDC).balanceOf(POT);
        for (uint256 i; i < N; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(splitter));
            vm.prank(KEEPER);
            splitter.sellForUsdc(tokens[i], bal, 0, block.timestamp + 600);
        }
        uint256 toPot = IERC20(USDC).balanceOf(POT) - potBefore;
        console2.log("USDC to the Pot", toPot);
        assertApproxEqAbs(toPot, splitter.chipBudget(), N);

        uint256 chipSupplyBefore = IERC20(CHIP).totalSupply();
        uint256 budget = splitter.chipBudget();
        vm.prank(KEEPER);
        uint256 burned = splitter.buyAndBurn(budget, 1, block.timestamp + 600);
        console2.log("CHIP bought and burned", burned);
        assertGt(burned, 0);
        assertEq(chipSupplyBefore - IERC20(CHIP).totalSupply(), burned, "CHIP supply fell by the burn");
        assertEq(IERC20(CHIP).balanceOf(CHIP_BURNER), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                               helpers                               */
    /* ------------------------------------------------------------------ */

    /// @dev Real stock taken from its Aerodrome USDC pool (a real B20 transfer).
    function _give(address token, address to, uint256 amount) internal {
        address pool = ISlipstreamFactory(SLIP_FACTORY).getPool(token, USDC, STOCK_TS);
        vm.prank(pool);
        IERC20(token).transfer(to, amount);
    }

    function _setBlocked(address who, bool blocked) internal {
        address[] memory a = new address[](1);
        a[0] = who;
        vm.prank(POLICY_ADMIN);
        IPolicyRegistry(POLICY_REGISTRY).updateBlocklist(COINBASE_BLOCKLIST, blocked, a);
        assertEq(IPolicyRegistry(POLICY_REGISTRY).isAuthorized(COINBASE_BLOCKLIST, who), !blocked);
    }

    /// @dev Grant a B20 role by writing the precompile's storage (layout from base-std, which
    ///      Base keeps byte-identical to the Rust implementation), then prove it took.
    function _grantRole(address token, bytes32 role, address who) internal {
        vm.store(token, MockB20Storage.roleMembershipSlot(role, who), bytes32(uint256(1)));
        assertTrue(IB20(token).hasRole(role, who), "role write did not take");
    }

    /// @dev Keep the real price, refresh only updatedAt (so weekends do not fail the suite).
    function _freshenFeeds() internal {
        vm.clearMockedCalls();
        for (uint256 i; i < N; ++i) {
            _freshen(feedAddrs[i]);
        }
        _freshen(ETH_USD_FEED);
    }

    function _freshen(address feed) internal {
        (uint80 r, int256 a, uint256 s,, uint80 air) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, a, s, block.timestamp, air)
        );
    }
}
