# Chip Index — independent review package

**Status:** pre-deployment. Nothing is deployed. All results below come from local tests and a
Base mainnet fork (2026-10-12).
**Scope:** `src/` (1,985 lines across 11 files). Out of scope: tests, scripts, and the existing
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
| `IndexVault` | 528 | 18.2 KB | The index token. Pro-rata in-kind mint (rounds up) and redeem (rounds down) with **no oracle**; redeem has **no pause**. Undeliverable legs (issuer pause, vault blocklisted) become claimable credits. Refuses redeem/claim for issuer-blocklisted caller, receiver or credit holder. Mint cap (global), mint pause. Fees: mint/redeem (cap 2%), management (cap 5%/yr, per-second accrual as minted shares). Executes rebalance trades for the Rebalancer and itself enforces Chainlink value-in vs value-out (max 1%, cap 2%). Rebalancer and fee-recipient changes: 48h timelock. |
| `BasketRegistry` | 319 | 10.4 KB | Tokens, feeds and target weights. Launch basket set in the constructor; any later change replaces the whole basket through a 48h timelock with a 14-day grace window. Dropped tokens still held stay listed at weight 0 until `prune`. Chainlink reads: positive answer, `maxFeedAge` (26h default, 1h–72h), Base sequencer uptime with 1h grace. |
| `IndexRouter` | 400 | 15.0 KB | Cash mint (exact-output swaps USDC/ETH→each stock on Aerodrome Slipstream) and cash redeem (exact-input stock→USDC/ETH). User limit plus each leg within 1% of Chainlink. Mint and redeem both require all feeds fresh. Owner or keeper can pause either path; only the owner unpauses. Checks the cash recipient against the blocklist. ETH refunds/payouts forward all gas and fall back to WETH if the recipient rejects ETH, so a contract wallet can never block its own mint or redeem. Holds no balance between calls. |
| `Rebalancer` | 173 | 6.1 KB | Keeper-only. Allowed when any weight drifts more than 3 points from target, or 30 days after the last rebalance. Each trade must sell an overweight and buy an underweight stock, and total absolute drift must fall. Routes stock→USDC→stock on Aerodrome via the vault's callback. |
| `IndexFeeSplitter` | 349 | 11.6 KB | Fee recipient. `redeemFees` (anyone, fee-free) → `sellForUsdc` (keeper, Chainlink floor) → `distribute` (anyone: 50% to the Pot, 50% to `chipBudget`) → `buyAndBurn` (keeper: USDC→WETH on Aerodrome, WETH→$CHIP on the Uniswap v4 pool via unlock callback, then ChipBurner.burnAll). `maxChipBuyUsdc` = $100 per call. `sweep` cannot touch fee-flow tokens or listed stocks. |
| `lib/OracleLib`, `lib/Timelock` | 118 | — | Feed and sequencer checks; generic queue/execute/cancel timelock keyed by `keccak256(action, data)`. |

Every contract is `Ownable2Step`, owned by the Chipworks Safe `0xe1096B72…73C7` from the
constructor. One-time wiring (`wireVault`, `wire`) is callable only by the deploying address and
only once. The keeper is `0x6571E341…95B9`.

## 3. Design invariants to check
1. In-kind redeem can never be blocked by the owner, the keeper, oracles or the sequencer. It is
   blocked only by the issuer's own blocklist, which is deliberate (§5).
2. Mint and redeem rounding always favours existing holders, so a mint→redeem round trip cannot profit.
3. `balanceOf(vault, token) >= held[token] + totalOwed[token]` for every listed token.
4. Sum of `owed[*][token]` equals `totalOwed[token]`.
5. Even a faulty Rebalancer cannot lose more than `maxTradeSlippageBps` of Chainlink value per trade.
6. The Router and FeeSplitter keep no user funds between transactions (apart from the splitter's
   booked `chipBudget`).

## 4. Known Coinbase-side (issuer) risks
These come from the B20 tokens themselves and cannot be removed by any contract.

| Risk | Effect on the index | Handling / test |
|---|---|---|
| **One blocklist for everything.** All 8 tokens bind Coinbase policy **5** to the SENDER, RECEIVER **and EXECUTOR** scopes (admin `0xEC0F05C1…2812`, verified onchain). | If the vault is blocklisted, all 8 stocks freeze together. Redeems still burn and record credits, which pay out if the block is lifted. Mint stops. | `test_fork_blocklistedVault` |
| Issuer **pause** (TRANSFER/MINT/BURN/SEIZE, per token) | A paused stock's redeem leg is credited and claimable later; mint fails while paused. | `test_fork_pausedToken`, `test_redeem_pausedTokenIsCreditedThenClaimed` |
| Issuer **seize** from any holder, including the vault | Loss is written down pro-rata for all holders by permissionless `sync`. | `test_sync_seizureIsWrittenDown` |
| **Multiplier** changes (dividends, splits) | None: balances are raw and the feeds are total-return. | `test_fork_multiplierChange` (10× change) |
| **Feeds freeze** nights, weekends, holidays and corporate actions | Cash mint/redeem, rebalancing and fee selling stop; in-kind paths continue. | `test_fork_staleFeed` |
| **Denim** upgrade (scheduled, no date) applies the executor check to plain `transfer` | The vault and router are not allowlisted. If policy 5 ever became an allowlist, all stock movement would stop. | Documented (ASSUMPTIONS A-4) |
| **Wrapper vs blocklist** | Owner decision: the vault refuses redeem and claim for any blocklisted caller, receiver or credit holder, and the router also checks the cash recipient. | 7 unit + 6 fork tests (§6) |

**Index-token transfers are INTENTIONALLY unrestricted (owner decision, 2026-10-12).** CHIPX is a
plain, freely transferable OpenZeppelin ERC-20 with no blocklist, pause or hook on `transfer` or
`transferFrom`. The blocklist is enforced only where stock leaves the vault (redeem and claim). So a
Coinbase-blocklisted holder can transfer index tokens to a clean address, and that address can then
redeem. This is accepted by design, to keep the index token composable. Please review the
redeem/claim checks on their own terms, not as a complete compliance barrier.

## 5. Other trust assumptions
- 1 USDC = $1 in the Router.
- $CHIP has no onchain TWAP (its Doppler hook keeps no oracle). Buys rely on the keeper's
  `minChipOut` and the $100 per-call cap.
- Owner powers: fee rates under hard caps, mint cap, mint pause, feed max age (1h–72h),
  pool tick spacing (validated against the factory), keeper address, cash-path pause/unpause;
  timelocked: basket, rebalancer, fee recipient. The owner cannot pause in-kind redeem or take
  vault assets.
- Keeper powers: rebalance (within rules and vault slippage), sell fee stocks (Chainlink floor),
  buy and burn $CHIP (budget and cap), pause cash paths.

## 6. Test results (2026-10-12)

**Unit + invariant (mocks): 88 passed, 0 failed.** `forge test --no-match-path "test/fork/*"`

| Suite | Tests | Covers |
|---|---|---|
| IndexVault | 32 | seed, pro-rata mint/redeem, fees and caps, management accrual, credits, pause, vault-blocklisted stock, **blocklist (5)**, sync, timelocks, 2 fuzz tests (512 runs) |
| IndexRouter | 19 | USDC/ETH mint and redeem, 1% leg bound, user limits, stale feeds, pause roles, credits go to the user, **blocklist (2)**, ETH-rejecting wallet gets WETH (2) |
| BasketRegistry | 15 | launch basket, validation, timelock delay/grace/mismatch/cancel, add/remove/prune, stale/bad/broken feeds, sequencer |
| Rebalancer | 11 | eligibility (drift / 30 days), over/underweight rules, overshoot, vault slippage, keeper minOut, removed ticker |
| IndexFeeSplitter | 8 | fee-free redeem, 50/50 split, oracle floor, buy-and-burn, caps, sweep limits |
| Invariants | 3 | §3 items 3 and 4, plus full redeem always succeeds: 64×100 calls by default, 512×500 in the `deep` profile (passed at 256,000 calls) |

**Base mainnet fork (real B20s, feeds, Aerodrome, $CHIP v4 pool, ChipBurner): 30 passed, 0 failed.**
`./script/fork-test.sh` (base-forge)

| Test | Result |
|---|---|
| Precompile canary (3) | real state readable, real transfer, multiplier 1.000538 |
| Deploy script + Safe seed batch | launch config verified; seed spent $1,000.59 → NAV $10.00/token |
| In-kind mint/redeem | real B20 delivered; in-kind redeem ~416k gas incl. blocklist check |
| Cash USDC mint/redeem | $99.95–$100.00 for 10 tokens; $97.86–$97.91 back for 9.9 |
| Cash ETH mint | 0.0408–0.0415 ETH for 10 tokens |
| Stale feed | cash mint refused; in-kind redeem works |
| Blocklist (6) | receiver, caller, credit holder, cash caller/recipient refused; claim refused until lifted; lifted restores |
| Vault blocklisted | all 8 legs credited, shares burned |
| Paused token | 7 legs delivered, NVDA credited, claimed after unpause |
| Multiplier ×10 | balances, books, NAV, redeem amounts unchanged |
| Rebalance | drift 4.95 → 4.01 points; NAV 1,060.00 → 1,059.95 |
| Fee pipeline (1 year) | 3% minted; $14.55 to Pot; ~20.2M $CHIP bought and burned; supply fell by exactly that |
| Small cash mints (4) | see table below; unspent ETH refunded |
| Contract wallets (6) | real Coinbase Smart Wallet v1.1 and Safe v1.4.1 created with the official Base factories: ETH and USDC mint + redeem, in-kind redeem; refunds arrive as ETH; an ETH-rejecting contract gets WETH (see below) |

Small cash mints, with gas at 0.006 gwei (live 2026-10-12):

| Mint | Paid | Index tokens received | Mint fee | Gas | Gas in $ |
|---|---|---|---|---|---|
| $20 USDC | 20.018 USDC | 1.98 | 0.02 tokens ($0.20) | 2.41M | $0.036 |
| $5 USDC | 5.004 USDC | 0.495 | 0.005 tokens ($0.05) | 2.41M | $0.036 |
| $20 ETH | 0.008071 ETH ($20.01) | 1.98 | 0.02 tokens ($0.20) | 3.01M | $0.045 |
| $5 ETH | 0.002018 ETH ($5.00) | 0.495 | 0.005 tokens ($0.05) | 3.01M | $0.045 |

**Measured on the fork:**
- Nothing blocks small cash mints; a $0.01 USDC mint also worked in a one-off probe. Gas does not
  depend on size (8 swaps), so it weighs most on the smallest mints.
- **Contract wallets.** On a  mint, both the Coinbase Smart Wallet and the Safe paid 0.008017 ETH
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
5. Management fee as per-second minted shares: rounding or accrual-ordering issues around `setFees`
   and `executeFeeRecipient`?
6. `IndexRouter._sendEth` forwards all gas and falls back to WETH on failure. The recipient is always
   the payer (refund) or a caller-chosen `to` (redeem). Is there any grief or reentrancy path? The
   Router is `nonReentrant` and holds nothing between calls.

## 8. Files to read
`docs/SPEC.md` (decisions) · `docs/ASSUMPTIONS.md` (trust model) · `docs/DEPLOY.md` (procedure) ·
`script/Deploy.s.sol` (`LaunchConfig` and `Addrs` blocks hold every launch value and address).
