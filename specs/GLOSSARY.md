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

**Tick bitmap** -- The vault's record of which ticks are initialized: `tickBitmap[int16 word] => uint256`, one bit per tick, bit `n` of word `w` set when tick `w × 256 + n` has liquidity. `updateTick` reads it to find the next initialized tick without walking every tick.

**Bitmap word** -- One `uint256` entry of the tick bitmap, covering 256 consecutive ticks. The word index is the tick divided by 256, rounded down, and it spans `int16`: word −32768 holds the lowest ticks and word 32767 the highest. The tick search stops at the word that holds the Operator's target.

**Position** -- A per-LP record stored in the vault: `(owner, tickLower, tickUpper, liquidity, feeGrowthInsideLastX128, tokensOwed)`. Each LP can hold multiple positions per vault with different ranges.

**feeGrowthGlobalX128** -- Vault-wide cumulative fees per unit of active liquidity since vault inception, scaled by 2^128 (Q128 fixed-point). Incremented on every `notifyFees` call.

**Concentrated Liquidity** -- The Uniswap v3-style model where each LP allocates capital to a chosen sub-range of the price curve. Tighter ranges earn more fees per dollar but take on more inventory risk.

**Condition ID** -- The `bytes32` identifier of a question on the Gnosis ConditionalTokens contract, `keccak256(oracle, questionId, outcomeSlotCount)`. Each vault stores the condition ID of its market.

**Index Set** -- A bit mask that selects outcomes of a condition. In a binary Prophet market, index set 1 is YES and index set 2 is NO.

**Outcome Token ID** -- The ERC-1155 token ID of one outcome, derived by the ConditionalTokens contract from the collateral (USDC), the condition ID, and the index set. A vault stores `yesTokenId` (index set 1) and `noTokenId` (index set 2).

**CTF Exchange** -- The ProphetCTFExchange contract (a Polymarket fork). A CLOB where orders are matched off-chain by an operator and settled atomically on-chain. The exchange pulls maker capital from pre-approved contracts at fill time.

**Intent (mint intent)** -- An EIP-712 message that the LP's owner key signs: put `usdcAmount` USDC from this Safe into the range from `tickLower` to `tickUpper`, under a unique `intentId`, before a `deadline`. The Operator escrows the USDC against it with `depositForIntent`, then mints with `mintPositionFor`. The LP never sends USDC to the vault address.

**Safe wallet** -- The Gnosis Safe that Prophet deploys for each user through the Poly Safe factory. The factory derives the Safe's address from its owner key with CREATE2, so any contract can compute a user's Safe from the owner key alone.

**Owner key** -- The externally owned account that owns a user's Safe. It signs every EIP-712 message and every Safe transaction. The Safe itself has no private key.

**Escrow** -- USDC that the vault holds for one mint intent until the Operator mints the position or the Safe reclaims the USDC. The record holds the Safe, the amount, and the intent hash.

**Deadline** -- The last `block.timestamp` at which a signed LP message is valid.

**Reclaim intent** -- An EIP-712 message that the owner key signs to have the Operator relay a reclaim: the Safe, the `intentId`, and a deadline.
