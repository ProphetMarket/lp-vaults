---
id: UC-REQ0-001
name: deploy-factory-with-role-registry
use_case: UC-REQ0
feature: FEAT-REPZ
objective: implement
files:
  create: [src/LPVaultFactory.sol, src/LPVault.sol]
  modify: []
depends_on: []
provides: [LPVaultFactory, LPVault, onlyAdmin, onlyOperator, onlyOracle, onlyFactory]
entry_type: contract-call
covers: [SC-REQ3, SC-REQ4, SC-REQ5]
last_update: 2026-06-17
status: pending
---

# UC-REQ0-001: Deploy Factory with Role Registry

## Rationale

Creates the two core contract files: LPVaultFactory (constructor + inlined Auth mixin) and LPVault (constructor that calls `_disableInitializers()`). Closes the three deployment scenarios -- successful factory deployment with role registry initialization, constructor revert when oracle equals operator, and proof that the implementation contract cannot be initialized directly. Downstream slices depend on these files and the Auth modifiers they export.

## Contracts

### Types

```solidity
// Auth registry storage (inlined in both LPVaultFactory and LPVault)
// mapping(address => uint256) admins;      // 1 = active
// mapping(address => uint256) operators;    // 1 = active
// uint256 adminCount;                       // >= 1 always
// address oracle;                           // single wallet
// address pendingAdmin;                     // two-step transfer

// LPVaultFactory constructor-set immutables
// address public immutable implementation;
// address public immutable usdc;
// address public immutable exchange;
// address public immutable conditionalTokens;
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `constructor` | `(address impl, address usdc_, address exchange_, address ct_, address admin_, address oracle_, address operator_)` | deployer | Reverts if oracle_ == operator_ (role separation) |

### Behavior

- **Preconditions:** All addresses non-zero; oracle_ != operator_
- **Postconditions:** `admins[admin_] == 1`, `adminCount == 1`, `oracle == oracle_`, `operators[operator_] == 1`; implementation/usdc/exchange/conditionalTokens stored; LPVault implementation has `_disableInitializers()` called in its constructor
- **Invariants:** `adminCount >= 1`; oracle is never an operator and vice versa
- **Error modes:** Constructor reverts on oracle == operator (role separation)

## Tests

- **SC-REQ3: Successful deployment with valid parameters**
  - Given all addresses are non-zero and initialOracle != initialOperator
    - When Factory Owner deploys LPVaultFactory
      - Then `admins[initialAdmin] == 1`
      - And `adminCount == 1`
      - And `oracle == initialOracle`
      - And `operators[initialOperator] == 1`
      - And `implementation` returns the LPVault implementation address
      - And `usdc` returns the USDC address
      - And `exchange` returns the exchange address
      - And `conditionalTokens` returns the ConditionalTokens address
- **SC-REQ4: Deployment reverts when oracle equals operator**
  - Given initialOracle == initialOperator
    - When Factory Owner deploys LPVaultFactory
      - Then the deployment reverts
- **SC-REQ5: Implementation contract is not directly initializable**
  - Given LPVaultFactory has been deployed (SC-REQ3)
    - When any address calls `initialize()` on the implementation contract
      - Then the call reverts
