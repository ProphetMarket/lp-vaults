---
id: UC-KX5O
name: Schedule and Apply Implementation Upgrade
feature: FEAT-KX5N
status: implemented
version: 1
actor: Admin
---

# UC-KX5O: Schedule and Apply Implementation Upgrade

> Admin schedules a new LPVault implementation address on the factory with a 7-day timelock, then either applies it (updating the pointer and incrementing the version counter) or cancels the pending schedule.

## Preconditions

- Factory is deployed with a valid implementation address
- Caller is a registered Admin in the factory's admin registry

## Trigger

Admin calls `scheduleImplementation(newImpl)`, `applyImplementation()`, or `cancelScheduledImplementation()` on the factory.

---

### SC-KX5P: Admin schedules a new implementation

**Given:**
- No pending schedule exists (`pendingImplementation == address(0)`)

**Steps:**
1. Admin calls `scheduleImplementation(newImpl)` with a valid non-zero address
2. System stores `pendingImplementation = newImpl` and `implementationUnlockAt = block.timestamp + 7 days`

**Outcomes:**
- `pendingImplementation == newImpl`
- `implementationUnlockAt == block.timestamp + 7 days`

**Side Effects:**
- `ImplementationScheduled(newImpl, unlockAt)` event emitted
- No change to `implementation` or `implementationVersion`

---

### SC-KX5Q: Admin applies after timelock

**Given:**
- A pending schedule exists and `block.timestamp >= implementationUnlockAt`

**Steps:**
1. Admin calls `applyImplementation()`
2. System updates `implementation` to `pendingImplementation`, increments `implementationVersion`, clears pending state

**Outcomes:**
- `implementation == newImpl` (the previously pending address)
- `implementationVersion` incremented by 1
- `pendingImplementation == address(0)`
- `implementationUnlockAt == 0`

**Side Effects:**
- `ImplementationApplied(newImpl, version)` event emitted

---

### SC-KX5R: New vault uses updated implementation and version

**Given:**
- Implementation was just updated via `applyImplementation()`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minFirstLiq)`
2. Factory deploys an EIP-1167 clone of the current `implementation`
3. Factory calls `initialize()` on the clone, passing the current `implementationVersion`

**Outcomes:**
- New vault clone uses the updated implementation bytecode
- Vault's `implementationVersion` matches the factory's current counter

**Side Effects:**
- `VaultCreated` event emitted (existing behavior)
- No additional events

---

### SC-KX5S: Admin cancels pending schedule

**Given:**
- A pending schedule exists

**Steps:**
1. Admin calls `cancelScheduledImplementation()`
2. System clears `pendingImplementation` and `implementationUnlockAt`

**Outcomes:**
- `pendingImplementation == address(0)`
- `implementationUnlockAt == 0`
- `implementation` unchanged

**Side Effects:**
- `ImplementationCancelled(cancelledImpl)` event emitted

---

### SC-KX5T: Apply reverts before timelock

**Given:**
- Pending schedule exists but `block.timestamp < implementationUnlockAt`

**Steps:**
1. Admin calls `applyImplementation()`
2. System reverts

**Outcomes:**
- Transaction reverts with timelock error

**Side Effects:**
- No state change
- No event emitted

---

### SC-KX5U: Revert when no pending schedule

**Given:**
- No pending schedule (`pendingImplementation == address(0)`)

**Steps:**
1. Admin calls `applyImplementation()` or `cancelScheduledImplementation()`
2. System reverts

**Outcomes:**
- Transaction reverts with no-pending error

**Side Effects:**
- No state change
- No event emitted

---

### SC-KX5V: Revert on zero address

**Given:**
- Admin calls `scheduleImplementation(address(0))`

**Steps:**
1. System validates `newImpl != address(0)`
2. System reverts

**Outcomes:**
- Transaction reverts

**Side Effects:**
- No state change
- No event emitted

---

### SC-KX5W: Non-admin callers revert

**Given:**
- Caller is Operator, LP, or arbitrary address

**Steps:**
1. Caller calls `scheduleImplementation(addr)`, `applyImplementation()`, or `cancelScheduledImplementation()`
2. System reverts

**Outcomes:**
- All three functions revert with `NotAdmin`

**Side Effects:**
- No state change
- No event emitted

---
