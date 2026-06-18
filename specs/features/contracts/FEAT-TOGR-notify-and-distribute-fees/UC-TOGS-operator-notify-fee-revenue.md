---
id: UC-TOGS
name: Operator Notify Fee Revenue
feature: FEAT-TOGR
status: implemented
version: 1
actor: Operator
---

# UC-TOGS: Operator Notify Fee Revenue

> The Operator distributes newly arrived fee revenue across all in-range LP positions by updating the vault's global fee accumulator.

## Preconditions

- A vault clone has been initialized via the factory (FEAT-REPZ)
- The caller holds a registered Operator key

## Trigger

Operator calls `notifyFees(amount)` on the vault.

---

### SC-TOGT: Successful fee notification with active liquidity

**Given:**
- At least one LP position is in range (`activeLiquidity > 0`)
- Operator has deposited `amount` USDC into the vault off-chain

**Steps:**
1. Operator calls `notifyFees(amount)` with amount > 0
2. System validates amount > 0 and activeLiquidity > 0
3. System computes `delta = mulDiv(amount, Q128, activeLiquidity)`
4. System increments `feeGrowthGlobalX128` by delta
5. System emits `FeesNotified(amount, feeGrowthGlobalX128)`

**Outcomes:**
- `feeGrowthGlobalX128` increased by the computed delta
- Call succeeds (no revert)

**Side Effects:**
- `feeGrowthGlobalX128` storage: incremented by `mulDiv(amount, Q128, activeLiquidity)`
- `FeesNotified(amount, feeGrowthGlobalX128)` event emitted
- No USDC transfers during the call
- No position-level state changes (fees accrue lazily via the global accumulator)

---

### SC-TOGU: Sequential notifications accumulate correctly

**Given:**
- `activeLiquidity > 0` (unchanged between calls)
- Operator deposits amounts A and B into the vault separately

**Steps:**
1. Operator calls `notifyFees(A)`
2. System increments `feeGrowthGlobalX128` by `mulDiv(A, Q128, activeLiquidity)`
3. Operator calls `notifyFees(B)`
4. System increments `feeGrowthGlobalX128` by `mulDiv(B, Q128, activeLiquidity)`

**Outcomes:**
- `feeGrowthGlobalX128 == initial + mulDiv(A, Q128, activeLiquidity) + mulDiv(B, Q128, activeLiquidity)`
- Two separate `FeesNotified` events emitted with correct cumulative values

**Side Effects:**
- `feeGrowthGlobalX128` storage updated twice
- Two `FeesNotified` events emitted
- No USDC transfers
- No position-level state changes

---

### SC-TOGV: Revert when no active liquidity

**Given:**
- `activeLiquidity == 0` (no in-range positions)

**Steps:**
1. Operator calls `notifyFees(amount)` with amount > 0
2. System detects `activeLiquidity == 0`
3. System reverts with `NoActiveLiquidity` error

**Outcomes:**
- Call reverts; no state changes

**Side Effects:**
- No storage updates
- No events emitted
- No USDC silently locked

---

### SC-TOGW: Revert for non-Operator caller

**Given:**
- Caller is not a registered Operator (LP, Admin, Oracle, or arbitrary address)

**Steps:**
1. Non-Operator calls `notifyFees(amount)`
2. System checks `operators[msg.sender] == 0`
3. System reverts with `NotOperator` error

**Outcomes:**
- Call reverts; no state changes

**Side Effects:**
- No storage updates
- No events emitted

---

### SC-TOGX: Revert for zero amount

**Given:**
- `activeLiquidity > 0`

**Steps:**
1. Operator calls `notifyFees(0)`
2. System validates amount > 0
3. System reverts with `ZeroAmount` error

**Outcomes:**
- Call reverts; no state changes

**Side Effects:**
- No storage updates
- No events emitted

---

### SC-TOGY: Q128 truncation dust behavior

**Given:**
- `activeLiquidity > 0`
- `amount` and `activeLiquidity` chosen so that `amount * Q128 % activeLiquidity != 0` (non-zero truncation dust)

**Steps:**
1. Operator calls `notifyFees(amount)`
2. System computes `delta = mulDiv(amount, Q128, activeLiquidity)` (truncates toward zero)
3. System increments `feeGrowthGlobalX128` by delta

**Outcomes:**
- `feeGrowthGlobalX128` incremented by the truncated (floor) value
- Dust (< 1/2^128 USDC per unit of liquidity) is economically negligible

**Side Effects:**
- `feeGrowthGlobalX128` storage updated with truncated value
- `FeesNotified` event emitted
- No separate dust tracking

---
