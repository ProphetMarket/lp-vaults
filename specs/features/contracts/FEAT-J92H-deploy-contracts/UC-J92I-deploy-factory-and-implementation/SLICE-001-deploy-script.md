---
id: UC-J92I-001
name: deploy-script
use_case: UC-J92I
feature: FEAT-J92H
objective: implement
status: implemented
files:
  create: [script/Deploy.s.sol]
  modify: []
depends_on: []
provides: [DeployScript]
entry_type: contract-call
covers: [SC-J92J, SC-J92K, SC-J92L, SC-J92M, FR-J92N, FR-J92O, FR-J92P, FR-J92Q, FR-J92R, FR-J92S, FR-J92T]
last_update: 2026-07-01
---

# UC-J92I-001: Deploy Script

## Rationale

This slice creates the Foundry deploy script (`script/Deploy.s.sol`) that deploys the LPVault implementation and LPVaultFactory to any EVM chain. The script reads all external addresses and role wallets from environment variables, validates them before broadcasting, and logs the deployed addresses. It covers all four scenarios: successful deployment (SC-J92J), missing env var validation (SC-J92K), role separation enforcement via the factory constructor (SC-J92L), and verification support (SC-J92M).

## Contracts

### Types

```solidity
// Deploy.s.sol extends forge-std/Script.sol
// No new types — uses existing LPVault and LPVaultFactory contracts
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `run` | `function run() external` | PRIVATE_KEY env var (Foundry broadcast) | Entry point; reads env vars, validates, deploys impl + factory |

### Behavior

- **Preconditions:** All required env vars (PRIVATE_KEY, USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS) must be set. All address env vars must be non-zero.
- **Postconditions:** LPVault implementation deployed with initializers disabled. LPVaultFactory deployed with correct constructor args matching env vars. Both addresses logged to stdout.
- **Invariants:** No addresses or keys hardcoded in source. Validation occurs before `vm.startBroadcast()`.
- **Error modes:** Reverts with descriptive error if any address env var is zero. Factory constructor reverts with `RoleSeparation()` if oracle == operator.

## Tests

- **SC-J92J: Successful deployment with valid configuration**
  - Given all env vars are set to valid non-zero addresses with oracle != operator
    - When the deploy script runs on a local Anvil fork
      - Then LPVault implementation is deployed at a non-zero address
      - And calling `initialize()` on the implementation reverts (initializers disabled)
      - And LPVaultFactory is deployed at a non-zero address
      - And `factory.implementation()` equals the implementation address
      - And `factory.usdc()` equals USDC_ADDRESS
      - And `factory.exchange()` equals EXCHANGE_ADDRESS
      - And `factory.conditionalTokens()` equals CONDITIONAL_TOKENS_ADDRESS
      - And `factory.admins(ADMIN_ADDRESS)` equals 1
      - And `factory.oracle()` equals ORACLE_ADDRESS
      - And `factory.operators(OPERATOR_ADDRESS)` equals 1
- **SC-J92K: Missing environment variable**
  - Given USDC_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
  - Given EXCHANGE_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
  - Given ADMIN_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
  - Given ORACLE_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
  - Given OPERATOR_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
  - Given CONDITIONAL_TOKENS_ADDRESS is set to the zero address
    - When the deploy script runs
      - Then the script reverts before any contract is deployed
- **SC-J92L: Oracle equals operator (role separation violation)**
  - Given all env vars are valid but ORACLE_ADDRESS == OPERATOR_ADDRESS
    - When the deploy script runs
      - Then the LPVaultFactory deployment reverts with RoleSeparation error
- **SC-J92M: Deployment with contract verification**
  - Given all env vars are valid with correct role separation and ETHERSCAN_API_KEY is set
    - When the deploy script runs with --verify
      - Then both contracts are deployed (same assertions as SC-J92J)
      - And Foundry submits verification requests (verified by successful script completion with --verify flag)
