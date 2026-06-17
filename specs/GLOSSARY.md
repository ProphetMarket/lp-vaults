# Glossary

> Canonical definitions for all terms used in specs.
> Every agent reads this before any other document.

## Terms

**Module** -- A physical application layer that maps to a deployable unit. In this project there is one module: the Solidity contracts.

**Domain Tag** -- A logical business concern that crosses module boundaries. Used to categorize features and use cases (e.g., @vault, @positions, @fees, @ticks).

**Feature** -- A user-facing capability described in a spec. Features accumulate use cases over their lifetime.

**Use Case** -- A single interaction scenario within a feature, with defined preconditions, steps, and postconditions.

**Actor** -- A role that interacts with the system: LP, Operator, Oracle, Admin, Keeper, or Factory Owner.

**Tick** -- A discrete price slot in the order book. The prediction market price space [0, 1] is divided into ticks at the vault's `tickSpacing` granularity (e.g., 1000 ticks at 0.001 spacing). Ticks are the unit of the fee accumulator system.

**Position** -- A per-LP record stored in the vault: `(owner, tickLower, tickUpper, liquidity, feeGrowthInsideLastX128, tokensOwed)`. Each LP can hold multiple positions per vault with different ranges.

**feeGrowthGlobalX128** -- Vault-wide cumulative fees per unit of active liquidity since vault inception, scaled by 2^128 (Q128 fixed-point). Incremented on every `notifyFees` call.

**Concentrated Liquidity** -- The Uniswap v3-style model where each LP allocates capital to a chosen sub-range of the price curve. Tighter ranges earn more fees per dollar but take on more inventory risk.

**CTF Exchange** -- The ProphetCTFExchange contract (a Polymarket fork). A CLOB where orders are matched off-chain by an operator and settled atomically on-chain. The exchange pulls maker capital from pre-approved contracts at fill time.

**Intent** -- An off-chain record representing an LP's desire to open a position. The LP creates an intent, sends USDC to the vault address, and the operator calls `mintPositionFor` after verifying the deposit matches the intent.
