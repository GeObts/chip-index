// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BasketRegistry, IB20FactoryView, IIssuerRegistry, IOwnedFeed} from "../src/BasketRegistry.sol";
import {IndexFeeSplitter} from "../src/IndexFeeSplitter.sol";
import {IndexRouter} from "../src/IndexRouter.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {Timelock} from "../src/lib/Timelock.sol";
import {Addrs, Deploy, LaunchConfig} from "./Deploy.s.sol";

interface ISafeView {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/**
 * @notice READ-ONLY post-deploy check of the live Chip Index contracts. It sends no transaction
 *         and needs no key. Every check prints one line, PASS or FAIL, and the script exits with
 *         an error if anything failed.
 *
 *         It checks, against `LaunchConfig` / `Addrs` in script/Deploy.s.sol:
 *         - every owner is the Safe and no ownership transfer is pending (ownership accepted);
 *         - the contracts point at each other, keepers, fees, caps, limits, timelock lengths;
 *         - no queued (timelocked) change is waiting on any of the five contracts;
 *         - every stock in the basket is on Coinbase's live list (api.coinbase.com/v1/
 *           tokenized-stocks, all pages) with the same symbol, is a B20, is registered in Coinbase's
 *           TokenSupplyManager, and its feed is a Chainlink feed named "Coinbase <TICKER>".
 *         A FAIL on a setting the Safe changed ON PURPOSE after launch is expected: update
 *         LaunchConfig to the new value and re-run.
 *
 *         Run (WSL, from the repo root; Base's forge is needed because it reads the B20 stocks):
 *           CHIPX_REGISTRY=0x.. CHIPX_VAULT=0x.. CHIPX_REBALANCER=0x.. CHIPX_ROUTER=0x.. \
 *           CHIPX_SPLITTER=0x.. \
 *           ~/.foundry/bin/base-forge script script/VerifyDeployment.s.sol --rpc-url $BASE_RPC_URL --ffi
 *         `--ffi` lets it run `curl` to read Coinbase's list. Queued changes are read onchain from
 *         each contract's `pendingChanges()`, so no event history (eth_getLogs) is needed.
 */
contract VerifyDeployment is Script {
    string internal constant COINBASE_API = "https://api.coinbase.com/v1/tokenized-stocks";

    uint256 public passes;
    uint256 public fails;

    function run() external {
        Deploy.Deployed memory d = Deploy.Deployed({
            registry: BasketRegistry(vm.envAddress("CHIPX_REGISTRY")),
            vault: IndexVault(vm.envAddress("CHIPX_VAULT")),
            rebalancer: Rebalancer(vm.envAddress("CHIPX_REBALANCER")),
            router: IndexRouter(payable(vm.envAddress("CHIPX_ROUTER"))),
            splitter: IndexFeeSplitter(payable(vm.envAddress("CHIPX_SPLITTER")))
        });
        (address[] memory cbTokens, string[] memory cbSymbols) = fetchCoinbaseList();
        console2.log("Coinbase list: tokens read (all pages)", cbTokens.length);
        check(d, cbTokens, cbSymbols);
        console2.log("");
        console2.log("PASS lines", passes);
        console2.log("FAIL lines", fails);
        require(fails == 0, "VERIFY FAILED: see the FAIL lines above");
    }

    /* ------------------------------------------------------------------ */
    /*                     Inputs from outside the chain                   */
    /* ------------------------------------------------------------------ */

    /// @notice Every token on Coinbase's list, following `next_page_token` to the last page.
    function fetchCoinbaseList() public returns (address[] memory tokens, string[] memory symbols) {
        string memory url = COINBASE_API;
        address[] memory accT = new address[](0);
        string[] memory accS = new string[](0);
        for (uint256 page; page < 50; ++page) {
            string[] memory cmd = new string[](3);
            cmd[0] = "curl";
            cmd[1] = "-sf";
            cmd[2] = url;
            string memory json = string(vm.ffi(cmd));
            uint256 n;
            while (vm.keyExistsJson(json, string.concat(".tokens[", vm.toString(n), "]"))) ++n;
            address[] memory t = new address[](n);
            string[] memory s = new string[](n);
            for (uint256 i; i < n; ++i) {
                string memory at = string.concat(".tokens[", vm.toString(i), "]");
                t[i] = vm.parseJsonAddress(json, string.concat(at, ".contract_address"));
                s[i] = vm.parseJsonString(json, string.concat(at, ".symbol"));
            }
            (accT, accS) = _append(accT, accS, t, s);
            string memory next =
                vm.keyExistsJson(json, ".next_page_token") ? vm.parseJsonString(json, ".next_page_token") : "";
            if (bytes(next).length == 0) break;
            url = string.concat(COINBASE_API, "?page_token=", next);
        }
        return (accT, accS);
    }

    /* ------------------------------------------------------------------ */
    /*                              The checks                             */
    /* ------------------------------------------------------------------ */

    /// @notice Runs every check against the given Coinbase list.
    function check(Deploy.Deployed memory d, address[] memory cbTokens, string[] memory cbSymbols)
        public
        returns (uint256, uint256)
    {
        console2.log("== Owners (Safe, ownership accepted)");
        _owners(d);
        console2.log("== Wiring");
        _wiring(d);
        console2.log("== Keepers");
        _ok(d.rebalancer.keeper() == Addrs.KEEPER, "rebalancer keeper is the launch keeper");
        _ok(d.router.keeper() == Addrs.KEEPER, "router keeper is the launch keeper");
        _ok(d.splitter.keeper() == Addrs.KEEPER, "fee splitter keeper is the launch keeper");
        console2.log("== Fees, caps and limits");
        _fees(d);
        _caps(d);
        console2.log("== Timelock");
        _timelock(d);
        _pending(d);
        console2.log("== Basket (Coinbase list, B20 factory, Coinbase register, Chainlink feeds)");
        _basket(d, cbTokens, cbSymbols);
        return (passes, fails);
    }

    function _owners(Deploy.Deployed memory d) internal {
        address[5] memory c = [
            address(d.registry), address(d.vault), address(d.rebalancer), address(d.router), address(d.splitter)
        ];
        string[5] memory n = ["BasketRegistry", "IndexVault", "Rebalancer", "IndexRouter", "IndexFeeSplitter"];
        for (uint256 i; i < 5; ++i) {
            _ok(IOwnable2(c[i]).owner() == Addrs.SAFE, string.concat(n[i], " owner is the Safe"));
            _ok(IOwnable2(c[i]).pendingOwner() == address(0), string.concat(n[i], " has no pending owner"));
        }
        _ok(Addrs.SAFE.code.length > 0, "the Safe is a deployed contract");
        try ISafeView(Addrs.SAFE).getThreshold() returns (uint256 t) {
            console2.log("INFO Safe threshold / owners", t, ISafeView(Addrs.SAFE).getOwners().length);
        } catch {}
    }

    function _wiring(Deploy.Deployed memory d) internal {
        _ok(d.registry.vault() == address(d.vault), "registry -> vault");
        _ok(address(d.vault.registry()) == address(d.registry), "vault -> registry");
        _ok(address(d.vault.policyRegistry()) == Addrs.POLICY_REGISTRY, "vault -> Base PolicyRegistry");
        _ok(d.vault.rebalancer() == address(d.rebalancer), "vault -> rebalancer");
        _ok(d.vault.feeRecipient() == address(d.splitter), "vault fees -> fee splitter");
        _ok(address(d.rebalancer.vault()) == address(d.vault), "rebalancer -> vault");
        _ok(address(d.router.vault()) == address(d.vault), "router -> vault");
        _ok(address(d.splitter.vault()) == address(d.vault), "fee splitter -> vault");
        _ok(d.splitter.pot() == Addrs.POT, "fee splitter -> Pot");
        _ok(address(d.splitter.burner()) == Addrs.CHIP_BURNER, "fee splitter -> ChipBurner");
        _ok(address(d.splitter.chip()) == Addrs.CHIP, "fee splitter buys $CHIP");
        _ok(address(d.registry.b20Factory()) == Addrs.B20_FACTORY, "registry -> Base B20 factory");
        _ok(d.registry.issuerRegistry() == Addrs.COINBASE_TOKEN_REGISTRY, "registry -> Coinbase TokenSupplyManager");
        _ok(d.registry.trustedFeedOwner() == Addrs.CHAINLINK_FEED_OWNER, "registry trusts Chainlink's Base multisig");
        _ok(d.registry.sequencerFeed() == Addrs.SEQUENCER_FEED, "registry -> sequencer uptime feed");
        _ok(keccak256(bytes(d.vault.name())) == keccak256(bytes(LaunchConfig.NAME)), "name is Chip Index");
        _ok(keccak256(bytes(d.vault.symbol())) == keccak256(bytes(LaunchConfig.SYMBOL)), "ticker is CHIPX");
    }

    function _fees(Deploy.Deployed memory d) internal {
        IndexVault.MintFeeSchedule memory m = d.vault.mintFeeSchedule();
        _ok(
            m.baseBps == LaunchConfig.MINT_FEE_BASE_BPS && m.tier1Bps == LaunchConfig.MINT_FEE_TIER1_BPS
                && m.tier2Bps == LaunchConfig.MINT_FEE_TIER2_BPS,
            "mint fee 1% / 0.75% / 0.5%"
        );
        _ok(
            m.tier1MinUsd == LaunchConfig.MINT_TIER1_MIN_USD * 1e18
                && m.tier2MinUsd == LaunchConfig.MINT_TIER2_MIN_USD * 1e18,
            "mint fee tiers from $10,000 and $50,000"
        );
        _ok(d.vault.redeemFeeBps() == LaunchConfig.REDEEM_FEE_BPS, "redeem fee 1%");
        _ok(d.vault.mgmtFeeBps() == LaunchConfig.MGMT_FEE_BPS, "management fee 3% a year");
    }

    function _caps(Deploy.Deployed memory d) internal {
        _ok(d.vault.mintCap() == LaunchConfig.MINT_CAP_TOKENS * 1e18, "mint cap 5,000 CHIPX ($50k at $10)");
        _ok(d.vault.maxTradeSlippageBps() == 75, "rebalance trade slippage 0.75%");
        _ok(d.vault.dailyTradeCapBps() == 1_500, "rebalance volume cap 15% of NAV per 24h");
        _ok(d.vault.dailyLossCapBps() == 10, "rebalance loss cap 0.10% of NAV per 24h");
        _ok(!d.vault.mintPaused(), "vault mint not paused");
        _ok(d.splitter.maxChipBuyUsdc() == LaunchConfig.MAX_CHIP_BUY_USDC * 1e6, "$CHIP buy at most $100 per call");
        _ok(d.splitter.dailyChipBuyUsdc() == LaunchConfig.DAILY_CHIP_BUY_USDC * 1e6, "$CHIP buys at most $300 per 24h");
        _ok(d.splitter.sellSlippageBps() == 100, "fee splitter sell slippage 1%");
        _ok(d.splitter.ethFeedMaxAge() == 1 hours, "fee splitter ETH feed max age 1h");
        _ok(d.splitter.wethUsdcTickSpacing() == Addrs.WETH_USDC_TS, "fee splitter WETH/USDC pool");
        _ok(d.router.legSlippageBps() == 100, "router per-leg slippage 1%");
        _ok(d.router.ethFeedMaxAge() == 1 hours, "router ETH feed max age 1h");
        _ok(d.router.staleBandBps() == 1_000, "router stale-feed band 10% (24/7 cash mint/redeem)");
        _ok(d.router.wethUsdcTickSpacing() == Addrs.WETH_USDC_TS, "router WETH/USDC pool");
        _ok(d.router.ethUsdFeed() == Addrs.ETH_USD_FEED, "router ETH/USD feed");
        _ok(!d.router.cashMintPaused() && !d.router.cashRedeemPaused(), "router USDC/ETH paths not paused");
        _ok(d.registry.maxFeedAge() == 26 hours, "stock feed max age 26h");
    }

    function _timelock(Deploy.Deployed memory d) internal {
        address[5] memory c = [
            address(d.registry), address(d.vault), address(d.rebalancer), address(d.router), address(d.splitter)
        ];
        bool ok = true;
        for (uint256 i; i < 5; ++i) {
            ok = ok && Timelock(c[i]).TIMELOCK_DELAY() == 48 hours && Timelock(c[i]).TIMELOCK_GRACE() == 14 days;
        }
        _ok(ok, "all five: 48h timelock, 14-day grace");
    }

    /// Every change waiting in any of the five timelocks (`pendingChanges`) is a FAIL line;
    /// an expired one (can no longer execute) is only reported.
    function _pending(Deploy.Deployed memory d) internal {
        address[5] memory c = [
            address(d.registry), address(d.vault), address(d.rebalancer), address(d.router), address(d.splitter)
        ];
        uint256 waiting;
        for (uint256 k; k < 5; ++k) {
            (bytes32[] memory ids, uint256[] memory at) = Timelock(c[k]).pendingChanges();
            for (uint256 i; i < ids.length; ++i) {
                if (block.timestamp > at[i] + 14 days) {
                    console2.log(string.concat("INFO expired queued change on ", vm.toString(c[k]), ": ", vm.toString(ids[i])));
                    continue;
                }
                ++waiting;
                _ok(
                    false,
                    string.concat(
                        "pending queued change on ", vm.toString(c[k]), " id ", vm.toString(ids[i]),
                        " executable at unix time ", vm.toString(at[i])
                    )
                );
            }
        }
        if (waiting == 0) _ok(true, "no queued change waiting on any of the five contracts");
    }

    function _basket(Deploy.Deployed memory d, address[] memory cbTokens, string[] memory cbSymbols) internal {
        BasketRegistry.AssetConfig[] memory cfg = Addrs.basket();
        _ok(d.registry.assetCount() == cfg.length, "basket has the 8 launch stocks");
        uint256 n = d.registry.assetCount();
        for (uint256 i; i < n; ++i) {
            BasketRegistry.Asset memory a = d.registry.assetAt(i);
            string memory sym = IERC20Metadata(a.token).symbol();
            string memory tag = string.concat(sym, " ", vm.toString(a.token));
            _ok(i < cfg.length && a.token == cfg[i].token && a.feed == cfg[i].feed, string.concat(tag, ": matches Addrs.basket"));
            _ok(a.weightBps == 1_250, string.concat(tag, ": weight 12.5%"));
            (bool listed, string memory cbSym) = _find(cbTokens, cbSymbols, a.token);
            _ok(listed, string.concat(tag, ": on Coinbase's live list"));
            _ok(listed && keccak256(bytes(cbSym)) == keccak256(bytes(sym)), string.concat(tag, ": symbol matches Coinbase's list"));
            _ok(IB20FactoryView(Addrs.B20_FACTORY).isB20Initialized(a.token), string.concat(tag, ": a B20 from Base's factory"));
            _ok(
                IIssuerRegistry(Addrs.COINBASE_TOKEN_REGISTRY).isRegisteredToken(a.token),
                string.concat(tag, ": registered in Coinbase's TokenSupplyManager")
            );
            _ok(a.tokenDecimals == 8 && IERC20Metadata(a.token).decimals() == 8, string.concat(tag, ": 8 decimals"));
            _feed(d, a, sym, tag);
            int24 ts = d.registry.usdcTickSpacing(a.token);
            _ok(
                ts == Addrs.STOCK_USDC_TS
                    && ISlipstreamFactory(Addrs.SLIP_FACTORY).getPool(a.token, Addrs.USDC, ts) != address(0),
                string.concat(tag, ": Aerodrome token/USDC pool exists")
            );
        }
    }

    function _feed(Deploy.Deployed memory d, BasketRegistry.Asset memory a, string memory sym, string memory tag)
        internal
    {
        bytes memory s = bytes(sym);
        bytes memory ticker = new bytes(s.length == 0 ? 0 : s.length - 1);
        for (uint256 j; j < ticker.length; ++j) {
            ticker[j] = s[j];
        }
        _ok(
            keccak256(bytes(IAggregatorV3(a.feed).description())) == keccak256(abi.encodePacked("Coinbase ", ticker)),
            string.concat(tag, ": feed ", vm.toString(a.feed), " is \"Coinbase ", string(ticker), "\"")
        );
        _ok(IOwnedFeed(a.feed).owner() == Addrs.CHAINLINK_FEED_OWNER, string.concat(tag, ": feed owned by Chainlink's multisig"));
        _ok(a.feed.codehash == d.registry.trustedFeedCodehash(), string.concat(tag, ": feed has Chainlink's feed code"));
        _ok(a.feedDecimals == 8, string.concat(tag, ": feed 8 decimals"));
        (,,, uint256 updatedAt,) = IAggregatorV3(a.feed).latestRoundData();
        console2.log(string.concat("INFO ", tag, ": feed age (seconds)"), block.timestamp - updatedAt);
    }

    /* ------------------------------------------------------------------ */
    /*                               Helpers                               */
    /* ------------------------------------------------------------------ */

    function _ok(bool ok, string memory what) internal {
        if (ok) {
            ++passes;
            console2.log(string.concat("PASS ", what));
        } else {
            ++fails;
            console2.log(string.concat("FAIL ", what));
        }
    }

    function _find(address[] memory t, string[] memory s, address token) internal pure returns (bool, string memory) {
        for (uint256 i; i < t.length; ++i) {
            if (t[i] == token) return (true, s[i]);
        }
        return (false, "");
    }

    function _append(address[] memory a, string[] memory b, address[] memory c, string[] memory e)
        internal
        pure
        returns (address[] memory x, string[] memory y)
    {
        x = new address[](a.length + c.length);
        y = new string[](a.length + c.length);
        for (uint256 i; i < a.length; ++i) {
            (x[i], y[i]) = (a[i], b[i]);
        }
        for (uint256 i; i < c.length; ++i) {
            (x[a.length + i], y[a.length + i]) = (c[i], e[i]);
        }
    }
}

interface IOwnable2 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}
