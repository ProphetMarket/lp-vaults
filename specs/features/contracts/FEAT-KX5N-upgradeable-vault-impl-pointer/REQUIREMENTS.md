---
id: FEAT-KX5N
name: Upgradeable Vault Implementation Pointer
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: [FEAT-REPZ]
---

# Upgradeable Vault Implementation Pointer

> Admin-driven two-step timelocked upgrade of the LPVaultFactory's implementation pointer so future clones use a new LPVault implementation while existing clones stay pinned to their original bytecode (safe by EIP-1167 construction).

## Non-Goals

- Does not upgrade existing vaults -- EIP-1167 bakes the impl address into each clone's bytecode
- Does not migrate state between vault versions
- Factory itself remains non-upgradable
- Does not allow scheduling while another schedule is already pending

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Admin | Calls scheduleImplementation, applyImplementation, cancelScheduledImplementation | Two-step with 7-day timelock; registry-only authority |

## Functional Requirements

### Schedule

**FR-KX5X** `When an Admin calls scheduleImplementation with a non-zero address, the system shall store the pending implementation address and set unlockAt to block.timestamp + IMPLEMENTATION_TIMELOCK.`
Fit Criterion: Given no pending schedule, after `scheduleImplementation(newImpl)`, `pendingImplementation == newImpl` and `implementationUnlockAt == block.timestamp + 7 days`.
Linked to: UC-KX5O

### Apply

**FR-KX5Y** `When an Admin calls applyImplementation after unlockAt has passed, the system shall update implementation to the pending address, increment implementationVersion, and clear the pending state.`
Fit Criterion: Given a pending schedule with elapsed timelock, after `applyImplementation()`, `implementation == newImpl`, `implementationVersion` incremented by 1, `pendingImplementation == address(0)`, `implementationUnlockAt == 0`.
Linked to: UC-KX5O

### Cancel

**FR-KX5Z** `When an Admin calls cancelScheduledImplementation while a schedule is pending, the system shall clear the pending implementation and unlockAt.`
Fit Criterion: Given a pending schedule, after `cancelScheduledImplementation()`, `pendingImplementation == address(0)` and `implementationUnlockAt == 0`.
Linked to: UC-KX5O

### Guards

**FR-KX60** `If applyImplementation is called before unlockAt has elapsed, then the system shall revert.`
Fit Criterion: Given a pending schedule with future unlockAt, `applyImplementation()` reverts.
Linked to: UC-KX5O

**FR-KX61** `If applyImplementation or cancelScheduledImplementation is called when no schedule is pending, then the system shall revert.`
Fit Criterion: Given `pendingImplementation == address(0)`, both calls revert.
Linked to: UC-KX5O

**FR-KX62** `If scheduleImplementation is called with address(0), then the system shall revert.`
Fit Criterion: Given `newImpl == address(0)`, `scheduleImplementation(address(0))` reverts.
Linked to: UC-KX5O

**FR-KX63** `If a non-Admin address calls scheduleImplementation, applyImplementation, or cancelScheduledImplementation, then the system shall revert.`
Fit Criterion: Given a non-Admin caller, all three functions revert with NotAdmin.
Linked to: UC-KX5O

### Version Tracking

**FR-KX64** `When createVault deploys a new clone, the system shall pass the factory's current implementationVersion into the vault's initialize() and the vault shall store it.`
Fit Criterion: Given `implementationVersion == N` on the factory, a newly created vault reports `implementationVersion == N`.
Linked to: UC-KX5O

**FR-KX65** `When createVault deploys a new clone, it shall use the factory's current implementation address as the EIP-1167 clone target.`
Fit Criterion: Given implementation was updated, new vaults use the new bytecode; existing vaults remain on the old bytecode.
Linked to: UC-KX5O

## Non-Functional Requirements

**NFR-KX66** Security: `IMPLEMENTATION_TIMELOCK shall be 7 days. Polygon block.timestamp tolerance is ±15s, negligible at this scale.`

**NFR-KX67** Security: `The two-step schedule-then-apply pattern shall prevent accidental immediate implementation changes.`

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Admin can schedule, apply (after timelock), and cancel
- Non-admin callers rejected on all three functions
- Apply before timelock reverts
- Zero-address schedule reverts
- Existing vaults unaffected after implementation change
- implementationVersion correctly stored per clone and incremented on apply
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
