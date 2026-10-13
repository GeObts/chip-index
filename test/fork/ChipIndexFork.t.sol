// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IPolicyRegistry} from "base-std/interfaces/IPolicyRegistry.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {MockB20Storage} from "base-std-test/lib/mocks/MockB20Storage.sol";

import {BasketRegistry, IB20FactoryView, IIssuerRegistry} from "../../src/BasketRegistry.sol";
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
abstract contract ChipIndexForkBase is Test {
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
    address constant B20_FACTORY = 0xB20f000000000000000000000000000000000000;
    address constant CHAINLINK_FEED_OWNER = 0xf0Db7318A51a21C413CaDd4AbDC1E8a500fE5B1b;
    address constant POLICY_ADMIN = 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812;
    /// Coinbase's TokenSupplyManager proxy: its admin-only register `isRegisteredToken`.
    address constant COINBASE_TOKEN_REGISTRY = 0xD1Ca4dAcdf3231011D175351f1f02D15C7c5664C;
    /// Coinbase's OracleRegistry (multiplier + pause flag per token, read by the Chainlink feeds).
    address constant COINBASE_ORACLE_REGISTRY = 0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD;
    /// Role holders shared by all 8 launch stocks (read onchain 2026-10-13).
    address constant COINBASE_TOKEN_ADMIN = 0x38467bE00970af18076fd08F6b4Cf38Ba91572B1;
    address constant COINBASE_TOKEN_OPERATOR = 0x5Da41bDDc73406F246d73CbE2e319f3cFc814D9A;
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

    // NOT makeAddr("alice"): that address has code on Base mainnet (it forwards any ETH it receives),
    // which silently ate the ETH-mint refund in an early run. setUp asserts both are plain EOAs.
    address internal alice = makeAddr("chip-index-test-alice");
    address internal bob = makeAddr("chip-index-test-bob");

    BasketRegistry internal registry;
    IndexVault internal vault;
    IndexRouter internal router;
    Rebalancer internal rebalancer;
    IndexFeeSplitter internal splitter;

    /// 1% under $10k, 0.75% from $10k, 0.5% from $50k (same as script/Deploy.s.sol LaunchConfig).
    function _launchMintFees() internal pure returns (IndexVault.MintFeeSchedule memory) {
        return IndexVault.MintFeeSchedule({
            tier1MinUsd: 10_000e18,
            tier2MinUsd: 50_000e18,
            baseBps: 100,
            tier1Bps: 75,
            tier2Bps: 50
        });
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        assertEq(alice.code.length + bob.code.length, 0, "test wallets must have no code on Base");
        _freshenFeeds();

        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](N);
        for (uint256 i; i < N; ++i) {
            cfg[i] = BasketRegistry.AssetConfig(tokens[i], feedAddrs[i], 1_250, STOCK_TS);
        }
        registry = new BasketRegistry(SAFE, SEQUENCER_FEED, SLIP_FACTORY, USDC, B20_FACTORY, COINBASE_TOKEN_REGISTRY, cfg);
        vault = new IndexVault(SAFE, registry, POLICY_REGISTRY, "Chip Index", "CHIPX", _launchMintFees(), 100, 300, 1_000_000e18);
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
                maxChipBuyUsdc: 500e6,
                dailyChipBuyUsdc: 2_000e6
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

/// @notice The core fork scenarios.
contract ChipIndexForkTest is ChipIndexForkBase {

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

    /* ---------------- Coinbase blocklist (real policy 5) ---------------- */

    /// The vault refuses to deliver to a Coinbase-blocklisted receiver.
    function test_fork_blocklist_receiverRefused() public {
        _setBlocked(bob, true);
        assertEq(vault.blockedOn(bob), tokens[0]);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, tokens[0]));
        vault.redeem(10e18, bob);
    }

    /// A blocklisted holder cannot redeem, even to a clean address; nothing is burned.
    function test_fork_blocklist_callerRefused() public {
        vm.prank(SAFE);
        vault.transfer(bob, 10e18);
        _setBlocked(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, tokens[0]));
        vault.redeem(10e18, alice);
        assertEq(vault.balanceOf(bob), 10e18);
    }

    /// A clean caller cannot park credits with a blocklisted account.
    function test_fork_blocklist_creditHolderRefused() public {
        _setBlocked(bob, true);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, tokens[0]));
        vault.redeem(10e18, alice, bob);
    }

    /// Cash redeem: refused for a blocklisted caller and for a blocklisted cash recipient.
    function test_fork_blocklist_cashRedeemRefused() public {
        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.mintWithUsdc(10e18, 200e6, alice, block.timestamp + 600);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        _setBlocked(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, bob, tokens[0]));
        router.redeemToUsdc(9.9e18, 0, bob, block.timestamp + 600);

        _setBlocked(bob, false);
        _setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, alice, tokens[0]));
        router.redeemToEth(9.9e18, 0, bob, block.timestamp + 600);
    }

    /// Credit earned while clean (NVDA paused at redeem) cannot be claimed once blocklisted;
    /// lifting the block lets the claim through.
    function test_fork_blocklist_claimRefusedUntilLifted() public {
        IB20 nvda = IB20(tokens[0]);
        _grantRole(tokens[0], nvda.PAUSE_ROLE(), address(this));
        _grantRole(tokens[0], nvda.UNPAUSE_ROLE(), address(this));
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        nvda.pause(f);
        vm.prank(SAFE);
        uint256[] memory out = vault.redeem(10e18, alice);
        nvda.unpause(f);
        assertEq(vault.owed(alice, tokens[0]), out[0]);

        _setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, alice, tokens[0]));
        vault.claimOwed(tokens[0], bob);

        _setBlocked(alice, false);
        vm.prank(alice);
        vault.claimOwed(tokens[0], alice);
        assertEq(nvda.balanceOf(alice), out[0]);
    }

    /// Lifting a block restores redeem; also measures what the check costs in gas.
    function test_fork_blocklist_liftedRestoresRedeem() public {
        _setBlocked(alice, true);
        _setBlocked(alice, false);
        assertEq(vault.blockedOn(alice), address(0));
        vm.prank(SAFE);
        uint256 g = gasleft();
        vault.redeem(10e18, alice);
        console2.log("in-kind redeem gas (8 legs, with blocklist check)", g - gasleft());
        assertGt(IERC20(tokens[0]).balanceOf(alice), 0);
    }

    /// Coinbase blocklists the VAULT: nothing can move, but redeem still burns and credits.
    function test_fork_blocklistedVault() public {
        _setBlocked(address(vault), true);
        // Item 3: mint refused up front with the vault blocklisted.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.Blocklisted.selector, address(vault), tokens[0]));
        vault.mint(1e18, alice);
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

        // Item 3: every mint is refused up front while a stock is paused.
        vm.expectRevert(abi.encodeWithSelector(IndexVault.StockPaused.selector, tokens[0]));
        vault.requireMintable();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.StockPaused.selector, tokens[0]));
        vault.mint(1e18, alice);

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

    /// The issuer seizes half the vault's NVDA while a credit is outstanding: `sync` shares the
    /// loss between index holders and the credit holder, and both still get paid in full.
    function test_fork_seizureWithOutstandingCredit() public {
        // The live precompile (base-anvil v1.1.0 fork) rejects SEIZE_ROLE(), SEIZE_EXEMPT_POLICY()
        // and seizeWithMemo (custom error 0xf916d81b), so the seizure is simulated: the vault's
        // NVDA is moved out by a transfer pranked as the vault, which has the same effect on the
        // vault's balance. The credit is created while NVDA is paused and is still outstanding.
        IB20 nvda = IB20(tokens[0]);
        _grantRole(tokens[0], nvda.PAUSE_ROLE(), address(this));
        _grantRole(tokens[0], nvda.UNPAUSE_ROLE(), address(this));
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        nvda.pause(f);

        vm.prank(SAFE);
        uint256 credit = vault.redeem(30e18, alice)[0];
        uint256 h = vault.held(tokens[0]);
        uint256 bal = nvda.balanceOf(address(vault));
        assertEq(bal, h + credit);

        nvda.unpause(f); // the credit stays outstanding until alice claims
        vm.prank(address(vault));
        nvda.transfer(address(0xdead), bal / 2);
        vault.sync(tokens[0]);
        uint256 left = bal - bal / 2;
        assertEq(vault.held(tokens[0]), h * left / bal);
        assertEq(vault.totalOwed(tokens[0]), credit * left / bal);
        assertEq(vault.owed(alice, tokens[0]), credit * left / bal, "credit written down");
        assertLe(vault.held(tokens[0]) + vault.totalOwed(tokens[0]), nvda.balanceOf(address(vault)));

        vm.prank(alice);
        uint256 claimed = vault.claimOwed(tokens[0], alice);
        assertEq(nvda.balanceOf(alice), claimed);
        uint256 rest = vault.balanceOf(SAFE);
        vm.prank(SAFE);
        vault.redeem(rest, SAFE);
        console2.log("credit before / after the 50% seizure", credit, claimed);
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

    /// The rebalance swap carries a Chainlink-derived minimum (value in minus 1%), and the real
    /// Aerodrome router enforces it: with the buy-side feed reading 3% low, so Chainlink expects
    /// 3% more MSTR than the pool can give, the router itself refuses the fill before the vault's
    /// own check is reached. With the real prices the exact minimum is passed and the trade fills.
    function test_fork_rebalanceSwapHasChainlinkMinimum() public {
        _give(tokens[0], address(vault), registry.amountForUsd(tokens[0], 60e18));
        vault.sync(tokens[0]);
        // 90% of MSTR's gap to target, so MSTR does not overshoot.
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](1);
        t[0] = Rebalancer.Trade(tokens[0], tokens[1], registry.amountForUsd(tokens[0], _underUsd(1) * 90 / 100), 0);
        uint256 deadline = block.timestamp + 600;

        uint256 snap = vm.snapshotState();
        _scaleFeed(feedAddrs[1], 97);
        vm.prank(KEEPER);
        vm.expectRevert(bytes("Too little received"));
        rebalancer.rebalance(t, deadline);
        vm.revertToState(snap);
        _freshenFeeds(); // mocked calls survive a state revert; back to the real prices

        uint256 minOut = _expectRebalanceSwap(tokens[0], tokens[1], t[0].amountIn, deadline);
        uint256 navBefore = vault.navUsd();
        uint256 mstrBefore = vault.held(tokens[1]);
        vm.prank(KEEPER);
        rebalancer.rebalance(t, deadline);
        console2.log("swap minimum / MSTR received", minOut, vault.held(tokens[1]) - mstrBefore);
        assertGe(vault.held(tokens[1]) - mstrBefore, minOut);
        console2.log("NAV before / after rebalance with swap minimum", navBefore, vault.navUsd());
        assertGe(vault.navUsd() * 10_000, navBefore * 9_925, "lost at most 0.75% of the traded value");
    }

    /// Dollars (18 dec) stock `j` is below its target; 0 if it is not underweight.
    function _underUsd(uint256 j) internal view returns (uint256) {
        (, int256[] memory d) = rebalancer.drifts();
        return d[j] < 0 ? uint256(-d[j]) * vault.navUsd() / 1e18 : 0;
    }

    /// Item 4 on the real chain: the launch basket passes the authenticity checks (setUp), and
    /// fakes are refused when the Safe queues them.
    function test_fork_basketRejectsFakes() public {
        assertEq(registry.trustedFeedOwner(), CHAINLINK_FEED_OWNER, "Chainlink's Base multisig");
        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](N);
        for (uint256 i; i < N; ++i) {
            cfg[i] = BasketRegistry.AssetConfig(tokens[i], feedAddrs[i], 1_250, STOCK_TS);
        }

        // 1. A plain ERC-20 posing as MSFT (not created by Base's B20 factory).
        FakeStock fake = new FakeStock();
        cfg[7].token = address(fake);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NotB20.selector, address(fake)));
        registry.queueBasket(cfg);

        // 2. Real NVDA paired with MSTR's real feed.
        cfg[7] = BasketRegistry.AssetConfig(tokens[7], feedAddrs[7], 1_250, STOCK_TS);
        cfg[0].feed = feedAddrs[1];
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.FeedDoesNotMatchToken.selector, tokens[0], feedAddrs[1]));
        registry.queueBasket(cfg);

        // 3. A look-alike feed: right description, claims Chainlink's owner, different code.
        LookAlikeChainlinkFeed look = new LookAlikeChainlinkFeed(CHAINLINK_FEED_OWNER);
        cfg[0].feed = address(look);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UntrustedFeed.selector, address(look)));
        registry.queueBasket(cfg);

        // The genuine basket queues fine.
        cfg[0].feed = feedAddrs[0];
        vm.prank(SAFE);
        registry.queueBasket(cfg);
    }

    /// A REAL B20, created through Base's B20 factory, that copies everything about MSFT that
    /// anyone can copy: name, symbol "MSFTc", 8 decimals, Coinbase's blocklist policy 5, and even
    /// Coinbase's admin, operator and TokenSupplyManager as role holders (any creator can grant
    /// roles to any address). The B20 factory, the role checks and Coinbase's OracleRegistry all
    /// accept it. Only Coinbase's TokenSupplyManager register tells it apart, and the basket
    /// refuses it with NotCoinbaseIssued.
    function test_fork_basketRejectsCopycatB20() public {
        bytes32 mintRole = keccak256("MINT_ROLE");
        bytes32 operatorRole = keccak256("OPERATOR_ROLE");
        bytes[] memory init = new bytes[](6);
        init[0] = B20FactoryLib.encodeGrantRole(bytes32(0), COINBASE_TOKEN_ADMIN);
        init[1] = B20FactoryLib.encodeGrantRole(operatorRole, COINBASE_TOKEN_OPERATOR);
        init[2] = B20FactoryLib.encodeGrantRole(mintRole, COINBASE_TOKEN_REGISTRY);
        init[3] = B20FactoryLib.encodeUpdatePolicy(keccak256("TRANSFER_SENDER_POLICY"), COINBASE_BLOCKLIST);
        init[4] = B20FactoryLib.encodeUpdatePolicy(keccak256("TRANSFER_RECEIVER_POLICY"), COINBASE_BLOCKLIST);
        init[5] = B20FactoryLib.encodeUpdatePolicy(keccak256("TRANSFER_EXECUTOR_POLICY"), COINBASE_BLOCKLIST);
        address attacker = makeAddr("chip-index-test-copycat");
        vm.prank(attacker);
        address copycat = IB20Factory(B20_FACTORY).createB20(
            IB20Factory.B20Variant.ASSET,
            keccak256("copycat MSFT"),
            B20FactoryLib.encodeAssetCreateParams("Microsoft Corporation", "MSFTc", attacker, 8),
            init
        );

        // Everything a contract can read looks like the real MSFT ...
        assertTrue(IB20FactoryView(B20_FACTORY).isB20Initialized(copycat), "a genuine B20");
        assertEq(IB20(copycat).symbol(), IB20(tokens[7]).symbol());
        assertEq(IB20(copycat).decimals(), IB20(tokens[7]).decimals());
        assertTrue(IB20(copycat).hasRole(bytes32(0), COINBASE_TOKEN_ADMIN) && IB20(tokens[7]).hasRole(bytes32(0), COINBASE_TOKEN_ADMIN));
        assertTrue(IB20(copycat).hasRole(operatorRole, COINBASE_TOKEN_OPERATOR));
        assertTrue(IB20(copycat).hasRole(mintRole, COINBASE_TOKEN_REGISTRY) && IB20(tokens[7]).hasRole(mintRole, COINBASE_TOKEN_REGISTRY));
        assertEq(IB20(copycat).policyId(keccak256("TRANSFER_EXECUTOR_POLICY")), COINBASE_BLOCKLIST);
        // ... and Coinbase's OracleRegistry answers for it like any other token (it keeps no list).
        (bool okOracle,) = COINBASE_ORACLE_REGISTRY.staticcall(abi.encodeWithSignature("getOracleParams(address)", copycat));
        assertTrue(okOracle, "OracleRegistry cannot tell a copycat apart");

        // Only the TokenSupplyManager register can.
        assertFalse(IIssuerRegistry(COINBASE_TOKEN_REGISTRY).isRegisteredToken(copycat));
        for (uint256 i; i < N; ++i) {
            assertTrue(IIssuerRegistry(COINBASE_TOKEN_REGISTRY).isRegisteredToken(tokens[i]), "launch stock registered");
        }

        BasketRegistry.AssetConfig[] memory cfg = new BasketRegistry.AssetConfig[](N);
        for (uint256 i; i < N; ++i) {
            cfg[i] = BasketRegistry.AssetConfig(tokens[i], feedAddrs[i], 1_250, STOCK_TS);
        }
        cfg[7].token = copycat; // with MSFT's real feed ("Coinbase MSFT")
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.NotCoinbaseIssued.selector, copycat));
        registry.queueBasket(cfg);
    }

    /// Make `feed` read `pct`% of its current answer (still fresh).
    function _scaleFeed(address feed, int256 pct) internal {
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(r, a * pct / 100, s, u, air)
        );
    }

    /// Expect the Rebalancer to call Aerodrome with exactly the Chainlink-derived minimum.
    function _expectRebalanceSwap(address sell, address buy, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 minOut)
    {
        minOut = registry.amountForUsd(
            buy, registry.valueUsd(sell, amountIn) * (10_000 - vault.maxTradeSlippageBps()) / 10_000
        );
        ISlipstreamRouter.ExactInputParams memory p = ISlipstreamRouter.ExactInputParams({
            path: abi.encodePacked(sell, registry.usdcTickSpacing(sell), USDC, registry.usdcTickSpacing(buy), buy),
            recipient: address(vault),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minOut
        });
        vm.expectCall(SLIP_ROUTER, abi.encodeCall(ISlipstreamRouter.exactInput, (p)));
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
        // Sell NVDA into each of the 7 underweight stocks, 95% of each one's gap (no overshoot).
        Rebalancer.Trade[] memory t = new Rebalancer.Trade[](N - 1);
        for (uint256 j = 1; j < N; ++j) {
            t[j - 1] = Rebalancer.Trade(tokens[0], tokens[j], registry.amountForUsd(tokens[0], _underUsd(j) * 95 / 100), 0);
        }
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

    /* -------------------------- small cash mints ------------------------- */

    /// Base gas price used to turn gas into dollars (read live 2026-10-12: 0.006 gwei).
    /// Override with GAS_PRICE_WEI. The L1 data fee (~4.6 gwei-units, < $0.0001) is ignored.
    function _gasUsd6(uint256 gasUsed) internal view returns (uint256) {
        uint256 gp = vm.envOr("GAS_PRICE_WEI", uint256(6_000_000));
        (, int256 ethUsd,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        return gasUsed * gp * uint256(ethUsd) / 1e8 / 1e12; // 6-dec dollars
    }

    function _smallUsdcMint(uint256 shares) internal {
        deal(USDC, alice, 100e6);
        uint256 feeBefore = vault.balanceOf(address(splitter));
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 g = gasleft();
        uint256 spent = router.mintWithUsdc(shares, 100e6, alice, block.timestamp + 600);
        uint256 used = g - gasleft();
        vm.stopPrank();
        uint256 fee = vault.balanceOf(address(splitter)) - feeBefore;
        console2.log("USDC paid (6 dec)          ", spent);
        console2.log("index tokens received      ", vault.balanceOf(alice));
        console2.log("mint fee (index tokens)    ", fee);
        console2.log("mint fee (USD, 6 dec)      ", fee * vault.navPerShare() / 1e18 / 1e12);
        console2.log("gas used                   ", used);
        console2.log("gas cost (USD, 6 dec)      ", _gasUsd6(used));
        assertEq(vault.balanceOf(alice), shares * 99 / 100);
        assertEq(fee, shares / 100);
    }

    function _smallEthMint(uint256 shares) internal {
        vm.deal(alice, 1 ether);
        uint256 feeBefore = vault.balanceOf(address(splitter));
        (, int256 ethUsd,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 spent = router.mintWithEth{value: 0.05 ether}(shares, alice, block.timestamp + 600);
        uint256 used = g - gasleft();
        uint256 fee = vault.balanceOf(address(splitter)) - feeBefore;
        console2.log("ETH paid (wei)             ", spent);
        console2.log("ETH paid (USD, 6 dec)      ", spent * uint256(ethUsd) / 1e8 / 1e12);
        console2.log("index tokens received      ", vault.balanceOf(alice));
        console2.log("mint fee (index tokens)    ", fee);
        console2.log("mint fee (USD, 6 dec)      ", fee * vault.navPerShare() / 1e18 / 1e12);
        console2.log("gas used                   ", used);
        console2.log("gas cost (USD, 6 dec)      ", _gasUsd6(used));
        assertEq(vault.balanceOf(alice), shares * 99 / 100);
        assertEq(alice.balance, 1 ether - spent, "unspent ETH refunded");
    }

    function test_fork_smallMint_usdc20() public {
        _smallUsdcMint(2e18); // 2 tokens at $10
    }

    function test_fork_smallMint_usdc5() public {
        _smallUsdcMint(0.5e18);
    }

    function test_fork_smallMint_eth20() public {
        _smallEthMint(2e18);
    }

    function test_fork_smallMint_eth5() public {
        _smallEthMint(0.5e18);
    }
}

/// @notice A plain ERC-20 with a Coinbase-style name, for the authenticity test.
contract FakeStock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function symbol() external pure returns (string memory) {
        return "MSFTc";
    }
}

/// @notice Answers like a Chainlink proxy and names Chainlink's owner, but is not their code.
contract LookAlikeChainlinkFeed {
    address public immutable owner;

    constructor(address o) {
        owner = o;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Coinbase NVDA";
    }
}