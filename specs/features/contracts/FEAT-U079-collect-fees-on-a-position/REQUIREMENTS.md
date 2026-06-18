---
id: FEAT-U079
name: Collect Fees on a Position
module: contracts
domain: "@positions"
status: implemented
version: 1
refs: [FEAT-TVS0]
---

# Collect Fees on a Position

> Enables an LP to withdraw accumulated trading fees from their position without removing it, using the v3 feeGrowthInside accumulator to compute what's owed and snapshotting the position to prevent double-counting.

## Non-Goals

- Does not remove the position or return the LP's original deposit -- see feature 6 (Burn LP Position)
- Does not handle fee notification or global accumulator updates -- see FEAT-TOGR
- Does not handle tick crossing or feeGrowthOutside flipping -- see FEAT-TVS0
- Does not handle vault lifecycle transitions (wind-down/emergency) -- see feature 8

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Calls `collect(positionId)` to withdraw earned fees | Only the position's owner can collect; verified via `position.owner == msg.sender` |

## Functional Requirements

### Fee Computation

**FR-U07H** `When the LP calls collect(positionId), the system shall compute feeGrowthInsideX128 for the position's [tickLower, tickUpper] range using feeGrowthGlobalX128 and each boundary tick's feeGrowthOutsideX128.`
Fit Criterion: Given feeGrowthGlobalX128 = G, ticks[tickLower].feeGrowthOutsideX128 and ticks[tickUpper].feeGrowthOutsideX128 reflecting accumulated fees below and above the range, feeGrowthInsideX128 = G - feeGrowthBelow - feeGrowthAbove per the v3 formula.
Linked to: UC-U07A

**FR-U07I** `When collect computes feeGrowthInsideX128, the system shall calculate owed fees as liquidity * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128, truncating toward zero.`
Fit Criterion: Given a position with liquidity L whose feeGrowthInsideX128 grew by delta since the last collect (or mint), the owed amount = L * delta / 2^128 (truncated), matching the v3 fee accounting.
Linked to: UC-U07A

### Snapshot

**FR-U07J** `When collect completes, the system shall set the position's feeGrowthInsideLastX128 to the current feeGrowthInsideX128 value.`
Fit Criterion: Given a collect at time T, a subsequent collect at time T+1 with no new fee growth produces zero owed fees.
Linked to: UC-U07A

### Payout

**FR-U07K** `When collect computes a nonzero owed amount, the system shall transfer that amount in USDC to the position's owner and emit a FeesCollected event with positionId, owner, and amount.`
Fit Criterion: Given owed > 0, the LP's USDC balance increases by exactly the owed amount after collect, and a FeesCollected(positionId, owner, amount) event is emitted.
Linked to: UC-U07A

**FR-U07L** `When collect computes zero owed fees, the system shall succeed without performing a USDC transfer.`
Fit Criterion: Given no fee growth since the last collect, no USDC transfer occurs and the transaction succeeds.
Linked to: UC-U07A

### Access Control

**FR-U07M** `If the caller is not the position's owner, then the system shall revert.`
Fit Criterion: Given position.owner != msg.sender, collect(positionId) reverts with a NotPositionOwner error.
Linked to: UC-U07A

**FR-U07N** `If positionId does not correspond to an existing position, then the system shall revert.`
Fit Criterion: Given a nonexistent positionId, collect(positionId) reverts with a PositionNotFound error.
Linked to: UC-U07A

### Phase Independence

**FR-U07O** `While the vault is in any phase (Active or WindDown), the system shall allow collect to proceed.`
Fit Criterion: Given a vault in WindDown phase, collect succeeds for valid positions with accrued fees, identical to Active phase behavior.
Linked to: UC-U07A

## Non-Functional Requirements

**NFR-U07P** Gas: `When the LP collects fees on a single position, the total gas cost shall remain below 100,000 gas on Polygon.`

**NFR-U07Q** Security: `The system shall apply an inline nonReentrant modifier on collect to prevent reentrancy via the USDC transfer callback.`

**NFR-U07R** Security: `The system shall follow checks-effects-interactions ordering in collect: validate ownership first, update position state (feeGrowthInsideLastX128 snapshot) second, transfer USDC last.`

**NFR-U07S** Security: `The system shall use an inline _safeTransfer helper for the USDC payout to handle both bool-returning and non-bool-returning ERC-20s (USDT semantics).`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-U07A pass with full coverage
- Non-owner callers cannot collect (FR-U07M verified in SC-U07D)
- Sequential collects with no fee growth produce zero payout (no double-counting, SC-U07G)
- Collect works in both Active and WindDown phases (SC-U07F)
- feeGrowthInsideX128 matches v3 formula: global - below(lower) - above(upper)
- Q128 truncation dust verified via fuzz test
- Inline nonReentrant guard on collect
- Checks-effects-interactions ordering verified
- Inline _safeTransfer used (no SafeERC20 import)
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
