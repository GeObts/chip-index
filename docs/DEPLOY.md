# Chip Index — deploy checklist

**Nothing here touches mainnet without the owner's explicit go-ahead.**

## 0. Launch settings
Every launch value is in ONE place: the `LaunchConfig` block at the top of `script/Deploy.s.sol`.

| Setting | Value | Status |
|---|---|---|
| Name / ticker | "Chip Index" / "CHIDX" | placeholders, confirm before deploy |
| Mint cap | 2,500 index tokens (= $25,000 at $10), global, Safe-raisable | decided |
| Max USDC per $CHIP buy | $100 (fork: 0.68% vs spot) | decided |
| First mint | $125 × 8 stocks = $1,000 → 100 tokens ($10 each) | decided |
| Fees | mint 1%, redeem 1%, management 3%/yr | decided |
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

## 4. First mint (Safe)
```
VAULT=<IndexVault address> base-forge script script/SafeSeed.s.sol --rpc-url $BASE_RPC_URL
```
This writes `safe/seed.json`, a single Safe Transaction Builder batch: approve USDC → buy $125 of
each stock on Aerodrome (max +2%) → reset the approval → approve the stocks to the vault →
`vault.seed(amounts, 100 tokens, Safe)`. The Safe needs about $1,020 of USDC. Copy the JSON to
Downloads, review it, then load it in the Safe app. Rehearsed on the fork: $1,000.59 spent, NAV $10.00.

## 5. Ongoing operations
- A new ticker needs `registry.setUsdcTickSpacing(token, ts)` after `executeBasket`, before
  cash mints and rebalances can trade it.
- The keeper runs `rebalancer.eligible()` → `rebalance(...)`, `splitter.redeemFees()` →
  `sellForUsdc(...)` → `buyAndBurn(...)` (at most $100 per call).
- Raising the cap later: Safe calls `vault.setMintCap(newCapInTokens * 1e18)`.
