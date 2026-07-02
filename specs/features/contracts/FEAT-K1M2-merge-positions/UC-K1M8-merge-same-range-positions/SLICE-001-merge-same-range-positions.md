---
id: UC-K1M8-001
name: merge-same-range-positions
use_case: UC-K1M8
feature: FEAT-K1M2
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [mergePositions]
entry_type: contract-call
covers: [SC-K1M9, SC-K1MA, SC-K1MB, SC-K1MC, FR-K1M3, FR-K1M4, FR-K1M5, FR-K1M6, NFR-K1M7]
last_update: 2026-07-02
---

# UC-K1M8-001: Merge Same-Range Positions

## Rationale

Adds the `mergePositions(uint256[] calldata positionIds)` function to LPVault. The Operator calls this to combine two or more positions that share the same owner, tickLower, and tickUpper into a single survivor position. The function computes uncollected fees for each position (same formula as `collect`), rolls them into the survivor's `tokensOwed`, sums liquidity into the survivor, sets the survivor's `feeGrowthInsideLastX128` to the current value, and zeroes consumed positions. Tick state (`liquidityGross`, `liquidityNet`) is unchanged since the total liquidity on the range stays the same. Covers all 4 scenarios: successful merge (SC-K1M9), mismatched ranges (SC-K1MA), empty/single input (SC-K1MB), and fee accounting preservation (SC-K1MC).

## Contracts

### Types

```solidity
// New event
event PositionsMerged(uint256[] positionIds, uint256 survivorId);

// New errors
error RangeMismatch();
error InsufficientPositions();
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `mergePositions` | `function mergePositions(uint256[] calldata positionIds) external` | onlyOperator | Reverts with `InsufficientPositions` if < 2 IDs; reverts with `RangeMismatch` if tick ranges differ; all positions must share owner |

### Behavior

- **Preconditions:** `positionIds.length >= 2`; all positions share `owner`, `tickLower`, `tickUpper`; all positions have `liquidity > 0`
- **Postconditions:** survivor (positionIds[0]) has summed liquidity, rolled-up tokensOwed, current feeGrowthInsideLastX128; consumed positions have `liquidity == 0`, `tokensOwed == 0`; tick state unchanged
- **Invariants:** total liquidity on the tick range is unchanged; `liquidityGross` unchanged; no USDC transferred
- **Error modes:** `InsufficientPositions` when < 2 IDs; `RangeMismatch` when tick ranges differ; `NotOperator` when caller is not operator

## Tests

- **SC-K1M9: Successful merge of two same-range positions**
  - Given two positions owned by the same LP with range [0, 100), each with liquidity ~500 (from 500 USDC deposits), and fees distributed
    - When Operator calls `mergePositions([posA, posB])`
      - Then survivor (posA) liquidity == sum of both
      - And consumed (posB) liquidity == 0
      - And `PositionsMerged([posA, posB], posA)` event emitted
      - And tick `liquidityGross` at tickLower and tickUpper unchanged
- **SC-K1MA: Revert on mismatched ranges**
  - Given two positions with different tick ranges (posA: [0, 100), posB: [0, 200))
    - When Operator calls `mergePositions([posA, posB])`
      - Then transaction reverts with `RangeMismatch()`
      - And no state change
- **SC-K1MB: Revert on empty or single-item input**
  - Given positionIds array is empty
    - When Operator calls `mergePositions([])`
      - Then transaction reverts with `InsufficientPositions()`
  - Given positionIds array has one element
    - When Operator calls `mergePositions([posA])`
      - Then transaction reverts with `InsufficientPositions()`
- **SC-K1MC: Fee accounting preserved after merge**
  - Given two positions with different accrued fees, same range
    - When Operator calls `mergePositions([posA, posB])`
      - Then survivor's tokensOwed includes both positions' uncollected fees
      - And survivor's feeGrowthInsideLastX128 == current feeGrowthInside
    - When LP subsequently calls `collect(survivorId)`
      - Then LP receives the rolled-up fees (no loss, no double-counting)
- **FR-K1M3 through FR-K1M6, NFR-K1M7** — Covered by SC-K1M9 through SC-K1MC assertions
