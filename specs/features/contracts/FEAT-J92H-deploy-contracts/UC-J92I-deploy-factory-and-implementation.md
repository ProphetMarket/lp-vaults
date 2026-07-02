---
id: UC-J92I
name: Deploy Factory and Implementation
feature: FEAT-J92H
status: implemented
version: 1
actor: Factory Owner
---

# UC-J92I: Deploy Factory and Implementation

> Factory Owner deploys the LPVault implementation contract and LPVaultFactory to Polygon Amoy or mainnet using a Foundry script configured via environment variables.

## Preconditions

- Factory Owner has a funded wallet on the target chain (Polygon Amoy or mainnet)
- Environment variables are set: PRIVATE_KEY, USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS
- RPC_URL points to the target chain
- Foundry toolchain (forge) is installed

## Trigger

Factory Owner runs `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast`

---

### SC-J92J: Successful deployment with valid configuration

**Given:**
- All required env vars (PRIVATE_KEY, USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS) are set to valid non-zero addresses
- ORACLE_ADDRESS and OPERATOR_ADDRESS are different addresses
- The deployer wallet has sufficient native token (MATIC/POL) for gas

**Steps:**
1. Factory Owner runs the deploy script with `--broadcast`
2. Script reads and validates all environment variables
3. Script deploys the LPVault implementation contract
4. Script deploys the LPVaultFactory with the implementation address and all env-var addresses
5. Script logs both deployed addresses to stdout

**Outcomes:**
- LPVault implementation is deployed and its `initialize()` is permanently disabled
- LPVaultFactory is deployed with correct role registry (admin, oracle, operator) and external addresses (USDC, exchange, conditionalTokens)
- Both contract addresses are printed to console

**Side Effects:**
- Two contract creation transactions broadcast to the target chain
- Foundry broadcast artifacts written to `broadcast/` directory
- No vault clones created (factory is deployed but no `createVault` is called)

---

### SC-J92K: Missing environment variable

**Given:**
- One or more required env vars (USDC_ADDRESS, EXCHANGE_ADDRESS, CONDITIONAL_TOKENS_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, or OPERATOR_ADDRESS) is unset or set to the zero address

**Steps:**
1. Factory Owner runs the deploy script
2. Script reads environment variables and detects the missing/zero value
3. Script reverts with an error identifying the missing variable

**Outcomes:**
- No contracts are deployed
- Error message identifies which env var is missing or zero

**Side Effects:**
- No transactions broadcast to the chain
- No broadcast artifacts written

---

### SC-J92L: Oracle equals operator (role separation violation)

**Given:**
- All required env vars are set to valid non-zero addresses
- ORACLE_ADDRESS and OPERATOR_ADDRESS are set to the same address

**Steps:**
1. Factory Owner runs the deploy script with `--broadcast`
2. Script reads and validates environment variables (address validation passes)
3. Script deploys the LPVault implementation contract
4. Script attempts to deploy LPVaultFactory -- the constructor reverts due to `RoleSeparation()`

**Outcomes:**
- LPVault implementation may be deployed (wasted gas) but LPVaultFactory is not
- Deployment fails with a role separation error

**Side Effects:**
- Implementation contract creation transaction may be broadcast (depending on Foundry's batch behavior)
- No factory contract created

---

### SC-J92M: Deployment with contract verification

**Given:**
- All required env vars are set to valid non-zero addresses with correct role separation
- ETHERSCAN_API_KEY is set to a valid Polygonscan API key
- Factory Owner passes the `--verify` flag

**Steps:**
1. Factory Owner runs the deploy script with `--broadcast --verify`
2. Script deploys LPVault implementation and LPVaultFactory as in SC-J92J
3. Foundry submits verification requests to the block explorer for both contracts

**Outcomes:**
- Both contracts are deployed and verified on the block explorer
- Source code is publicly readable on Polygonscan (mainnet) or Amoy explorer

**Side Effects:**
- Two contract creation transactions broadcast to the target chain
- Two verification API calls made to the block explorer
- Foundry broadcast artifacts written to `broadcast/` directory

---
