# DEPLOYMENT GUIDE

Step-by-step instructions for deploying the LP Vaults contracts to **Polygon Amoy (testnet)** and **Polygon mainnet**.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Dependencies](#2-install-dependencies)
3. [Build the Contracts](#3-build-the-contracts)
4. [Environment Variables](#4-environment-variables)
5. [Set Up a Deployer Account in Foundry](#5-set-up-a-deployer-account-in-foundry)
6. [Deploy to Polygon Amoy (Testnet)](#6-deploy-to-polygon-amoy-testnet)
7. [Deploy to Polygon Mainnet](#7-deploy-to-polygon-mainnet)
8. [Verify Deployment](#8-verify-deployment)
9. [Post-Deployment Steps](#9-post-deployment-steps)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **Foundry** (forge, cast, anvil) | latest stable | see below |
| **Git** | ≥ 2.30 | system package manager |
| **Node.js** | ≥ 18 (for `cast` wallet management via `npx`) | [nodejs.org](https://nodejs.org) |

### Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify:

```bash
forge --version
# forge 0.2.0 (abcdef 2025-...)
```

---

## 2. Install Dependencies

```bash
# Clone the repository (if you haven't already)
git clone <repo-url>
cd lp-vaults

# Install git-submodule dependencies (forge-std, ctf-exchange)
forge install
```

If `forge install` prompts about submodule conflicts, run:

```bash
git submodule update --init --recursive
```

---

## 3. Build the Contracts

```bash
forge build
```

Expected output ends with:

```
Compiler run successful!
```

### Compiler settings

`foundry.toml` turns the optimizer on with `optimizer_runs = 200`, chosen for contract size. Before a deploy, run `forge build --sizes --skip test --skip script`. It prints the runtime size of each `src/` contract and must exit 0. `forge verify-contract` reads the optimizer settings from `foundry.toml`, so verification needs no extra flag. Artifacts under `broadcast/` made before this setting hold different bytecode.

If you see compilation errors, ensure you are on the exact compiler version:

```bash
forge build --use solc:0.8.20
```

---

## 4. Environment Variables

The deploy script reads seven required address variables. **None of them is a private key** — signing is handled by Foundry's keystore (see §5).

Create a `.env` file in the repository root:

```bash
cp .env.example .env   # if an example exists
# or create it from scratch:
touch .env
```

### Required variables

```dotenv
# ── External contract addresses ──────────────────────────────────────────────

# USDC ERC-20 contract on the target chain
USDC_ADDRESS=0x...

# ProphetCTFExchange contract on the target chain
EXCHANGE_ADDRESS=0x...

# Gnosis ConditionalTokens (ERC-1155) contract on the target chain
CTF_ADDRESS=0x...

# Poly Safe factory on the target chain — the CREATE2 deployer of every user's Safe.
# Use the value the deployed exchange returns from getSafeFactory(), so LPs sign
# for the same Safe on the vault and on the exchange. The script reads the proxy
# bytecode from this contract and hashes it (see "Known contract addresses").
SAFE_FACTORY_ADDRESS=0x...

# ── Role wallet addresses (NOT private keys) ─────────────────────────────────

# Initial Admin — registry-only authority (add/remove operators, set oracle)
ADMIN_ADDRESS=0x...

# Initial Oracle — vault lifecycle authority (createVault, startWindDown)
# Must be a DIFFERENT wallet from OPERATOR_ADDRESS
ORACLE_ADDRESS=0x...

# Initial Operator — transactional authority (depositForIntent, mintPositionFor,
# reclaimDepositFor, notifyFees, etc.)
# Must be a DIFFERENT wallet from ORACLE_ADDRESS
OPERATOR_ADDRESS=0x...

# ── Verification ─────────────────────────────────────────────────────────────

# Etherscan API key — REQUIRED for --verify; without this the verify step is skipped
# One key works across all Etherscan V2 supported chains (including Polygon).
# Get one free at https://etherscan.io/apis
ETHERSCAN_API_KEY=<your-etherscan-api-key>
```

> **Important:** `ORACLE_ADDRESS` and `OPERATOR_ADDRESS` **must be different wallets**. The constructor enforces this with a `RoleSeparation` revert. Using the same address for both causes the deployment to fail.

Load the variables into your shell:

```bash
source .env
```

### Known contract addresses

| Network | USDC | CTF Exchange | ConditionalTokens |
|---------|------|--------------|-------------------|
| Polygon mainnet | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | `0x127aD3A6e55EbBDaecC0eaeb12615879611e1839` | `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` |
| Polygon Amoy | varies — check Prophet testnet docs | `0xe97fe5338f70c4e82a5292b274ad16d87799c476` | (testnet address) |

### Safe derivation inputs

The factory holds two immutable values that every vault reads to check an LP's owner-key signature: the Poly Safe factory address and the hash of that factory's proxy bytecode (`keccak256(getContractBytecode())`, which is the proxy creation code concatenated with the ABI-encoded master copy). The deploy script reads the bytecode from the live factory and prints the hash. Compare the printed hash with this table before you broadcast.

| Chain | Safe factory (`SAFE_FACTORY_ADDRESS`) | Master copy | Expected proxy bytecode hash |
|-------|--------------------------------------|-------------|------------------------------|
| Polygon (137) | `0xD0d6655B69d5589402593a854836bbe5305ab09B` | `0x0b71A0e839474D7eCF2ED1546fBB1D0603D19760` | `0x4b856c0ca50349cc4a9add5f9bfa9cb369b54f8b87f90023a3fb45b49eadec50` |
| Amoy (80002) | `0x0F95cE955dE28995F41f0A89B61aEa1c5e8F4c7a` | `0xA2AfB5D91dE9Dfddb2B202770B2CE2178afdC039` | `0x182112daed9969029a2a0edb10305e67a23eb3aa54543a1b8c7c08e9c8977c48` |

Provenance, read on 2026-09-12: each Safe factory address is the value the deployed exchange on that chain returns from `getSafeFactory()`, and matches the Poly Safe deploy broadcast (`all-contracts/contracts-poly-safe/broadcast/DeployPolySafeFactory.s.sol/<chain>/`). Each master copy is the factory's `masterCopy()`. Each hash is `keccak256` of the factory's `getContractBytecode()`. The proxy creation code alone hashes to `0x8a72557f8d679f61f25b538fe487e8cdcdc3b9cb3f77163e11be999f2beed2df` on both chains, which matches the constant in the exchange's `PolySafeLib.sol` and in the server's `safe.go`.

Check the hash yourself:

```bash
cast call $SAFE_FACTORY_ADDRESS "getContractBytecode()(bytes)" --rpc-url $RPC_URL | cast keccak
```

Check the derivation against the live factory for any owner key (the test key `0xA11CE`, owner `0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7`, derives `0x511894A9736bdE6F848364A33e81F67cC183655E` on Polygon and `0x40953b353BFFa880AD4EF3A38f994625fD92aEf3` on Amoy):

```bash
cast call $SAFE_FACTORY_ADDRESS "computeProxyAddress(address)(address)" <OWNER_KEY> --rpc-url $RPC_URL
```

A factory deployed with a wrong hash rejects every relayed LP signature on every vault it creates, and neither value can change after deployment. A new Safe factory needs a new LP vault factory.

Fill these in before sourcing your `.env`.

---

## 5. Set Up a Deployer Account in Foundry

Foundry's **keystore** (`cast wallet`) stores encrypted private keys locally so you never paste a raw key into a command. The deploy script uses `--account <name>` to reference the keystore entry.

### Create a keystore entry

```bash
cast wallet import <account-name> --interactive
```

You will be prompted to:
1. Paste your private key (input is hidden)
2. Set a password to encrypt the keystore file

Replace `<account-name>` with any label you want (e.g., `deploy-amoy`, `deploy-mainnet`).

### Verify the account was saved

```bash
cast wallet list
# deploy-amoy
```

> **Why `--account` and not `--sender`?**
> `--sender` sets the *from* address for simulation only — it does **not** sign transactions. Using `--sender` alone causes the broadcast to fail. Always use `--account` for live deployments.

---

## 6. Deploy to Polygon Amoy (Testnet)

### 6.1 Get testnet MATIC

Fund your deployer wallet with Amoy MATIC from the [Polygon Faucet](https://faucet.polygon.technology/).

### 6.2 Source your environment

```bash
source .env
```

### 6.3 Simulate the deployment (dry run — no broadcast)

Always simulate first to catch address validation errors without spending gas:

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc-amoy.polygon.technology \
  --account <account-name>
```

Look for the Safe derivation inputs and both contract addresses printed at the end. Compare the hash with the table in §4 before you broadcast:

```
Safe factory:             0x...
Safe master copy:         0x...
Safe proxy bytecode hash:
0x...
LPVault implementation:   0x...
LPVaultFactory:           0x...
```

### 6.4 Broadcast the deployment

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc-amoy.polygon.technology \
  --account <account-name> \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

> **Etherscan V2 API.** Polygonscan is now served through Etherscan's unified V2 endpoint (`https://api.etherscan.io/v2/api?chainid=<id>`). The old `api-amoy.polygonscan.com/api` and `api.polygonscan.com/api` V1 URLs are deprecated and return `NOTOK` — see the [V2 migration guide](https://docs.etherscan.io/v2-migration). Your **Etherscan API key** works across all supported chains (including Polygon); you no longer need a chain-specific key.
>
> **`ETHERSCAN_API_KEY` is mandatory for `--verify`.** If it is not set (or set to an empty string), Foundry will broadcast successfully but skip verification silently — your contract will show as unverified on Polygonscan. Get a free API key at [etherscan.io/apis](https://etherscan.io/apis).

You will be prompted for the keystore password you set in §5.

### 6.5 Confirm success

Foundry prints the transaction hashes and contract addresses:

```
##### amoy
✅  [Success] Hash: 0xabc... (LPVault)
✅  [Success] Hash: 0xdef... (LPVaultFactory)
```

The broadcast artifact is saved to:

```
broadcast/Deploy.s.sol/80002/run-latest.json
```

---

## 7. Deploy to Polygon Mainnet

Steps are identical to Amoy; only the RPC URL, chain ID, and Polygonscan verifier URL change.

### 7.1 Source your environment

```bash
source .env
```

### 7.2 Simulate (dry run)

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://polygon-rpc.com \
  --account <account-name>
```

### 7.3 Broadcast

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://polygon-rpc.com \
  --account <account-name> \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=137" \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

You will be prompted for the keystore password.

### 7.4 Confirm success

The broadcast artifact is saved to:

```
broadcast/Deploy.s.sol/137/run-latest.json
```

---

## 8. Verify Deployment

If verification was skipped (e.g., you forgot the API key), you can verify manually after the fact:

```bash
# Verify LPVaultFactory
forge verify-contract \
  <FACTORY_ADDRESS> \
  src/LPVaultFactory.sol:LPVaultFactory \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=137" \
  --chain-id 137 \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address,address,bytes32)" \
    <IMPL_ADDRESS> $USDC_ADDRESS $EXCHANGE_ADDRESS $CTF_ADDRESS $ADMIN_ADDRESS $ORACLE_ADDRESS $OPERATOR_ADDRESS \
    $SAFE_FACTORY_ADDRESS <SAFE_PROXY_BYTECODE_HASH>)

# Verify LPVault implementation (no constructor args needed — it uses _disableInitializers)
forge verify-contract \
  <IMPL_ADDRESS> \
  src/LPVault.sol:LPVault \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=137" \
  --chain-id 137
```

For Amoy, replace both instances of `chainid=137` (in the URL) and `--chain-id 137` with `80002`.

---

## 9. Post-Deployment Steps

After the factory is deployed, the **Oracle** must call `createVault` to deploy individual market vaults:

```bash
cast send <FACTORY_ADDRESS> \
  "createVault(bytes32,int24,uint128,bytes32,uint256,uint256)" \
  <MARKET_ID> <TICK_SPACING> <MIN_FIRST_LIQUIDITY> <CONDITION_ID> <YES_TOKEN_ID> <NO_TOKEN_ID> \
  --rpc-url https://polygon-rpc.com \
  --account <oracle-account-name>
```

`<CONDITION_ID>` is the market's condition ID on the ConditionalTokens contract. `<YES_TOKEN_ID>` is the index set 1 position ID and `<NO_TOKEN_ID>` is the index set 2 position ID of that condition, with USDC as collateral. Read both from the ConditionalTokens contract with `getPositionId(<USDC>, getCollectionId(0x0000000000000000000000000000000000000000000000000000000000000000, <CONDITION_ID>, 1))` for YES and the same call with index set `2` for NO. The factory checks all three values and reverts before it deploys a vault if any value is wrong, because a vault can never correct its identity later.

Before the first deposit into a vault, the app relays `USDC.approve(<VAULT_ADDRESS>, <amount>)` from the LP's Safe, as it relays every Safe transaction today. Prophet adds that call and `USDC.approve(<VAULT_ADDRESS>, 0)` to the relay allow list, so an LP can also revoke. The Operator then calls `depositForIntent` with the owner key's signed `MintIntent`, and `mintPositionFor` with the same six fields. The self-service `reclaimDeposit(bytes32)` is a Safe transaction the owner key signs; Prophet either adds it to the relay allow list, or the LP submits it through another relayer or the Safe app when the Operator does not cooperate.

The **Admin** should immediately:
1. Confirm the initial operator and oracle are set correctly by calling `operators(<address>)` and `oracle()` on the factory, and the Safe derivation inputs by calling `safeFactory()` and `safeProxyBytecodeHash()`.
2. Review the `adminCount` — it should be `1`.
3. Transfer admin if needed via the two-step `transferAdmin` / `acceptAdmin` flow.
4. After a transfer, call `removeAdmin(<old admin address>)` from the new admin. `acceptAdmin` adds the new admin but does not remove the old one, so the old key keeps full admin rights on the factory and on every vault until it is removed.
5. Review `defaultEmergencyCancelTimelock()` on the factory (7 days at deployment). To change it for vaults created from now on, run `cast send <FACTORY_ADDRESS> "setDefaultEmergencyCancelTimelock(uint32)" <seconds> --rpc-url https://polygon-rpc.com --account <admin-account-name>`, with a value above 0 and at most 2,592,000 (30 days). An existing vault keeps the value it copied at creation, readable as `emergencyCancelTimelock()` on the vault, and nothing can change it.

### Operator USDC approval per vault

`notifyFees(amount)` takes `amount` USDC from the Operator wallet with `transferFrom` in the same call, so no fee credit exists without the USDC behind it. Every Operator wallet therefore needs a standing USDC approval to every vault it reports fees to. Grant it when the keeper onboards the vault, from each Operator wallet:

```bash
cast send <USDC_ADDRESS> \
  "approve(address,uint256)" \
  <VAULT_ADDRESS> 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --rpc-url https://polygon-rpc.com \
  --account <operator-account-name>
```

A max approval is the recommended grant, as `initialize()` grants to the exchange: the vault pulls only inside `notifyFees`, which the Operator itself calls with the amount it chose, so the approval never exposes more than the Operator reports. Repeat the grant for each vault, because every vault is its own EIP-1167 clone, and for each Operator wallet the keeper uses. A vault whose Operator wallet gave no approval, or holds less USDC than it reports, reverts on `notifyFees` with `TransferFailed`; that is the expected failure mode, and the fix is the approval or the sweep, not a contract change.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `RoleSeparation()` revert | `ORACLE_ADDRESS == OPERATOR_ADDRESS` | Use two distinct wallets |
| `ZeroAddress("X")` revert | Env var `X` is unset or `0x0` | `source .env` and check the variable |
| Verification fails silently | `ETHERSCAN_API_KEY` not set or empty | Set the variable and re-run `forge verify-contract` |
| `--account` not found | Keystore entry not created | Run `cast wallet import <name> --interactive` |
| `insufficient funds` | Deployer has no MATIC | Fund from faucet (Amoy) or bridge (mainnet) |
| Compilation error `0.8.20` | Wrong compiler installed | Run `forge build --use solc:0.8.20` |
| `DuplicateMarket()` on createVault | Vault for this marketId already exists | Check `vaultForMarket[marketId]` on the factory |
| `ZeroConditionId()` on createVault | `<CONDITION_ID>` is zero | Pass the market's condition ID |
| `ZeroTokenId()` on createVault | `<YES_TOKEN_ID>` or `<NO_TOKEN_ID>` is zero | Pass both outcome token IDs |
| `DuplicateTokenId()` on createVault | The same ID was passed for YES and NO | Pass the index set 1 ID as YES and the index set 2 ID as NO |
| `NotBinaryCondition()` on createVault | The condition is not prepared, or it has 3 or more outcomes | Call `getOutcomeSlotCount(<CONDITION_ID>)` on the ConditionalTokens contract. It must return `2` |
| `TokenIdMismatch()` on createVault | The token IDs belong to another condition, or YES and NO are swapped | Recompute both IDs from `<CONDITION_ID>` with USDC as collateral, index set 1 for YES and index set 2 for NO |
