---
id: UC-J92I
name: Deploy Factory and Implementation
feature: FEAT-J92H
status: implemented
version: 3
actor: Factory Owner
---

# UC-J92I: Deploy Factory and Implementation

> Factory Owner deploys the LPVault implementation contract and LPVaultFactory to Polygon Amoy or mainnet using a Foundry script configured via environment variables.

## Preconditions

- Factory Owner has a funded wallet on the target chain (Polygon Amoy or mainnet)
- Environment variables are set: USDC_ADDRESS, EXCHANGE_ADDRESS, CTF_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS, SAFE_FACTORY_ADDRESS
- Factory Owner has a signing method configured: either a `cast` wallet (`--account <name>`) or a hardware wallet (`--ledger` / `--trezor`)
- RPC_URL points to the target chain
- Foundry toolchain (forge) is installed

## Trigger

Factory Owner runs `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --account <wallet-name>` (for cast wallets) or `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --ledger` (for hardware wallets).

---

### SC-J92J: Successful deployment with valid configuration

**Given:**
- All required env vars (USDC_ADDRESS, EXCHANGE_ADDRESS, CTF_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS, SAFE_FACTORY_ADDRESS) are set to valid non-zero addresses
- SAFE_FACTORY_ADDRESS is a deployed Poly Safe factory on the target chain
- A signing method is provided via CLI flag (`--account`, `--ledger`, or `--trezor`)
- ORACLE_ADDRESS and OPERATOR_ADDRESS are different addresses
- The deployer wallet has sufficient native token (MATIC/POL) for gas

**Steps:**
1. Factory Owner runs the deploy script with `--broadcast`
2. Script reads and validates all address environment variables (signing is handled by Foundry CLI)
3. Script reads `getContractBytecode()` and `masterCopy()` from the Safe factory, hashes the bytecode, and logs the factory, the master copy, and the hash
4. Script deploys the LPVault implementation contract
5. Script deploys the LPVaultFactory with the implementation address, all env-var addresses, and the hash
6. Script logs both deployed addresses to stdout

**Outcomes:**
- LPVault implementation is deployed and its `initialize()` is permanently disabled
- LPVaultFactory is deployed with correct role registry (admin, oracle, operator), external addresses (USDC, exchange, conditionalTokens, safeFactory), and the Safe proxy bytecode hash
- Both contract addresses and the hash are printed to console

**Side Effects:**
- Two contract creation transactions broadcast to the target chain
- Two view calls to the Safe factory before the broadcast
- Foundry broadcast artifacts written to `broadcast/` directory
- No vault clones created (factory is deployed but no `createVault` is called)

---

### SC-J92K: Missing environment variable

**Given:**
- One or more required address env vars (USDC_ADDRESS, EXCHANGE_ADDRESS, CTF_ADDRESS, ADMIN_ADDRESS, ORACLE_ADDRESS, OPERATOR_ADDRESS, or SAFE_FACTORY_ADDRESS) is unset or set to the zero address

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
- No call to the Safe factory

---

### SC-9OY8: The hash is read from the Safe factory on chain

**Given:**
- A contract at SAFE_FACTORY_ADDRESS exposes `getContractBytecode()` and `masterCopy()`

**Steps:**
1. The test calls `readSafeProxyBytecodeHash(safeFactory)` on the script with a stub factory that returns known bytes
2. The script returns `keccak256` of those bytes

**Outcomes:**
- The returned hash equals the hash the test computes from the same bytes
- Given a zero hash passed to `deploy()`, the call reverts with `ZeroBytecodeHash`, so a zero hash never reaches the factory

**Side Effects:**
- One view call to the stub factory
- No contract deployed on the zero-hash path

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

### SC-K49S: Script does not read raw private keys

**Given:**
- PRIVATE_KEY environment variable is set

**Steps:**
1. Factory Owner runs the deploy script with `--account <wallet-name>`
2. Script reads address environment variables but does not call `vm.envUint("PRIVATE_KEY")`
3. Transaction signing is handled by Foundry's CLI-level wallet management

**Outcomes:**
- Script executes without reading PRIVATE_KEY
- No raw private key material enters the script's memory

**Side Effects:**
- No raw private key read from environment
- PRIVATE_KEY env var is ignored entirely

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
