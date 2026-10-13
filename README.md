# Chip Index

An onchain stock index on Base: one ERC-20 backed by an equal-weight basket of Coinbase B20
tokenized stocks (NVDA, MSTR, GOOGL, AMZN, AAPL, META, TSLA, MSFT). Part of the Chipworks stack.

| Contract | Role |
|---|---|
| `BasketRegistry` | Stocks, feeds and target weights; changes go through a 48h timelock |
| `IndexVault` | The index token. In-kind mint/redeem (redeem can never be paused), fees |
| `IndexRouter` | Mint/redeem with USDC or ETH via Aerodrome, 1% max slippage per leg |
| `Rebalancer` | Keeper-only; trades on more than 3 points of drift, or every 30 days |
| `IndexFeeSplitter` | Fees → 50% USDC to the Pot, 50% buys $CHIP for the ChipBurner |

- Spec and decisions: [docs/SPEC.md](docs/SPEC.md)
- Trust model and open questions: [docs/ASSUMPTIONS.md](docs/ASSUMPTIONS.md)
- Deploy checklist: [docs/DEPLOY.md](docs/DEPLOY.md)

```
forge test --no-match-path "test/fork/*"   # unit + invariant tests
./script/fork-test.sh                      # Base fork tests (needs base-forge, run in WSL)
```
