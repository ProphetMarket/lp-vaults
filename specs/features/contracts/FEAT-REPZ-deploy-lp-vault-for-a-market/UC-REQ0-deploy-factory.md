---
id: UC-REQ0
name: Deploy Factory
feature: FEAT-REPZ
status: implemented
version: 3
actor: Factory Owner
---

# UC-REQ0: Deploy Factory

> Factory Owner deploys the LPVaultFactory with the LPVault implementation, external contract addresses, and initial role assignments so the system is ready to create per-market vaults.

## Preconditions

- Factory Owner has the compiled LPVault implementation bytecode
- USDC, CTF Exchange, and ConditionalTokens contracts are deployed on the target chain
- Initial Admin, Oracle, and Operator wallet addresses are known
- The Poly Safe factory address on the target chain is known, and its combined proxy bytecode hash was read from it

## Trigger

Factory Owner sends the LPVaultFactory deployment transaction.

---

### SC-REQ3: Successful deployment with valid parameters

**Given:**
- All addresses are non-zero, and the Safe proxy bytecode hash is non-zero
- initialOracle != initialOperator (role separation satisfied)

**Steps:**
1. Factory Owner deploys LPVaultFactory with (implementation, usdc, exchange, conditionalTokens, initialAdmin, initialOracle, initialOperator, safeFactory, safeProxyBytecodeHash)
2. System stores implementation, usdc, exchange, conditionalTokens, safeFactory, and safeProxyBytecodeHash
3. System sets `admins[initialAdmin] = 1` and `adminCount = 1`
4. System sets `oracle = initialOracle`
5. System sets `operators[initialOperator] = 1`
6. System sets `defaultEmergencyCancelTimelock = 7 days`

**Outcomes:**
- Factory contract exists at a deployed address with all configuration stored
- Role registry is initialized: one admin, one oracle, one operator
- `safeFactory()` and `safeProxyBytecodeHash()` return the constructor values
- `defaultEmergencyCancelTimelock()` returns 7 days

**Side Effects:**
- No events emitted (constructor-only; standard EVM creation receipt)
- No USDC transferred

---

### SC-9OY7: Zero Safe derivation input reverts

**Given:**
- Every other constructor argument is valid

**Steps:**
1. Factory Owner deploys LPVaultFactory with `safeFactory == address(0)`, or with `safeProxyBytecodeHash == bytes32(0)`
2. System validates the two derivation inputs

**Outcomes:**
- The deployment reverts with `ZeroAddress` for the zero factory and with `ZeroBytecodeHash` for the zero hash
- A zero input would make every derived Safe wrong on every vault the factory creates, and an `immutable` can never be corrected

**Side Effects:**
- No contract deployed
- No state changes on chain

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
