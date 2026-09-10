---
id: UC-REQ2
name: Manage Roles on Factory
feature: FEAT-REPZ
status: implemented
version: 3
actor: Admin
---

# UC-REQ2: Manage Roles on Factory

> Admin manages the role registry on the LPVaultFactory -- adding/removing operators, setting the oracle, transferring admin, adding/removing/renouncing admins -- to control who can perform lifecycle and transactional operations.

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
1. Non-admin calls any of: `addOperator`, `removeOperator`, `setOracle`, `transferAdmin`, `addAdmin`, `removeAdmin`, `renounceAdminRole`
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

### SC-5UJF: Add admin successfully

**Given:**
- Address Y does not hold the admin role
- Address Y is non-zero

**Steps:**
1. Admin A calls `addAdmin(Y)`
2. System sets `admins[Y] = 1`
3. System increments `adminCount`

**Outcomes:**
- Y holds the admin role
- `adminCount` has increased by 1

**Side Effects:**
- `NewAdmin(Y, A)` event emitted
- No `pendingAdmin`, operator, or oracle change

---

### SC-5UJG: Add admin reverts on the zero address

**Given:**
- Caller A holds the admin role

**Steps:**
1. A calls `addAdmin(address(0))`
2. System checks the address is non-zero

**Outcomes:**
- The call reverts with `ZeroAddress`

**Side Effects:**
- No state changes
- No events emitted

---

### SC-5UJH: Add admin for an existing admin changes no role state

**Given:**
- Address X already holds the admin role

**Steps:**
1. Admin A calls `addAdmin(X)`
2. System finds X already holds the role

**Outcomes:**
- The call does not revert
- `admins[X] == 1` and `adminCount` is unchanged

**Side Effects:**
- `NewAdmin(X, A)` event emitted
- No `adminCount` change

---

### SC-5UJI: Remove admin successfully

**Given:**
- Admins A and X hold the admin role (`adminCount == 2`)
- X is not `pendingAdmin`

**Steps:**
1. Admin A calls `removeAdmin(X)`
2. System sets `admins[X] = 0`
3. System decrements `adminCount`

**Outcomes:**
- X no longer holds the admin role
- `adminCount == 1`

**Side Effects:**
- `RemovedAdmin(X, A)` event emitted
- No operator, oracle, or `pendingAdmin` change

---

### SC-5UJJ: Remove admin reverts when it would remove the last admin

**Given:**
- A is the only admin (`adminCount == 1`)

**Steps:**
1. A calls `removeAdmin(A)`
2. System checks `adminCount <= 1`

**Outcomes:**
- The call reverts with `CannotRemoveLastAdmin`
- A still holds the admin role

**Side Effects:**
- No state changes
- No events emitted

---

### SC-5UJK: Remove admin on an address that is not an admin changes no role state

**Given:**
- Address Y does not hold the admin role
- Y is not `pendingAdmin`
- `adminCount == 1`

**Steps:**
1. Admin A calls `removeAdmin(Y)`
2. System finds Y holds no role

**Outcomes:**
- The call does not revert
- `admins[Y] == 0` and `adminCount == 1`

**Side Effects:**
- `RemovedAdmin(Y, A)` event emitted
- No `pendingAdmin` change

---

### SC-5UJL: Admin removal propagates to existing vaults

**Given:**
- Admins A and X hold the admin role
- Vault V was created by the factory while X held the role

**Steps:**
1. Admin A calls `removeAdmin(X)` on the factory
2. X calls `pauseTrading()` on vault V
3. Admin A calls `pauseTrading()` on vault V

**Outcomes:**
- X's call reverts with `NotAdmin`
- A's call succeeds and vault V is paused

**Side Effects:**
- `RemovedAdmin(X, A)` event emitted by the factory at step 1
- `TradingPaused(A)` event emitted by vault V at step 3
- No role state written to vault V's storage

---

### SC-5UJM: Renounce admin role successfully

**Given:**
- Admins A and X hold the admin role (`adminCount == 2`)
- X is not `pendingAdmin`

**Steps:**
1. X calls `renounceAdminRole()`
2. System sets `admins[X] = 0`
3. System decrements `adminCount`

**Outcomes:**
- X no longer holds the admin role
- `adminCount == 1`

**Side Effects:**
- `RemovedAdmin(X, X)` event emitted
- No `pendingAdmin`, operator, or oracle change

---

### SC-5UJN: Renounce admin role reverts for the last admin

**Given:**
- A is the only admin (`adminCount == 1`)

**Steps:**
1. A calls `renounceAdminRole()`
2. System checks `adminCount <= 1`

**Outcomes:**
- The call reverts with `CannotRemoveLastAdmin`
- A still holds the admin role

**Side Effects:**
- No state changes
- No events emitted

---

### SC-5UJO: Removing an admin withdraws its pending proposal

**Given:**
- Admin A called `transferAdmin(X)`, so `pendingAdmin == X`
- Admin A then called `addAdmin(X)`, so X holds the admin role and `adminCount == 2`

**Steps:**
1. Admin A calls `removeAdmin(X)`
2. System sets `admins[X] = 0`, decrements `adminCount`, and sets `pendingAdmin = address(0)`
3. X calls `acceptAdmin()`

**Outcomes:**
- Step 3 reverts with `NotPendingAdmin`
- X does not hold the admin role
- `adminCount == 1`

**Side Effects:**
- `RemovedAdmin(X, A)` event emitted at step 1
- No `NewAdmin` event emitted

---

### SC-5UJP: Removing a proposed-only address withdraws its proposal

**Given:**
- Admin A called `transferAdmin(Y)`, so `pendingAdmin == Y`
- Y does not hold the admin role

**Steps:**
1. Admin A calls `removeAdmin(Y)`
2. System sets `pendingAdmin = address(0)`
3. Y calls `acceptAdmin()`

**Outcomes:**
- Step 3 reverts with `NotPendingAdmin`
- `admins[Y] == 0` and `adminCount` is unchanged

**Side Effects:**
- `RemovedAdmin(Y, A)` event emitted at step 1
- No `NewAdmin` event emitted

---

### SC-5UJQ: Renouncing withdraws the caller's pending proposal

**Given:**
- Admin A called `transferAdmin(X)`, then `addAdmin(X)`
- X holds the admin role, `pendingAdmin == X`, and `adminCount == 2`

**Steps:**
1. X calls `renounceAdminRole()`
2. System sets `admins[X] = 0`, decrements `adminCount`, and sets `pendingAdmin = address(0)`
3. X calls `acceptAdmin()`

**Outcomes:**
- Step 3 reverts with `NotPendingAdmin`
- X does not hold the admin role
- `adminCount == 1`

**Side Effects:**
- `RemovedAdmin(X, X)` event emitted at step 1
- No `NewAdmin` event emitted

---

### SC-5UJR: Accept admin reverts when the caller already holds the admin role

**Given:**
- Admin A called `transferAdmin(X)`, then `addAdmin(X)`
- `pendingAdmin == X`, X holds the admin role, and `adminCount == 2`

**Steps:**
1. X calls `acceptAdmin()`
2. System checks `admins[msg.sender] == 1`

**Outcomes:**
- The call reverts with `AlreadyAdmin`
- `adminCount == 2`

**Side Effects:**
- No state changes
- `pendingAdmin` stays X
- No events emitted

---
