// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BasketRegistry} from "../src/BasketRegistry.sol";
import {IndexFeeSplitter} from "../src/IndexFeeSplitter.sol";
import {IndexRouter} from "../src/IndexRouter.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";

/* ========================================================================== */
/*                LAUNCH CONFIG: EDIT HERE BEFORE DEPLOYING                   */
/* ========================================================================== */
/// @notice Every owner-chosen launch value lives in this one block. The deploy and the seed
///         scripts both read it, and `Deploy.verify` checks the deployed contracts against it.
library LaunchConfig {
    // Confirmed by the owner 2026-10-13.
    string internal constant NAME = "Chip Index";
    string internal constant SYMBOL = "CHIPX";

    /// Total cap on index tokens in existence, for ALL holders together (no per-wallet limit).
    /// 5,000 tokens = $50,000 at the $10 launch price (owner decision 2026-10-13, was 2,500).
    /// The Safe can lower it instantly, or raise it through the 48h timelock
    /// (vault.queueSetting(SET_MINT_CAP, ...)).
    uint256 internal constant MINT_CAP_TOKENS = 5_000;

    /// Most USDC one $CHIP buy may spend. Fork-measured 2026-10-12: a $100 buy fills 0.68% worse
    /// than spot (pool fee ~0.38% + impact ~0.30%), inside the 1% limit; $250 was 1.13%.
    uint256 internal constant MAX_CHIP_BUY_USDC = 100;
    /// Most USDC all $CHIP buys together may spend in 24h (hard limit $2,000 in the contract).
    uint256 internal constant DAILY_CHIP_BUY_USDC = 300;
    /// First mint by the Safe: $125 of each of the 8 stocks ($1,000) for 100 index tokens ($10).
    uint256 internal constant SEED_USD_PER_STOCK = 125;
    uint256 internal constant SEED_TOKENS = 100;

    // Fees (bps). Hard caps live in IndexVault: mint 100 (every tier) / redeem 200 / mgmt 500.
    // Mint fee is size-tiered by the NAV value of one mint (owner decision 2026-10-13):
    // under $10,000 pays 1%, $10,000 to $49,999 pays 0.75%, $50,000 and up pays 0.5%.
    uint256 internal constant MINT_TIER1_MIN_USD = 10_000;
    uint256 internal constant MINT_TIER2_MIN_USD = 50_000;
    uint16 internal constant MINT_FEE_BASE_BPS = 100;
    uint16 internal constant MINT_FEE_TIER1_BPS = 75;
    uint16 internal constant MINT_FEE_TIER2_BPS = 50;
    uint16 internal constant REDEEM_FEE_BPS = 100;
    uint16 internal constant MGMT_FEE_BPS = 300;
}

/// @notice Every Base mainnet address the deploy uses, in one place.
///         Basket + feeds verified 2026-10-12 (Coinbase API, all pages, and onchain descriptions).
library Addrs {
    address internal constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address internal constant KEEPER = 0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address internal constant CHIP_BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;
    address internal constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    address internal constant SLIP_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant SLIP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant CHIP_HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    address internal constant B20_FACTORY = 0xB20f000000000000000000000000000000000000;
    /// Owner of all 8 Coinbase stock feeds and the ETH/USD feed (Chainlink's Base multisig),
    /// read onchain 2026-10-13. The registry takes it from the first launch feed; verify checks it.
    address internal constant CHAINLINK_FEED_OWNER = 0xf0Db7318A51a21C413CaDd4AbDC1E8a500fE5B1b;
    /// Coinbase's TokenSupplyManager (ERC1967 proxy): mints/redeems the Coinbase stocks and keeps the
    /// admin-only register `isRegisteredToken`. All 135 tokens on the Coinbase API are registered
    /// (checked onchain 2026-10-13); it is set in the same tx that creates each token.
    address internal constant COINBASE_TOKEN_REGISTRY = 0xD1Ca4dAcdf3231011D175351f1f02D15C7c5664C;
    uint24 internal constant CHIP_POOL_FEE = 0x800000; // dynamic-fee flag
    int24 internal constant CHIP_POOL_TS = 200;
    int24 internal constant STOCK_USDC_TS = 10; // every B20/USDC pool with real depth
    int24 internal constant WETH_USDC_TS = 50; // deepest Aerodrome WETH/USDC pool

    function basket() internal pure returns (BasketRegistry.AssetConfig[] memory c) {
        c = new BasketRegistry.AssetConfig[](8);
        c[0] = BasketRegistry.AssetConfig(0xb20000000000000000000078ee7ce2fE4908108C, 0x04689a41629776563E6822F76f2e57D148d28513, 1_250, STOCK_USDC_TS); // NVDA
        c[1] = BasketRegistry.AssetConfig(0xb2000000000000000000004884b426556b92883d, 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a, 1_250, STOCK_USDC_TS); // MSTR
        c[2] = BasketRegistry.AssetConfig(0xb2000000000000000000002D0BA3164cc74f58B7, 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2, 1_250, STOCK_USDC_TS); // GOOGL
        c[3] = BasketRegistry.AssetConfig(0xb200000000000000000000d9192b6B456483C2E8, 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295, 1_250, STOCK_USDC_TS); // AMZN
        c[4] = BasketRegistry.AssetConfig(0xb200000000000000000000C2e324d24d7eEcd1fb, 0x787f13dEa48Db0897CbCDD985de77809D837F988, 1_250, STOCK_USDC_TS); // AAPL
        c[5] = BasketRegistry.AssetConfig(0xb2000000000000000000008bC8786B856E61707C, 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D, 1_250, STOCK_USDC_TS); // META
        c[6] = BasketRegistry.AssetConfig(0xb2000000000000000000001e800a7f5189430cD0, 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4, 1_250, STOCK_USDC_TS); // TSLA
        c[7] = BasketRegistry.AssetConfig(0xB200000000000000000000Ab99cFa739E253872B, 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c, 1_250, STOCK_USDC_TS); // MSFT
    }
}

/**
 * @notice Deploys the five Chip Index contracts, owned by the Safe from the constructor, wires
 *         them, and checks the result. The deploy wallet ends up owning NOTHING.
 *
 *         It does NOT seed the index: the first mint comes from the Safe (script/SafeSeed.s.sol).
 *         All owner-chosen values come from `LaunchConfig` at the top of this file.
 *
 *         MUST be simulated with Base's forge (the registry reads B20 decimals):
 *             base-forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL           (dry run)
 *         Broadcasting to mainnet happens ONLY with the owner's explicit go-ahead.
 */
contract Deploy is Script {
    struct Deployed {
        BasketRegistry registry;
        IndexVault vault;
        Rebalancer rebalancer;
        IndexRouter router;
        IndexFeeSplitter splitter;
    }

    struct Params {
        string name;
        string symbol;
        uint256 mintCap; // 18-dec index tokens
        uint256 maxChipBuyUsdc; // 6-dec USDC
        uint256 dailyChipBuyUsdc; // 6-dec USDC
    }

    uint16 internal constant REDEEM_FEE_BPS = LaunchConfig.REDEEM_FEE_BPS;
    uint16 internal constant MGMT_FEE_BPS = LaunchConfig.MGMT_FEE_BPS;

    function launchMintFees() public pure returns (IndexVault.MintFeeSchedule memory) {
        return IndexVault.MintFeeSchedule({
            tier1MinUsd: uint128(LaunchConfig.MINT_TIER1_MIN_USD * 1e18),
            tier2MinUsd: uint128(LaunchConfig.MINT_TIER2_MIN_USD * 1e18),
            baseBps: LaunchConfig.MINT_FEE_BASE_BPS,
            tier1Bps: LaunchConfig.MINT_FEE_TIER1_BPS,
            tier2Bps: LaunchConfig.MINT_FEE_TIER2_BPS
        });
    }

    function launchParams() public pure returns (Params memory) {
        return Params({
            name: LaunchConfig.NAME,
            symbol: LaunchConfig.SYMBOL,
            mintCap: LaunchConfig.MINT_CAP_TOKENS * 1e18,
            maxChipBuyUsdc: LaunchConfig.MAX_CHIP_BUY_USDC * 1e6,
            dailyChipBuyUsdc: LaunchConfig.DAILY_CHIP_BUY_USDC * 1e6
        });
    }

    function run() external returns (Deployed memory d) {
        Params memory p = launchParams();
        require(Addrs.SAFE.code.length > 0, "Safe has no code");

        vm.startBroadcast();
        d = deploy(p);
        vm.stopBroadcast();

        verify(d, p);
        _log(d);
    }

    function deploy(Params memory p) public returns (Deployed memory d) {
        d.registry = new BasketRegistry(
            Addrs.SAFE, Addrs.SEQUENCER_FEED, Addrs.SLIP_FACTORY, Addrs.USDC, Addrs.B20_FACTORY, Addrs.COINBASE_TOKEN_REGISTRY,
            Addrs.basket()
        );
        d.vault = new IndexVault(
            Addrs.SAFE,
            d.registry,
            Addrs.POLICY_REGISTRY,
            p.name,
            p.symbol,
            launchMintFees(),
            REDEEM_FEE_BPS,
            MGMT_FEE_BPS,
            p.mintCap
        );
        d.rebalancer = new Rebalancer(Addrs.SAFE, d.vault, ISlipstreamRouter(Addrs.SLIP_ROUTER), Addrs.USDC, Addrs.KEEPER);
        d.router = new IndexRouter(
            Addrs.SAFE,
            d.vault,
            ISlipstreamRouter(Addrs.SLIP_ROUTER),
            Addrs.USDC,
            Addrs.WETH,
            Addrs.ETH_USD_FEED,
            Addrs.WETH_USDC_TS,
            Addrs.KEEPER
        );
        d.splitter = new IndexFeeSplitter(
            IndexFeeSplitter.Config({
                owner: Addrs.SAFE,
                vault: d.vault,
                swapRouter: ISlipstreamRouter(Addrs.SLIP_ROUTER),
                usdc: Addrs.USDC,
                weth: Addrs.WETH,
                chip: Addrs.CHIP,
                burner: Addrs.CHIP_BURNER,
                pot: Addrs.POT,
                poolManager: Addrs.POOL_MANAGER,
                ethUsdFeed: Addrs.ETH_USD_FEED,
                chipPoolKey: PoolKey(Addrs.WETH, Addrs.CHIP, Addrs.CHIP_POOL_FEE, Addrs.CHIP_POOL_TS, Addrs.CHIP_HOOK),
                wethUsdcTickSpacing: Addrs.WETH_USDC_TS,
                keeper: Addrs.KEEPER,
                maxChipBuyUsdc: p.maxChipBuyUsdc,
                dailyChipBuyUsdc: p.dailyChipBuyUsdc
            })
        );
        d.registry.wireVault(address(d.vault));
        d.vault.wire(address(d.splitter), address(d.rebalancer));
    }

    /// @notice Everything the deploy promises, checked onchain. Also used by the fork rehearsal.
    function verify(Deployed memory d, Params memory p) public view {
        require(d.registry.owner() == Addrs.SAFE, "registry owner");
        require(d.vault.owner() == Addrs.SAFE, "vault owner");
        require(d.rebalancer.owner() == Addrs.SAFE, "rebalancer owner");
        require(d.router.owner() == Addrs.SAFE, "router owner");
        require(d.splitter.owner() == Addrs.SAFE, "splitter owner");
        require(d.registry.pendingOwner() == address(0) && d.vault.pendingOwner() == address(0), "pending owner");

        require(d.registry.vault() == address(d.vault), "registry -> vault");
        require(address(d.vault.registry()) == address(d.registry), "vault -> registry");
        require(address(d.vault.policyRegistry()) == Addrs.POLICY_REGISTRY, "vault -> policy registry");
        require(keccak256(bytes(d.vault.name())) == keccak256(bytes(p.name)), "name");
        require(d.vault.feeRecipient() == address(d.splitter), "fee recipient");
        require(d.vault.rebalancer() == address(d.rebalancer), "rebalancer");
        require(address(d.router.vault()) == address(d.vault), "router -> vault");
        require(address(d.rebalancer.vault()) == address(d.vault), "rebalancer -> vault");
        require(address(d.splitter.vault()) == address(d.vault), "splitter -> vault");

        require(d.rebalancer.keeper() == Addrs.KEEPER, "rebalancer keeper");
        require(d.router.keeper() == Addrs.KEEPER, "router keeper");
        require(d.splitter.keeper() == Addrs.KEEPER, "splitter keeper");

        require(
            keccak256(abi.encode(d.vault.mintFeeSchedule())) == keccak256(abi.encode(launchMintFees())), "mint fee"
        );
        require(d.vault.redeemFeeBps() == REDEEM_FEE_BPS, "redeem fee");
        require(d.vault.mgmtFeeBps() == MGMT_FEE_BPS, "mgmt fee");
        require(d.vault.mintCap() == p.mintCap, "mint cap");
        require(d.vault.totalSupply() == 0, "unexpected supply");
        require(keccak256(bytes(d.vault.symbol())) == keccak256(bytes(p.symbol)), "symbol");
        require(d.splitter.pot() == Addrs.POT, "pot");
        require(address(d.splitter.burner()) == Addrs.CHIP_BURNER, "burner");
        require(d.splitter.maxChipBuyUsdc() == p.maxChipBuyUsdc, "chip buy cap");
        require(d.splitter.dailyChipBuyUsdc() == p.dailyChipBuyUsdc, "daily chip buy cap");
        require(d.vault.maxTradeSlippageBps() == 75, "trade slippage 0.75%");
        require(d.vault.dailyTradeCapBps() == 1_500 && d.vault.dailyLossCapBps() == 10, "daily trade caps");
        require(d.registry.trustedFeedOwner() == Addrs.CHAINLINK_FEED_OWNER, "trusted feed owner");
        require(address(d.registry.b20Factory()) == Addrs.B20_FACTORY, "b20 factory");
        require(d.registry.issuerRegistry() == Addrs.COINBASE_TOKEN_REGISTRY, "coinbase token registry");

        BasketRegistry.AssetConfig[] memory cfg = Addrs.basket();
        require(d.registry.assetCount() == cfg.length, "basket size");
        for (uint256 i; i < cfg.length; ++i) {
            BasketRegistry.Asset memory a = d.registry.assetAt(i);
            require(a.token == cfg[i].token && a.feed == cfg[i].feed && a.weightBps == 1_250, "basket entry");
            require(a.tokenDecimals == 8 && a.feedDecimals == 8, "decimals");
            require(d.registry.usdcTickSpacing(a.token) == Addrs.STOCK_USDC_TS, "pool");
        }
    }

    function _log(Deployed memory d) internal pure {
        console2.log("BasketRegistry  ", address(d.registry));
        console2.log("IndexVault      ", address(d.vault));
        console2.log("Rebalancer      ", address(d.rebalancer));
        console2.log("IndexRouter     ", address(d.router));
        console2.log("IndexFeeSplitter", address(d.splitter));
    }
}
