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

If you see compilation errors, ensure you are on the exact compiler version:

```bash
forge build --use solc:0.8.20
```

---

## 4. Environment Variables

The deploy script reads six required address variables. **None of them is a private key** — signing is handled by Foundry's keystore (see §5).

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

# ── Role wallet addresses (NOT private keys) ─────────────────────────────────

# Initial Admin — registry-only authority (add/remove operators, set oracle)
ADMIN_ADDRESS=0x...

# Initial Oracle — vault lifecycle authority (createVault, startWindDown)
# Must be a DIFFERENT wallet from OPERATOR_ADDRESS
ORACLE_ADDRESS=0x...

# Initial Operator — transactional authority (mintPositionFor, notifyFees, etc.)
# Must be a DIFFERENT wallet from ORACLE_ADDRESS
OPERATOR_ADDRESS=0x...

# ── Verification ─────────────────────────────────────────────────────────────

# Polygonscan API key — REQUIRED for --verify; without this the verify step is skipped
# Get one free at https://polygonscan.com/apis
ETHERSCAN_API_KEY=<your-polygonscan-api-key>
```

> **Important:** `ORACLE_ADDRESS` and `OPERATOR_ADDRESS` **must be different wallets**. The constructor enforces this with a `RoleSeparation` revert. Using the same address for both causes the deployment to fail.

Load the variables into your shell:

```bash
source .env
```

### Known contract addresses

| Network | USDC | CTF Exchange | ConditionalTokens |
|---------|------|--------------|-------------------|
| Polygon mainnet | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | (Prophet address) | `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` |
| Polygon Amoy | varies — check Prophet testnet docs | (Prophet testnet address) | (testnet address) |

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

Look for both contract addresses printed at the end:

```
LPVault implementation: 0x...
LPVaultFactory:         0x...
```

### 6.4 Broadcast the deployment

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc-amoy.polygon.technology \
  --account <account-name> \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url https://api-amoy.polygonscan.com/api \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

> **`ETHERSCAN_API_KEY` is mandatory for `--verify`.** If it is not set (or set to an empty string), Foundry will broadcast successfully but skip verification silently — your contract will show as unverified on Polygonscan. Get a free API key at [polygonscan.com/apis](https://polygonscan.com/apis).

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
  --verifier-url https://api.polygonscan.com/api \
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
  --rpc-url https://polygon-rpc.com \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api.polygonscan.com/api \
  --chain-id 137 \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address)" \
    <IMPL_ADDRESS> $USDC_ADDRESS $EXCHANGE_ADDRESS $CTF_ADDRESS $ADMIN_ADDRESS $ORACLE_ADDRESS $OPERATOR_ADDRESS)

# Verify LPVault implementation (no constructor args needed — it uses _disableInitializers)
forge verify-contract \
  <IMPL_ADDRESS> \
  src/LPVault.sol:LPVault \
  --rpc-url https://polygon-rpc.com \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api.polygonscan.com/api \
  --chain-id 137
```

For Amoy, replace `--chain-id 137` with `--chain-id 80002` and the mainnet verifier URL with `https://api-amoy.polygonscan.com/api`.

---

## 9. Post-Deployment Steps

After the factory is deployed, the **Oracle** must call `createVault` to deploy individual market vaults:

```bash
cast send <FACTORY_ADDRESS> \
  "createVault(bytes32,int24,uint128)" \
  <MARKET_ID> <TICK_SPACING> <MIN_FIRST_LIQUIDITY> \
  --rpc-url https://polygon-rpc.com \
  --account <oracle-account-name>
```

The **Admin** should immediately:
1. Confirm the initial operator and oracle are set correctly by calling `operators(<address>)` and `oracle()` on the factory.
2. Review the `adminCount` — it should be `1`.
3. Transfer admin if needed via the two-step `transferAdmin` / `acceptAdmin` flow.

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
