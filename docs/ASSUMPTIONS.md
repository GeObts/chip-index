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
- Cash mint/redeem, rebalancing and fee selling all need fresh feeds and a live sequencer
  (Base sequencer uptime feed, 1h grace). **In-kind mint and redeem never read a price.**
- 1 USDC is treated as $1 in the Router.

## A-2 In-kind mint/redeem are pro-rata
Mint pays `ceil(held × shares / supply)` of each stock and redeem returns `floor(...)`, so rounding
always favours existing holders. The fuzz tests check that a mint-then-redeem round trip never profits.

## A-3 Redeem can never be paused
Redeem has no pause flag and no oracle or freshness check. The only owner levers on the vault are
mint pause, mint cap, fee rates (hard-capped), and 48h-timelocked changes of the rebalancer and fee
recipient. A stock leg that cannot be delivered is credited to `creditTo` and claimable later with
`claimOwed`.

## A-4 Coinbase (issuer) powers, which no contract can remove
- All 8 tokens share Coinbase blocklist **policy 5** on the SENDER, RECEIVER and **EXECUTOR**
  scopes (admin `0xEC0F05C1…2812`). If Coinbase blocklists the vault, **all 8 stocks freeze at
  once**. Redeems still burn and credit, and the credits pay out if the block is lifted.
  `test_fork_blocklistedVault`.
- The issuer can pause transfers per token (`test_fork_pausedToken`) and can seize from any holder,
  the vault included. `sync` writes a seizure down pro-rata for all holders.
- Base's upcoming **Denim** upgrade (no date yet) extends the executor check to plain `transfer`.
  The vault and router are not allowlisted anywhere, so if Coinbase ever switched policy 5 from a
  blocklist to an allowlist, every contract here would stop moving stock.

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
**Index-token transfers stay unrestricted, by owner decision (2026-10-12).** CHIDX is a plain,
freely transferable ERC-20, with no blocklist check on `transfer`/`transferFrom`. A blocklisted holder
can therefore move index tokens to a clean address that then redeems. This is accepted, to keep the
index token a normal composable ERC-20.

## A-7 Fees
- Mint 1% / redeem 1% (cap 2% each). Taken in index tokens and sent to the IndexFeeSplitter; the
  fee recipient itself redeems fee-free.
- Management fee 3%/yr (cap 5%), accrued per second on every mint/redeem/`accrue` (Base blocks are
  2s) as newly minted index tokens. Continuous minting dilutes holders by about 2.96% of value a year.
- The splitter sends 50% of the USDC to the Pot (`0x3918…855B`) and spends 50% on $CHIP, which goes
  to the ChipBurner (`0x7Bc1…5C0`). $CHIP has no onchain TWAP (the Doppler hook keeps no oracle),
  so each buy is limited by the keeper's `minChipOut` and `maxChipBuyUsdc` per call.

## A-8 Keeper powers
The keeper (`0x6571…95B9`) can rebalance (only within the drift/schedule rules and vault-enforced
slippage), sell fee stocks (with a Chainlink floor), buy and burn $CHIP (budget and per-call cap),
and pause the Router's cash paths (only the Safe unpauses). It cannot touch user funds, the in-kind
paths, fees, the basket or ownership.

## A-9 Testing
B20 stocks are precompiles: under stock `forge` their code is the single byte `0xef` and every
call fails. The fork suite runs under Base's `base-forge` (base-anvil v1.1.0), which executes the
real precompiles against real fork state. Issuer actions in tests (pause role, operator role) are
granted by writing the token's storage at the slots base-std documents, and each write is checked
with `hasRole`.
