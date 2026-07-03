---
id: UC-KX5O-001
name: schedule-apply-cancel-impl-upgrade
use_case: UC-KX5O
feature: FEAT-KX5N
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVaultFactory.sol, src/LPVault.sol]
depends_on: []
provides: [scheduleImplementation, applyImplementation, cancelScheduledImplementation]
entry_type: contract-call
covers: [SC-KX5P, SC-KX5Q, SC-KX5R, SC-KX5S, SC-KX5T, SC-KX5U, SC-KX5V, SC-KX5W, FR-KX5X, FR-KX5Y, FR-KX5Z, FR-KX60, FR-KX61, FR-KX62, FR-KX63, FR-KX64, FR-KX65, NFR-KX66, NFR-KX67]
last_update: 2026-07-02
---

# UC-KX5O-001: Schedule, Apply, and Cancel Implementation Upgrade

## Rationale

Adds the two-step timelocked implementation upgrade flow to LPVaultFactory and the per-clone version stamp to LPVault. The factory gets three new admin-only functions (`scheduleImplementation`, `applyImplementation`, `cancelScheduledImplementation`), storage for the pending schedule and version counter, a 7-day timelock constant, and three events. The `implementation` field changes from `immutable` to regular storage so `applyImplementation` can update it. `createVault` is modified to pass the current `implementationVersion` into `initialize()`, and `LPVault.initialize()` is extended to accept and store a `version_` parameter. Covers all 8 scenarios: schedule (SC-KX5P), apply after timelock (SC-KX5Q), new vault uses updated impl + version (SC-KX5R), cancel (SC-KX5S), early apply revert (SC-KX5T), no-pending revert (SC-KX5U), zero address revert (SC-KX5V), and non-admin revert (SC-KX5W).

## Contracts

### Types

```solidity
// New storage on LPVaultFactory
address public implementation;           // was immutable, now regular storage
address public pendingImplementation;
uint256 public implementationUnlockAt;
uint256 public implementationVersion;    // starts at 1 in constructor

// New constant on LPVaultFactory
uint256 public constant IMPLEMENTATION_TIMELOCK = 7 days;

// New events on LPVaultFactory
event ImplementationScheduled(address indexed newImpl, uint256 unlockAt);
event ImplementationApplied(address indexed newImpl, uint256 version);
event ImplementationCancelled(address indexed cancelledImpl);

// New errors on LPVaultFactory
error NoPendingSchedule();
error ScheduleAlreadyPending();
error TimelockNotElapsed();

// New storage on LPVault
uint256 public implementationVersion;    // set once in initialize
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `scheduleImplementation` | `function scheduleImplementation(address newImpl) external` | onlyAdmin | Reverts with ZeroAddress if newImpl == 0; reverts with ScheduleAlreadyPending if pending exists |
| `applyImplementation` | `function applyImplementation() external` | onlyAdmin | Reverts with NoPendingSchedule if none pending; reverts with TimelockNotElapsed if too early |
| `cancelScheduledImplementation` | `function cancelScheduledImplementation() external` | onlyAdmin | Reverts with NoPendingSchedule if none pending |

### Behavior

- **Preconditions:** caller must be Admin via factory `onlyAdmin` modifier
- **Postconditions:** on schedule: pending fields set, event emitted; on apply: implementation updated, version incremented, pending cleared, event emitted; on cancel: pending cleared, event emitted
- **Invariants:** `implementation` is never address(0); `implementationVersion` is monotonically increasing; existing vaults' `implementationVersion` never changes; `pendingImplementation != address(0)` iff a schedule is active
- **Error modes:** `NotAdmin` for non-admin; `ZeroAddress` for zero impl; `ScheduleAlreadyPending` for double schedule; `NoPendingSchedule` for apply/cancel with no pending; `TimelockNotElapsed` for early apply

## Tests

- **SC-KX5P: Admin schedules a new implementation**
  - Given no pending schedule
    - When Admin calls `scheduleImplementation(newImpl)` with valid address
      - Then `pendingImplementation == newImpl`
      - And `implementationUnlockAt == block.timestamp + 7 days`
      - And `ImplementationScheduled(newImpl, unlockAt)` event emitted
      - And `implementation` unchanged
      - And `implementationVersion` unchanged
- **SC-KX5Q: Admin applies after timelock**
  - Given pending schedule exists and 7 days have passed
    - When Admin calls `applyImplementation()`
      - Then `implementation == newImpl`
      - And `implementationVersion` incremented by 1
      - And `pendingImplementation == address(0)`
      - And `implementationUnlockAt == 0`
      - And `ImplementationApplied(newImpl, version)` event emitted
- **SC-KX5R: New vault uses updated implementation and version**
  - Given implementation was updated via apply, `implementationVersion == N`
    - When Oracle calls `createVault(marketId, tickSpacing, minFirstLiq)`
      - Then vault's `implementationVersion == N`
      - And vault is a clone of the new implementation (verified by code behavior)
- **SC-KX5S: Admin cancels pending schedule**
  - Given pending schedule exists
    - When Admin calls `cancelScheduledImplementation()`
      - Then `pendingImplementation == address(0)`
      - And `implementationUnlockAt == 0`
      - And `implementation` unchanged
      - And `ImplementationCancelled(cancelledImpl)` event emitted
- **SC-KX5T: Apply reverts before timelock**
  - Given pending schedule exists, timelock has not elapsed
    - When Admin calls `applyImplementation()`
      - Then transaction reverts with `TimelockNotElapsed()`
- **SC-KX5U: Revert when no pending schedule**
  - Given no pending schedule
    - When Admin calls `applyImplementation()`
      - Then transaction reverts with `NoPendingSchedule()`
    - When Admin calls `cancelScheduledImplementation()`
      - Then transaction reverts with `NoPendingSchedule()`
- **SC-KX5V: Revert on zero address**
  - Given Admin calls `scheduleImplementation(address(0))`
    - Then transaction reverts with `ZeroAddress()`
- **SC-KX5W: Non-admin callers revert**
  - Given caller is Operator
    - When Operator calls `scheduleImplementation(addr)` — reverts with `NotAdmin()`
    - When Operator calls `applyImplementation()` — reverts with `NotAdmin()`
    - When Operator calls `cancelScheduledImplementation()` — reverts with `NotAdmin()`
  - Given caller is arbitrary address
    - When caller calls any of the three — reverts with `NotAdmin()`
- **FR-KX5X through FR-KX65, NFR-KX66, NFR-KX67** — Covered by SC-KX5P through SC-KX5W assertions
