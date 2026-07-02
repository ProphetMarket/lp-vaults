---
id: UC-JXQW
name: Emergency Cancel All
feature: FEAT-JXQO
status: implemented
version: 1
actor: LP
---

# UC-JXQW: Emergency Cancel All

> Any position holder force-closes all open positions in the vault after the Operator has been silent beyond the emergency timelock, distributing each position's principal and accrued fees to its owner and transitioning the vault to a terminal Cancelled state.

## Preconditions

- Vault has been deployed and initialized (phase == Active or WindDown)
- At least one position exists in the vault
- `lastOperatorActivityTimestamp` was set during the most recent Operator action

## Trigger

Any address holding at least one position calls `emergencyCancelAll()` on the vault.

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
5. Oracle calls `startWindDown()` -- reverts
6. Position holder calls `emergencyCancelAll()` again -- reverts

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
