---
id: UC-JXQW
name: Emergency Cancel All
feature: FEAT-JXQO
status: implemented
version: 3
actor: LP
---

# UC-JXQW: Emergency Cancel All

> Any position holder force-closes all open positions in the vault after the Operator has been silent beyond the emergency timelock, distributing each position's principal and accrued fees to its owner and transitioning the vault to a terminal Cancelled state.

## Preconditions

- Vault has been deployed and initialized (phase == Active or WindDown)
- At least one position exists in the vault
- `lastOperatorActivityTimestamp` was set during the most recent successful Operator action

## Trigger

Any address holding at least one position calls `emergencyCancelAll()` on the vault.

The silence timer this use case reads is refreshed by every successful Operator-gated call -- `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`, and the dedicated `heartbeat()`. A call that reverts does not refresh it. On a quiet Active market the keeper's report with the unchanged tick refreshes the timer and does not revert (SC-TVS7). `heartbeat()` exists for a vault that is paused or wound down, where `updateTick` reverts, and for an Operator with no report to send. Every later Operator function carries `touchesHeartbeat` (`CLAUDE.md`, hard rules).

---

### SC-JXQX: Successful emergency cancel after silence timelock

**Given:**
- Vault is in Active phase with one LP position (in-range, with accrued fees)
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK`

**Steps:**
1. Position holder calls `emergencyCancelAll()` on the vault
2. System validates the operator-silence timelock has elapsed
3. System validates the caller owns at least one position
4. System iterates all positions, computes each position's principal + accrued fees
5. System transfers each position's share to its owner
6. System zeroes all position liquidity and tick state
7. System transitions phase to Cancelled (3)

**Outcomes:**
- Vault phase is Cancelled (3)
- `activeLiquidity == 0`
- All position owners received their USDC (principal + accrued fees)

**Side Effects:**
- `EmergencyCancelExecuted(address indexed caller)` event emitted
- All positions zeroed (liquidity = 0, tokensOwed = 0)
- USDC transferred from vault to each position owner
- No new positions created

---

### SC-JXQY: Revert before timelock elapses

**Given:**
- Vault is in Active phase with at least one position
- `block.timestamp - lastOperatorActivityTimestamp < EMERGENCY_CANCEL_TIMELOCK`

**Steps:**
1. Position holder calls `emergencyCancelAll()`
2. System checks timelock
3. System reverts

**Outcomes:**
- Transaction reverts with timelock error

**Side Effects:**
- No state change
- No event emitted

---

### SC-JXQZ: Revert if caller holds no position

**Given:**
- Vault is in Active phase
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK`
- Caller owns zero positions in this vault

**Steps:**
1. Non-position-holder calls `emergencyCancelAll()`
2. System checks caller's position ownership
3. System reverts

**Outcomes:**
- Transaction reverts with access control error

**Side Effects:**
- No state change
- No event emitted

---

### SC-JXR0: Multi-LP distribution

**Given:**
- Vault has 3 positions owned by 2 different LPs (LP-A has 2 positions, LP-B has 1)
- Each position has different ranges and liquidity amounts
- Fees have been distributed via `notifyFees`
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK`

**Steps:**
1. LP-A calls `emergencyCancelAll()`
2. System computes each position's share (principal + accrued fees)
3. System transfers LP-A's total (sum of 2 positions) to LP-A
4. System transfers LP-B's total (1 position) to LP-B

**Outcomes:**
- LP-A received principal + fees for both positions
- LP-B received principal + fees for their position
- Vault USDC balance is zero (or dust)

**Side Effects:**
- `EmergencyCancelExecuted(LP-A)` event emitted
- All 3 positions zeroed
- USDC transferred to both LP-A and LP-B

---

### SC-JXR1: Terminal state gates off all operations

**Given:**
- Vault phase is Cancelled (3) after a successful `emergencyCancelAll()`

**Steps:**
1. Operator calls `mintPositionFor(...)` -- reverts
2. LP calls `collect(positionId)` -- reverts
3. Operator calls `notifyFees(amount)` -- reverts
4. Operator calls `updateTick(newTick)` -- reverts
5. Operator calls `mergePositions(...)` -- reverts
6. Operator calls `heartbeat()` -- reverts
7. Oracle calls `startWindDown()` -- reverts
8. Position holder calls `emergencyCancelAll()` again -- reverts

**Outcomes:**
- All calls revert with phase error

**Side Effects:**
- No state change
- No events emitted

---

### SC-JXR2: Operator activity resets timelock

**Given:**
- Vault is in Active phase
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK` (timelock would have elapsed)

**Steps:**
1. Operator calls `notifyFees(amount)` (resets `lastOperatorActivityTimestamp`)
2. Position holder immediately calls `emergencyCancelAll()`
3. System checks timelock -- it has NOT elapsed since the recent `notifyFees`
4. System reverts

**Outcomes:**
- Transaction reverts with timelock error
- `lastOperatorActivityTimestamp` reflects the `notifyFees` call time

**Side Effects:**
- Fee distribution from `notifyFees` succeeded
- No emergency cancel occurred
- No `EmergencyCancelExecuted` event emitted

---

### SC-3XTZ: Heartbeat defers emergency cancel on a quiet market

**Given:**
- Vault is in Active phase, not paused, with at least one position
- The market is quiet and stable: the tick has not moved and no fee revenue has arrived, so `notifyFees` would revert with `ZeroAmount`
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK` (timelock would have elapsed)

**Steps:**
1. Operator calls `heartbeat()`
2. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
3. Position holder immediately calls `emergencyCancelAll()`
4. System checks the timelock -- it has NOT elapsed since the `heartbeat()`
5. System reverts
6. Time advances past the timelock again
7. Operator calls `updateTick(currentTick)`, the keeper's normal 60-second report
8. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp` and returns without a crossing or an event (SC-TVS7)
9. Position holder immediately calls `emergencyCancelAll()`
10. System checks the timelock -- it has NOT elapsed since the report
11. System reverts

**Outcomes:**
- `heartbeat()` and `updateTick(currentTick)` both succeeded
- Neither reverts on a quiet Active market
- Each `emergencyCancelAll()` reverts with the timelock error
- A healthy Operator on a market with no other work to do is no longer indistinguishable from a silent one

**Side Effects:**
- `lastOperatorActivityTimestamp` updated to `block.timestamp` on each of the two Operator calls
- No change to `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, `phase`, or any position or tick record
- No `TickUpdated` event emitted
- No USDC transferred
- No emergency cancel occurred and no `EmergencyCancelExecuted` event emitted

---

### SC-3XU0: Position minting and merging reset the timelock

**Given:**
- Vault is in Active phase
- `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK` (timelock would have elapsed)

**Steps:**
1. Operator calls `mintPositionFor(...)` for an LP
2. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
3. Position holder calls `emergencyCancelAll()` and the call reverts on the timelock
4. Time advances past the timelock again
5. Operator calls `mergePositions(...)` on two same-range positions
6. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
7. Position holder calls `emergencyCancelAll()` and the call reverts on the timelock

**Outcomes:**
- Both Operator actions refreshed the silence timer
- Active deposit processing and position housekeeping now count as proof of life, where previously neither did

**Side Effects:**
- `lastOperatorActivityTimestamp` updated on each of the two Operator calls
- The mint and merge produced their own normal side effects
- No emergency cancel occurred and no `EmergencyCancelExecuted` event emitted

---

### SC-3XU1: Non-Operator cannot call heartbeat

**Given:**
- Vault is in Active phase
- Caller is an LP, Admin, Oracle, or arbitrary address -- not a registered Operator

**Steps:**
1. Non-Operator calls `heartbeat()`
2. System checks the `onlyOperator` gate

**Outcomes:**
- The call reverts with an access control error
- `lastOperatorActivityTimestamp` is unchanged, so a non-Operator cannot hold off `emergencyCancelAll`

**Side Effects:**
- No state changes
- No events emitted

---

### SC-3XUO: Heartbeat still works while trading is paused or the vault is wound down

**Given:**
- Case A: Vault is in Active phase and an Admin has called `pauseTrading()`, so `paused == true`. Every other Operator-gated function (`mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`) reverts on the `whenNotPaused` gate
- Case B: the Oracle has called `startWindDown()`, so `phase == 2`, and `updateTick` reverts with `VaultNotActive`, so the keeper's unchanged report cannot refresh the timer

**Steps:**
1. Operator calls `heartbeat()`
2. System checks the Operator gate and the Cancelled-phase guard, but not the pause flag and not the Active phase

**Outcomes:**
- In both cases the call succeeds and `lastOperatorActivityTimestamp == block.timestamp`
- A pause is an Admin decision about trading, and a wind-down is an Oracle decision about the market. Neither says whether the Operator is alive, so neither state drifts toward emergency cancellation while its Operator is still responding
- The keeper calls `heartbeat()` in both states

**Side Effects:**
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No change to any other vault state
- No events emitted

---

### SC-3XU2: Heartbeat reverts once the vault is Cancelled

**Given:**
- Vault phase is Cancelled (3) after a successful `emergencyCancelAll()`

**Steps:**
1. Operator calls `heartbeat()`
2. System checks the Cancelled-phase guard

**Outcomes:**
- The call reverts with the phase error
- There is nothing left to protect once every position has been closed and distributed

**Side Effects:**
- No state changes
- No events emitted

---
