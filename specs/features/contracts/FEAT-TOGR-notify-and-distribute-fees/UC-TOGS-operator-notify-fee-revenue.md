---
id: UC-TOGS
name: Operator Notify Fee Revenue
feature: FEAT-TOGR
status: implemented
version: 4
actor: Operator
---

# UC-TOGS: Operator Notify Fee Revenue

> The Operator distributes newly arrived fee revenue across all in-range LP positions by updating the vault's global fee accumulator, and the vault takes that revenue from the Operator wallet in the same call.

## Preconditions

- A vault clone has been initialized via the factory (FEAT-REPZ)
- The caller holds a registered Operator key
- The Operator wallet holds a standing USDC approval to the vault (NFR-ASNQ)

## Trigger

Operator calls `notifyFees(amount)` on the vault.

---

### SC-TOGT: Successful fee notification with active liquidity

**Given:**
- At least one LP position is in range (`activeLiquidity > 0`)
- The Operator wallet holds at least `amount` USDC and has approved the vault for at least `amount`

**Steps:**
1. Operator calls `notifyFees(amount)` with amount > 0
2. System validates amount > 0 and activeLiquidity > 0
3. System computes `delta = mulDiv(amount, Q128, activeLiquidity)`
4. System increments `feeGrowthGlobalX128` by delta
5. System transfers `amount` USDC from the Operator wallet to the vault with `transferFrom`
6. System emits `FeesNotified(amount, feeGrowthGlobalX128)`

**Outcomes:**
- `feeGrowthGlobalX128` increased by the computed delta
- The vault's USDC balance rose by `amount` and the Operator wallet's balance fell by `amount` in the same transaction
- Call succeeds (no revert)

**Side Effects:**
- `feeGrowthGlobalX128` storage: incremented by `mulDiv(amount, Q128, activeLiquidity)`
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful notification is proof the Operator is alive (FEAT-JXQO)
- `amount` USDC moves from the Operator wallet to the vault: the USDC contract emits `Transfer(operator, vault, amount)` before the vault emits `FeesNotified`
- `FeesNotified(amount, feeGrowthGlobalX128)` event emitted
- No position-level state changes (fees accrue lazily via the global accumulator)

---

### SC-TOGU: Sequential notifications accumulate correctly

**Given:**
- `activeLiquidity > 0` (unchanged between calls)
- The Operator wallet holds at least A + B USDC and has approved the vault for at least A + B

**Steps:**
1. Operator calls `notifyFees(A)`
2. System increments `feeGrowthGlobalX128` by `mulDiv(A, Q128, activeLiquidity)` and takes A USDC from the Operator wallet
3. Operator calls `notifyFees(B)`
4. System increments `feeGrowthGlobalX128` by `mulDiv(B, Q128, activeLiquidity)` and takes B USDC from the Operator wallet

**Outcomes:**
- `feeGrowthGlobalX128 == initial + mulDiv(A, Q128, activeLiquidity) + mulDiv(B, Q128, activeLiquidity)`
- The vault's USDC balance rose by A + B
- Two separate `FeesNotified` events emitted with correct cumulative values

**Side Effects:**
- `feeGrowthGlobalX128` storage updated twice
- `lastOperatorActivityTimestamp` storage refreshed on each call
- Two USDC transfers from the Operator wallet to the vault, A then B
- Two `FeesNotified` events emitted
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
- No storage updates -- in particular `lastOperatorActivityTimestamp` is NOT refreshed, so a market with no fee revenue cannot prove Operator liveness through this path; `heartbeat()` exists for that (FEAT-JXQO)
- No events emitted

---

### SC-TOGY: Q128 truncation dust behavior

**Given:**
- `activeLiquidity > 0`
- `amount` and `activeLiquidity` chosen so that `amount * Q128 % activeLiquidity != 0` (non-zero truncation dust)
- The Operator wallet holds and has approved `amount` USDC

**Steps:**
1. Operator calls `notifyFees(amount)`
2. System computes `delta = mulDiv(amount, Q128, activeLiquidity)` (truncates toward zero)
3. System increments `feeGrowthGlobalX128` by delta
4. System takes `amount` USDC from the Operator wallet

**Outcomes:**
- `feeGrowthGlobalX128` incremented by the truncated (floor) value
- Dust (< 1/2^128 USDC per unit of liquidity) is economically negligible

**Side Effects:**
- `feeGrowthGlobalX128` storage updated with truncated value
- `amount` USDC moves from the Operator wallet to the vault, so the truncation dust is USDC that the vault holds and that no position can claim
- `FeesNotified` event emitted
- No separate dust tracking

---

### SC-ASNK: Revert when the Operator did not fund the report

**Given:**
- `activeLiquidity > 0`
- One of two cases holds: (A) the Operator wallet holds less than `amount` USDC, or (B) the Operator wallet holds `amount` USDC but has approved the vault for less than `amount`

**Steps:**
1. Operator calls `notifyFees(amount)` with amount > 0
2. System passes the phase, amount, and liquidity checks and increments `feeGrowthGlobalX128`
3. System calls `transferFrom` on the USDC contract, which rejects the transfer
4. System reverts with `TransferFailed`, which rolls back the increment

**Outcomes:**
- Call reverts
- `feeGrowthGlobalX128` is unchanged
- The vault's and the Operator wallet's USDC balances are unchanged
- `lastOperatorActivityTimestamp` is unchanged, because a reverted call is not proof of life

**Side Effects:**
- No storage updates
- No events emitted
- No USDC moves

---

### SC-COF0: Revert when the amount is above 2^128

**Given:**
- `activeLiquidity > 0`
- The Operator wallet holds and has approved `2^128 + 1` USDC base units, an amount above 3.4 × 10^32 USDC

**Steps:**
1. Operator calls `notifyFees(2^128 + 1)`
2. System computes the accumulator increment and multiplies it by `activeLiquidity` for the fee total of the solvency ledger (FEAT-9BQZ FR-9BRA), which does not fit in 256 bits
3. System reverts with an arithmetic panic before the USDC pull

**Outcomes:**
- Call reverts
- `feeGrowthGlobalX128`, `totalFeesOwedX128`, and both USDC balances are unchanged
- A report of `2^128 − 1` succeeds and credits `growth × activeLiquidity` to the fee total (NFR-COEV)

**Side Effects:**
- No storage updates
- No events emitted
- No USDC moves

---
