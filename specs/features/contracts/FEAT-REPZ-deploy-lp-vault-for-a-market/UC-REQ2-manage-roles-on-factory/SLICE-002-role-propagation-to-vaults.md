---
id: UC-REQ2-002
name: role-propagation-to-vaults
use_case: UC-REQ2
feature: FEAT-REPZ
objective: implement
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: [UC-REQ1-001, UC-REQ2-001]
provides: []
entry_type: contract-call
covers: [SC-FKD4, SC-FKD5]
last_update: 2026-06-30
status: implemented
---

# UC-REQ2-002: Role Propagation to Vaults

## Rationale

Verifies that factory-level role changes (operator rotation, oracle rotation) propagate immediately to all existing vaults. Since vaults delegate authorization to the factory via cross-contract calls (FR-FKD0, FR-FKD1), a role change on the factory takes effect on every vault without any additional transaction. Closes SC-FKD4 (operator propagation) and SC-FKD5 (oracle propagation). The production code enabling this lives in UC-REQ1-001's delegation modifiers; this slice adds the cross-contract integration tests that prove propagation works end-to-end.

## Contracts

### Types

```solidity
// No new types — tests use the existing ILPVaultFactory interface
// and the factory's public role-management functions from UC-REQ2-001.
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `addOperator` | `(address operator_)` | onlyAdmin (factory) | Verified to propagate to vault's `onlyOperator` check |
| `removeOperator` | `(address operator_)` | onlyAdmin (factory) | Verified to propagate to vault's `onlyOperator` check |
| `setOracle` | `(address newOracle)` | onlyAdmin (factory) | Verified to propagate to vault's `onlyOracle` check |

### Behavior

- **Preconditions:** Factory deployed with admin, operator, oracle (UC-REQ0-001); vault created (UC-REQ1-001); factory role management functions available (UC-REQ2-001)
- **Postconditions:** After `removeOperator(A)` + `addOperator(B)` on factory: vault rejects A and accepts B for operator-gated calls. After `setOracle(Y)` on factory: vault rejects old oracle X and accepts Y for oracle-gated calls.
- **Invariants:** Vault holds no local role state — every auth check is a live read from the factory
- **Error modes:** `NotOperator` (old operator after rotation); `NotOracle` (old oracle after rotation)

## Tests

- **SC-FKD4: Operator rotation propagates to existing vaults**
  - Given factory has operator A active and vault V was created while A was active
    - When Admin calls `removeOperator(A)` on factory
      - And Admin calls `addOperator(B)` on factory
        - Then old operator A calling an operator-gated function on vault V reverts with NotOperator
        - And new operator B calling an operator-gated function on vault V succeeds
        - And `RemovedOperator(A, admin)` event was emitted by factory
        - And `NewOperator(B, admin)` event was emitted by factory
- **SC-FKD5: Oracle rotation propagates to existing vaults**
  - Given factory has oracle X and vault V was created while X was active
    - When Admin calls `setOracle(Y)` on factory (Y is not a current operator)
      - Then old oracle X calling `setMinimumFirstLiquidity(newMin)` on vault V reverts with NotOracle
      - And new oracle Y calling `setMinimumFirstLiquidity(newMin)` on vault V succeeds
      - And `MinimumFirstLiquidityUpdated` event is emitted by vault V
