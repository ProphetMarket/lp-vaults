---
id: FEAT-K1M2
name: Merge Positions
module: contracts
domain: "@positions"
status: implemented
version: 4
refs: [FEAT-T7AF]
---

# Merge Positions

> Operator-called housekeeping that combines two or more distinct positions with identical owner, tickLower, tickUpper, and mintTick into a single position record, preserving total liquidity and accrued fees. This merge joins LP position records. It is not the complete-set merge of YES and NO tokens into USDC (`mergeCompleteSets()`, audit-fix step R9).

## Non-Goals

- Does not merge positions with different tick ranges -- reverts on mismatch
- Does not merge positions owned by different LPs -- all positions must share the same owner
- Does not merge across vaults
- Does not merge positions with different mint ticks -- reverts, because the mint tick is part of what a claim holds (decision C26 in `audits/audit-fixes-ranged.md`)
- Does not merge YES and NO outcome tokens into USDC -- that is the complete-set merge `mergeCompleteSets()` that audit-fix step R9 adds (C26)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Calls `mergePositions(positionIds[])` | Housekeeping to reduce storage and gas for overlapping positions |

## Functional Requirements

### Merge Operation

**FR-K1M3** `When the Operator calls mergePositions with two or more distinct position IDs that share the same owner, tickLower, tickUpper, and mintTick, the system shall combine them into one position with the summed liquidity and correctly computed fee state, zeroing the consumed positions.`
Fit Criterion: Given positions [A, B] with identical owner, range, and mintTick, after merge the surviving position holds `liquidityA + liquidityB`, consumed positions have `liquidity == 0`, tick state `liquidityGross` is unchanged.
Linked to: UC-K1M8

**FR-K1M4** `If mergePositions is called with position IDs that have different tickLower or tickUpper values, then the system shall revert.`
Fit Criterion: Given positions with mismatched ranges, the call reverts.
Linked to: UC-K1M8

**FR-K1M5** `If mergePositions is called with fewer than two position IDs, then the system shall revert.`
Fit Criterion: Given empty array or single-element array, the call reverts.
Linked to: UC-K1M8

**FR-AFPS** `If mergePositions is called with a position ID that appears more than once in positionIds, then the system shall revert before it reads any position or adds any liquidity.`
Fit Criterion: Given `[A, A]`, `[A, B, A]`, or any array with a repeat at any two indexes, the call reverts with `DuplicatePositionId` and every position keeps its liquidity. The check compares every pair of IDs in the calldata array and uses no storage. A pairwise check is enough because the function merges a handful of positions, not a bulk batch (audit issue 6.14, decision C16).
Linked to: UC-K1M8

**FR-AFPT** `If mergePositions is called with position IDs whose mintTick values differ, then the system shall revert.`
Fit Criterion: Given positions with the same owner and range and different mintTick values, the call reverts with `MintTickMismatch` and no position changes. Under the claim model (decision C26) two positions with different mint ticks hold different assets, so one record cannot represent both.
Linked to: UC-K1M8

### Liquidity Conservation

**FR-AFPU** `When mergePositions completes, the sum of liquidity over every position in the vault shall equal the sum before the call.`
Fit Criterion: The fuzz test in the UC-K1M8 test file asserts that the survivor's liquidity after a merge of a random set equals the sum of the merged positions before it, and `invariant_mergeConservesLiquidity` in `test/invariants/TickState.t.sol` asserts, after any sequence of mints, tick moves, and merges, that the sum of every position's liquidity equals half the sum of `liquidityGross` over every distinct referenced tick. The invariant reads vault state only and keeps no handler mirror, so a burn action (R9) changes no check. This is the auditors' requirement FR-2J6X in `audit-solutions.md`.
Linked to: UC-K1M8

### Fee Accounting

**FR-K1M6** `When mergePositions completes, the surviving position's fee accounting shall reflect the sum of all consumed positions' uncollected fees with no loss or double-counting.`
Fit Criterion: Given two positions with accrued fees, after merge the surviving position's `tokensOwed` includes both positions' uncollected fees and `feeGrowthInsideLastX128` is set to the current value. The fee total of FEAT-9BQZ falls by the remainders the two floors drop, Σ (liquidity × delta) mod 2^128, so it still equals the survivor's scaled fee claim; the three principal totals are unchanged (FR-9BRH).
Linked to: UC-K1M8

### Operator Liveness

**FR-3XU7** `When mergePositions completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given the Operator successfully merges same-range positions, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given the merge reverts for any reason, `lastOperatorActivityTimestamp` is unchanged. The silence timer this feeds is consumed by `emergencyCancelAll` (FEAT-JXQO, FR-JXQS).
Linked to: UC-K1M8

## Non-Functional Requirements

**NFR-K1M7** Security: `The mergePositions function shall only be callable by a registered Operator.`

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Operator can merge same-range same-owner positions
- Mismatched ranges revert
- Empty/single-item input reverts
- Fee accounting preserved after merge (no loss, no double-counting)
- A repeated position ID reverts before any liquidity is read
- Positions with different mint ticks do not merge
- The merge conservation fuzz test and `invariant_mergeConservesLiquidity` pass
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
