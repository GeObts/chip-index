# Chip Index — independent review package

**Status:** pre-deployment. Nothing is deployed. All results below come from local tests and a
Base mainnet fork (2026-10-12; size-tiered mint fee, review-round-1 fixes and pre-round-2 hardening 2026-10-13).
**Review rounds:** findings, fixes and the pre-round-2 hardening are in `docs/REVIEW_RESPONSE.md`.
**Scope:** `src/` (2,539 lines across 12 files). Out of scope: tests, scripts, and the existing
Chipworks contracts (Pot, ChipBurner, $CHIP), which are integrated as external dependencies.
**Toolchain:** solc 0.8.24, `evm_version = cancun`, optimizer 200 runs, no via-IR,
OpenZeppelin v5.1.0, base-std @ `6a249339`. Fork tests use base-forge (base-anvil v1.1.0).

## 1. What it is
One ERC-20 index token on Base, backed by an equal-weight basket (12.5% each) of 8 Coinbase B20
tokenized stocks: NVDA, MSTR, GOOGL, AMZN, AAPL, META, TSLA, MSFT. Anyone can mint by depositing
the stocks in proportion, or with USDC/ETH through a router, and anyone can redeem for their share
of the stocks. Fees go 50% to the Chipworks Pot as USDC and 50% to buy-and-burn $CHIP.

## 2. Contracts

| Contract | Lines | Runtime size | What it does |
|---|---|---|---|
| `IndexVault` | 756 | 23.1 KB | The index token. Pro-rata in-kind mint (rounds up) and redeem (rounds down). The basket ratio never depends on an oracle; mint reads Chainlink only to pick its fee rate, and still works at the base rate when a feed is stale. Redeem has **no pause** and **no oracle**. Undeliverable legs (issuer pause, vault blocklisted) become claimable credits, held as shares of a per-token credit pool so an issuer seizure is written down pro-rata for index holders and credit holders alike. Refuses redeem/claim for issuer-blocklisted caller, receiver or credit holder. Mint cap (global), mint pause; **mint refuses outright while any stock is issuer-paused or the vault is blocklisted on any stock**. Fees: **size-tiered mint fee** (see below; every rate capped at 1%), redeem (cap 2%), management (cap 5%/yr, per-second accrual as minted shares). Executes rebalance trades for the Rebalancer and itself enforces Chainlink value-in vs value-out (max 0.75%, hard cap 1%) **and 24h caps on rebalance trading (15% of NAV) and on value lost (0.10% of NAV)**, which bind any Rebalancer. Rebalancer, fee-recipient and mint-fee-schedule changes: 48h timelock; other settings per §5. Every contract lists its waiting timelocked changes onchain (`pendingChanges()`). |
| `BasketRegistry` | 422 | 13.8 KB | Tokens, feeds, target weights and each token's Aerodrome pool (tick spacing), so a pool change is a basket change. **Every entry is checked on queue and on execute:** the token must be a B20 per Base's B20 factory (`isB20Initialized`) **and registered in Coinbase's TokenSupplyManager (`isRegisteredToken`)**; the feed must have the launch feeds' code hash and owner (Chainlink's Base multisig); the feed description must be `Coinbase <TICKER>` for a token whose symbol is `<TICKER>c`; the pool must exist. Launch basket set in the constructor; any later change replaces the whole basket through a 48h timelock with a 14-day grace window. Dropped tokens still held or still owed in credits stay listed at weight 0 until `prune`, which refuses while either is non-zero. Chainlink reads: positive answer, `maxFeedAge` (26h default, 1h–72h), Base sequencer uptime with 1h grace. |
| `IndexRouter` | 426 | 16.7 KB | Cash mint (exact-output swaps USDC/ETH→each stock on Aerodrome Slipstream) and cash redeem (exact-input stock→USDC/ETH). User limit plus each leg within 1% of Chainlink. Mint and redeem both require all feeds fresh. Owner or keeper can pause either path; only the owner unpauses. Checks the cash recipient against the blocklist. ETH refunds/payouts forward all gas and fall back to WETH if the recipient rejects ETH, so a contract wallet can never block its own mint or redeem. Holds no balance between calls. |
| `Rebalancer` | 232 | 9.1 KB | Keeper-only. Allowed when any weight drifts more than 3 points from target, or 30 days after the last rebalance. Each trade must sell an overweight and buy an underweight stock; **no trade may push either stock past its target**; **total Chainlink value sold per rebalance ≤ the basket's total overweight in dollars**; total absolute drift must fall. Routes stock→USDC→stock on Aerodrome via the vault's callback, with a Chainlink-derived `amountOutMinimum` on the swap itself. |
| `IndexFeeSplitter` | 402 | 13.8 KB | Fee recipient. `redeemFees` (anyone, fee-free) → `sellForUsdc` (keeper, Chainlink floor) → `distribute` (anyone: 50% to the Pot, 50% to `chipBudget`) → `buyAndBurn` (keeper: USDC→WETH on Aerodrome, WETH→$CHIP on the Uniswap v4 pool via unlock callback, then ChipBurner.burnAll). `maxChipBuyUsdc` = $100 per call (hard limit $500), `dailyChipBuyUsdc` = $300 per 24h (hard limit $2,000); `minChipOut` may not be 0. `sweep` cannot touch fee-flow tokens or listed stocks. |
| `lib/OracleLib`, `lib/Timelock`, `lib/Settings` | 193 | — | Feed and sequencer checks; generic queue/execute/cancel timelock keyed by `keccak256(action, data)`; `Settings`: one rule for every owner setting (§5). |

Every contract is `Ownable2Step` (through `Settings`), owned by the Chipworks Safe `0xe1096B72…73C7` from the
constructor. One-time wiring (`wireVault`, `wire`) is callable only by the deploying address and
only once. The keeper is `0x6571E341…95B9`.

### Size-tiered mint fee (added 2026-10-13)

The mint fee depends on the dollar size of one mint. The vault prices the gross shares at NAV
(`navUsd() × shares / supply`, Chainlink, all feeds fresh) **before** the deposit lands, and picks:

| Value of one mint | Launch rate |
|---|---|
| under $10,000 | 1% (`baseBps` 100) |
| $10,000 to $49,999.99 | 0.75% (`tier1Bps` 75) |
| $50,000 and up | 0.5% (`tier2Bps` 50) |

- One rule for every mint path: USDC and ETH mints reach the vault through the router as an in-kind
  `mint`, so the vault charges them the same way. The tier is per call, not cumulative.
- **Stale feed or sequencer down:** `mintFeeFor` catches the revert (`try this.navUsd()`) and charges
  the base rate. In-kind mint keeps working without prices, it just gets no discount.
- **Owner-settable, timelocked:** `queueMintFeeSchedule` / `executeMintFeeSchedule` through the same
  48h timelock (14-day grace) as the rebalancer and fee recipient. Hard caps checked on queue and on
  execute: every rate ≤ `MAX_MINT_FEE_BPS` = 100 (1%); rates are `uint16`, so none can go below 0%;
  thresholds must be > 0 and strictly increasing. The constructor applies the same checks.
- Redeem and management fees now follow §5: a cut is instant, a rise waits 48h. The 2% mint cap
  from SPEC v0 is now 1%.
- Redeem fee is unchanged: 1% at any size.
- Launch values live in `LaunchConfig` (`script/Deploy.s.sol`); `verify` checks the deployed schedule.
- At the launch mint cap (5,000 tokens = $50k in total, of which the Safe's seed is $1k) one mint
  of $50k cannot fit, so the 0.5% tier is not reachable until the Safe raises the cap.

## 3. Design invariants to check
1. In-kind redeem can never be blocked by the owner, the keeper, oracles or the sequencer. It is
   blocked only by the issuer's own blocklist, which is deliberate (§5).
2. Mint and redeem rounding always favours existing holders, so a mint→redeem round trip cannot profit.
3. `balanceOf(vault, token) >= held[token] + totalOwed[token]` for every listed token, after any
   `sync` (a seizure puts the books ahead of the balance until someone syncs).
4. Sum of `owed(*, token)` is at most `totalOwed[token]`, short only by rounding (each account
   rounds down).
5. Even a faulty or rogue Rebalancer cannot lose more than `maxTradeSlippageBps` of Chainlink value
   per trade, nor more than `dailyLossCapBps` of NAV (0.10%) per 24h window, nor trade more than
   `dailyTradeCapBps` of NAV (15%) per window.
6. The Router and FeeSplitter keep no user funds between transactions (apart from the splitter's
   booked `chipBudget`).

## 4. Known Coinbase-side (issuer) risks
These come from the B20 tokens themselves and cannot be removed by any contract.

| Risk | Effect on the index | Handling / test |
|---|---|---|
| **One blocklist for everything.** All 8 tokens bind Coinbase policy **5** to the SENDER, RECEIVER **and EXECUTOR** scopes (admin `0xEC0F05C1…2812`, verified onchain). | If the vault is blocklisted, all 8 stocks freeze together. Redeems still burn and record credits, which pay out if the block is lifted. Mint stops. | `test_fork_blocklistedVault` |
| Issuer **pause** (TRANSFER/MINT/BURN/SEIZE, per token) | A paused stock's redeem leg is credited and claimable later; mint is refused up front (`StockPaused`) while any stock's TRANSFER is paused. | `test_fork_pausedToken`, `test_redeem_pausedTokenIsCreditedThenClaimed` |
| Issuer **seize** from any holder, including the vault | Permissionless `sync` writes the loss down pro-rata across index holders (`held`) and credit holders (`totalOwed`, scaling every credit at once). | 6 unit seizure tests incl. fuzz, invariant handler, `test_fork_seizureWithOutstandingCredit` |
| **Multiplier** changes (dividends, splits) | None: balances are raw and the feeds are total-return. | `test_fork_multiplierChange` (10× change) |
| **Feeds freeze** nights, weekends, holidays and corporate actions | Cash mint/redeem, rebalancing and fee selling stop; in-kind paths continue. | `test_fork_staleFeed` |
| **Denim** upgrade (Sepolia 2026-10-21, mainnet planned November 2026) applies the executor check to plain `transfer` | Executor and sender share policy 5 (a BLOCKLIST) on all 8 stocks, so for a plain `transfer` it asks the same question again: no change while our contracts are not blocklisted. Only an allowlist-style executor policy would stop stock movement (here and on every DEX). | Checked onchain; ASSUMPTIONS A-4 |
| **Wrapper vs blocklist** | Owner decision: the vault refuses redeem and claim for any blocklisted caller, receiver or credit holder, and the router also checks the cash recipient. | 7 unit + 6 fork tests (§6) |

**Index-token transfers are INTENTIONALLY unrestricted (owner decision, 2026-10-12).** CHIPX is a
plain, freely transferable OpenZeppelin ERC-20 with no blocklist, pause or hook on `transfer` or
`transferFrom`. The blocklist is enforced only where stock leaves the vault (redeem and claim). So a
Coinbase-blocklisted holder can transfer index tokens to a clean address, and that address can then
redeem. This is accepted by design, to keep the index token composable. Please review the
redeem/claim checks on their own terms, not as a complete compliance barrier.

## 5. Other trust assumptions
- 1 USDC = $1 in the Router's per-leg USDC limits and the FeeSplitter's sell floor. A depeg below
  $1 makes those paths revert (fail closed); in-kind mint/redeem and NAV never use USDC. Using
  Chainlink's USDC/USD feed instead is costed in REVIEW_RESPONSE §14 (owner has not decided).
- $CHIP has no onchain TWAP (its Doppler hook keeps no oracle). Buys rely on the keeper's
  `minChipOut` and the $100 per-call cap.
- **Safe powers (owner decision 2026-10-13): anything that only stops things is instant; anything
  that could cost holders money waits 48h.** One mechanism everywhere (`lib/Settings`):
  `tighten(key, value)` is instant and only accepts a stricter value; `queueSetting` /
  `executeSetting` go through the 48h timelock (14-day grace) for any value within the hard caps.

  | Contract | Instant | 48h timelock |
  |---|---|---|
  | IndexVault | mint pause/unpause; lower: redeem fee, mgmt fee, mint cap, trade slippage, daily trade cap, daily loss cap | raise any of those (hard caps 2%, 5%/yr, —, 1%, 25%, 0.5%); mint fee schedule; rebalancer; fee recipient |
  | BasketRegistry | shorter feed max age | longer feed max age (≤72h); basket incl. pool choice; trusted feed owner / code hash; Coinbase token register address |
  | IndexRouter | pause (owner or keeper), unpause (owner); remove keeper; lower leg slippage; shorter ETH feed age | add keeper; raise leg slippage (≤1%); longer ETH feed age (≤24h); WETH/USDC pool |
  | Rebalancer | remove keeper | add keeper |
  | IndexFeeSplitter | remove keeper; lower $CHIP per-call cap, daily cap, sell slippage; shorter ETH feed age | add keeper; raise per-call cap (≤$500), daily cap (≤$2,000), sell slippage (≤2%); longer ETH feed age; WETH/USDC pool |

  Not settings: `sweep` (non-fee tokens only), `renounceOwnership` (OpenZeppelin default). The
  owner cannot pause in-kind redeem or take vault assets.
- Keeper powers: rebalance (within the anti-churn rules and the vault's 24h caps), sell fee stocks
  (Chainlink floor), buy and burn $CHIP (budget, $100/call, $300/day), pause cash paths.
- **Worst case for a stolen keeper key** (launch cap $50k NAV): see REVIEW_RESPONSE §11 and §13.4.
  Rebalancer about $15 per eligible episode by its own rules, never more than $50 per 24h window
  (0.10% of NAV, enforced by the vault); FeeSplitter up to $300 of $CHIP budget per day (fee
  money, not holders' stock); Router: pause only. The Safe removes a keeper instantly.
- **Hostile Rebalancer contract** (installed through the 48h timelock): fuzzed with every trade
  shape; worst case measured $49.99 per window at $50k NAV, $99.93 if two windows fall inside one
  24h span (REVIEW_RESPONSE §13.4).
- Basket authenticity: every added stock must be registered in Coinbase's TokenSupplyManager
  (`isRegisteredToken`, admin-only), so a copycat B20 is refused onchain. Accepted as handled
  operationally too: addresses come from Coinbase's official list and are checked by
  `script/VerifyDeployment.s.sol`.

## 6. Test results (2026-10-12, re-run after review rounds 1–3, 2026-10-13)

**Unit + invariant (mocks): 147 passed, 0 failed.** `forge test --no-match-path "test/fork/*"`

| Suite | Tests | Covers |
|---|---|---|
| IndexVault | 41 | seed, pro-rata mint/redeem, fees and caps (cut instant, rise 48h), management accrual, credits, pause, **mint refused while a stock is paused or the vault blocklisted (2)**, mint cap rise 48h, vault-blocklisted stock, **blocklist (5)**, sync, **seizure with credits outstanding (6)**, trade slippage and daily caps, timelocks, 3 fuzz tests (512 runs) |
| MintFeeTiers | 19 | just under / at / just over $10k and $50k (±$0.01), small mint, per-mint (not cumulative), USDC and ETH router mints get the tier, stale feed → mint works at 1%, redeem stays 1% at $60k, timelock (early, mismatched data, owner-only), caps (101 bps rejected on each rate, bad thresholds, constructor), donation attack on a tier (loses $2,062 to save $117.50), stale feed only moves the tier boundary |
| IndexRouter | 21 | USDC/ETH mint and redeem, 1% leg bound, user limits, stale feeds, pause roles, credits go to the user, **blocklist (2)**, ETH-rejecting wallet gets WETH (2), settings (slippage, keeper, ETH feed age, pool 48h-only) |
| BasketRegistry | 23 | launch basket, validation, timelock delay/grace/mismatch/cancel, add/remove/prune (refused while held or owed), **authenticity: fake token, B20 not registered by Coinbase (queue and execute), untrusted or look-alike feed, feed/ticker mismatch, re-checked at execute (5)**, Coinbase register address 48h-only, pool change is a basket change, feed max age, trusted feed owner 48h-only, stale/bad/broken feeds, sequencer |
| Rebalancer | 13 | eligibility (drift / 30 days), over/underweight rules, **buyer overshoot refused, over-budget refused**, Chainlink minimum on the swap, vault slippage, keeper minOut, removed ticker |
| IndexFeeSplitter | 11 | fee-free redeem, 50/50 split, oracle floor, buy-and-burn, caps, zero `minChipOut` refused, **$CHIP per-call hard limit and 48h raise, daily cap**, keeper remove/add, sweep limits |
| RebalancerDrain | 4 | **the self-review's 48-trade ping-pong now reverts**; small ping-pong reverts; a stolen keeper playing by the rules for a day loses 0.03% of NAV; a rogue Rebalancer installed via the timelock is stopped by the vault at 0.074% (cap 0.10%) per day |
| TinyRoundTrips | 1 | 2,000 mint→redeem loops of ≤0.001 token: NAV per token never falls; nobody gets more stock out than in |
| PendingChanges | 2 | every waiting timelocked change is listed onchain (`pendingChanges`) until executed or cancelled; expired entries stay listed; re-queue does not duplicate |
| Invariants | 3 | §3 items 3 and 4, plus full redeem always succeeds, with random issuer seizures (0–100%) in the mix: 64×100 calls by default, 512×500 in the `deep` profile (passed at 256,000 calls) |
| Credit invariants | 4 | **12 creditors, repeated seizures, tiny credits (to 1 wei), claims in random order**: paid + owed ≤ credited per stock; balance covers books; credits add up; everyone can claim and redeem everything |
| Hostile Rebalancer | 5 | **an attacker's Rebalancer contract** trying every trade shape, re-entry, wrong-token payment, price moves: loss ≤ 0.10% of NAV per window and ≤ 0.20% per 24h; no re-entry; books covered; worst case $49.99/window, $99.93/24h at $50k NAV |

**Base mainnet fork (real B20s, feeds, Aerodrome, $CHIP v4 pool, ChipBurner): 40 passed, 0 failed.**
`./script/fork-test.sh` (base-forge)

| Test | Result |
|---|---|
| Precompile canary (3) | real state readable, real transfer, multiplier 1.000538 |
| Deploy script + Safe seed batch | launch config verified (incl. the real launch basket passing every authenticity check); seed spent $1,000.59 → NAV $10.00/token |
| Basket authenticity (real chain) | a plain ERC-20 named MSFTc, NVDA with MSTR's feed, and a look-alike feed naming Chainlink's owner are all refused; the genuine basket queues |
| Copycat B20 (real chain) | a REAL B20 made through Base's factory with MSFT's name, symbol, decimals, policy 5 and Coinbase's role holders passes the factory, role and OracleRegistry checks, and is refused (`NotCoinbaseIssued`) because Coinbase's TokenSupplyManager never registered it |
| VerifyDeployment script (2) | real deploy script on the fork: 150 PASS / 0 FAIL; five planted problems give exactly 5 FAIL lines |
| In-kind mint/redeem | real B20 delivered; in-kind redeem ~416k gas incl. blocklist check |
| Cash USDC mint/redeem | $99.95–$100.00 for 10 tokens; $97.86–$97.91 back for 9.9 |
| Cash ETH mint | 0.0408–0.0415 ETH for 10 tokens |
| Stale feed | cash mint refused; in-kind redeem works |
| Blocklist (6) | receiver, caller, credit holder, cash caller/recipient refused; claim refused until lifted; lifted restores |
| Vault blocklisted | mint refused up front; all 8 redeem legs credited, shares burned |
| Paused token | mint refused up front (`StockPaused`); 7 legs delivered, NVDA credited, claimed after unpause |
| Multiplier ×10 | balances, books, NAV, redeem amounts unchanged |
| Rebalance | NVDA sold into all 7 underweights, none past target: drift 4.95 → 0.25 points; NAV $1,060.00 → $1,060.08 |
| Rebalance swap minimum | the exact Chainlink `amountOutMinimum` reaches the real Aerodrome router (`expectCall`); with a feed 3% off the router itself refuses; real fill 0.04418 MSTR vs minimum 0.04374 (a trade sized to 90% of MSTR's gap) |
| Seizure with a credit outstanding | half the vault's NVDA removed: held and alice's credit both halve (0.16469535 → 0.08234767 NVDA); claim and full redeem succeed |
| Fee pipeline (1 year) | 3% minted; $14.55 to Pot; ~20.2M $CHIP bought and burned; supply fell by exactly that |
| Small cash mints (4) | see table below; unspent ETH refunded |
| Tiered mints (4) | $10k and $50k with USDC and with ETH: 0.75% and 0.5% charged exactly; every stock leg within the 1% limit (table below) |
| Contract wallets (6) | real Coinbase Smart Wallet v1.1 and Safe v1.4.1 created with the official Base factories: ETH and USDC mint + redeem, in-kind redeem; refunds arrive as ETH; an ETH-rejecting contract gets WETH (see below) |

Small cash mints, with gas at 0.006 gwei (live 2026-10-12):

| Mint | Paid | Index tokens received | Mint fee | Gas | Gas in $ |
|---|---|---|---|---|---|
| $20 USDC | 20.018 USDC | 1.98 | 0.02 tokens ($0.20) | 2.41M | $0.036 |
| $5 USDC | 5.004 USDC | 0.495 | 0.005 tokens ($0.05) | 2.41M | $0.036 |
| $20 ETH | 0.008071 ETH ($20.01) | 1.98 | 0.02 tokens ($0.20) | 3.01M | $0.045 |
| $5 ETH | 0.002018 ETH ($5.00) | 0.495 | 0.005 tokens ($0.05) | 3.01M | $0.045 |

Tiered cash mints (fork 2026-10-13, test vault with a 1,000,000-token cap; the launch cap is not
changed). "Leg cost" is what each stock cost versus its Chainlink value, pool fee included. That is
the number the router holds to 1% per leg (`MAX_LEG_SLIPPAGE_BPS`). Negative means it filled better
than Chainlink.

| Stock | USDC $10k | USDC $50k | ETH $10k | ETH $50k |
|---|---|---|---|---|
| NVDA | 0.11% | 0.11% | 0.21% | 0.21% |
| MSTR | −0.26% | −0.25% | −0.17% | −0.15% |
| GOOGL | 0.40% | 0.41% | 0.50% | 0.51% |
| AMZN | 0.12% | 0.13% | 0.21% | 0.23% |
| AAPL | 0.47% | 0.47% | 0.57% | 0.58% |
| META | 0.14% | 0.15% | 0.24% | 0.25% |
| TSLA | −0.04% | −0.03% | 0.05% | 0.07% |
| MSFT | 0.37% | 0.39% | 0.47% | 0.50% |
| **Worst leg** | 0.47% | 0.47% | 0.56% | 0.58% |
| Paid | 10,016 USDC | 50,086 USDC | $10,026 of ETH | $50,136 of ETH |
| Mint fee | 0.75% ($75) | 0.5% ($250) | 0.75% ($75) | 0.5% ($250) |

None came within 0.4 points of the 1% limit. Going from $1,250 to $6,250 per leg moved the cost by
at most 0.03 points, so at these sizes the cost is mostly the pool fee, not price impact. The ETH
route costs about 0.1 point more because it also crosses the WETH/USDC pool. Source:
`test/fork/MintTierFork.t.sol`, run with `-vv`.

**Measured on the fork:**
- Nothing blocks small cash mints; a $0.01 USDC mint also worked in a one-off probe. Gas does not
  depend on size (8 swaps), so it weighs most on the smallest mints.
- **Contract wallets.** On a $20 mint, both the Coinbase Smart Wallet and the Safe paid 0.008017 ETH
  (or 20.03 USDC). The unspent ETH came back as ETH, with no WETH and no reverts. A redeem returned
  0.007845 ETH (or 19.61 USDC). The Router held nothing afterwards. The Smart Wallet is driven by its
  owner calling execute/executeBatch. Through a 4337 bundler the wallet makes the same call, so the
  Router sees the same caller. The Safe is a 1-of-1 driven through execTransaction. If a contract
  cannot accept ETH at all, the refund or payout is sent as WETH instead (EthPaidAsWeth event).
- Fork wallets are checked to have no code. The default `makeAddr("alice")` address carries an
  EIP-7702 delegation on Base mainnet that forwards received ETH, which once made the router's
  correct ETH refund look missing.
- $CHIP buy cost versus spot: $1 0.38% · $25 0.45% · $50 0.52% · **$100 0.68%** · $250 1.13%.
- Aerodrome WETH/USDC tick spacing 50 is the deepest pool ($1.8M USDC + 2,514 WETH).
  Stock/USDC pools (tick spacing 10) held $0.4M–$1.5M USDC each.

**How issuer actions are simulated on the fork:** blocklisting is done by impersonating the real
policy-5 admin (an EOA) through `PolicyRegistry.updateBlocklist`. Pause and multiplier changes grant
roles by writing the token's role slot at the layout base-std documents, then assert `hasRole`.
Feed prices are always the real values; only `updatedAt` is refreshed so the suite also runs on
weekends.

## 7. Specific questions for the reviewer
1. Redeem leg failure handling: a gas-capped `call` per leg (`REDEEM_LEG_GAS` = 250k) with a
   `gasleft` guard. Any way to force a leg into a credit when the token would have accepted it?
2. `sync` is permissionless in both directions. Any manipulation path?
3. The blocklist check dedupes policy ids across 8 tokens × 3 scopes. Is it correct for inverted
   ids and composite policies?
4. The v4 unlock-callback swap in IndexFeeSplitter: does the full-fill check plus the price limit
   behave correctly with the Doppler hook's dynamic fee?
5. Management fee as per-second minted shares: rounding or accrual-ordering issues around a management-fee change (`_applySetting` accrues first)
   and `executeFeeRecipient`?
6. Tiered mint fee: `mintFeeFor` prices the mint with `try this.navUsd()` (an external self-call)
   and falls back to the base rate on any revert. Can a minter push the priced value across a
   threshold cheaply (for example by donating to the vault and calling `sync` first), and is the
   fallback sound? (Starving the inner call of gas only makes the minter pay the higher rate.)
7. `IndexRouter._sendEth` forwards all gas and falls back to WETH on failure. The recipient is always
   the payer (refund) or a caller-chosen `to` (redeem). Is there any grief or reentrancy path? The
   Router is `nonReentrant` and holds nothing between calls.
8. **New in round 2.** `lib/Settings`: is there any setting whose "lower is tighter" default is
   wrong (a lower value that costs holders money), or any way to reach a loosening change without
   the 48h queue?
9. The vault's 24h trade window opens at the first trade after the previous window expired, so in
   any 24 hours a rogue Rebalancer can use at most two windows' allowance (0.20% of NAV) back to
   back. Acceptable, or should the window be rolling?
10. Rebalancer: overshoot is checked on Chainlink weights after each trade with exact (rounded-down)
    weights, and the per-rebalance budget is the overweight measured once at the start. Any
    sequence of trades that still nets a loss beyond 0.75% of the overweight, or that can be
    repeated without the drift first rising above 3 points again?
11. BasketRegistry authenticity: the feed check trusts `extcodehash` plus `owner()` of the
    launch feeds (Chainlink proxies, two-step ownership). Can a contract match both without being
    a Chainlink-owned proxy?
12. **New in round 3.** BasketRegistry now requires Coinbase's TokenSupplyManager
    (`0xD1Ca…664C`, an upgradeable Coinbase proxy) to list every added stock. Is trusting that
    register (instead of only the Safe's off-chain check) the right call, and is failing closed
    (no new stock can be added if Coinbase moves it, until a 48h settings change) acceptable?
13. **New in round 3.** `Timelock.pendingChanges()` keeps an onchain list of waiting changes
    (swap-and-pop on execute/cancel; expired entries stay until cancelled). Any way to desync the
    list from `executableAt`?

## 8. How to rebuild and re-run everything

The review zip has no `lib/`, `out/`, `cache/` or `.git`, so dependencies are installed first.
Tested from a clean unzip on Ubuntu (WSL) on 2026-10-13, with a fresh HOME (nothing preinstalled): every
step below passed. Needs `git` and `curl`.

Forge 1.8.x reports each invariant suite as ONE test, with its invariants listed inside it, so its
unit count reads lower than forge 1.7.x (147). Every invariant still runs.

**1. Foundry (stock) for build, unit and invariant tests.**
```
curl -L https://foundry.paradigm.xyz | bash      # installs foundryup
foundryup                                        # stock forge/cast/anvil (tested with forge 1.7.1 and 1.8.5)
```

**2. Dependencies, pinned to the exact commits in `foundry.lock`.**
```
cd chip-index
forge install --no-git \
  foundry-rs/forge-std@v1.17.0 \
  OpenZeppelin/openzeppelin-contracts@v5.1.0 \
  base/base-std@6a249339bdeab7a51a4a6d66819bd3e639032dd5
```

**3. Build and unit/invariant tests** (no network needed).
```
forge build --sizes
forge test --no-match-path "test/fork/*"          # expect 147 passed (forge 1.7.x); fewer lines on 1.8.x
FOUNDRY_PROFILE=deep forge test --no-match-path "test/fork/*" --match-path "test/invariant/*"   # optional, ~8 min
```

**4. base-forge for the Base fork tests.** Stock forge cannot run them: a B20 stock is a Base
precompile, whose code is the single byte `0xef` to stock forge. Base publishes its own Foundry
build (`base/base-anvil`) with its own installer script. Saved under the name `base-foundryup` it
installs ONLY the Base build, as `base-forge` / `base-anvil` / `base-cast`, and leaves the stock
`forge` alone:
```
mkdir -p ~/.foundry/bin
curl -fsSL https://raw.githubusercontent.com/base/base-anvil/HEAD/foundryup/foundryup \
  -o ~/.foundry/bin/base-foundryup
chmod +x ~/.foundry/bin/base-foundryup
~/.foundry/bin/base-foundryup --install v1.1.0   # base-anvil v1.1.0, the release these tests used
~/.foundry/bin/base-forge --version               # forge 1.6.0-v1.1.0
```
Do NOT use stock `foundryup --network base`: the current stock foundryup has no `--network` option
and silently installs plain Foundry 1.1.0 instead (checked 2026-10-13). `base-forge` is a
wrapper that runs the Base build with `FOUNDRY_BASE=true`.

**5. Fork tests** (40, against live Base mainnet state, ~3 minutes).
```
export BASE_RPC_URL=https://mainnet.base.org     # or your own Base RPC; the public one works but is slow
./script/fork-test.sh                             # expect 40 passed
./script/fork-test.sh --match-contract MintTierForkTest -vv   # the per-stock slippage logs in §6
```
Fork results depend on live pool and feed state, so dollar figures will differ slightly from §6.

## 9. Files to read
`docs/REVIEW_RESPONSE.md` (review rounds 1–3) · `docs/SPEC.md` (decisions) · `docs/ASSUMPTIONS.md` (trust model) · `docs/DEPLOY.md` (procedure) · `docs/MIGRATION.md` (the vault is not upgradeable; how users would move) ·
`script/Deploy.s.sol` (`LaunchConfig` and `Addrs` blocks hold every launch value and address) ·
`script/VerifyDeployment.s.sol` (read-only post-deploy check).
