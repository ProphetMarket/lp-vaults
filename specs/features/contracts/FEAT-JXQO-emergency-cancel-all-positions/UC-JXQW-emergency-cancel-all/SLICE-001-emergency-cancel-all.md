---
id: UC-JXQW-001
name: emergency-cancel-all
use_case: UC-JXQW
feature: FEAT-JXQO
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [emergencyCancelAll]
entry_type: contract-call
covers: [SC-JXQX, SC-JXQY, SC-JXQZ, SC-JXR0, SC-JXR1, SC-JXR2, FR-JXQP, FR-JXQQ, FR-JXQR, FR-JXQS, FR-JXQT, NFR-JXQU, NFR-JXQV]
last_update: 2026-07-02
---

# UC-JXQW-001: Emergency Cancel All

## Rationale

Adds the `emergencyCancelAll()` function and supporting infrastructure (constant, event, errors, phase guards) to LPVault. The function iterates all positions (0..nextPositionId-1), computes each position's accrued fees via the existing feeGrowthInside accumulator, distributes principal + fees to each owner as USDC, zeroes all position and tick state, sets activeLiquidity to 0, transitions phase to Cancelled (3), and emits EmergencyCancelExecuted. Also adds `lastOperatorActivityTimestamp = block.timestamp` to `notifyFees` (currently only `updateTick` resets it) and adds `phase == 3` guards to `collect`, `reclaimDeposit`, and `notifyFees` (functions that currently have no phase check but must revert in Cancelled). Covers all 6 scenarios: success (SC-JXQX), timelock revert (SC-JXQY), no-position revert (SC-JXQZ), multi-LP distribution (SC-JXR0), terminal state gating (SC-JXR1), and operator activity reset (SC-JXR2).

## Contracts

### Types

```solidity
// Phase constant (added alongside Active=1, WindDown=2)
// Cancelled = 3 (set by emergencyCancelAll, terminal)

// New constant
uint256 public constant EMERGENCY_CANCEL_TIMELOCK = 7 days;

// New event
event EmergencyCancelExecuted(address indexed caller);

// New errors
error TimelockNotElapsed();
error NoPositionHeld();
error VaultCancelled();
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `emergencyCancelAll` | `function emergencyCancelAll() external` | any position holder + timelock | Reverts with `TimelockNotElapsed` if silence < `EMERGENCY_CANCEL_TIMELOCK`; reverts with `NoPositionHeld` if caller owns no position; reverts with `VaultNotActive` if phase == Cancelled via existing check pattern |

### Behavior

- **Preconditions:** `phase != 3` (not already cancelled); `block.timestamp - lastOperatorActivityTimestamp >= EMERGENCY_CANCEL_TIMELOCK`; `msg.sender` owns at least one position (any positionId where `positions[id].owner == msg.sender`)
- **Postconditions:** `phase == 3`; `activeLiquidity == 0`; every position has `liquidity == 0` and `tokensOwed == 0`; every position owner received their USDC share; `EmergencyCancelExecuted(msg.sender)` emitted
- **Invariants:** `phase` never transitions from 3 to any other value; no state-changing function succeeds when `phase == 3`
- **Error modes:** `TimelockNotElapsed` when silence period hasn't elapsed; `NoPositionHeld` when caller has no position; `VaultCancelled` when phase is already 3 (on collect/reclaimDeposit/notifyFees); `VaultNotActive` when phase != 1 (on mintPositionFor/updateTick/startWindDown — existing guards catch Cancelled too)

## Tests

- **SC-JXQX: Successful emergency cancel after silence timelock**
  - Given an Active vault with one in-range LP position and accrued fees, and `EMERGENCY_CANCEL_TIMELOCK` has elapsed since last operator action
    - When the position holder calls `emergencyCancelAll()`
      - Then `phase` storage reads `3` (Cancelled)
      - And `activeLiquidity == 0`
      - And position liquidity is zeroed
      - And LP USDC balance increased by their principal + accrued fees
      - And `EmergencyCancelExecuted(caller)` event is emitted
      - And vault USDC balance is zero (or dust from Q128 truncation)
- **SC-JXQY: Revert before timelock elapses**
  - Given an Active vault with a position, and `EMERGENCY_CANCEL_TIMELOCK` has NOT elapsed
    - When position holder calls `emergencyCancelAll()`
      - Then transaction reverts with `TimelockNotElapsed()`
      - And no state change
- **SC-JXQZ: Revert if caller holds no position**
  - Given an Active vault and `EMERGENCY_CANCEL_TIMELOCK` has elapsed
    - When an address with no positions calls `emergencyCancelAll()`
      - Then transaction reverts with `NoPositionHeld()`
      - And no state change
- **SC-JXR0: Multi-LP distribution**
  - Given a vault with 3 positions owned by 2 LPs (LP-A: 2 positions, LP-B: 1 position) with varying ranges/liquidity, fees distributed, and timelock elapsed
    - When LP-A calls `emergencyCancelAll()`
      - Then LP-A USDC balance increased by sum of both positions' principal + fees
      - And LP-B USDC balance increased by their position's principal + fees
      - And vault USDC balance is zero (or dust)
      - And all 3 positions have liquidity == 0
      - And `phase == 3`
- **SC-JXR1: Terminal state gates off all operations**
  - Given a vault in Cancelled phase (after successful `emergencyCancelAll()`)
    - When Operator calls `mintPositionFor(...)` — reverts with `VaultNotActive()`
    - When LP calls `collect(positionId)` — reverts with `VaultCancelled()`
    - When Operator calls `notifyFees(amount)` — reverts with `VaultCancelled()`
    - When Operator calls `updateTick(newTick)` — reverts with `VaultNotActive()`
    - When Oracle calls `startWindDown()` — reverts with `VaultNotActive()`
    - When position holder calls `emergencyCancelAll()` again — reverts (phase != Active/WindDown)
- **SC-JXR2: Operator activity resets timelock**
  - Given an Active vault where `EMERGENCY_CANCEL_TIMELOCK` would have elapsed
    - When Operator calls `notifyFees(amount)` (resets `lastOperatorActivityTimestamp`)
      - Then `lastOperatorActivityTimestamp == block.timestamp`
    - When position holder immediately calls `emergencyCancelAll()`
      - Then transaction reverts with `TimelockNotElapsed()`
      - And no emergency cancel occurred
- **FR-JXQP: Emergency cancel after timelock** — Covered by SC-JXQX
- **FR-JXQQ: Revert before timelock** — Covered by SC-JXQY
- **FR-JXQR: Revert if no position** — Covered by SC-JXQZ
- **FR-JXQS: Operator resets timer** — Covered by SC-JXR2
- **FR-JXQT: Cancelled gates everything** — Covered by SC-JXR1
- **NFR-JXQU: One-way terminal state** — Covered by SC-JXR1 (emergencyCancelAll reverts after cancel)
- **NFR-JXQV: Single-transaction close** — Covered by SC-JXR0 (3 positions closed atomically)
