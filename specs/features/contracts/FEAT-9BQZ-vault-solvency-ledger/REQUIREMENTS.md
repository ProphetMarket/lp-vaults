---
id: FEAT-9BQZ
name: Vault Solvency Ledger
module: contracts
domain: "@vault"
status: implemented
version: 6
refs: [FEAT-REPZ, FEAT-T7AF, FEAT-7G40, FEAT-TVS0, FEAT-3ZRI, FEAT-JAIJ, FEAT-JXQO, FEAT-K1M2, FEAT-6HBN, FEAT-E943]
---

# Vault Solvency Ledger

> Gives the vault running totals of what it owes to its live positions, per asset and in the pre-division fixed-point unit, plus the spread it has credited in X128 units, moved on every mint, burn, merge, credit, and segment of a tick move under the claim model (decision C26), and a per-asset ratio that every burn applies, so a shortfall is a cut that every claimant takes alike instead of a race won by whoever exits first.

## Non-Goals

- Does not assert solvency anywhere: no revert, no halt, no pause, and no warning when a ratio falls below 1 -- see ADR-9BSK
- Does not price outcome tokens, read a price feed, or accept a price input other than `currentTick`, which the claim formula already reads
- Does not define what a claim holds; FEAT-7G40 owns the claim formula (FR-7G4M), and the ledger sums the same formula in its pre-division unit
- Does not measure or attribute the spread; FEAT-E943 owns the measurement, the growth accumulator, and every credit site, and the ledger carries the resulting obligation as its fourth total
- Does not reconstruct any total by iterating positions -- see FR-9BR3
- Does not cut an escrow refund, because escrowed USDC is senior (decision C7): the reclaim pays the recorded amount (FEAT-JAIJ) and stays outside every ratio
- Does not pay a remainder later, because a cut is final -- see ADR-COEN
- Does not convert a token total into USDC, before or after the market resolves -- after the switch (FEAT-6HBN UC-6HBP) the USDC ratio values the token totals at the stored payout, and the totals themselves stay token-denominated (ADR-9BSJ)
- Does not convert, trade, swap, or route any asset, and places no order on the CTF Exchange
- Does not perform off-chain monitoring or alerting; the ledger exposes state and off-chain systems watch it
- Does not change any role's authority, add a role, or gate any existing function behind a new one

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Receives a burn scaled by the ratio of each asset | Never calls the ledger directly. Observes it through `burnPosition` and `burnPositionFor` paying a share when the vault is short, and through the public views |
| Operator | Drives the call sites that move totals without an LP present: `mintPositionFor`, `updateTick`, and `mergePositions` | `updateTick` is the only path that moves principal between asset sides. The Operator cannot set, override, or repair any total directly; every total moves only as a consequence of the operation that caused it |

## Functional Requirements

### Ledger State

**FR-9BR3** `The system shall maintain totalUsdcOwedScaled, totalYesOwedScaled, totalNoOwedScaled, and totalSpreadOwedX128 as running totals, updating each incrementally in the same call as the operation that changes it, and shall never compute a total by looping over positions.`
Fit Criterion: Given any sequence of mints, burns, merges, credits, freezes, and tick moves, each total reads its correct value immediately after every call, and no code path loops over `positions` to compute one. A credit adds `growth × active` to `totalSpreadOwedX128` for each segment it credits; a burn debits the position's `liquidity × (spreadGrowthInside − spreadGrowthInsideLast)`; a position merge debits the dust its floor drops. All of it happens in the same call as the operation. Iteration would make the ledger's cost grow with the position count and put the exit paths at the mercy of a gas limit, the failure audit issue 6.11 named.
Linked to: UC-9BR0, UC-9BR1

**FR-9BR4** `The system shall hold every total in the pre-division fixed-point unit of the claim it sums, shall truncate only in the getters totalUsdcOwed, totalYesOwed, and totalNoOwed, and shall accept no price input other than currentTick, which the claim formula already reads.`
Fit Criterion: Given the units USDC principal in units × `PRICE_TICK_ONE` × `LIQUIDITY_PRECISION` (`USDC_CLAIM_SCALE = 1e22`), tokens in units × `LIQUIDITY_PRECISION` (1e18), a mint of 123,456,789 units over 1,000 ticks followed by two moves and a burn leaves `totalUsdcOwedScaled` exactly where it started, and `totalUsdcOwed()` returns `totalUsdcOwedScaled / 1e22`. Worked: the R9 example (300 USDC over `[5500, 6500)` minted at 6000, the vault at 5700) reads `totalUsdcOwedScaled == 3e23 × (10,000,000 − 1,754,850) = 2.4735e30` and `totalUsdcOwed() == 247,354,500`, the USDC of SC-7G44. A truncating total would drift by up to one unit per booking (Appendix D at prompts.md:2208); the scaled unit is what makes the conservation invariant exact (NFR-9BRX).
Linked to: UC-9BR0

**FR-9BR5** `The system shall track the YES and NO totals as separate non-negative quantities and shall never combine them into a single signed net.`
Fit Criterion: Given one position whose band holds YES and another whose band holds NO, `totalYesOwed()` and `totalNoOwed()` each report their own obligation and neither is reduced by the other. Under a signed net the two would cancel, so a vault holding neither token would look covered while unable to pay either side.
Linked to: UC-9BR0, UC-9BR2

**FR-9BR6** `The system shall expose the four scaled totals, the four truncating getters, and the spread growth as public views.`
Fit Criterion: Given any vault state, an off-chain caller reads `totalUsdcOwedScaled`, `totalYesOwedScaled`, `totalNoOwedScaled`, `totalSpreadOwedX128`, `totalUsdcOwed()`, `totalYesOwed()`, `totalNoOwed()`, `totalSpreadOwed()`, and `spreadGrowthGlobalX128` without a transaction, and `ticks(t)` returns `spreadGrowthOutsideX128` as a fourth value and `positions(id)` returns `spreadGrowthInsideLastX128` as a sixth word, so the app computes a position's spread claim off-chain with the same formula the burn uses (FEAT-E943 FR-E94B, FR-E94Y). This is the monitoring surface: no on-chain path reverts on a shortfall (FR-9BRS), so the views are the only way a shortfall becomes visible.
Linked to: UC-9BR0, UC-9BR2

### Maintaining the Totals

**FR-9BR8** `When a position is minted, the system shall increment totalUsdcOwedScaled by liquidity × (tickUpper − tickLower) × PRICE_TICK_ONE.`
Fit Criterion: Given a mint of 300 USDC over `[5500, 6500)`, `totalUsdcOwedScaled` rises by `3e23 × 1000 × 10000` and `totalUsdcOwed()` by 300,000,000, and the token totals are unchanged. The clamped mint tick (FEAT-T7AF ADR-AFPP) leaves the band empty at mint, so a mint's claim is USDC only.
Linked to: UC-9BR0

**FR-9BR9** `When a position is burned, the system shall decrement totalUsdcOwedScaled and the band's token total by the position's scaled claim at currentTick, computed once and before any effect.`
Fit Criterion: Given the R9 example with the vault at 5700, the burn lowers `totalUsdcOwedScaled` by `3e23 × 8,245,150` and `totalYesOwedScaled` by `3e23 × 300`, so `totalUsdcOwed()` falls by 247,354,500 and `totalYesOwed()` by 90,000,000, the amounts `PositionBurned` reports as owed, whatever the burn paid. The scaled claim comes from the same `_claim` the payout truncates.
Linked to: UC-9BR0

**FR-9BRH** `When positions are merged, the system shall leave the three principal totals unchanged, roll the merged positions' spread claims into one survivor snapshot, and debit totalSpreadOwedX128 by the dust the floor drops, at most the merged liquidity in X128 units.`
Fit Criterion: Given two positions with the same range and mint tick, after the merge `totalUsdcOwedScaled`, `totalYesOwedScaled`, and `totalNoOwedScaled` read as before. The principal claim is linear in liquidity and every merged position shares the range and the mint tick, so the principal is conserved without a write, and a merge that wrote a principal total would be a bug the conservation invariant catches. The spread cannot be conserved without a write, because one snapshot cannot represent two: given spread claims `x_a` and `x_b` in X128 units and liquidity `L_a` and `L_b`, the survivor's snapshot becomes `inside − floor((x_a + x_b) ÷ (L_a + L_b))`, its claim becomes `(x_a + x_b) − dust` with `dust < L_a + L_b` X128 units, which is below one USDC unit, and `totalSpreadOwedX128` falls by exactly that dust. A consumed record's snapshot is zeroed with its liquidity. The debit is checked, so a ledger bug reverts the Operator's call (NFR-9BRT).
Linked to: UC-9BR0

### Price Movement

**FR-9BRI** `When updateTick crosses an initialized tick, the system shall accrue the shift for the segment that ends at that tick (moving up) or starts at it (moving down) before it applies the tick's liquidityNet and noLiquidityNet, using activeLiquidity and noSideLiquidity as they stood during that segment.`
Fit Criterion: Given a crossing at tick T, the segment from the previous segment edge to T is accrued against the pre-crossing `activeLiquidity` and `noSideLiquidity`, and only then are the two nets applied. Reversing the two attributes the segment to liquidity that was not in range across it; the error is silent, and the invariant of NFR-9BRX fails on it (checked by mutation on 2026-09-14).
Linked to: UC-9BR1

**FR-9BRJ** `When the crossing loop exits, the system shall accrue one more segment from the last crossed tick to newTick, and when nothing was crossed that segment is the whole move.`
Fit Criterion: Given a move that crosses one or more ticks and then continues past the last of them, the remaining span is accrued once after the loop. Given a move that crosses none, the trailing segment spans from the old tick to the new tick and is the only accrual. Most moves do not land on an initialized tick, so an accrual inside the loop alone is wrong on the common case.
Linked to: UC-9BR1

**FR-9BRK** `When a move crosses no initialized tick, the system shall still move the totals by the shift of the whole span.`
Fit Criterion: Given the R9 example and a move from 6000 to 5700 inside the range, `totalYesOwedScaled` rises by `3e23 × 300` and `totalUsdcOwedScaled` falls by `3e23 × 1,754,850`, so `totalUsdcOwed()` reads 247,354,500 and `totalYesOwed()` reads 90,000,000 with no tick crossed.
Linked to: UC-9BR1

**FR-9BRL** `When the system accrues a segment of levels [s, e) with k = e − s and Σt = k × (s + e − 1) / 2, it shall change the NO total by noSideLiquidity × k, the YES total by (activeLiquidity − noSideLiquidity) × k, and the USDC total by (activeLiquidity − noSideLiquidity) × Σt − noSideLiquidity × (k × PRICE_TICK_ONE − Σt), with the signs set by the direction, so that a move up and the same move down cancel exactly and a move in one call equals the same move in any number of chunks.`
Fit Criterion: Given one position minted at 6000, a move from 6000 to 5700 is one segment with `noSideLiquidity = 0`, `k = 300`, and `Σt = 1,754,850`, so YES gains `3e23 × 300` and USDC loses `3e23 × 1,754,850`; the move back restores both, and the moves 6000 → 5900 → 5750 → 5700 land on the same totals as 6000 → 5700. A segment with `activeLiquidity == 0` is skipped, which also keeps `s` and `e` inside `[0, 10000]`, because a non-empty in-range set puts the segment inside a position's range. Every product stays under 2^155 (`L < 2^128`, `k × PRICE_TICK_ONE < 2^27`), so no product needs `mulDiv`.
Linked to: UC-9BR1

### Payout Ratios

**FR-9BRM** `While the switch is off, when a burn pays USDC, the system shall compute the USDC ratio as the smaller of 1 and (usdc.balanceOf(vault) + the free pairs the merge produces − totalEscrowed, floored at zero) ÷ (totalUsdcOwed() + totalSpreadOwed()), read after the burn's own credit and before the debit, where the free pairs are min(YES balance − min(YES balance, totalYesOwed()), NO balance − min(NO balance, totalNoOwed())) with the totals read before the debit.`
Fit Criterion: Given three positions of the R9 example, the vault at 5700, no spread credited, and a USDC balance drained to half of the 742,063,500 owed, each burn pays `247,354,500 / 2 = 123,677,250` USDC. Escrowed USDC is not in the numerator, because it is senior (decision C7), and not in the denominator, because the reclaim applies no ratio. Given the two-claim state of UC-6HBO (150 YES and 120 NO held, 90 YES and 60 NO owed, 460,951,500 USDC held, 520,951,500 owed), the numerator counts 60 free pairs, the ratio is 1, and A's burn pays 247,354,500. The totals are read before the debit, so the exiting position's own band never counts as free. The credited spread is in the denominator because the credit turned that surplus into an obligation: without it the numerator would exceed the denominator, the cap of FR-9BRP would discard the difference, and the surplus this change exists to attribute would strand again. Under drift-free fills the numerator equals the denominator within one unit after the burn's own credit, so the ratio is 1.
Linked to: UC-9BR2

**FR-CYS5** `While the switch is on (payoutNumerators() is non-zero), when a burn pays, the system shall compute one USDC ratio as the smaller of 1 and (usdc.balanceOf(vault) + the USDC the vault's YES and NO balances redeem for at the stored payout − totalEscrowed, floored at zero) ÷ (totalUsdcOwed() + totalSpreadOwed() + the USDC totalYesOwed() and totalNoOwed() redeem for at the stored payout), read after the burn's own credit and before the debit, and shall apply it to the claim's USDC, the position's spread, and the token leg's USDC as one prorate of their sum.`
Fit Criterion: Given three R9 positions at 5700 (each owed 247,354,500 USDC units and 90 YES), no spread credited, the vault holding 270 YES and its USDC drained to half of the 742,063,500 owed (371,031,750), the result `[1, 0]`, and the Oracle's redemption: `held = 371,031,750 + 270,000,000 = 641,031,750`, `owed = 742,063,500 + 270,000,000 = 1,012,063,500`, and each of three burns in a row pays `floor(337,354,500 × 641,031,750 ÷ 1,012,063,500) = 213,677,250` USDC units, the same ratio each time, and the third leaves the vault at the escrow total. A position with spread credited after the switch receives it at the same pooled ratio in the same transfer. The USDC a balance redeems for is `floor(yes × numYes ÷ den) + floor(no × numNo ÷ den)` with `den = numYes + numNo`, exactly what `redeemPositions` pays, so the numerator never exceeds what the redemption produces. After the switch every asset is USDC, and one pooled ratio is what pro-rata means (ADR-9BSH).
Linked to: UC-9BR2

**FR-9BRN** `While the switch is off, when a burn pays YES, the system shall compute the YES ratio as the smaller of 1 and (the vault's YES balance − the free pairs the merge produces) ÷ totalYesOwed(), read before the debit.`
Fit Criterion: Given 270 YES owed to three positions and 150 held, the ratio is `150 / 270 = 5/9`, and each burn pays `90 × 150 / 270 = 50` YES; after the first burn 100 are held against 180 owed, the same ratio. The YES balance less the free pairs is never below `min(YES balance, totalYesOwed())`, so a balance that covers the total gives a ratio of 1 whatever the NO balance is: given 150 YES and 120 NO held against 90 YES and 60 NO owed, the merge leaves 90 YES and the ratio is 1. Given 150 YES held against 270 owed and 100 NO held against nothing owed, no YES is free, nothing merges, and the ratio stays `150 / 270`.
Linked to: UC-9BR2

**FR-9BRO** `While the switch is off, when a burn pays NO, the system shall compute the NO ratio as the smaller of 1 and (the vault's NO balance − the free pairs the merge produces) ÷ totalNoOwed(), read before the debit.`
Fit Criterion: Given 90 NO owed and 60 held, the burn pays `90 × 60 / 90 = 60` NO. Given 120 NO and 150 YES held against 60 NO and 90 YES owed, the merge leaves 60 NO and B's burn pays 60 NO in full.
Linked to: UC-9BR2

**FR-9BRP** `While an asset's holding covers its total, the system shall cap that asset's ratio at 1.`
Fit Criterion: Given a holding at or above the total, the ratio reads exactly 1 and the payout is the owed amount. A surplus is never distributed through the ratio. An LP receives what is owed and no more, so a donated or stranded balance cannot be drained by whoever exits first. The USDC surplus becomes owed through the spread credit (FEAT-E943 FR-E946), which attributes it to the liquidity in range at the levels where it was earned, and the last live position takes what no credit could attribute (FR-E94C), so no balance strands. Given a zero total for an asset, the ratio is 1 and no division by zero occurs.
Linked to: UC-9BR2

**FR-9BRQ** `While the switch is off, the system shall compute the three ratios independently of one another; while the switch is on, the system shall compute one USDC ratio for every leg.`
Fit Criterion: Given a vault short of YES but holding enough USDC, the YES ratio is below 1 while the USDC ratio reads 1, and a burn is reduced only on its YES leg. A shortfall in one asset never cuts a payout in an asset the vault covers in full. After the switch a vault short of USDC cuts the principal and the token leg by the same ratio (SC-CYSB).
Linked to: UC-9BR2

**FR-9BRR** `When a burn pays, the system shall pay usdcOwed and spreadOwed times the USDC ratio and tokenOwed times the band's token ratio, each rounded down and never above what is held, and shall debit the four totals by the full scaled owed amount, so every later claimant meets the same ratio. While the switch is on, a burn shall pay the sum of usdcOwed, spreadOwed, and the token leg's USDC times the one USDC ratio, rounded down once and never above what is held, in one USDC transfer.`
Fit Criterion: Given the three-burn cases of FR-9BRM and FR-9BRN, the three burns pay the same share each, and after the third the vault holds nothing of the short asset and its total reads zero. Given the three-burn case of FR-CYS5 after the switch, each burn pays 213,677,250 USDC units in one transfer. The two USDC legs are prorated as one floor, `spreadPaid = _prorate(usdcOwed + spreadOwed) − _prorate(usdcOwed)`, so their sum never exceeds what the vault holds even after a saturated debit. `totalSpreadOwedX128` falls by the position's full X128 spread whatever the burn paid, the same full-debit rule the three principal totals follow. The reclaim paths apply no ratio (decision C7).
Linked to: UC-9BR2

**FR-9BRS** `The system shall not revert, halt, pause, or emit an event when any ratio is below 1.`
Fit Criterion: Given a vault short in USDC and in the band's token, a burn succeeds and pays its reduced amounts, with no event other than the ones a covered payout emits. A solvency assertion on a payout path would brick withdrawals during the shortfall the ratio exists to absorb (ADR-9BSK). Detection is off-chain, against the views of FR-9BR6.
Linked to: UC-9BR2

## Non-Functional Requirements

**NFR-9BRT** Security: `A ledger debit in _burn shall saturate at zero and never revert; a ledger write in updateTick or mergePositions shall use checked arithmetic, so a ledger bug reverts the Operator's call and never a payout.`
Fit Criterion: no burn reverts on a ledger write under any interleaving of mints, burns, merges, freezes, and tick moves reachable by fuzzing, and the invariant harness records no undocumented revert of `updateTick`. An underflowing debit on an exit path would be a solvency assertion by accident (ADR-COEN).

**NFR-9BRU** Security: `No ledger read or write shall introduce a revert into burnPosition or burnPositionFor.`
Rationale: these are the paths LP capital leaves by, and `burnPosition` is the unconditional escape hatch (FEAT-7G40 NFR-7G5B). `reclaimDeposit` and `reclaimDepositFor` read no total.

**NFR-9BRV** Gas: `Ledger maintenance shall add constant-cost work per call site, and constant-cost work per segment in updateTick.`
Fit Criterion: the added cost at each call site is independent of the number of live positions, and `updateTick`'s added cost grows only with the number of segments it traverses, bounded by the 256-crossing cap (FEAT-TVS0 ADR-TVUW) plus the trailing segment. Measured cold on the prototype on 2026-09-14: about 14,700 more gas on a zero-crossing move of 50 ticks, 16,000 more on a move with one boundary crossing, 50,900 more on the first crossing of a mint tick, 25,600 more on a mint, 31,700 more on a burn, 7,800 more on a collect, and 5,300 more on a fee report.

**NFR-9BRW** Precision: `Ratio application shall round down.`
Fit Criterion: a scaled payout never exceeds the exact proportional share, and the sum of every per-position floor never exceeds the floor of the sum, so the payouts never exceed what is held. The truncated dust stays in the vault.

**NFR-9BRX** Testability: `The ledger's conservation property shall be an exact invariant: the three scaled totals equal the sum over every live position of its scaled claim at currentTick, and totalSpreadOwedX128 equals the sum over every live position of liquidity × (spreadGrowthInside − spreadGrowthInsideLastX128) mod 2^256, with no tolerance.`
Fit Criterion: `invariant_ledgerEqualsSumOfClaims` in `test/invariants/SolvencyLedger.t.sol` holds over fuzzed mints with deposits that rarely divide by the width, moves that cross nothing, end between ticks, cross mint ticks, and leave the price scale, burns, merges, credits at every site, a freeze, a resolution, and the Oracle's redemption, with both sums computed per position in the test; and `invariant_noSideLiquidity` holds beside it. The invariant fails with the trailing segment removed, with the pre-crossing segment removed, with `liquidityNet` applied before the segment (checked by mutation on 2026-09-14), with a credit written to the global without the spread total, with a burn that skips the spread debit, and with a position merge that skips the dust debit.

**NFR-9BRY** Security: `Ledger updates shall occur in the effects phase, before any token transfer.`
Fit Criterion: every total reaches its post-operation value before the first external call, so a recipient re-entering through the ERC-1155 receive hook reads a ledger that already reflects the payout in flight and cannot compute a ratio against a stale, overstated obligation.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-9BR0, UC-9BR1, and UC-9BR2 pass against the real ConditionalTokens bytecode
- The four totals are maintained incrementally; no code path iterates positions to compute one
- No ledger read or write consults a price other than `currentTick`
- A mint and its burn cancel exactly with a deposit that does not divide by the width
- `totalYesOwed()` and `totalNoOwed()` are independent: a test drives one YES band and one NO band and asserts neither total nets against the other
- `updateTick` accrues every segment: multi-crossing, zero-crossing, a trailing segment to a `newTick` off an initialized tick, and a mint tick crossed like a boundary; three chunks equal one call and a reversal restores the mint totals
- A test pins the ordering of FR-9BRI by asserting the accrued shift against the pre-crossing split
- The freeze leaves every total and `noSideLiquidity` unchanged; a position merge writes the spread dust and no principal total
- A covered vault pays every burn in full
- A short vault pays three burns in a row the same ratio, short of YES and short of USDC
- After the switch, a short vault pays three burns in a row the same pooled ratio in one USDC transfer each, and a payout redeems late tokens first
- A vault whose USDC balance is below `totalEscrowed` pays zero USDC and does not revert
- No payout path reverts on a shortfall (FR-9BRS, NFR-9BRT)
- A position devalued purely by price movement is paid in full
- Under drift-free fills at a spread of 0 and of 2,000 bps, before and after the switch, every burn pays every leg in full, the spread leg included, the Safes together receive their deposits plus the spread income the fixture summed, and the vault ends with 0 YES, 0 NO, and exactly `totalEscrowed`; `invariant_holdingsCoverTotals` and `invariant_burnsPayInFull` hold in `test/invariants/SolvencyLedger.t.sol` under the drift-free handler
- `invariant_ledgerEqualsSumOfClaims`, `invariant_noSideLiquidity`, `invariant_payoutsNeverExceedHeld`, and `invariant_surplusIsCredited` hold in `test/invariants/SolvencyLedger.t.sol`
- Forge fmt passes; no console.log in production code
- `forge build --sizes --skip test --skip script` exits 0
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
