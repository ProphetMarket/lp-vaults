---
id: UC-K1MK
name: Pause and Unpause Vault
feature: FEAT-K1MD
status: implemented
version: 3
actor: Admin
---

# UC-K1MK: Pause and Unpause Vault

> Admin toggles the vault's pause flag to halt all trading entry points as a circuit breaker, while keeping LP exit paths (burnPosition, reclaimDeposit) live so capital is never trapped.

## Preconditions

- Vault is initialized
- Admin address is registered in the factory's admin registry

## Trigger

Admin calls `pauseTrading()` or `unpauseTrading()` on the vault.

---

### SC-K1ML: Admin pauses vault and gated functions revert

**Given:**
- Vault is unpaused and in Active phase with at least one position

**Steps:**
1. Admin calls `pauseTrading()`
2. Operator calls `mintPositionFor(...)` -- reverts
3. Operator calls `updateTick(newTick)` -- reverts

**Outcomes:**
- All gated functions revert with paused error
- `paused == true`

**Side Effects:**
- `TradingPaused(address indexed caller)` event emitted
- No state changes from reverted calls

---

### SC-K1MM: Unpause returns vault to normal

**Given:**
- Vault is paused

**Steps:**
1. Admin calls `unpauseTrading()`
2. Operator calls `updateTick(newTick)` with a changed tick -- succeeds

**Outcomes:**
- `paused == false`
- Gated functions work normally again

**Side Effects:**
- `TradingUnpaused(address indexed caller)` event emitted

---

### SC-K1MN: Revert if non-Admin calls

**Given:**
- Vault is Active and unpaused

**Steps:**
1. Operator calls `pauseTrading()` -- reverts
2. LP calls `pauseTrading()` -- reverts
3. Arbitrary address calls `unpauseTrading()` -- reverts

**Outcomes:**
- All revert with `NotAdmin`

**Side Effects:**
- No state change
- No events emitted

---

### SC-K1MP: ReclaimDeposit works while paused

**Given:**
- Vault is paused
- The Operator escrowed the Safe's USDC against an intent that was not minted

**Steps:**
1. The Safe calls `reclaimDeposit(intentId)`

**Outcomes:**
- USDC transferred to the Safe successfully

**Side Effects:**
- USDC transferred to the Safe
- `intentId` marked as used
- Escrow deleted
- No revert

---
