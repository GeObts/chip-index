# Chip Index — assumptions, trust and open decisions

Facts below were verified onchain or against Coinbase/Base sources on 2026-10-12.

## A-1 Prices
- Value = raw B20 balance × Chainlink price. The Coinbase feeds ("Coinbase NVDA", ...) are
  *total-return*, so they already include the B20 dividend multiplier (Coinbase API `multiplier`
  equals onchain `multiplier()`, e.g. NVDA 1.000538). The fork test `test_fork_multiplierChange`
  proves a 10-for-1 multiplier change leaves balances, books, NAV and redeem amounts unchanged.
- Feeds update on a 0.5% move or a 24h heartbeat, 24/5, and freeze nights, weekends, holidays and
  corporate actions. "Stale" = `updatedAt` older than `maxFeedAge` (default 26h, settable 1h–72h).
  On a weekday some feeds were 9h old with markets open, so a tight limit would block normal use.
- Rebalancing and fee selling need fresh feeds and a live sequencer (Base sequencer uptime feed,
  1h grace). Cash mint/redeem need only the live sequencer: they run 24/7, within 1% of Chainlink
  when every feed they read is fresh, else within 10% of the last Chainlink price (at most 7 days
  old) plus the user's own limit (owner decision 2026-10-14). **In-kind mint and redeem never read
  a price**, so a bad cash fill only costs that user, never holders.
- 1 USDC is treated as $1 in the Router.

## A-2 In-kind mint/redeem are pro-rata
Mint pays `ceil(held × shares / supply)` of each stock and redeem returns `floor(...)`, so rounding
always favours existing holders. The fuzz tests check that a mint-then-redeem round trip never profits.

## A-3 Redeem can never be paused
Redeem has no pause flag and no oracle or freshness check. The only owner levers on the vault are
mint pause, mint cap, fee rates (hard-capped), trade limits, and 48h-timelocked changes of the
rebalancer and fee recipient. Every setting that could cost holders money (raising a fee, cap or
limit, adding a keeper, choosing a pool, a longer feed age) waits 48h; only stricter values are
instant (`lib/Settings`). A stock leg that cannot be delivered is credited to `creditTo` and claimable later with
`claimOwed`.

## A-4 Coinbase (issuer) powers, which no contract can remove
- All 8 tokens share Coinbase blocklist **policy 5** on the SENDER, RECEIVER and **EXECUTOR**
  scopes (admin `0xEC0F05C1…2812`). If Coinbase blocklists the vault, **all 8 stocks freeze at
  once**. Redeems still burn and credit, and the credits pay out if the block is lifted.
  `test_fork_blocklistedVault`.
- The issuer can pause transfers per token (`test_fork_pausedToken`) and can seize from any holder,
  the vault included. A seizure is written down pro-rata for index holders and credit holders
  alike (credits are shares of a per-token pool, so every credit scales at once). The write-down
  happens automatically at the start of every mint, redeem, claim and rebalance trade, so nobody
  needs to call `sync` first (ChatGPT F-01); `sync` is still how a donation is folded in.
- Base's **Denim** upgrade (official: Sepolia October 21, 2026; mainnet "planning, November
  2026", docs.base.org/upgrades/denim/overview) applies `TRANSFER_EXECUTOR_POLICY` to plain
  `transfer` too. Checked onchain 2026-10-13: on all 8 stocks the SENDER, RECEIVER, EXECUTOR and
  MINT_RECEIVER scopes are all policy 5, a BLOCKLIST (type byte 0, no child policies). For a plain
  `transfer` the executor is the sender, so Denim asks policy 5 the same question it already asks
  for the sender: nothing changes for our contracts while they are not blocklisted. It would only
  matter if Coinbase pointed the executor scope at a different, allowlist-style policy; then every
  contract here, and every DEX pool, would stop moving stock. Denim also makes a send to the
  token's own address revert: a redeem to such a receiver is credited, not lost.
- Seizure needs two steps by Coinbase: the seize-exempt scope is policy 129, a BLOCKLIST run by
  Coinbase's token admin `0x3846…72B1`; every address is exempt until Coinbase adds it.

## A-5 Swap venue
All B20 liquidity is on Aerodrome Slipstream (factory B `0xf8f2eB49…61Ef`, router
`0x698Cb2b6…A92F`). Each stock/USDC pool uses tick spacing 10 and held $0.4M–$1.5M of USDC on
2026-10-12. WETH/USDC uses tick spacing 50 ($1.8M USDC + 2,514 WETH). Every leg must fill within 1%
of Chainlink, so pool depth caps how large a single cash mint can be.

## A-6 DECIDED (owner, 2026-10-12): blocklisted accounts cannot redeem
Before every in-kind or cash redeem, the vault checks the caller, the receiver and the credit holder
against every listed stock's SENDER/RECEIVER/EXECUTOR policies through Base's PolicyRegistry
(`isAuthorized`). It reverts `Blocklisted(account, token)` if any of them is blocked by any stock.
Claiming a credit checks the claimant and the destination for that stock. The Router also checks the
cash recipient. Nothing is burned when a redeem is refused.
**Index-token transfers stay unrestricted, by owner decision (2026-10-12).** CHIPX is a plain,
freely transferable ERC-20, with no blocklist check on `transfer`/`transferFrom`. A blocklisted holder
can therefore move index tokens to a clean address that then redeems. This is accepted, to keep the
index token a normal composable ERC-20.

## A-7 Fees
- Mint 1% / redeem 1% (mint every tier capped at 1%, redeem capped at 2%; cuts instant, rises 48h). Taken in index tokens and sent to the IndexFeeSplitter; the
  fee recipient itself redeems fee-free.
- Management fee 3%/yr (cap 5%), accrued per second on every mint/redeem/`accrue` (Base blocks are
  2s) as newly minted index tokens. Continuous minting dilutes holders by about 2.96% of value a year.
- The splitter sends 50% of the USDC to the Pot (`0x3918…855B`) and spends 50% on $CHIP, which goes
  to the ChipBurner (`0x7Bc1…5C0`). $CHIP has no onchain TWAP (the Doppler hook keeps no oracle),
  so each buy is limited by the keeper's `minChipOut` (from a live quote; the contract rejects 0)
  and `maxChipBuyUsdc` per call.

## A-8 Keeper powers
The keeper (`0x6571…95B9`) can rebalance (only within the drift/schedule rules, never pushing a
stock past its target, selling at most the basket's overweight per rebalance, and inside the
vault's 0.75% per-trade and 24h caps of 15% of NAV traded and 0.10% of NAV lost), sell fee stocks
(with a Chainlink floor), buy and burn $CHIP (budget, $100 per call, $300 per 24h),
and pause the Router's cash paths (only the Safe unpauses). It cannot touch user funds, the in-kind
paths, fees, the basket or ownership. Worst case with a stolen keeper key: REVIEW_RESPONSE §11.

## A-9 Basket authenticity
Adding a stock is checked onchain: real B20 (Base's B20 factory), **registered in Coinbase's
TokenSupplyManager** (`0xD1Ca…664C`, `isRegisteredToken`; only Coinbase's admin can register, and
all 145 tokens on Coinbase's list are registered, checked 2026-10-13), Chainlink feed (same code
and owner as the launch feeds), feed description `Coinbase <TICKER>` for symbol `<TICKER>c`, and an
existing pool. A copycat B20 with the same name, symbol, policies and even Coinbase's role holders
is refused (`test_fork_basketRejectsCopycatB20`). The check trusts Coinbase's register (an
upgradeable Coinbase contract), so the Safe still takes addresses from Coinbase's official list,
and `script/VerifyDeployment.s.sol` checks them against it after deploy.

## A-10 Testing
B20 stocks are precompiles: under stock `forge` their code is the single byte `0xef` and every
call fails. The fork suite runs under Base's `base-forge` (base-anvil v1.1.0), which executes the
real precompiles against real fork state. Issuer actions in tests (pause role, operator role) are
granted by writing the token's storage at the slots base-std documents, and each write is checked
with `hasRole`.
