---
id: FEAT-J92H
name: Deploy Contracts
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: [FEAT-REPZ]
---

# Deploy Contracts

> Foundry deploy script that deploys the LPVault implementation and LPVaultFactory to Polygon Amoy or mainnet using environment-variable-driven configuration.

## Non-Goals

- Does not create vaults for specific markets -- see FEAT-REPZ (createVault is called separately after factory deployment)
- Does not handle post-deployment role management -- see FEAT-REPZ UC-REQ2
- Does not deploy or configure off-chain services (keeper, event listener, server)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Factory Owner | Runs the deploy script | Configures a cast wallet or hardware wallet; signs deployment transactions |

## Functional Requirements

### Environment Configuration

**FR-J92N** `When the Factory Owner runs the deploy script, the system shall read the following addresses from environment variables: USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS.`
Fit Criterion: Given any of the required env vars is unset or zero-address, the script reverts before broadcasting any transaction.
Linked to: UC-J92I

**FR-J92O** `When the Factory Owner runs the deploy script, the system shall delegate transaction signing to Foundry's CLI-level wallet management (--account for cast keystores, --ledger for Ledger, --trezor for Trezor) and shall not read any raw private key from environment variables.`
Fit Criterion: Given the script executes, it calls `vm.startBroadcast()` without a private key argument; no call to `vm.envUint("PRIVATE_KEY")` exists in the script; signing is resolved by the CLI flag the Factory Owner provides.
Linked to: UC-J92I

### Deployment Sequence

**FR-J92P** `When the deploy script executes, the system shall first deploy the LPVault implementation contract, then deploy the LPVaultFactory with the implementation address and all env-var-sourced addresses as constructor arguments.`
Fit Criterion: Given valid env vars and a funded deployer, two contracts are deployed in sequence; the factory's `implementation` storage matches the first contract's address; the factory's role registry matches the env-var addresses.
Linked to: UC-J92I

**FR-J92Q** `When the deploy script executes, the system shall call _disableInitializers() in the LPVault implementation's constructor, preventing direct initialization.`
Fit Criterion: Given a successful deployment, calling `initialize()` directly on the implementation contract reverts.
Linked to: UC-J92I

### Contract Verification

**FR-J92R** `When the Factory Owner runs the deploy script with the --verify flag and ETHERSCAN_API_KEY set, the system shall verify both deployed contracts on the target chain's block explorer.`
Fit Criterion: Given --verify flag and valid API key, both contracts are verified on Polygonscan (mainnet) or Amoy explorer after deployment.
Linked to: UC-J92I

### Network Targeting

**FR-J92S** `When the Factory Owner provides --rpc-url pointing to Polygon mainnet or Amoy, the system shall deploy to that specific network without any script modification.`
Fit Criterion: Given --rpc-url for Amoy, contracts deploy to Amoy; given --rpc-url for mainnet, contracts deploy to mainnet. The same script file works for both.
Linked to: UC-J92I

### Deployment Output

**FR-J92T** `When the deploy script completes successfully, the system shall log the deployed LPVault implementation address and LPVaultFactory address to stdout.`
Fit Criterion: Given a successful broadcast, both addresses are printed in the console output.
Linked to: UC-J92I

## Non-Functional Requirements

**NFR-J92U** Security: `The deploy script shall never hardcode private keys, addresses, or secrets in source code. Raw private keys shall not be accepted via environment variables. Transaction signing must use Foundry's keystore (cast wallet) or hardware wallet integration exclusively. Non-secret addresses may be read from environment variables.`

**NFR-J92V** Reliability: `The deploy script shall validate all environment variable addresses are non-zero before broadcasting any transaction, failing fast on misconfiguration.`

## Acceptance

> The feature is complete when all of the following are true:

- The deploy script successfully deploys LPVault implementation + LPVaultFactory to a local Anvil fork
- All env vars are validated before any transaction is broadcast
- The factory's on-chain state matches the env-var-provided addresses after deployment
- The implementation contract rejects direct `initialize()` calls
- The same script works for Polygon Amoy and mainnet by changing only `--rpc-url`
- Contract verification succeeds on Polygonscan when `--verify` and `ETHERSCAN_API_KEY` are provided
- No private keys or addresses are hardcoded in the script source
- `forge fmt` passes
- FEATURES.md status is `implemented`
