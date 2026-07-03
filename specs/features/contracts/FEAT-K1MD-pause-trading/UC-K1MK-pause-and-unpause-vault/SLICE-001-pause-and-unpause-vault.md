---
id: UC-K1MK-001
name: pause-and-unpause-vault
use_case: UC-K1MK
feature: FEAT-K1MD
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: [UC-K1M8-001]
provides: [pauseTrading, unpauseTrading]
entry_type: contract-call
covers: [SC-K1ML, SC-K1MM, SC-K1MN, SC-K1MO, SC-K1MP, FR-K1ME, FR-K1MF, FR-K1MG, FR-K1MH, FR-K1MI, NFR-K1MJ]
last_update: 2026-07-02
---

# UC-K1MK-001: Pause and Unpause Vault

## Rationale

Adds the `pauseTrading()` and `unpauseTrading()` functions, a `bool public paused` storage field, and an inline `whenNotPaused` modifier to LPVault. The modifier is applied to `mintPositionFor`, `notifyFees`, `updateTick`, and `mergePositions` (hence the dependency on UC-K1M8-001). It is NOT applied to `collect`, `reclaimDeposit`, `emergencyCancelAll`, or `startWindDown` — LP exit paths and lifecycle functions remain live. The `paused` flag is independent of the phase state machine. Covers all 5 scenarios: pause + gated reverts (SC-K1ML), unpause (SC-K1MM), non-admin revert (SC-K1MN), collect while paused (SC-K1MO), and reclaimDeposit while paused (SC-K1MP).

## Contracts

### Types

```solidity
// New storage field
bool public paused;

// New events
event TradingPaused(address indexed caller);
event TradingUnpaused(address indexed caller);

// New error
error TradingIsPaused();

// New modifier (inlined)
modifier whenNotPaused() {
    if (paused) revert TradingIsPaused();
    _;
}
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `pauseTrading` | `function pauseTrading() external` | onlyAdmin | Sets `paused = true`; emits `TradingPaused` |
| `unpauseTrading` | `function unpauseTrading() external` | onlyAdmin | Sets `paused = false`; emits `TradingUnpaused` |

### Behavior

- **Preconditions:** caller must be Admin (via factory delegation)
- **Postconditions:** `paused` flag toggled; corresponding event emitted; `whenNotPaused` modifier gates `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`
- **Invariants:** pause does not change `phase`; LP exit paths (`collect`, `reclaimDeposit`) and safety net (`emergencyCancelAll`) are unaffected by pause
- **Error modes:** `NotAdmin` when caller is not admin; `TradingIsPaused` when a gated function is called while paused

## Tests

- **SC-K1ML: Admin pauses vault and gated functions revert**
  - Given an unpaused Active vault with at least one position
    - When Admin calls `pauseTrading()`
      - Then `paused == true`
      - And `TradingPaused(admin)` event emitted
    - When Operator calls `mintPositionFor(...)` — reverts with `TradingIsPaused()`
    - When Operator calls `notifyFees(amount)` — reverts with `TradingIsPaused()`
    - When Operator calls `updateTick(newTick)` — reverts with `TradingIsPaused()`
- **SC-K1MM: Unpause returns vault to normal**
  - Given a paused vault
    - When Admin calls `unpauseTrading()`
      - Then `paused == false`
      - And `TradingUnpaused(admin)` event emitted
    - When Operator calls `notifyFees(amount)` — succeeds
- **SC-K1MN: Revert if non-Admin calls**
  - Given an Active unpaused vault
    - When Operator calls `pauseTrading()` — reverts with `NotAdmin()`
    - When LP calls `pauseTrading()` — reverts with `NotAdmin()`
    - When arbitrary address calls `unpauseTrading()` — reverts with `NotAdmin()`
- **SC-K1MO: Collect works while paused**
  - Given a paused vault with an LP position that has accrued fees
    - When LP calls `collect(positionId)`
      - Then fees transferred to LP successfully
      - And transaction does not revert
- **SC-K1MP: ReclaimDeposit works while paused**
  - Given a paused vault with a valid unfulfilled mint intent past RECLAIM_TIMELOCK
    - When LP calls `reclaimDeposit(...)` with valid signatures
      - Then USDC transferred to LP successfully
      - And transaction does not revert
- **FR-K1ME through FR-K1MI, NFR-K1MJ** — Covered by SC-K1ML through SC-K1MP assertions
