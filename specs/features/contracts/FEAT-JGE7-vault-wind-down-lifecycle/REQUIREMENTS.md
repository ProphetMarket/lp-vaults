---
id: FEAT-JGE7
name: Vault Wind-Down Lifecycle
module: contracts
domain: "@vault"
status: implemented
version: 4
refs: [FEAT-REPZ, FEAT-T7AF]
---

# Vault Wind-Down Lifecycle

> Oracle-driven phase transition that moves a vault from Active to WindDown when its underlying market resolves, gating off new position mints while keeping exit paths (burn, collect, reclaim) open for existing LPs.

## Non-Goals

- Does not handle emergency cancel (`emergencyCancelAll`) -- separate feature
- Does not handle position burning mechanics -- see burn position feature
- Does not modify fee distribution behavior during WindDown -- Operator can still call `notifyFees`, `updateTick`, `mergePositions`
- Does not handle market resolution on the CTF Exchange -- `startWindDown` is a downstream Oracle signal, not a resolution mechanism

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Oracle | Calls `startWindDown()` to transition vault phase | Same Oracle that creates vaults; single wallet via factory delegation |

## Functional Requirements

### Phase Transition

**FR-JGE8** `When the Oracle calls startWindDown() on a vault in Active phase, the system shall transition the vault's phase to WindDown and emit a VaultWindDownStarted event.`
Fit Criterion: Given a vault in Active phase, after Oracle calls `startWindDown()`, `phase == WindDown` and a `VaultWindDownStarted(bytes32 indexed marketId)` event is emitted.
Linked to: UC-JGEE

**FR-JGE9** `If startWindDown() is called on a vault whose phase is not Active, then the system shall revert.`
Fit Criterion: Given a vault in WindDown phase, `startWindDown()` reverts.
Linked to: UC-JGEE

**FR-JGEA** `If a non-Oracle address calls startWindDown(), then the system shall revert.`
Fit Criterion: Given a non-Oracle caller (LP, Operator, Admin, arbitrary address), `startWindDown()` reverts with an access control error.
Linked to: UC-JGEE

### WindDown Phase Gating

**FR-JGEB** `While the vault phase is WindDown, when any caller invokes depositForIntent or mintPositionFor, the system shall revert.`
Fit Criterion: Given a vault in WindDown phase, `depositForIntent(...)` and `mintPositionFor(...)` both revert with `VaultNotActive` regardless of caller authorization, and an escrow made before the wind-down stays reclaimable (FR-JGEC).
Linked to: UC-JGEE

**FR-JGEC** `While the vault phase is WindDown, when the position owner calls burnPosition, collect, or reclaimDeposit, or the Operator relays burnPositionFor, collectFor, or reclaimDepositFor, the system shall succeed as in Active phase.`
Fit Criterion: Given a vault in WindDown phase with an existing position and an escrow, `burnPosition(posId)`, `collect(posId)`, `reclaimDeposit(intentId)`, `burnPositionFor(...)`, `collectFor(...)`, and `reclaimDepositFor(...)` succeed with the same behavior as Active phase. The burn pays the claim's USDC plus its one outcome token (FEAT-7G40 FR-7G4V).
Linked to: UC-JGEE

## Non-Functional Requirements

**NFR-JGED** Security: `The startWindDown() transition shall be a one-way state change with no mechanism to revert from WindDown back to Active.`

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Phase transition is one-way (Active -> WindDown, no reverse path)
- Non-Oracle callers revert on `startWindDown()`
- Mints revert in WindDown for all callers
- Burns, collects, reclaim deposits succeed in WindDown
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
