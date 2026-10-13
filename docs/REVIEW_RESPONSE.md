# Chip Index — response to the independent reviews

**Date:** 2026-10-13. **Reviews:** ChatGPT (findings 1–2, plus 7 questions) and Bankr (M-1, M-2,
L-1, L-2, L-3). Nothing is deployed or pushed. Every change below is in local commits only.

> **Reviewer IDs still to be matched.** The review texts have not been received yet (they were
> not attached to either instruction, 2026-10-13). Each issue below is listed as the owner's instructions described it. The table in §1
> leaves an empty slot to record which reviewer ID (ChatGPT 1/2, Bankr M-1/M-2/L-1/L-2/L-3) each
> issue answers. Fill it in from the review texts before sending this back. Any ID that matches
> none of these issues still needs its own row.

## 1. Status of every issue

| # | Issue | Reviewer ID | Status |
|---|---|---|---|
| A | Credits become insolvent after an issuer seizure: `sync` wrote the whole loss onto index holders and left `totalOwed` untouched | _to fill_ | **Fixed** (§2) |
| B | `BasketRegistry.prune` could drop a token that the vault still owes in credits | _to fill_ | **Fixed** (§3) |
| C | `Rebalancer.onRebalanceTrade` swapped with `amountOutMinimum: 0` | _to fill_ | **Fixed** (§4) |
| D | The $50k tier rate (0.5%) equals Chainlink's 0.5% deviation threshold: can someone mint at a stale-low NAV and profit? | _to fill_ | **Not exploitable; accepted by design** (§5) |
| E | Can donations plus `sync()` move a mint into a cheaper fee tier profitably? | _to fill_ | **Not profitable; accepted by design** (§6) |
| F | Does the keeper send a live-quoted `minChipOut` to `buyAndBurn`, never 0? | _to fill_ | **Fixed in the contract** (0 now reverts); the keeper script is not written yet (§7) |
| Q1–Q7 | The 7 reviewer questions (REVIEW_PACKAGE §7) | ChatGPT questions | Answered in §8 |
| G | Self-review item 4: a stolen keeper key can drain the vault through Rebalancer ping-pong | self-review | **Fixed** (§10.1) |
| H | Self-review item 11: Safe powers that could cost holders money were instant | self-review | **Fixed** (§10.2) |
| I | Self-review item 10: `` buys had no hard per-call limit and no daily cap | self-review | **Fixed** (§10.2) |
| J | Self-review item 3: no explicit mint stop while a stock is paused or the vault is blocklisted | self-review | **Fixed** (§10.3) |
| K | Self-review item 9: adding a stock checked nothing about the token or the feed | self-review | **Fixed**, one residual documented (§10.4) |
| L | Self-review item 7: the 2,000 tiny mint/redeem loop was not a permanent test | self-review | **Fixed** (§10.5) |

## 2. Fix A — credits share a seizure pro-rata (IndexVault)

**Problem.** An undeliverable redeem leg becomes a credit (`owed`, `totalOwed`). If the issuer then
seized stock from the vault, `sync` set `held = balance − totalOwed`. All of the loss fell on index
holders while credit holders kept 100%. If the seizure was larger than `held`, the credits alone
exceeded the balance and the last claimers could not be paid.

**Fix.**
- Credits are now **shares of one pool per token**. One account's credit =
  `shares × totalOwed / totalOwedShares`, rounded down. `totalOwed / totalOwedShares` is the
  per-token scaling factor, so writing down `totalOwed` writes down every account at once, lazily,
  with no loop over accounts.
- `sync` on a shortfall (`balance < held + totalOwed`) scales both books by the same factor:
  `held' = floor(held × bal / (held + owed))` and `totalOwed' = floor(owed × bal / (held + owed))`.
  Both round down, so `held + totalOwed ≤ balance` after every sync. A donation (balance above the
  books) still goes to index holders only, as before.
- New credits buy pool shares at the current scale, rounded down, so they never dilute existing
  credit holders, and the write-down never touches them retroactively.
- **100% seizure:** `totalOwed` becomes 0, the pool's shares are retired and `owedEpoch[token]`
  moves on. Old shares are worth 0 and new credits start a fresh pool at full value.
- `owed(account, token)` is now a view with the same signature, so the Router, the FeeSplitter and
  any UI read it unchanged. New public views: `totalOwedShares`, `owedEpoch`. New event:
  `CreditsWrittenDown(token, oldTotalOwed, newTotalOwed)`.

**Tests (unit, all pass).**

| Test | What it proves |
|---|---|
| `test_seizure_smallerThanTotalOwed` | seizure of half the credits: held and every credit shrink by the same fraction; everyone is then paid in full |
| `test_seizure_largerThanTotalOwed` | seizure of 1.5× all credits: credits are written down rather than wiped, and index holders are not over-charged |
| `test_seizure_everything` | 100% seizure: held 0, credits 0, epoch +1, claim reverts `NothingOwed` |
| `test_seizure_everythingThenNewCredits` | after a wipe-out, a new credit is worth its full amount; the old one stays 0 |
| `test_seizure_multipleInARow` | three seizures, with a new credit between the first and second: no dilution either way; alice keeps the same share of the pool |
| `testFuzz_seizuresKeepCreditsSolvent` | any 3 seizures (0–100%) with a credit in between: `held + totalOwed ≤ balance`, credits ≤ `totalOwed`, all claims and full redeems succeed (512 runs) |
| Invariant handler `seize` | random seizures of 0–100% mixed with mints, redeems, pauses, claims and time jumps: `balance ≥ held + totalOwed` and `Σ owed ≤ totalOwed` (gap ≤ 5 units of rounding) |
| Fork `test_fork_seizureWithOutstandingCredit` | real NVDA precompile: a credit is outstanding when half the vault's NVDA leaves; `sync` halves held and the credit; claim and full redeem succeed |

Note on the fork test: the live B20 release behind base-anvil v1.1.0 rejects `SEIZE_ROLE()`,
`SEIZE_EXEMPT_POLICY()` and `seizeWithMemo` (custom error `0xf916d81b`), so the fork test moves the
stock out of the vault with a transfer pranked as the vault. That has the same effect on the
vault's balance as a seizure. The mock token has a real `seize` that ignores pause and blocklist.

**What the invariant really says.** `held + totalOwed ≤ balance` holds after every `sync`. Between
a seizure and the next `sync`, the books are ahead of the balance. Nothing can hook a seizure, and
`sync` is permissionless so anyone can close that window. The invariant handler models that as
seize-then-sync.

## 3. Fix B — prune refuses outstanding credits (BasketRegistry)

- `prune` now also reverts `StillOwed(token, totalOwed)` when the vault's `totalOwed[token]` is
  not 0. `totalOwed` is read through the registry's vault interface (`IHoldings`).
- The same gap existed one step earlier: `executeBasket` only carried over dropped tokens that were
  still **held**. It now also carries over tokens that are still **owed**, at weight 0. Otherwise a
  basket change could unlist a token with credits outstanding, and `sync` (listed tokens only)
  could no longer write those credits down.
- Test `test_pruneRefusedWhileCreditsOutstanding`: credits outstanding and nothing held. The basket
  change keeps the token listed, `prune` reverts `StillOwed`, and once every credit is claimed
  `prune` succeeds.

## 4. Fix C — the rebalance swap carries a Chainlink minimum (Rebalancer)

- `onRebalanceTrade` now computes
  `minOut = amountForUsd(tokenOut, valueUsd(tokenIn, amountIn) × (1 − vault.maxTradeSlippageBps))`
  from Chainlink (both feeds must be fresh, or it reverts) and passes it as `amountOutMinimum`. A
  bad fill now reverts inside the Aerodrome router itself.
- The vault-level check (`TradeValueLoss`) and the keeper's own `minOut` are unchanged and still
  apply after the callback.
- Unit `test_rebalance_swapCarriesChainlinkMinimum`: the minimum sent equals the Chainlink figure.
  A fill 1.5% below Chainlink fails in the swap router with "Too little received", and 0.9% fills.
- Fork `test_fork_rebalanceSwapHasChainlinkMinimum`, on real Aerodrome:
  - `vm.expectCall` proves the exact `exactInput` parameters, including the minimum, reach the
    real router.
  - With MSTR's feed made to read 3% low, the real router refuses the fill.
  - With real prices the trade fills. Measured: minimum 0.32320197 MSTR, received 0.32705759 MSTR.

## 5. Check D — a stale-low (or stale-high) NAV at the $50k tier

**Answer: no profit is possible.** NAV is never used to decide how many index tokens a mint gets.

- In-kind mint is pure pro-rata: `amount_i = ceil(held_i × shares / supply)`. The same stock in
  gives the same shares out, whatever the feeds say.
- Cash mint (USDC or ETH) buys those exact stock amounts in the market at the real pool price, then
  does the same in-kind mint. A wrong feed only moves the router's 1% per-leg ceiling. That ceiling
  protects the minter; it never changes what the vault receives.
- The only thing NAV picks is the **fee rate**.
  - A feed reading up to 0.5% **low** pushes a mint into a lower tier, so the minter pays a higher
    fee and loses.
  - A feed reading up to 0.5% **high** lets a mint truly worth at least $49,751 (or $9,951) price
    at the next tier.
  - The most anyone can save is 0.25 points on ~$50k (about $125), or 0.25 points on ~$10k (about
    $25). Paying the honest threshold amount gets the same rate anyway, and the extra deposit is
    kept as index tokens. So this is a ≤0.5% blur of the tier boundary, not a way to take value
    from holders.
- Any feed older than 26h, or a sequencer outage, already drops the mint to the base 1% rate.
- Test `test_stalePriceOnlyMovesTheTierBoundary`: all 8 feeds 0.5% high. The stock needed for the
  mint is identical, and a $49,800 mint moves from 0.75% to 0.5%.
- At the launch cap (2,500 tokens = $25k) the $50k tier cannot be reached at all.

**Recommendation:** no change. If the Safe wants zero blur, it can set each threshold 0.5% higher
through the 48h timelock (e.g. $10,050 / $50,250).

## 6. Check E — donation plus `sync()` to reach a cheaper tier

**Answer: never profitable.** The donation raises the price of every share, including the shares
the attacker is about to mint. Their deposit grows by the same proportion, and the whole donation
ends up with the holders who were already in the vault.

Measured (`test_donationToReachTier_costsMoreThanItSaves`, ~$101k already in the vault):

| | Honest $50k mint at 0.5% | Attack: $49k of shares + donation + `sync` |
|---|---|---|
| Donation | — | $2,062.22 |
| Attacker's net loss (spent − value of tokens received) | $250.00 (the fee) | $2,312.23 |
| Fee saved versus a $49k mint at 0.75% | — | $117.50 |

The attack loses about $2,062 more than minting honestly. A donation needed to move the price by x%
costs x% of the whole vault, while the most it can save is 0.25 points on the attacker's own mint.
So it loses more as the vault grows. `sync` in the other direction (a seizure write-down) only
lowers NAV, which raises fees.

## 7. Check F — `minChipOut` for `buyAndBurn`

- **There is no keeper script for Chip Index in this repo yet.** The fork tests call
  `buyAndBurn(budget, 1, …)` by hand. So there was nothing to confirm, and this must be built
  before launch.
- **Contract change (defence in depth):** `buyAndBurn` now reverts `ZeroMinChipOut` when
  `minChipOut == 0`. Even a broken keeper cannot send 0. Unit test: `test_buyAndBurn_limits`.
- **Keeper requirement (recorded in DEPLOY.md §5):** before each call, quote the same route live and
  set `minChipOut = quote × (1 − 1%)`. The route is USDC→WETH on Aerodrome (tick spacing 50), then
  WETH→$CHIP on the v4 pool. The simplest quote is an `eth_call` of `buyAndBurn` itself from the
  keeper address with `minChipOut = 1`, reading the returned `chipOut`. Send within the same few
  blocks, keep the $100 cap, and abort if the quote is more than 2% worse than the last
  successful buy.
- A tiny non-zero floor (for example 1 wei) would still pass the contract check. The live quote in
  the keeper is what actually protects the buy; the per-call $100 cap bounds the worst case.

## 8. Answers to the 7 reviewer questions (REVIEW_PACKAGE §7)

1. **Can a redeem leg be forced into a credit when the token would have accepted it?** No. Each leg
   gets a fixed 250k gas, and the vault first checks that more than 250k × 64/63 + 10k is left, or
   it reverts `NotEnoughGasForLeg`. So a caller cannot starve a leg into failing. A real B20
   transfer costs about 30k (fork). Credits can only come from the token itself refusing (pause,
   blocklist). **Accepted by design.**
2. **Any manipulation path through permissionless `sync`?**
   - Upward (donation): pure gift to existing holders (§6).
   - Downward (shortfall): it can only record a loss that already happened on the token. It now
     shares that loss with credit holders instead of putting it all on index holders (Fix A).
   - `sync` cannot be used to inflate any book above the balance.
   - **Fixed** (the credit part); otherwise by design.
3. **Is the deduped blocklist check correct for inverted ids and composite policies?** Yes. It
   dedupes on the policy **id** and asks the PolicyRegistry `isAuthorized(id, account)` for each
   distinct id. The registry resolves inverted (allowlist) and composite policies itself, so the
   vault never interprets policy types. **Accepted by design.**
4. **v4 swap with the Doppler hook's dynamic fee?** `buyAndBurn` checks the full fill and the
   price limit, and requires `chipOut ≥ minChipOut`, which may no longer be 0. On the fork:
   - The $100 cap measured 0.68% versus spot.
   - The fee pipeline test bought and burned $CHIP through the live hook.
   - The keeper's live quote (§7) absorbs the hook's fee changes.
   **Fixed** (non-zero floor); otherwise by design.
5. **Management-fee rounding or ordering around a fee change / `executeFeeRecipient`?** Both call
   `_accrue()` first, so the old rate applies up to that moment and fees earned so far go to the
   old recipient (`test_mgmtFeeChange_accruesAtOldRateFirst`). Accrual rounds down; `previewMint`,
   `previewRedeem` and `mintFeeFor` all include the pending fee in supply. **Accepted by design.**
6. **Can a minter cheaply cross a fee threshold (donation + `sync`), and is the `try` fallback
   sound?**
   - Crossing: not profitably (§5, §6).
   - Fallback: any revert inside `this.navUsd()` (stale feed, sequencer down, or a gas-starved
     inner call) charges the base 1% rate. Every failure mode makes the minter pay more, never
     less.
   - **Accepted by design.**
7. **Grief or reentrancy through `_sendEth`?**
   - The Router is `nonReentrant` and holds nothing between calls; every amount is computed before
     the send.
   - The recipient is the payer (refund) or the caller's chosen `to` (redeem payout).
   - A recipient that reverts gets WETH instead, so it can only fail its own payout to plain ETH,
     never block the transaction or anyone else.
   - Forwarding all gas only lets the recipient spend its own transaction's gas.
   - Tested with a real Coinbase Smart Wallet, a Safe, and an ETH-rejecting contract.
   - **Accepted by design.**

## 9. Test counts after the fixes (2026-10-13)

- **Unit + invariant (mocks): 115 passed, 0 failed** (was 105).
  - +6 seizure tests in IndexVault (5 tests and 1 fuzz).
  - +1 prune test in BasketRegistry.
  - +1 rebalance minimum test.
  - +2 tier checks in MintFeeTiers.
  - The invariant handler now also seizes.
- **Base mainnet fork (real B20s, base-forge): 36 passed, 0 failed** (was 34).
  - +1 real Aerodrome rebalance minimum test.
  - +1 seizure with an outstanding credit.

## 10. Pre-round-2 hardening (owner instruction, 2026-10-13)

### 10.1 Rebalancer drain (self-review item 4)

**Before:** one rebalance of 48 NVDA↔MSTR ping-pong trades lost $101.77 (9.7%) of a $1,049 test vault
and left it eligible to repeat, so a stolen keeper key could empty the vault in minutes.

**Now, in the Rebalancer:**
- No trade may push either stock past its target. After every trade the seller must still be at
  or above target and the buyer at or below (`Overshoot`). Something sold can therefore never be
  bought back, so ping-pong is impossible by construction.
- The Chainlink value sold in one rebalance is capped at the basket's total overweight in dollars,
  measured when the rebalance starts (`OverTradeBudget`).
- Unchanged: sell only overweight, buy only underweight, total drift must fall, eligible only at
  more than 3 points of drift or after 30 days.

**Now, in the vault (binds this and ANY future Rebalancer):**
- Max trade slippage tightened from 1% to **0.75%** (hard cap lowered from 2% to 1%). On the fork,
  real Aerodrome rebalances filled at or better than Chainlink, so 0.75% blocked nothing.
- **24h caps, proposed numbers:**
  - Trading: **15% of NAV per day** (hard cap 25%). 15% lets the keeper sell off one whole stock
    (12.5%) in a day when the basket changes. A normal 3-point rebalance trades about 3–5%.
  - Value lost (Chainlink value in minus out, gains not netted): **0.10% of NAV per day** (hard
    cap 0.5%). A legitimate 5% rebalance at the measured ~0.1–0.5% cost loses 0.005–0.025% of NAV.
  - The window opens at the first trade after the previous one expired and prices NAV once then.
    In the worst timing a rogue contract can use two windows back to back (0.20% of NAV in one
    24h span); after that, 0.10% per day.
- Lowering any of these is instant (0% slippage stops every trade); raising waits 48h.

**The drain test is permanent** (`test/unit/RebalancerDrain.t.sol`) and must fail:

| Test | Result |
|---|---|
| The self-review's exact 48-trade ping-pong | **reverts** (`OverTradeBudget`); NAV unchanged |
| Small ping-pong, each leg within budget | **reverts** (`NotOverweight`: the stock just bought is never overweight) |
| Stolen keeper, playing by the rules, rebalancing every 10 minutes for a day at the worst allowed fill (0.74%) | 1 rebalance went through, then not eligible: lost $0.32 of $1,049 (0.03%) |
| Rogue Rebalancer installed through the timelock, ignoring every Rebalancer rule | the vault stopped it after 2 trades: lost $0.78 of $1,049 (0.074%, under the 0.10% cap); nothing more that day; next day capped again |

### 10.2 Safe powers (self-review items 10 and 11)

One mechanism in every contract (`src/lib/Settings.sol`):
- `tighten(key, value)` is instant and only accepts a stricter value: a lower cap, fee, slippage
  or feed age, or removing a keeper.
- `queueSetting(key, value)`, then 48h later `executeSetting(key, value)`, for anything else
  within the hard caps. The same 14-day grace and cancel apply as for every other timelock.

Mapping of the owner's list:

| Owner's list | Where | Now |
|---|---|---|
| pause, unpause | vault mint pause; router cash mint/redeem pause | instant (unchanged) |
| removing a keeper | Router, Rebalancer, FeeSplitter | instant (`tighten(SET_KEEPER, 0)`) |
| lowering a cap | all caps, fees, slippages, feed ages | instant |
| redeem fee, management fee | vault | raise: 48h (cut: instant) |
| adding keepers | Router, Rebalancer, FeeSplitter | 48h |
| feed max age | registry (stocks), Router and FeeSplitter (ETH) | longer: 48h (shorter: instant) |
| pool choice | registry: each stock's pool is now part of the basket (48h basket change); Router and FeeSplitter WETH/USDC pool | 48h only, never instant |
| raising the mint cap | vault | 48h |
| `` buy cap | FeeSplitter | raise: 48h; **hard limit $500 per call** (launch $100); new **daily cap $300 per 24h, hard limit $2,000** |

Also moved behind the 48h rule (they could cost holders money): router leg slippage, the vault's
trade slippage and daily caps, the FeeSplitter's sell slippage.

Unit tests: fee cut instant and rise after 48h, mint cap rise after 48h, slippage and daily caps,
max feed age, pool change, keeper remove/add on two contracts, `` per-call hard limit and daily cap.

### 10.3 Mint stops while a stock is paused or the vault is blocklisted (item 3)

`mint` and `seed` now call `_requireMintable()` before anything moves. It reverts
`StockPaused(token)` if any listed stock has TRANSFER paused (`isPaused(0)`, the real B20 call),
and `Blocklisted(vault, token)` if the vault is not authorized on any stock's policies. A public
`requireMintable()` view lets the website show why minting is closed. Unit tests (paused,
blocklisted, nothing moved) and fork checks on the real NVDA precompile and the real policy-5
blocklist.

### 10.4 A new stock must be real (item 9)

Checked on `queueBasket` AND again on `executeBasket`, for every entry, so a fake is refused
even if the Safe queues it:
1. The token is a B20 according to Base's B20 factory precompile (`0xB20f…0000`,
   `isB20Initialized`). A plain ERC-20 fails (`NotB20`).
2. The feed has the same code hash and the same `owner()` as the launch feeds. Onchain, all 8
   stock feeds and the ETH/USD feed are one Chainlink proxy code (hash `0xbd6f…66c2`) owned by
   Chainlink's Base multisig `0xf0Db…5B1b`. A look-alike contract fails on code; a genuine proxy
   deployed by anyone else fails on owner (Chainlink's ownership only moves when the new owner
   accepts) (`UntrustedFeed`).
3. The feed description is `Coinbase <TICKER>` for a token whose symbol is `<TICKER>c`
   (e.g. `NVDAc` / `Coinbase NVDA`) (`FeedDoesNotMatchToken`).
4. The token/USDC pool exists at the chosen tick spacing.

If Chainlink ever migrates its feeds, the trusted owner and code hash can be updated through the
48h timelock only.

**Residual, documented:** the B20 factory proves the token is a B20, not that Coinbase issued it.
Anyone can create a B20 called "NVDAc" through the factory. That fake would pass checks 1, 3 and 4,
and check 2 when paired with Chainlink's real "Coinbase NVDA" feed. Coinbase's issuer address
cannot be read onchain: the tokens emitted no role events at creation, and the policy-5 admin
holds no token role. So the Safe must match the token address against
api.coinbase.com/v1/tokenized-stocks before queueing, and the 48h gives everyone else the same
chance. Tests: 4 unit tests (fake token, untrusted owner, look-alike code, wrong pairing, re-check
at execute) and one fork test on the real chain (fake ERC-20, NVDA with MSTR's feed, look-alike
feed naming Chainlink's owner; the genuine basket passes).

### 10.5 2,000 tiny round trips (item 7)

`test/unit/TinyRoundTrips.t.sol`: 2,000 mint→redeem loops of up to 0.001 index token (about
$0.01). NAV per token started at $9.99999983 and never went below that (lowest seen $10.00000018,
since rounding always leaves dust in the vault). No user got more of any stock out than they put
in. (`foundry.toml` now allows 4B gas per test; this one uses 1.37B.)

## 11. Worst case for a stolen keeper key (launch settings, $25,000 NAV)

The keeper key is used by three contracts. Until the Safe removes it (instant, one transaction):

| Contract | What a thief can do | Worst case |
|---|---|---|
| Rebalancer | Only rebalances that obey the rules above, at the worst allowed fill (0.75%) | ~0.03% of NAV per eligible episode ($7.50 at $25k), then nothing until drift exceeds 3 points again or 30 days pass. Hard ceiling enforced by the vault: **$25 per 24h window** (0.10%), at most $50 if two windows fall in one 24h span. Chainlink can lag the market by up to 0.5%, so the true market loss on the traded volume could be up to ~0.05% of NAV more. |
| IndexFeeSplitter | Sell fee stock for USDC (Chainlink floor, 1%), buy `` with a bad `minChipOut` and sandwich it | Fee money only, never holders' stock: at most **$300 per day** of the `` budget ($100 per call). Selling at the 1% floor costs at most 1% of the fee stock sold. |
| IndexRouter | Pause cash mint/redeem | No money: the Safe unpauses, and in-kind redeem never stops |

**Total: about $25–50 of holders' value per day plus up to $300 per day of fee money**, versus
"most of the vault within minutes" before. Holders' share scales with NAV (0.10% per day); the
fee-money cap does not.

## 12. Test counts after the pre-round-2 hardening (2026-10-13)

- **Unit + invariant (mocks): 134 passed, 0 failed** (was 115; forge 1.8.x shows 132).
  - New: 4 drain, 1 tiny-loop, 3 mint-stop/mint-cap, 5 registry authenticity/settings,
    2 router settings, 3 splitter caps/keeper.
  - Rebalancer tests now send keeper-sized trades (none past target), plus buyer-overshoot and
    over-budget refusals.
- **Base mainnet fork: 37 passed, 0 failed** (was 36).
  - New: basket authenticity on the real chain.
  - Added to existing tests: mint refused up front on a real paused stock and with the real
    blocklist.
  - The deploy rehearsal now also proves the real launch basket passes every authenticity check.
  - Both rebalance tests now spread the sale over all 7 underweight stocks.