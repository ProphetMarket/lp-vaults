---
id: UC-REQ2-001
name: factory-role-management
use_case: UC-REQ2
feature: FEAT-REPZ
objective: implement
files:
  create: []
  modify: [src/LPVaultFactory.sol]
depends_on: [UC-REQ0-001]
provides: [addOperator, removeOperator, setOracle, transferAdmin, acceptAdmin]
entry_type: contract-call
covers: [SC-REQB, SC-REQC, SC-REQD, SC-REQE, SC-REQF, SC-REQG, SC-REQH]
last_update: 2026-06-17
status: pending
---

# UC-REQ2-001: Factory Role Management

## Rationale

Adds the role management functions to LPVaultFactory: addOperator, removeOperator, setOracle, transferAdmin, and acceptAdmin. Closes 7 scenarios covering happy-path operator add/remove, oracle set, two-step admin transfer, and the access-control and role-separation revert paths. All functions live on LPVaultFactory, so they form one slice per the file-ownership constraint.

## Contracts

### Types

```solidity
// Events (emitted by Auth mixin on LPVaultFactory)
// event NewOperator(address indexed operator, address indexed caller);
// event RemovedOperator(address indexed operator, address indexed caller);
// event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
// event NewAdmin(address indexed admin, address indexed caller);
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `addOperator` | `(address operator_)` | onlyAdmin | Reverts if operator_ == oracle (role separation) |
| `removeOperator` | `(address operator_)` | onlyAdmin | Sets `operators[operator_] = 0` |
| `setOracle` | `(address newOracle)` | onlyAdmin | Reverts if newOracle is a current operator (role separation) |
| `transferAdmin` | `(address newAdmin)` | onlyAdmin | Sets `pendingAdmin`; does not grant role |
| `acceptAdmin` | `()` | pendingAdmin only | Grants admin role, increments adminCount, clears pendingAdmin |

### Behavior

- **Preconditions:** Factory deployed with at least one admin (UC-REQ0-001 provides)
- **Postconditions:** After addOperator: `operators[addr] == 1`; after removeOperator: `operators[addr] == 0`; after setOracle: `oracle == newOracle`; after transferAdmin+acceptAdmin: `admins[newAdmin] == 1`, `adminCount` incremented, `pendingAdmin == address(0)`
- **Invariants:** `adminCount >= 1`; oracle is never simultaneously an operator; only Admin can call role management functions
- **Error modes:** `NotAdmin` (non-admin caller); `RoleSeparation` (addOperator with oracle address, or setOracle with operator address); `NotPendingAdmin` (acceptAdmin from wrong caller); `ZeroAddress` (transferAdmin to address(0)); `AlreadyAdmin` (transferAdmin to existing admin)

## Tests

- **SC-REQB: Add operator successfully**
  - Given target address is not the current oracle and not already an operator
    - When Admin calls `addOperator(newOperator)`
      - Then `operators[newOperator] == 1`
      - And `NewOperator(newOperator, admin)` event is emitted
- **SC-REQC: Add operator reverts when address is current oracle**
  - Given target address is the current oracle
    - When Admin calls `addOperator(oracleAddress)`
      - Then the call reverts with RoleSeparation
- **SC-REQD: Remove operator successfully**
  - Given target address is a current operator
    - When Admin calls `removeOperator(operatorAddress)`
      - Then `operators[operatorAddress] == 0`
      - And `RemovedOperator(operatorAddress, admin)` event is emitted
- **SC-REQE: Set oracle successfully**
  - Given new oracle address is not a current operator and is non-zero
    - When Admin calls `setOracle(newOracle)`
      - Then `oracle == newOracle`
- **SC-REQF: Set oracle reverts when address is current operator**
  - Given new oracle address is a current operator
    - When Admin calls `setOracle(operatorAddress)`
      - Then the call reverts with RoleSeparation
- **SC-REQG: Two-step admin transfer**
  - Given proposed admin is not already an admin and is non-zero
    - When Admin calls `transferAdmin(proposedAdmin)`
      - Then `pendingAdmin == proposedAdmin`
      - And `admins[proposedAdmin] == 0` (not yet granted)
      - And `AdminTransferProposed(admin, proposedAdmin)` event is emitted
    - When proposedAdmin calls `acceptAdmin()`
      - Then `admins[proposedAdmin] == 1`
      - And `adminCount` has increased by 1
      - And `pendingAdmin == address(0)`
      - And `NewAdmin(proposedAdmin, proposedAdmin)` event is emitted
- **SC-REQH: Non-admin caller reverts on all role management functions**
  - Given caller does not hold the Admin role
    - When caller calls `addOperator(addr)`
      - Then the call reverts with NotAdmin
    - When caller calls `removeOperator(addr)`
      - Then the call reverts with NotAdmin
    - When caller calls `setOracle(addr)`
      - Then the call reverts with NotAdmin
    - When caller calls `transferAdmin(addr)`
      - Then the call reverts with NotAdmin
