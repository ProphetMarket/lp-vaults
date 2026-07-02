---
id: FEAT-JXQO
name: Emergency Cancel All Positions
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: [FEAT-REPZ, FEAT-JGE7]
---

# Emergency Cancel All Positions

> User-side safety net that lets any position holder force-close all open positions and distribute principal + accrued fees after the Operator has been silent beyond a configurable timelock, transitioning the vault to a terminal Cancelled state.

## Non-Goals

- Does not handle individual position cancellation -- this is a vault-wide emergency operation
- Does not handle Operator key recovery -- the assumption is the Operator is permanently absent
- Does not provide a mechanism to un-cancel -- the Cancelled state is terminal
- Does not handle `mergePositions` -- that function does not exist yet

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

**FR-JXQS** `When the Operator calls notifyFees or updateTick, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given Operator calls `notifyFees(amount)`, `lastOperatorActivityTimestamp == block.timestamp`. (updateTick already does this; notifyFees does not yet.)
Linked to: UC-JXQW

### Cancelled Phase Gating

**FR-JXQT** `While the vault phase is Cancelled (3), when any address calls any state-changing function, the system shall revert.`
Fit Criterion: Given `phase == 3`, calls to `mintPositionFor`, `collect`, `notifyFees`, `updateTick`, `startWindDown`, `reclaimDeposit`, and `emergencyCancelAll` all revert.
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
- Operator activity (notifyFees, updateTick) resets the silence timer
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
