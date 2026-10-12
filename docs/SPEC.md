# Chip Index — Spec (v0, agreed 2026-10-12)

One ERC-20 index token on Base mainnet, backed by a basket of Coinbase B20 tokenized stocks.

## Launch basket (equal weight, 12.5% each, all 8 decimals)

Addresses verified 2026-10-12 against api.coinbase.com/v1/tokenized-stocks (all pages) and onchain
(`description()` = "Coinbase <TICKER>", 8 decimals).

| Ticker | B20 token | Chainlink feed |
|---|---|---|
| NVDA | 0xb20000000000000000000078ee7ce2fE4908108C | 0x04689a41629776563E6822F76f2e57D148d28513 |
| MSTR | 0xb2000000000000000000004884b426556b92883d | 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a |
| GOOGL | 0xb2000000000000000000002D0BA3164cc74f58B7 | 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2 |
| AMZN | 0xb200000000000000000000d9192b6B456483C2E8 | 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295 |
| AAPL | 0xb200000000000000000000C2e324d24d7eEcd1fb | 0x787f13dEa48Db0897CbCDD985de77809D837F988 |
| META | 0xb2000000000000000000008bC8786B856E61707C | 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D |
| TSLA | 0xb2000000000000000000001e800a7f5189430cD0 | 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4 |
| MSFT | 0xB200000000000000000000Ab99cFa739E253872B | 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c |

## Decisions

| Topic | Decision |
|---|---|
| Swap venue | Aerodrome Slipstream (CL factory B `0xf8f2eB49…61Ef`, router `0x698Cb2b6…A92F`). All B20 liquidity is there; not Uniswap. |
| In-kind mint / redeem | Pro-rata against current holdings, so no oracle is involved and it can't be gamed with a stale price. Redeem can never be paused. A leg that fails (token paused, vault blocklisted) is credited to the redeemer and claimable later, so the other legs still pay out. |
| Cash mint / redeem | Router swaps ETH/USDC ↔ all 8 legs. The user sets a minimum out, and each leg must land within 1% of the Chainlink price. Cash mint is blocked if any feed is stale. Cash redeem is pausable for emergencies; in-kind redeem never is. |
| Valuation | raw balance × feed price. Feeds are total-return, and the Coinbase `multiplier` equals onchain `multiplier()`. |
| Mint cap | Owner-set cap on index totalSupply. |
| Fees (launch / hard cap) | mint 1% / 2%, redeem 1% / 2%, management 3%/yr / 5%/yr (accrued continuously as newly minted index tokens). |
| Fee destination | New IndexFeeSplitter. Fees are sold to USDC: 50% goes to Pot `0x3918a9B4…855B` and 50% buys $CHIP (Uniswap v4 pool, keeper-supplied min-out, size cap) and sends it to ChipBurner `0x7Bc1C03e…5C0`. |
| Rebalancer | Keeper only. It may trade any time a stock drifts more than 3 points from its target, and also once per 30 days regardless of drift. Every trade has slippage caps. |
| Basket changes | BasketRegistry: add/remove ticker and change weights through a 48h timelock with a 14-day grace window (the Anvil pattern). |
| Ownership | All contracts are Ownable2Step, owned by Safe `0xe1096B72…73C7` from the constructor. Keeper is `0x6571E341…95B9`. |
| Out of scope | Staking, Morpho, Superform (phase 2). |
| Mainnet | No deploy without the owner's explicit go-ahead. |

## Known trust assumptions (B20)
- All 8 tokens share Coinbase blocklist policy 5 on the SENDER, RECEIVER and EXECUTOR scopes. A blocklisted vault or router cannot move that token.
- The issuer can pause transfers and seize tokens from any holder, including the vault.
- Base's upcoming Denim upgrade (no date yet) extends the executor check to plain `transfer`.
