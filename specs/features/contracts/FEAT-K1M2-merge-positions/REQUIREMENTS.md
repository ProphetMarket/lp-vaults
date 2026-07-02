---
id: FEAT-K1M2
name: Merge Positions
module: contracts
domain: "@positions"
status: implemented
version: 1
refs: [FEAT-T7AF]
---

# Merge Positions

> Operator-called housekeeping that combines two or more positions with identical owner, tickLower, and tickUpper into a single position record, preserving total liquidity and accrued fees.

## Non-Goals

- Does not merge positions with different tick ranges -- reverts on mismatch
- Does not merge positions owned by different LPs -- all positions must share the same owner
- Does not merge across vaults

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Calls `mergePositions(positionIds[])` | Housekeeping to reduce storage and gas for overlapping positions |

## Functional Requirements

### Merge Operation

**FR-K1M3** `When the Operator calls mergePositions with two or more position IDs that share the same owner, tickLower, and tickUpper, the system shall combine them into one position with the summed liquidity and correctly computed fee state, zeroing the consumed positions.`
Fit Criterion: Given positions [A, B] with identical owner/range, after merge the surviving position holds `liquidityA + liquidityB`, consumed positions have `liquidity == 0`, tick state `liquidityGross` is unchanged.
Linked to: UC-K1M8

**FR-K1M4** `If mergePositions is called with position IDs that have different tickLower or tickUpper values, then the system shall revert.`
Fit Criterion: Given positions with mismatched ranges, the call reverts.
Linked to: UC-K1M8

**FR-K1M5** `If mergePositions is called with fewer than two position IDs, then the system shall revert.`
Fit Criterion: Given empty array or single-element array, the call reverts.
Linked to: UC-K1M8

### Fee Accounting

**FR-K1M6** `When mergePositions completes, the surviving position's fee accounting shall reflect the sum of all consumed positions' uncollected fees with no loss or double-counting.`
Fit Criterion: Given two positions with accrued fees, after merge the surviving position's `tokensOwed` includes both positions' uncollected fees and `feeGrowthInsideLastX128` is set to the current value.
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
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
