---
id: FEAT-K1MD
name: Pause Trading
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: [FEAT-REPZ]
---

# Pause Trading

> Admin-callable circuit breaker that halts all vault trading entry points (mintPositionFor, notifyFees, updateTick, mergePositions) while keeping LP exit paths (collect, reclaimDeposit) live so capital is never trapped.

## Non-Goals

- Does not pause `collect` or `reclaimDeposit` -- LP exit paths are always open
- Does not pause `emergencyCancelAll` -- the safety net must work even when paused
- Does not auto-unpause -- Admin must explicitly call `unpauseTrading()`

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Admin | Calls `pauseTrading()` and `unpauseTrading()` | Registry-only authority; pause is a circuit breaker |

## Functional Requirements

### Pause

**FR-K1ME** `When an Admin calls pauseTrading() on a vault, the system shall set the paused flag to true and emit a TradingPaused event.`
Fit Criterion: Given an unpaused vault, after `pauseTrading()`, `paused == true` and `TradingPaused(caller)` emitted.
Linked to: UC-K1MK

**FR-K1MF** `While the vault is paused, when any address calls mintPositionFor, notifyFees, updateTick, or mergePositions, the system shall revert.`
Fit Criterion: Given paused vault, all four functions revert.
Linked to: UC-K1MK

### Unpause

**FR-K1MG** `When an Admin calls unpauseTrading() on a paused vault, the system shall set the paused flag to false and emit a TradingUnpaused event.`
Fit Criterion: Given paused vault, after `unpauseTrading()`, `paused == false` and `TradingUnpaused(caller)` emitted.
Linked to: UC-K1MK

### Access Control

**FR-K1MH** `If a non-Admin address calls pauseTrading() or unpauseTrading(), then the system shall revert.`
Fit Criterion: Given non-Admin caller, both functions revert with `NotAdmin`.
Linked to: UC-K1MK

### LP Exit Paths

**FR-K1MI** `While the vault is paused, when the position owner calls collect or reclaimDeposit, the system shall succeed.`
Fit Criterion: Given paused vault with an existing position, `collect` and `reclaimDeposit` succeed.
Linked to: UC-K1MK

## Non-Functional Requirements

**NFR-K1MJ** Security: `The pause mechanism shall be independent of the phase state machine -- pausing does not change the vault's phase, and unpausing restores normal phase-gated behavior.`

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Admin can pause and unpause
- Trading functions revert while paused
- LP exit paths (collect, reclaimDeposit) succeed while paused
- Non-Admin callers rejected
- Pause is independent of phase state machine
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
