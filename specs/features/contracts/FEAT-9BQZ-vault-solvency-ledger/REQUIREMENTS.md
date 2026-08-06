---
id: FEAT-9BQZ
name: Vault Solvency Ledger
module: contracts
domain: "@vault"
status: dirty
version: 1
refs: [FEAT-REPZ, FEAT-T7AF, FEAT-7G40, FEAT-U079, FEAT-TOGR, FEAT-TVS0, FEAT-3ZRI, FEAT-JAIJ, FEAT-JXQO, FEAT-K1M2]
---

# Vault Solvency Ledger

> Gives the vault an on-chain account of what it owes -- per asset, in token counts -- and a pooled per-asset payout ratio that every exit path applies, so a shortfall is absorbed as a proportional haircut shared by all claimants rather than a race won by whoever calls first.

## Non-Goals

- Does not assert solvency anywhere: no revert, no halt, no pause, and no warning when a ratio falls below unity -- see ADR-9BSK
- Does not price outcome tokens, read a price feed, or accept a price input of any kind -- every total is a token count
- Does not define what asset split a mint creates or what composition a burn pays out; FEAT-T7AF and FEAT-7G40 own that math and the ledger mirrors whatever they compute
- Does not decide which outcome side a traversed tick segment converts principal into; that assignment belongs to the mint/burn split model, and this feature requires only that the ledger record the same shift that model produces
- Does not convert, trade, swap, or route any asset, and places no order on the CTF Exchange
- Does not reconstruct any total by iterating positions -- see FR-9BR3
- Does not rank claimants, introduce seniority classes, or subordinate fees to principal -- see ADR-9BSI
- Does not perform off-chain monitoring or alerting; the ledger exposes state and off-chain systems watch it
- Does not change any role's authority, add a role, or gate any existing function behind a new one

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Receives payouts scaled by the ratio their exit path applies | Never calls the ledger directly. Observes it through `burnPosition`, `collect`, and `reclaimDeposit` paying a proportional share when the vault is short, and through the public views |
| Operator | Drives the two call sites that move totals without an LP present -- `notifyFees` and `updateTick` | `updateTick` is the only path that redistributes principal between asset sides. The Operator cannot set, override, or repair any total directly; every total moves only as a consequence of the operation that caused it |

## Functional Requirements

### Ledger State

**FR-9BR3** `The system shall maintain totalUsdcOwed, totalYesOwed, totalNoOwed, totalFeesUsdcOwed, totalFeesYesOwed, totalFeesNoOwed, and totalEscrowed as running totals, updating each incrementally in the same call as the operation that changes it.`
Fit Criterion: Given any sequence of mints, burns, collects, fee notifications, deposits, reclaims, and tick updates, each total reads its correct value immediately after every call, and no code path computes a total by looping over `positions`. Iteration would make the ledger's cost grow with position count and put the vault's exit paths at the mercy of a gas limit -- exactly the failure the ledger exists to prevent.
Linked to: UC-9BR0, UC-9BR1

**FR-9BR4** `The system shall denominate every total in token counts of the asset owed, and shall accept no price input when maintaining or reading them.`
Fit Criterion: Given 100 YES owed, `totalYesOwed == 100` whether YES trades at $0.60 or $0.30, and no ledger read or write consults a price, an oracle, or `currentTick` for valuation. Dollar-denominating recreates the bug this feature exists to remove: recording "owed $60" against 100 YES at $0.60 leaves the vault owing $60 backed by $30 once the price halves, while a token-denominated entitlement cannot drift -- owe 100 YES, hold 100 YES, at any price.
Linked to: UC-9BR0

**FR-9BR5** `The system shall track the YES and NO totals as separate non-negative quantities and shall never combine them into a single signed net.`
Fit Criterion: Given one position tilted toward YES and another tilted toward NO, `totalYesOwed` and `totalNoOwed` each report their own obligation and neither is reduced by the other. Under a signed net the two cancel, so a vault holding neither token would report itself solvent while unable to pay either side. The vault holds two distinct ERC-1155 balances and the ledger mirrors that.
Linked to: UC-9BR0, UC-9BR2

**FR-9BR6** `The system shall expose every total and every payout ratio as a public view.`
Fit Criterion: Given any vault state, an off-chain caller reads all seven totals and all three ratios without a transaction. This is the entire monitoring surface: because no on-chain path reverts on a shortfall (FR-9BRS), observability is the only way a shortfall becomes visible.
Linked to: UC-9BR0, UC-9BR2

**FR-9BR7** `The system shall leave totalUsdcOwed, totalYesOwed, and totalNoOwed unchanged when a position collects fees without closing.`
Fit Criterion: Given a fee-only collect, all three principal totals read identically before and after. A collect changes neither the position's liquidity nor its tick range, so its principal claim is unchanged; decrementing a principal total for a fee payment would understate what the vault still owes by exactly the fees paid.
Linked to: UC-9BR0

### Maintaining the Totals

**FR-9BR8** `When a position is minted, the system shall increment the principal totals by that position's starting asset split.`
Fit Criterion: Given a mint producing a starting split of U USDC, Y YES, and N NO, `totalUsdcOwed` rises by U, `totalYesOwed` by Y, and `totalNoOwed` by N. The split is whatever FEAT-T7AF computes at the market ratio in force -- it is not assumed to be balanced, and the ledger asserts no relationship between Y and N.
Linked to: UC-9BR0

**FR-9BR9** `When a position is burned, the system shall decrement the principal totals by that position's current asset split.`
Fit Criterion: Given a burn whose payout composition is U USDC, Y YES, and N NO before any ratio is applied, the three principal totals fall by exactly those amounts. The decrement uses the split at burn time, not the split recorded at mint, because price movement has been redistributing it ever since (FR-9BRI, FR-9BRJ).
Linked to: UC-9BR0

**FR-9BRA** `When fees are notified, the system shall increment the fee total for the asset the fees arrived in.`
Fit Criterion: Given a fee notification denominated in USDC, `totalFeesUsdcOwed` rises by that amount and the YES and NO fee totals are unchanged; given one denominated in YES, only `totalFeesYesOwed` rises. Which asset a fee arrives in is a property of the fill the exchange executed, not a choice the vault makes, so all three fee totals are live.
Linked to: UC-9BR0

**FR-9BRB** `When a position collects fees, the system shall decrement the fee totals by the amounts actually paid out.`
Fit Criterion: Given a collect paying F USDC, `totalFeesUsdcOwed` falls by exactly F -- the amount transferred after any ratio is applied, not the amount owed before it. Decrementing by the pre-haircut entitlement would erase an obligation the vault never discharged. This requirement binds `collect` and any future Operator-relayed twin of it identically.
Linked to: UC-9BR0, UC-9BR2

**FR-9BRC** `When a position is burned, the system shall decrement the fee totals by the fee amounts actually paid out, in the same call as the principal decrement.`
Fit Criterion: Given a burn paying principal and F in accrued fees, both the principal totals (FR-9BR9) and the fee totals fall in that one call, and no separate collect is needed to retire the fee obligation.
Linked to: UC-9BR0

**FR-9BRD** `When USDC is escrowed against a mint intent, the system shall increment totalEscrowed by the deposited amount.`
Fit Criterion: Given a deposit of D against an intent, `totalEscrowed` rises by D in the same call that pulls the USDC, so the obligation and the balance backing it enter the ledger together.
Linked to: UC-9BR0

**FR-9BRE** `When a mint consumes an escrowed deposit, the system shall decrement totalEscrowed by the consumed amount.`
Fit Criterion: Given a mint fulfilling an intent escrowed at D, `totalEscrowed` falls by D in the same call in which the principal totals rise by the new position's split (FR-9BR8). The obligation is not discharged -- it changes form from a pending refund into a live position claim, and both legs move together so the ledger never double-counts or drops it.
Linked to: UC-9BR0

**FR-9BRF** `When an escrowed deposit is refunded, the system shall decrement totalEscrowed by the amount refunded.`
Fit Criterion: Given a reclaim refunding R, `totalEscrowed` falls by exactly R -- the amount transferred after `usdcRatio` is applied (FR-9BRR), not the amount originally escrowed.
Linked to: UC-9BR0, UC-9BR2

**FR-9BRG** `When the vault executes an emergency cancellation, the system shall reduce every total by the obligations that cancellation discharges.`
Fit Criterion: Given an emergency cancel that pays out every live position, all seven totals read zero afterwards apart from obligations the cancellation genuinely leaves outstanding. Without this the terminal state reports a fully-drained vault as still owing everything, and every ratio reads as a total shortfall against an empty balance.
Linked to: UC-9BR0

**FR-9BRH** `When positions are merged, the system shall leave every total unchanged.`
Fit Criterion: Given a merge of two positions sharing an owner and a range, all seven totals read identically before and after. A merge preserves total liquidity and the tick range and moves no assets -- uncollected fees roll into the survivor's record rather than being paid -- so the vault's obligations are unchanged in both composition and amount. Stated explicitly so no adjustment is added here later on the assumption that a position-count change must move the ledger. The consequence is a bounded understatement rather than a silent error: because principal is reconstructed from a truncated `liquidity`, the merged survivor can claim up to one base unit per asset leg more than each position it consumed contributed, so the totals understate obligations by at most the number of positions merged away. That drift is carried in NFR-9BRX's tolerance rather than compensated for here -- see ADR-9Q3Y.
Linked to: UC-9BR0

### Price Movement

**FR-9BRI** `When the price crosses an initialized tick, the system shall accumulate the principal shift for the segment ending at that tick before applying the tick's liquidityNet, using activeLiquidity as it stood before that step.`
Fit Criterion: Given a crossing at tick T, the segment from the previous segment boundary to T is accumulated against the pre-crossing `activeLiquidity`, and only then is `liquidityNet` applied. Reversing the two attributes the segment to liquidity that was not active across it. That error corrupts the ledger silently -- nothing reverts, no event looks wrong, and the totals simply drift from what the vault owes.
Linked to: UC-9BR1

**FR-9BRJ** `When a tick update finishes crossing, the system shall accumulate the principal shift for the trailing segment from the last crossed tick to the new tick.`
Fit Criterion: Given a move that crosses one or more ticks and then continues past the last of them, the remaining span is accumulated once after the crossing loop exits. Given a move that crosses none, the trailing segment spans from the old tick to the new tick and is the only accumulation performed. Most moves do not land exactly on an initialized tick, so accumulating only inside the crossing loop is wrong on the common case rather than an edge case.
Linked to: UC-9BR1

**FR-9BRK** `When a price move crosses no initialized ticks, the system shall still accumulate the shift for the span it traversed.`
Fit Criterion: Given a move entirely within one gap between initialized ticks, the principal totals change by the shift across that span even though the crossing loop never ran. A move inside a gap redistributes the principal of every position spanning it exactly as a longer move does.
Linked to: UC-9BR1

**FR-9BRL** `When the system accumulates a segment's principal shift, it shall move the shifted amount out of one asset's principal total and into another's, leaving the total obligation unchanged in token terms.`
Fit Criterion: Given a segment shifting S of principal, the decrease in the origin total equals the increase in the destination total, and no principal is created or destroyed by a price move. Which asset receives the shift follows the split model of FEAT-T7AF and FEAT-7G40; this feature fixes only that the ledger records the same movement that model produces, so a burn's decrement (FR-9BR9) always finds the obligation where the traversal left it.
Linked to: UC-9BR1

### Payout Ratios

**FR-9BRM** `The system shall compute usdcRatio as the vault's USDC balance divided by the sum of totalUsdcOwed, totalFeesUsdcOwed, and totalEscrowed.`
Fit Criterion: Given a USDC balance of B against those three obligations summing to O, `usdcRatio == B / O` for `B < O`. Escrow belongs in the denominator because the deposit that created it pulled real USDC that already sits in the numerator; omitting it overstates solvency by exactly the pending-escrow balance and lets burners be paid in full out of pending depositors' money.
Linked to: UC-9BR2

**FR-9BRN** `The system shall compute yesRatio as the vault's YES token balance divided by the sum of totalYesOwed and totalFeesYesOwed.`
Fit Criterion: Given a YES balance of B against obligations summing to O, `yesRatio == B / O` for `B < O`. There is no escrow term: escrow is USDC by construction.
Linked to: UC-9BR2

**FR-9BRO** `The system shall compute noRatio as the vault's NO token balance divided by the sum of totalNoOwed and totalFeesNoOwed.`
Fit Criterion: Given a NO balance of B against obligations summing to O, `noRatio == B / O` for `B < O`.
Linked to: UC-9BR2

**FR-9BRP** `While an asset's balance covers its obligations, the system shall cap that asset's ratio at 100%.`
Fit Criterion: Given a balance at or above the obligation, the ratio reads exactly unity and payouts are unreduced. A surplus is never distributed as a bonus -- an LP receives what they are owed and no more, so a donated or stranded balance cannot be drained by whoever exits first. Given zero obligation for an asset, the ratio is unity and no division by zero occurs.
Linked to: UC-9BR2

**FR-9BRQ** `The system shall compute the three ratios independently of one another.`
Fit Criterion: Given a vault short of YES but holding enough USDC and NO, `yesRatio` is below unity while `usdcRatio` and `noRatio` read unity, and a burn is reduced only on its YES leg. A shortfall in one asset never haircuts a payout in an asset the vault can cover in full.
Linked to: UC-9BR2

**FR-9BRR** `When an exit path pays out, the system shall apply to each leg of the payout the ratio for that leg's asset.`
Fit Criterion: Given a burn paying USDC, YES, and NO, each leg is scaled by its own asset's ratio; given a fee collection, the fee-side ratios apply; given an escrow refund, `usdcRatio` applies to the whole refund. Every claimant against an asset takes the identical haircut on it regardless of which path they used or when they called -- one pooled ratio per asset, shared by principal, fees, and escrow refunds alike.
Linked to: UC-9BR2

**FR-9BRS** `The system shall not revert, halt, pause, or otherwise block a payout when any ratio is below 100%.`
Fit Criterion: Given a vault short in every asset, a burn, a collect, and a reclaim each succeed and pay their reduced amounts. A solvency assertion on a payout path bricks withdrawals during precisely the shortfall the ratio exists to handle gracefully, converting a recoverable partial loss into a total one. Detection is off-chain, against the views of FR-9BR6.
Linked to: UC-9BR2

## Non-Functional Requirements

**NFR-9BRT** Security: `Every ledger decrement shall be safe against underflow.`
Fit Criterion: no decrement can revert a payout path or wrap around, under any interleaving of mints, burns, collects, fee notifications, deposits, reclaims, and tick traversals reachable by fuzzing. An underflowing decrement on an exit path is a solvency assertion by accident -- it produces the exact bricked withdrawal FR-9BRS forbids.

**NFR-9BRU** Security: `No ledger read or write shall introduce a revert into burnPosition, burnPositionFor, collect, reclaimDeposit, or reclaimDepositFor.`
Rationale: these are the paths LP capital leaves by, one of which (`burnPosition`) is the protocol's unconditional escape hatch under FEAT-7G40 NFR-7G5B. A ledger that can revert them silently voids that guarantee.

**NFR-9BRV** Gas: `Ledger maintenance shall add constant-cost work per call site, and constant-cost work per traversed segment in updateTick.`
Fit Criterion: the added cost at each call site is independent of the number of live positions, and `updateTick`'s added cost grows only with the number of segments it already traverses -- bounded by the existing 256-crossing cap.

**NFR-9BRW** Precision: `Ratio application shall round down.`
Fit Criterion: a scaled payout never exceeds the exact proportional share. Rounding up would pay out value the vault does not hold and turn a small shortfall into a failed transfer for the last claimant; the truncated dust stays in the vault and raises every remaining claimant's ratio fractionally, matching the Q128 fee-dust convention already used across this repo.

**NFR-9BRX** Testability: `The ledger's conservation properties shall be expressed as invariants, each stated modulo the reconstruction truncation it is subject to.`
Fit Criterion: invariant tests assert that no total is ever negative, that a price move preserves total principal in token terms (FR-9BRL), and that each total equals the sum of its per-position or per-intent contributions to within one base unit per asset leg per position ever merged away. Exact equality is unsatisfiable and must not be asserted: a position's principal is never stored, only reconstructed from its truncated `liquidity`, so `mergePositions` -- which combines N positions' liquidity into one record while writing no ledger total (FR-9BRH) -- collapses N downward truncations into one and lets the survivor's reconstructed claim exceed the sum of the credits recorded for the positions it consumed. The tolerance accumulates over the vault's life and is never reset, bounded by the count of positions ever merged away. Outside that one path the invariant holds exactly, because every other site credits and debits the identical `_owedAmounts` computation. See ADR-9Q3Y for why this is carried as a tolerance rather than compensated for.

**NFR-9BRY** Security: `Ledger updates shall occur in the effects phase, before any token transfer.`
Fit Criterion: every total reaches its post-operation value before the first external call, so a recipient reentering through the ERC-1155 receive hook reads a ledger that already reflects the payout in flight and cannot compute a ratio against a stale, overstated obligation.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-9BR0, UC-9BR1, and UC-9BR2 pass with full coverage
- All seven totals are maintained incrementally; no code path iterates positions to compute one
- No ledger read or write consults a price, an oracle, or a tick for valuation
- `totalYesOwed` and `totalNoOwed` are provably independent: a test drives one YES-tilted and one NO-tilted position and asserts neither total nets against the other
- All three fee totals are exercised, including fees arriving in YES and in NO
- `updateTick` accumulates every traversed segment: multi-crossing, zero-crossing, and a trailing segment to a `newTick` off an initialized tick
- A test pins the ordering of FR-9BRI by asserting the accumulated shift against the pre-crossing `activeLiquidity`
- `emergencyCancelAll` leaves no total overstating a discharged obligation; `mergePositions` leaves every total byte-identical
- A fully-solvent vault pays every path at unity
- An under-collateralized vault pays two claimants the same proportional share in either call order
- Escrowed-but-unminted USDC is in the `usdcRatio` denominator, verified by a test in which omitting it would have overpaid a burner
- **No payout path reverts on a shortfall** (FR-9BRS, NFR-9BRT) -- pinned by a test that drives every asset short and completes a burn, a collect, and a reclaim
- A position devalued purely by price movement is paid at unity: impermanent loss is not a shortfall
- Invariant tests cover conservation and non-negativity; fuzz tests cover the ratio formula
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
