# Chip Index — basket review

How the CHIPX basket can change after launch, and what it costs. Studied 2026-10-14/15 on a
fork of live Base, using the live contracts and the real Safe-only 48h path.

## Can the basket grow? Yes, up to 16 stocks

- **Hard limit: 16 listed tokens** — `BasketRegistry.MAX_ASSETS = 16` (`src/BasketRegistry.sol:79`),
  checked when a basket is queued and executed (`:353`) and again after any dropped stock is carried
  over at weight 0 (`:203`). A stock removed while the vault still holds or owes it stays listed at
  weight 0 until `prune`d, and **counts toward the 16**.
- The vault has no stock limit of its own; every mint, redeem, NAV and reconcile loop walks
  `registry.tokens()`.
- There is no maximum on redeem gas. `REDEEM_LEG_GAS = 250_000` (`src/IndexVault.sol:88`) is the gas
  forwarded to EACH stock transfer on redeem, and `_tryTransfer` (`:809`) refuses to start a leg
  with less than ~264k gas left, so a redeem cannot be made to "fail" a leg by sending too little
  gas. It is a floor per leg, not a cap: wallets' gas estimates already include it.

## Which stocks can actually be added (checked 2026-10-15)

A stock must pass all four registry checks: a B20 from Base's factory, registered in Coinbase's
TokenSupplyManager `0xD1Ca…664C`, a Chainlink "Coinbase <TICKER>" feed with the trusted owner and
code, and an Aerodrome token/USDC pool.

| Ticker | Coinbase B20 | Registered | Chainlink feed on Base | Aerodrome USDC pool | Addable |
|---|---|---|---|---|---|
| SNDK | `0xb200…a10c5` | yes | `0x388b0dC4…a2eA` | tick spacing 10 | **yes** |
| SPCX | `0xb200…aCBd5` | yes | `0x6A634B23…Fa68` | tick spacing 10 | **yes** |
| INTC | `0xB200…dFBc` | yes | `0xAB657C39…EECB` | none (1/10/50/100/200/2000) | no — refused `NoSuchPool` |
| CRCL | `0xB200…2e4D` | yes | `0x0231cF26…1f33` | none | no |

Base has 13 "Coinbase <TICKER>" feeds in total (Chainlink's directory), so today the most the
index could hold is the 8 launch stocks + SNDK + SPCX = **10**. More become possible only when
Chainlink adds feeds and Aerodrome pools exist.

## Fork rehearsal: 10 stocks at 10% each

Live contracts on a Base fork; the Safe queued the 10-stock basket, waited 48h, executed it.
(A fork cannot make new Chainlink rounds, so after each time jump the feeds keep their real last
price and only the timestamp is refreshed.)

| Step | Result |
|---|---|
| `queueBasket` / 48h / `executeBasket` (Safe) | PASS. INTC/CRCL basket refused with `NoSuchPool` |
| Rebalance day 1: 8 trades, real Aerodrome pools | PASS: 14% of NAV moved (daily cap 15%); drift 10 → 3.0 points; 4.46M gas |
| Rebalance day 2: 9 trades | PASS: drift 0.3 points; every stock 9.7–10.1%; 4.14M gas |
| In-kind mint (brings all 10 stocks) | PASS |
| In-kind redeem (delivers all 10, SNDK + SPCX included) | PASS |
| Cash mint / redeem (USDC) | PASS: $9.88 in, $9.73 back for ~1 CHIPX |
| Claim: SNDK transfers paused at redeem → credited → `claimOwed` | PASS |

Adding stocks means buying them out of the existing ones. With the 15%/day volume cap a 10-point
move per new stock takes **2 days**, and once the largest drift is under 3 points the next
rebalance waits for the 30-day schedule.

## Gas by number of stocks (cold, like a real transaction)

| Stocks | In-kind redeem | Cash redeem (USDC) |
|---|---|---|
| 8 (live) | 508,907 | 2,323,691 |
| 9 | 540,202 | 2,116,150 |
| 10 | 593,985 | 2,326,893 |
| 12 | ~680,000 (estimate) | ~2.7M (estimate) |
| 15 | ~810,000 (estimate) | ~3.3M (estimate) |

- 12 and 15 are **estimates**: no 11th or 12th real stock can be listed yet. In-kind grows by about 42k
  per stock (8 → 10 measured). Cash redeem is dominated by one Aerodrome swap per stock (~150–250k
  each, varying with how many price ticks a swap crosses, which is why 9 measured below 8).
- At Base's ~0.006–0.01 gwei, even 15 stocks is about $0.02 (in-kind) or $0.08 (cash) per redeem.
- Base's block gas limit is 400M. The largest of these, ~3.3M, is far under it, and also far under
  the 16.7M (2^24) per-transaction cap Ethereum adopted in Fusaka, if Base applies one.

**Practical limit:** gas is not what stops growth. The real limits are the 16-stock hard cap
(including weight-0 leftovers), which tickers have a Chainlink feed AND a deep Aerodrome USDC
pool (today only SNDK and SPCX), and how long the rebalance takes (15% of NAV a day). A rebalance
of 8+ trades costs ~4–5M gas; the keeper can split one into several transactions.

## Add a stock (Safe steps)

1. **Check the ticker** (free, read-only):
   - Token address from `api.coinbase.com/v1/tokenized-stocks` (symbol `<TICKER>c`), never from
     anywhere else.
   - Feed: Chainlink's Base directory
     (`reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json`), entry
     "Coinbase <TICKER>", use its `proxyAddress`.
   - Pool: `SlipstreamFactory(0xf8f2…61Ef).getPool(token, USDC, 10)` must be non-zero and have real
     depth.
2. **Write the whole new basket** in `script/Deploy.s.sol` `Addrs.basket()`: every stock (old and
   new) with its feed, tick spacing 10 and new weights that add up to exactly 10,000 (e.g. 10 × 1,000).
   `queueBasket` replaces the whole list, so leaving a stock out removes it.
3. **Build the Safe file**: one transaction to the registry `0x653B2cC8…004e`,
   `queueBasket(AssetConfig[])` with that exact list. Simulate it against live Base (the registry
   re-checks all four rules now and again at execute). Copy it to Downloads.
4. **Sign** (2 of 3 owners). The change can be executed from 48h later, for 14 days.
5. **Execute**: a second Safe file, `executeBasket(...)` with the **byte-identical** list (anything
   different is `NotQueued`). It re-checks every entry.
6. **Rebalance**: the keeper moves value into the new stock over the following days, within the
   vault's 15%-of-NAV-a-day volume and 0.10%-of-NAV loss caps. Until then in-kind mints ask for
   none of the new stock (mints are proportional to what the vault holds).
7. **Verify**: update `VerifyDeployment.s.sol`'s expectations (it reads `Addrs.basket()`), then run
   it (DEPLOY.md §3a). Expect the per-stock checks to include the new ticker, and 0 FAIL.
8. **Docs**: SPEC.md basket table, DEPLOY.md §0, the CHIPX page's basket list.

To **swap** a stock instead, queue a basket without it: it stays listed at weight 0 (holders can
still redeem it), the Rebalancer sells it down, and anyone can `prune` it once the vault holds and
owes none.
