# Chip Index — deploy checklist

**Nothing here touches mainnet without the owner's explicit go-ahead.**

## 0. Owner decisions still needed
- [ ] Token name and ticker (`INDEX_NAME`, `INDEX_SYMBOL`)
- [ ] Starting mint cap in index tokens (`MINT_CAP`)
- [ ] Max USDC per $CHIP buy (`MAX_CHIP_BUY_USDC`)
- [ ] Seed size and starting price per index token (e.g. $1,000 of stock for 100 tokens = $10)
- [ ] A-6 in ASSUMPTIONS.md (blocklisted holders)
- [ ] External audit before real money (recommended)

## 1. Tests (free, local)
```
forge test --no-match-path "test/fork/*"          # Windows PowerShell: unit + invariant
wsl ./script/fork-test.sh                          # WSL: Base mainnet fork, real B20s
FOUNDRY_PROFILE=deep forge test --no-match-path "test/fork/*"   # long fuzz run (~8 min)
```

## 2. Dry run (free: simulates, sends nothing)
```
INDEX_NAME=... INDEX_SYMBOL=... MINT_CAP=... MAX_CHIP_BUY_USDC=... \
  base-forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL
```
It must use `base-forge`, because the registry reads B20 decimals in its constructor. The script
ends by checking owners, wiring, keeper, fees, cap and all 8 basket entries.

## 3. Broadcast (costs gas — OWNER GO-AHEAD REQUIRED)
Same command plus `--broadcast --account <keystore>`, then verify the source on Basescan.
The deploy wallet owns nothing afterwards; the Safe owns all five contracts.

## 4. Safe transactions
1. Seed: approve the 8 stocks to the vault, then `vault.seed(amounts, shares, Safe)`. This bundle is
   built at seed time from live prices.
2. Nothing else is needed to go live. Optional: `setMintCap`, `registry.setMaxFeedAge`.

## 5. Ongoing operations
- A new ticker needs `registry.setUsdcTickSpacing(token, ts)` after `executeBasket`, before
  cash mints and rebalances can trade it.
- The keeper runs `rebalancer.eligible()` → `rebalance(...)`, `splitter.redeemFees()` →
  `sellForUsdc(...)` → `buyAndBurn(...)`.
