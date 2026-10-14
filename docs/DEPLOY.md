# Chip Index — deploy checklist

**Nothing here touches mainnet without the owner's explicit go-ahead.**

## 0. Launch settings
Every launch value is in ONE place: the `LaunchConfig` block at the top of `script/Deploy.s.sol`.

| Setting | Value | Status |
|---|---|---|
| Name / ticker | "Chip Index" / "CHIPX" | decided (2026-10-13) |
| Mint cap | 5,000 index tokens (= $50,000 at $10), global; lower instantly, raise after 48h | decided 2026-10-13 (was 2,500) |
| Max USDC per $CHIP buy | $100 (fork: 0.68% vs spot); hard limit $500 | decided |
| $CHIP buys per 24h | $300 (hard limit $2,000) | proposed 2026-10-13 |
| Rebalance limits | 0.75% per trade; per 24h at most 15% of NAV traded and 0.10% of NAV lost | proposed 2026-10-13 |
| Safe settings | stricter = instant (`tighten`); looser = 48h (`queueSetting` / `executeSetting`) | decided 2026-10-13 |
| First mint | $12.50 × 8 stocks = $100 → 10 tokens ($10 each); Safe needs up to $102 USDC | decided 2026-10-14 (was $1,000) |
| Fees | mint 1%, redeem 1%, management 3%/yr | decided |
| Cash mint/redeem hours | 24/7. Fresh feeds: each leg within 1% of Chainlink. Stale feeds: within 10% of the last Chainlink price (≤ 7 days old), redeem needs a nonzero min-out, mint fee base 1%. `router.tighten(4, x)` narrows the band instantly; `tighten(4, 0)` turns stale-feed cash off | decided 2026-10-14 |
| Blocklist | refuse redeem/claim for Coinbase-blocklisted accounts | decided, built |
| Independent review | `docs/REVIEW_PACKAGE.md` | before real money |

## 1. Tests (free, local)
```
forge test --no-match-path "test/fork/*"                         # Windows: unit + invariant
wsl ./script/fork-test.sh                                         # WSL: Base mainnet fork, real B20s
FOUNDRY_PROFILE=deep forge test --no-match-path "test/fork/*"     # long fuzz run (~8 min)
```

## 2. Dry run (free: simulates, sends nothing)
```
base-forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL
```
It must use `base-forge`, because the registry reads B20 decimals in its constructor. The script
ends by checking owners, wiring, policy registry, keeper, fees, cap, name/ticker and all 8 basket entries.

## 3. Broadcast (costs gas — OWNER GO-AHEAD REQUIRED)
Same command plus `--broadcast --account <keystore>`, then verify the source on Basescan.
The deploy wallet owns nothing afterwards; the Safe owns all five contracts.

## 3a. Verify the live deployment (free, read-only, sends nothing)
Run this right after the deploy, and again any time you want to confirm nothing has drifted. It
needs no key. It prints one `PASS` or `FAIL` line per check (151 checks for the launch basket)
and exits with an error if any line failed.

In WSL, from the repo folder, fill in the five addresses the deploy printed:
```
export BASE_RPC_URL=https://mainnet.base.org
CHIPX_REGISTRY=0x...  CHIPX_VAULT=0x...  CHIPX_REBALANCER=0x...  CHIPX_ROUTER=0x...  CHIPX_SPLITTER=0x...   ~/.foundry/bin/base-forge script script/VerifyDeployment.s.sol --rpc-url $BASE_RPC_URL --ffi
```
- `--ffi` lets the script run `curl` to read Coinbase's list (all pages of
  api.coinbase.com/v1/tokenized-stocks). Nothing else runs outside forge.
- What it checks: all five owners are the Safe with no ownership transfer pending; the contracts
  point at each other; the keepers; every fee, cap and limit against `LaunchConfig`; the 48h
  timelock; **no queued change waiting** on any contract (read onchain from `pendingChanges()`);
  and for each of the 8 stocks: on Coinbase's live list with the same symbol, a real B20,
  registered in Coinbase's TokenSupplyManager, its feed named "Coinbase <TICKER>" with Chainlink's
  owner and code, and its Aerodrome pool.
- Feed ages are printed as `INFO` (not pass/fail): they are normal up to 24h on weekends.
- A `FAIL` on a setting the Safe changed on purpose after launch is expected. Update
  `LaunchConfig` to the new value and run it again.
- Rehearsed on a Base fork (`test/fork/VerifyDeploymentFork.t.sol`): a clean deploy gives 151
  PASS and 0 FAIL; a queued change, an unaccepted ownership transfer, a removed keeper and a stock
  missing from Coinbase's list give exactly 5 FAIL lines.

## 4. First mint (Safe)
```
VAULT=<IndexVault address> base-forge script script/SafeSeed.s.sol --rpc-url $BASE_RPC_URL
```
This writes `safe/seed.json`, a single Safe Transaction Builder batch: approve USDC → buy $12.50 of
each stock on Aerodrome (max +2%) → reset the approval → approve the stocks to the vault →
`vault.seed(amounts, 10 tokens, Safe)`. The Safe needs at most $102 of USDC (seed + 2%). Copy the JSON to
Downloads, review it, then load it in the Safe app. Rehearsed on the fork: $1,000.59 spent, NAV $10.00.

Full rehearsal 2026-10-13 (local base-anvil fork, deploy → seed through the real 2-of-3 Safe with
`execTransaction` + MultiSendCallOnly → VerifyDeployment): $1,000 seed spent $1,002.17 for 100 CHIPX
($10.00 each); an $80 seed ($10 × 8, `SEED_TOKENS = 8`) spent $80.19 for 8 CHIPX; both 150 PASS /
0 FAIL; Safe tx ~2.2M gas. Before the seed every public mint path reverts `NotSeeded` and `seed` is
Safe-only, so there is no first-depositor window.
Re-run 2026-10-14 at 2c73b72 (24/7 cash): seed $999.36 → 100 CHIPX at $10.00; VerifyDeployment
151 PASS / 0 FAIL; then +60h with the real stock feeds stale: USDC mint of 10 CHIPX $99.92, a
redeem with min-out 0 refused, a redeem with min-out $90 paid $117.40 for 11.88 CHIPX.
Launch seed $100 (14c7e9b, 2026-10-14), with the Safe's REAL 150 USDC: batch capped at $102.00,
spent $99.88 → 10 CHIPX at $10.00; 151 PASS / 0 FAIL; weekend cash mint/redeem worked.
Mainnet dry run as deployer `0x8a424ef1…502b` (nonce 0): registry `0x653B2cC8…004e`, vault
`0x8d6bbB52…E9a2`, rebalancer `0xd62D1b24…35C1`, router `0xffAA57A3…7903`, splitter
`0x791f9236…BeD6`; at most 0.000273 ETH.
**Before the owners sign on mainnet**, simulate the exact Safe transaction against live Base
(`eth_simulateV1`, or the Safe app's built-in simulation): base-anvil sometimes fails the first B20
transfer it meets in a transaction (`OpcodeNotFound`), which is a simulator artefact, not a contract
failure.

## 5. Ongoing operations
- A new ticker: the basket entry carries its Aerodrome pool (tick spacing), so one 48h
  `queueBasket` / `executeBasket` covers it. **Take the token address from
  api.coinbase.com/v1/tokenized-stocks.** The contract also refuses any token that Coinbase's
  TokenSupplyManager (`0xD1Ca…664C`) has not registered, any feed that is not Chainlink's
  "Coinbase <TICKER>" feed, and any pool that does not exist. After executing, run
  `VerifyDeployment.s.sol` (it fails until `Addrs.basket()` is updated to the new basket).
- The keeper sizes each rebalance trade so neither stock crosses its target (the contract refuses
  any trade that does) and runs `rebalancer.eligible()` → `rebalance(...)`, `splitter.redeemFees()` →
  `sellForUsdc(...)` → `buyAndBurn(...)` (at most $100 per call, $300 per 24h).
- `buyAndBurn`'s `minChipOut` must come from a live quote taken just before sending: `eth_call`
  `buyAndBurn(usdcIn, 1, deadline)` from the keeper address, read `chipOut`, and send
  `minChipOut = chipOut × 0.99`. The contract rejects 0. **The Chip Index keeper script does not
  exist yet; build it before launch.**
- Raising the cap later: Safe calls `vault.queueSetting(2, newCapInTokens * 1e18)` (key 2 =
  `SET_MINT_CAP`), then `executeSetting` with the same values 48h later. Lowering it:
  `vault.tighten(2, newCap)`, instant.
- A stolen or misbehaving keeper: `tighten(0, 0)` (`SET_KEEPER` = 0) on the Rebalancer,
  FeeSplitter and Router removes it instantly; `vault.tighten(3, 0)` (`SET_MAX_TRADE_SLIPPAGE`)
  stops every rebalance trade.
