---
id: UC-REQ0
name: Deploy Factory
feature: FEAT-REPZ
status: pending
version: 1
actor: Factory Owner
---

# UC-REQ0: Deploy Factory

> Factory Owner deploys the LPVaultFactory with the LPVault implementation, external contract addresses, and initial role assignments so the system is ready to create per-market vaults.

## Preconditions

- Factory Owner has the compiled LPVault implementation bytecode
- USDC, CTF Exchange, and ConditionalTokens contracts are deployed on the target chain
- Initial Admin, Oracle, and Operator wallet addresses are known

## Trigger

Factory Owner sends the LPVaultFactory deployment transaction.

---

### SC-REQ3: Successful deployment with valid parameters

**Given:**
- All addresses are non-zero
- initialOracle != initialOperator (role separation satisfied)

**Steps:**
1. Factory Owner deploys LPVaultFactory with (implementation, usdc, exchange, conditionalTokens, initialAdmin, initialOracle, initialOperator)
2. System stores implementation, usdc, exchange, and conditionalTokens addresses
3. System sets `admins[initialAdmin] = 1` and `adminCount = 1`
4. System sets `oracle = initialOracle`
5. System sets `operators[initialOperator] = 1`

**Outcomes:**
- Factory contract exists at a deployed address with all configuration stored
- Role registry is initialized: one admin, one oracle, one operator

**Side Effects:**
- No events emitted (constructor-only; standard EVM creation receipt)
- No USDC transferred

---

### SC-REQ4: Deployment reverts when oracle equals operator

**Given:**
- initialOracle == initialOperator (same wallet for both roles)

**Steps:**
1. Factory Owner deploys LPVaultFactory with initialOracle == initialOperator
2. System validates role separation constraint

**Outcomes:**
- Deployment reverts

**Side Effects:**
- No contract deployed
- No state changes on chain

---

### SC-REQ5: Implementation contract is not directly initializable

**Given:**
- Factory has been deployed successfully (SC-REQ3 completed)

**Steps:**
1. Any address calls `initialize()` directly on the implementation contract
2. System checks the initializer guard set by `_disableInitializers()` in the constructor

**Outcomes:**
- The call reverts

**Side Effects:**
- No state changes on the implementation contract

---
