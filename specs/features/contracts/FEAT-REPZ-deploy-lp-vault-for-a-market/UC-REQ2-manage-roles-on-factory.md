---
id: UC-REQ2
name: Manage Roles on Factory
feature: FEAT-REPZ
status: implemented
version: 2
actor: Admin
---

# UC-REQ2: Manage Roles on Factory

> Admin manages the role registry on the LPVaultFactory -- adding/removing operators, setting the oracle, transferring admin -- to control who can perform lifecycle and transactional operations.

## Preconditions

- LPVaultFactory is deployed and initialized
- Caller holds the Admin role on the factory

## Trigger

Admin calls a role-management function on the LPVaultFactory.

---

### SC-REQB: Add operator successfully

**Given:**
- The target address is not the current oracle
- The target address is not already an operator

**Steps:**
1. Admin calls `addOperator(newOperator)`
2. System validates the address is not the current oracle
3. System sets `operators[newOperator] = 1`

**Outcomes:**
- The new address is registered as an operator

**Side Effects:**
- `NewOperator(newOperator, admin)` event emitted
- No oracle change

---

### SC-REQC: Add operator reverts when address is current oracle

**Given:**
- The target address is the current oracle

**Steps:**
1. Admin calls `addOperator(oracleAddress)`
2. System checks role separation constraint

**Outcomes:**
- The call reverts

**Side Effects:**
- No state changes
- No events emitted

---

### SC-REQD: Remove operator successfully

**Given:**
- The target address is a current operator

**Steps:**
1. Admin calls `removeOperator(operatorAddress)`
2. System sets `operators[operatorAddress] = 0`

**Outcomes:**
- The address is no longer an operator

**Side Effects:**
- `RemovedOperator(operatorAddress, admin)` event emitted

---

### SC-REQE: Set oracle successfully

**Given:**
- The new oracle address is not a current operator
- The new oracle address is non-zero

**Steps:**
1. Admin calls `setOracle(newOracle)`
2. System validates the address is not a current operator
3. System updates `oracle = newOracle`

**Outcomes:**
- The oracle is updated to the new address

**Side Effects:**
- Oracle-change event emitted
- No operator changes

---

### SC-REQF: Set oracle reverts when address is current operator

**Given:**
- The new oracle address is a current operator

**Steps:**
1. Admin calls `setOracle(operatorAddress)`
2. System checks role separation constraint

**Outcomes:**
- The call reverts

**Side Effects:**
- No state changes

---

### SC-REQG: Two-step admin transfer

**Given:**
- The proposed admin address is not already an admin
- The proposed admin address is non-zero

**Steps:**
1. Admin calls `transferAdmin(proposedAdmin)`
2. System sets `pendingAdmin = proposedAdmin`
3. Proposed admin calls `acceptAdmin()`
4. System sets `admins[proposedAdmin] = 1`, increments `adminCount`, clears `pendingAdmin`

**Outcomes:**
- The proposed admin now has the admin role
- adminCount has increased by 1

**Side Effects:**
- `AdminTransferProposed(admin, proposedAdmin)` event emitted at step 2
- `NewAdmin(proposedAdmin, proposedAdmin)` event emitted at step 4

---

### SC-REQH: Non-admin caller reverts on all role management functions

**Given:**
- Caller does not hold the Admin role (is an Operator, Oracle, or unrelated address)

**Steps:**
1. Non-admin calls any of: `addOperator`, `removeOperator`, `setOracle`, `transferAdmin`
2. System checks the `onlyAdmin` modifier

**Outcomes:**
- The call reverts with a NotAdmin error

**Side Effects:**
- No state changes
- No events emitted

---

### SC-FKD4: Operator rotation propagates to existing vaults

**Given:**
- Factory has operator A active (`operators[A] == 1`)
- Vault V was created while operator A was active

**Steps:**
1. Admin calls `removeOperator(A)` on factory
2. Admin calls `addOperator(B)` on factory
3. Old operator A calls an operator-gated function on vault V
4. New operator B calls an operator-gated function on vault V

**Outcomes:**
- Old operator A's call reverts with access control error
- New operator B's call succeeds

**Side Effects:**
- `RemovedOperator(A, admin)` event emitted by factory at step 1
- `NewOperator(B, admin)` event emitted by factory at step 2
- No role-related state changes on vault V's storage (role state lives on factory)

---

### SC-FKD5: Oracle rotation propagates to existing vaults

**Given:**
- Factory has oracle X
- Vault V was created while oracle X was active

**Steps:**
1. Admin calls `setOracle(Y)` on factory (Y is not a current operator)
2. Old oracle X calls `setMinimumFirstLiquidity(newMin)` on vault V
3. New oracle Y calls `setMinimumFirstLiquidity(newMin)` on vault V

**Outcomes:**
- Old oracle X's call reverts with access control error
- New oracle Y's call succeeds and `minimumFirstLiquidity` is updated

**Side Effects:**
- Oracle-change state updated on factory at step 1
- `MinimumFirstLiquidityUpdated` event emitted at step 3
- No role-related state changes on vault V's storage

---
