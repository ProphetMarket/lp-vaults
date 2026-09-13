---
id: FEAT-JXQO
name: Emergency Cancel All Positions
module: contracts
domain: "@vault"
status: implemented
version: 5
refs: [FEAT-REPZ, FEAT-JGE7, FEAT-TVS0]
---

# Emergency Cancel All Positions

> User-side safety net that lets any position holder force-close all open positions and distribute principal + accrued fees after the Operator has been silent beyond a configurable timelock, transitioning the vault to a terminal Cancelled state.

## Non-Goals

- Does not handle individual position cancellation -- this is a vault-wide emergency operation
- Does not handle Operator key recovery -- the assumption is the Operator is permanently absent
- Does not provide a mechanism to un-cancel -- the Cancelled state is terminal
- Does not prevent an Operator that is alive but uncooperative from calling `heartbeat()` indefinitely to hold off `emergencyCancelAll` -- see ADR-3XU3

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP (any position holder) | Calls `emergencyCancelAll()` after operator silence | Must hold at least one position in the vault; not restricted to a specific LP |

## Functional Requirements

### Emergency Cancel

**FR-JXQP** `When any position holder calls emergencyCancelAll() after the operator-silence timelock has elapsed since the last Operator action, the system shall close all open positions, distribute each position's principal and accrued fees to its owner, transition the vault to the Cancelled phase (3), and emit an EmergencyCancelExecuted event.`
Fit Criterion: Given `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK` and caller owns at least one position, all positions are closed, each owner's USDC increases by their share, `phase == 3`, `activeLiquidity == 0`, and `EmergencyCancelExecuted(caller)` is emitted.
Linked to: UC-JXQW

**FR-JXQQ** `If emergencyCancelAll() is called before the operator-silence timelock has elapsed since the last Operator action, then the system shall revert.`
Fit Criterion: Given `block.timestamp - lastOperatorActivityTimestamp < EMERGENCY_CANCEL_TIMELOCK`, the call reverts.
Linked to: UC-JXQW

**FR-JXQR** `If emergencyCancelAll() is called by an address that holds no position in the vault, then the system shall revert.`
Fit Criterion: Given caller has no position where `position.owner == msg.sender`, the call reverts.
Linked to: UC-JXQW

### Operator Silence Timer

**FR-JXQS** `When any Operator-gated vault function completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given the Operator successfully calls any of `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`, or `heartbeat`, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given the call reverts for any reason, `lastOperatorActivityTimestamp` is unchanged.
Linked to: UC-JXQW

**FR-3XTW** `When the Operator calls heartbeat(), the system shall reset lastOperatorActivityTimestamp to block.timestamp and change no other vault state.`
Fit Criterion: Given the Operator calls `heartbeat()`, `lastOperatorActivityTimestamp == block.timestamp` and `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, `phase`, and every position and tick record are unchanged. `heartbeat()` succeeds while the vault is paused and while the vault is in WindDown, because a pause is an Admin decision about trading and a wind-down is an Oracle decision about the market, and neither says whether the Operator is alive.
Linked to: UC-JXQW

**FR-3XTX** `If any caller other than a registered Operator calls heartbeat(), then the system shall revert.`
Fit Criterion: Given an LP, Admin, Oracle, or arbitrary address calls `heartbeat()`, the call reverts with an access control error and `lastOperatorActivityTimestamp` is unchanged.
Linked to: UC-JXQW

**FR-3XTY** `If heartbeat() is called while the vault phase is Cancelled (3), then the system shall revert.`
Fit Criterion: Given `phase == 3`, `heartbeat()` reverts. There is nothing left to protect once every position has been closed and distributed, so refreshing the silence timer serves no purpose.
Linked to: UC-JXQW

### Cancelled Phase Gating

**FR-JXQT** `While the vault phase is Cancelled (3), when any address calls a trading entry point, the system shall revert; every LP exit and the complete-set merge succeed.`
Fit Criterion: Given `phase == 3`, calls to `mintPositionFor`, `depositForIntent`, `notifyFees`, `updateTick`, `mergePositions`, `heartbeat`, `startWindDown`, and `emergencyCancelAll` all revert. `reclaimDeposit`, `reclaimDepositFor`, `collect`, `collectFor`, `burnPosition`, `burnPositionFor`, and `mergeCompleteSets` do not revert on the phase (FEAT-JAIJ FR-9OYO, FEAT-U079 FR-U07O, FEAT-7G40 FR-7G4V, FEAT-6HBN FR-6HC1). At this step the cancel still zeroes every position, so a burn of a cancelled position reverts `PositionNotFound` and a collect pays zero; R10 makes the cancel a freeze, after which both pay in full. Decision C9.
Linked to: UC-JXQW

## Non-Functional Requirements

**NFR-JXQU** Security: `The Cancelled phase shall be a one-way terminal state with no mechanism to revert to Active or WindDown.`

**NFR-JXQV** Gas: `emergencyCancelAll() shall close all positions in a single transaction. The function is bounded by the number of positions in the vault, which is expected to be in the low hundreds for Prophet markets.`

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Position holders can emergency-cancel after operator silence timelock
- Non-position-holders rejected
- Early callers (before timelock) rejected
- All position owners receive principal + accrued fees
- activeLiquidity zeroed
- Vault enters terminal Cancelled state (phase 3)
- All vault operations revert after cancel
- Every successful Operator-gated call (mintPositionFor, notifyFees, updateTick, mergePositions, heartbeat) resets the silence timer
- A reverted Operator call leaves the silence timer untouched
- `heartbeat()` is Operator-only, changes no other state, works while paused, and reverts once the vault is Cancelled
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
