# Chip Index — moving to a new vault

**Design decision (owner, 2026-10-13): the IndexVault is not upgradeable.** It is a plain contract
deployed with `new`. There is no proxy, no `delegatecall`, no `selfdestruct` and no upgrade key, so
nobody can change its code, ever. If the vault itself ever needs to change, the only path is a
**new vault** and users moving to it themselves. This document describes that move.

The other pieces are replaceable without moving users:

| Piece | How it is replaced | Delay |
|---|---|---|
| Rebalancer | `vault.queueRebalancer(new)` → wait → `vault.executeRebalancer(new)` | 48h timelock |
| Fee splitter (fee recipient) | `vault.queueFeeRecipient(new)` → wait → `vault.executeFeeRecipient(new)` | 48h timelock |
| Router | Deploy a new one and point the website at it. The router has no special power over the vault: it calls the same public `mint`/`redeem` as anyone. Users re-approve the new router. The old one can be stopped with `pauseCashMint`/`pauseCashRedeem`. | none needed |
| Basket (stocks, feeds, weights) | `registry.queueBasket` → wait → `registry.executeBasket` | 48h timelock |
| Mint fee schedule | `vault.queueMintFeeSchedule` → wait → `vault.executeMintFeeSchedule` | 48h timelock |

The BasketRegistry itself is fixed to the vault (an immutable address), so replacing the registry
also means a new vault.

## When a new vault would be needed
- A bug in the vault's own code (mint, redeem, accounting, fees).
- Coinbase changes the B20 tokens in a way the vault cannot handle (for example the Denim upgrade
  turning policy 5 into an allowlist, see ASSUMPTIONS A-4).
- A feature that needs new vault code.

## What users can always rely on in the old vault
- **In-kind redeem never stops.** No owner, keeper, oracle or sequencer can pause it. Each holder
  can always burn their index tokens for their share of every stock (only Coinbase's own blocklist
  can refuse a specific account, see REVIEW_PACKAGE §4).
- **Credits stay claimable.** A stock leg that could not be delivered at redeem stays in
  `owed(account, token)` and is collected with `claimOwed(token, to)` whenever the token can move.
- Nobody can take the stock out of the old vault for themselves. (Two indirect owner paths that
  need the 48h timelock are listed in the security self-review; the 48h is the users' window.)

## The move, step by step

### Owner (Safe)
1. Deploy and verify the new set (registry, vault, rebalancer, router, fee splitter) with the deploy
   script, and seed the new vault.
2. Announce the move with the new addresses and a date.
3. On the old set:
   - `vault.setMintPaused(true)` — no new money goes into the old vault.
   - `router.pauseCashMint()` on the old router.
   - `vault.tighten(SET_REDEEM_FEE, 0)` and `vault.tighten(SET_MGMT_FEE, 0)` — no redeem fee and no
     management fee, so leaving is free and remaining holders stop paying. (Cuts take effect
     immediately; only increases wait 48h.)
   - `rebalancer.tighten(SET_KEEPER, 0)` — no more trades in the old vault (instant).
   - Leave in-kind redeem and the old router's cash redeem as they are. Do not change the basket.
4. Keep the old fee splitter running until it has redeemed and sold the fees it already holds.

### Each holder
1. **Redeem from the old vault.** Either:
   - in kind: `oldVault.redeem(shares, me)` — you receive the 8 stocks directly. Works any day,
     including weekends; or
   - to cash: `oldRouter.redeemToUsdc(...)` or `redeemToEth(...)` — needs all price feeds fresh
     (market days), each stock sold within 1% of Chainlink.
2. If a leg was credited instead of delivered, collect it later with `oldVault.claimOwed(token, me)`.
3. **Mint in the new vault.** Either:
   - in kind: approve each stock to the new vault and call `newVault.mint(shares, me)`
     (`previewMint(shares)` shows the exact amounts), or
   - with cash: `newRouter.mintWithUsdc(...)` or `mintWithEth(...)`.

Going in kind both ways costs no swap fees: the stocks you get out are the stocks you put in. With
the old redeem fee set to 0, the only cost is the new vault's mint fee (and gas).

### Optional: a one-click migrator
A small helper contract could do steps 1 and 3 in one transaction (pull the user's old tokens,
redeem in kind to itself, approve and mint in the new vault to the user). It needs no special power
in either vault, because both `redeem` and `mint` are public. It is NOT built. If it is built, it
should hold nothing between calls, send any undeliverable leg's credit to the user (`creditTo` =
user), and go through review like the rest.

## What this does not cover
- Holders who never move stay in the old vault forever, still fully redeemable.
- Index tokens sitting in other contracts (pools, lending markets) must be withdrawn by their owners
  first; the old vault cannot move them.
