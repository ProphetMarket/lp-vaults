---
id: UC-J92I-001
name: deploy-script
use_case: UC-J92I
feature: FEAT-J92H
objective: implement
status: implemented
files:
  create: []
  modify: [script/Deploy.s.sol]
depends_on: []
provides: [DeployScript]
entry_type: contract-call
covers: [SC-J92J, SC-J92K, SC-J92L, SC-J92M, SC-K49S, FR-J92N, FR-J92O, FR-J92P, FR-J92Q, FR-J92R, FR-J92S, FR-J92T]
last_update: 2026-07-02
---

# UC-J92I-001: Deploy Script

## Rationale

This slice modifies the Foundry deploy script (`script/Deploy.s.sol`) to remove raw private key handling via `PRIVATE_KEY` environment variable. Transaction signing is delegated to Foundry's CLI-level wallet management (`--account` for cast keystores, `--ledger` / `--trezor` for hardware wallets). The `deploy()` helper drops its `deployerKey` parameter and broadcast management; `run()` calls `vm.startBroadcast()` without arguments. Covers all five scenarios: successful deployment (SC-J92J), missing env var validation (SC-J92K), role separation enforcement (SC-J92L), verification support (SC-J92M), and the new no-raw-private-key guarantee (SC-K49S).

## Contracts

### Types

```solidity
// Deploy.s.sol extends forge-std/Script.sol
// No new types — uses existing LPVault and LPVaultFactory contracts
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `run` | `function run() external returns (LPVault, LPVaultFactory)` | Foundry CLI wallet (`--account` / `--ledger` / `--trezor`) | Entry point; reads address env vars, validates, deploys impl + factory |
| `deploy` | `function deploy(address usdc, address exchange, address conditionalTokens, address admin, address oracleAddr, address operatorAddr) public returns (LPVault, LPVaultFactory)` | none (caller manages broadcast) | Pure validation-and-deploy helper; no broadcast management |

### Behavior

- **Preconditions:** All required address env vars (USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS) must be set and non-zero. A signing method must be provided via Foundry CLI flag.
- **Postconditions:** LPVault implementation deployed with initializers disabled. LPVaultFactory deployed with correct constructor args matching env vars. Both addresses logged to stdout.
- **Invariants:** No private keys or addresses hardcoded in source. No raw private key read from environment variables. Validation occurs before `vm.startBroadcast()`. `deploy()` does not call `vm.startBroadcast` or `vm.stopBroadcast`.
- **Error modes:** Reverts with descriptive error if any address env var is zero. Factory constructor reverts with `RoleSeparation()` if oracle == operator.

## Tests

- **SC-J92J: Successful deployment with valid configuration**
  - Given all address env vars are set to valid non-zero addresses with oracle != operator
    - When the deploy helper is called directly (test contract as deployer)
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
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("USDC_ADDRESS")
  - Given EXCHANGE_ADDRESS is set to the zero address
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("EXCHANGE_ADDRESS")
  - Given CONDITIONAL_TOKENS_ADDRESS is set to the zero address
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("CONDITIONAL_TOKENS_ADDRESS")
  - Given ADMIN_ADDRESS is set to the zero address
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("ADMIN_ADDRESS")
  - Given ORACLE_ADDRESS is set to the zero address
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("ORACLE_ADDRESS")
  - Given OPERATOR_ADDRESS is set to the zero address
    - When the deploy helper is called
      - Then the call reverts with ZeroAddress("OPERATOR_ADDRESS")
- **SC-J92L: Oracle equals operator (role separation violation)**
  - Given all address env vars are valid but ORACLE_ADDRESS == OPERATOR_ADDRESS
    - When the deploy helper is called
      - Then the LPVaultFactory deployment reverts with RoleSeparation error
- **SC-J92M: Deployment with contract verification**
  - Given all address env vars are valid with correct role separation
    - When the deploy helper is called
      - Then both contracts are deployed (same assertions as SC-J92J)
      - And verification is a CLI-level concern handled by Foundry's --verify flag
- **SC-K49S: Script does not read raw private keys**
  - Given the Deploy.s.sol source code
    - When inspected for env var reads
      - Then no call to `vm.envUint("PRIVATE_KEY")` exists in the script
      - And `deploy()` does not accept a private key parameter
      - And `run()` calls `vm.startBroadcast()` without a key argument
