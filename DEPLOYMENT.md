# Deployment Guide

This guide deploys the LP Vaults contracts to Polygon Amoy (the testnet) and to Polygon mainnet. It covers the checks before a deployment, the deployment, the checks after it, the creation of a market vault, daily operations, and an implementation upgrade.

The addresses and hashes in this guide were read from both chains on 2026-09-15. The chain is the source of truth, so run the pre-flight checks in section 8 before every deployment.

---

## Contents

1. [What you deploy](#1-what-you-deploy)
2. [Network reference](#2-network-reference)
3. [Wallets and roles](#3-wallets-and-roles)
4. [Install the tools and get the code](#4-install-the-tools-and-get-the-code)
5. [Build and test the commit you deploy](#5-build-and-test-the-commit-you-deploy)
6. [Configure the environment](#6-configure-the-environment)
7. [Create the keystore accounts](#7-create-the-keystore-accounts)
8. [Pre-flight checks](#8-pre-flight-checks)
9. [Deploy to Polygon Amoy](#9-deploy-to-polygon-amoy)
10. [Deploy to Polygon mainnet](#10-deploy-to-polygon-mainnet)
11. [Check the deployed factory](#11-check-the-deployed-factory)
12. [Create a market vault](#12-create-a-market-vault)
13. [Smoke test on Amoy](#13-smoke-test-on-amoy)
14. [Operations](#14-operations)
15. [Upgrade the implementation for new vaults](#15-upgrade-the-implementation-for-new-vaults)
16. [Verify on the explorer by hand](#16-verify-on-the-explorer-by-hand)
17. [Troubleshooting](#17-troubleshooting)
18. [Deployment record](#18-deployment-record)

---

## 1. What you deploy

One run of `script/Deploy.s.sol` deploys two contracts:

| Contract | What it is |
|---|---|
| `LPVault` (the implementation) | The vault code. Nobody uses it directly. Its constructor disables `initialize`, so the implementation can never become a vault itself. |
| `LPVaultFactory` | The role registry (Admin, Oracle, Operators) and the vault factory. The Oracle calls `createVault` once per market, and the factory deploys an EIP-1167 clone: a minimal proxy that runs the implementation's code with its own storage. |

The script does not deploy the exchange, USDC, the Conditional Tokens contract, or the Safe factory. Prophet already runs them on each chain. The script creates no market vault. Section 12 does that.

### Five values that can never change

The factory stores these values as immutables, and every vault uses them:

| Value | Why it must be exact |
|---|---|
| `EXCHANGE_ADDRESS` | Each vault approves this exchange for its USDC and its outcome tokens. It answers `isValidSignature` only when this exchange calls. |
| `USDC_ADDRESS` | It must equal the exchange's collateral, `getCollateral()`. The outcome token IDs are computed from it, so any other USDC makes every `createVault` revert with `TokenIdMismatch()`. |
| `CTF_ADDRESS` | It must equal the exchange's Conditional Tokens contract, `getCtf()`. A vault accepts outcome tokens only from it, and merges and redeems through it. |
| `SAFE_FACTORY_ADDRESS` | It must equal the exchange's Safe factory, `getSafeFactory()`. A vault derives each LP's Safe from the owner key through it. A wrong factory rejects every relayed LP signature. |
| The Safe proxy bytecode hash | The script reads it from the Safe factory. It is the second input of the Safe derivation. |

No function can correct these values. A wrong value needs a new factory, and every vault the old factory created keeps the wrong value.

---

## 2. Network reference

### Polygon mainnet (chain ID 137)

| Item | Value |
|---|---|
| Gas token | POL |
| Block explorer | https://polygonscan.com |
| RPC | Use a private RPC provider for the broadcast. The public `https://polygon-bor-rpc.publicnode.com` worked for reads on 2026-09-15. The public `https://polygon-rpc.com` answered `401 API key disabled` on 2026-09-15. |
| `EXCHANGE_ADDRESS` (ProphetCTFExchange) | `0x127aD3A6e55EbBDaecC0eaeb12615879611e1839` |
| `USDC_ADDRESS` (Circle native USDC) | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` |
| `CTF_ADDRESS` (Gnosis ConditionalTokens) | `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` |
| `SAFE_FACTORY_ADDRESS` (Poly Safe factory) | `0xD0d6655B69d5589402593a854836bbe5305ab09B` |
| Safe master copy | `0x0b71A0e839474D7eCF2ED1546fBB1D0603D19760` |
| `EXPECTED_SAFE_HASH` (Safe proxy bytecode hash) | `0x4b856c0ca50349cc4a9add5f9bfa9cb369b54f8b87f90023a3fb45b49eadec50` |
| `EXPECTED_TEST_SAFE` (the Safe of the test key) | `0x511894A9736bdE6F848364A33e81F67cC183655E` |

> **Do not use the bridged USDC.e (`0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`).** The exchange uses native USDC. An earlier version of this guide named USDC.e by mistake. The Prophet server also refuses any USDC other than native USDC on chain 137.

### Polygon Amoy (chain ID 80002)

| Item | Value |
|---|---|
| Gas token | POL (testnet), from https://faucet.polygon.technology |
| Block explorer | https://amoy.polygonscan.com |
| RPC | `https://polygon-amoy-bor-rpc.publicnode.com` worked on 2026-09-15. Polygon's own `https://rpc-amoy.polygon.technology` is an alternative. |
| `EXCHANGE_ADDRESS` (ProphetCTFExchange) | `0x0D9BD7320985ee23c04885Ec93f6c118a83c7ec0` |
| `USDC_ADDRESS` (Prophet's "Test USD Coin", 6 decimals) | `0x4b0a4ADc5349709D9111C473cf93e9Af30Fd5fA6` |
| `CTF_ADDRESS` (Prophet's mock of the Gnosis contract) | `0xc8c5f5946Ab75658994b68D131aDbB6D22A4D9e5` |
| `SAFE_FACTORY_ADDRESS` (Poly Safe factory) | `0x5aa054022E1Fd277246026a05908071C1d6342A1` |
| Safe master copy | `0x6C9385AE09fC4Bc3511c2C651961b016a300B46A` |
| `EXPECTED_SAFE_HASH` (Safe proxy bytecode hash) | `0x429fab1122fd10e23ed01de931c34fa9a6c84298f2324ae9f17f770ad9cdf548` |
| `EXPECTED_TEST_SAFE` (the Safe of the test key) | `0xE4cE6BC765AccCdB4aC1ab884D7C968F014Dc60E` |

The Amoy exchange, USDC, and Conditional Tokens contract come from the Prophet contracts deployment of 2026-04-30 (contracts commit `341f331`). The Prophet app's dev environment uses the same addresses.

- The test USDC has a public `faucet(address to, uint256 amount)`, so a test Safe can get USDC without the token owner.
- The mock Conditional Tokens contract has every function a vault calls: `getOutcomeSlotCount`, `getCollectionId`, `getPositionId`, `mergePositions`, `redeemPositions`, `payoutNumerators`, `payoutDenominator`, and the ERC-1155 transfers.

### Retired Amoy contracts: do not use

| Contract | Address | Reason |
|---|---|---|
| Older ProphetCTFExchange | `0xe97fe5338f70c4e82a5292b274ad16d87799c476` | The exchange above replaced it. Its collateral, Conditional Tokens contract, and Safe factory are all different. |
| Older Poly Safe factory | `0x0F95cE955dE28995F41f0A89B61aEa1c5e8F4c7a` | The current Amoy exchange does not use it. Its master copy is `0xA2AfB5D91dE9Dfddb2B202770B2CE2178afdC039`, its hash is `0x182112daed9969029a2a0edb10305e67a23eb3aa54543a1b8c7c08e9c8977c48`, and the test key derives `0x40953b353BFFa880AD4EF3A38f994625fD92aEf3`. The Safe derivation test in `test/features/FEAT-3ZRI-escrow-deposit-for-mint-intent/` still uses these values as a fixed vector. |
| LP vault factory of 2026-07-03 | `0x565fec72c70ff4f744d3a703f0114ab88bb54d67` (implementation `0x91d3c66ed0783dfb1a9aac14fb94fda708f11ebc`) | Built before the audit fixes, with the old seven-argument constructor. |

### The test key

The checks use a public test key: private key `0xA11CE`, owner address `0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7`. Its Safe address on each chain proves that the Safe factory derives Safes the way the vault does. Never send funds to this key or to its Safes.

---

## 3. Wallets and roles

| Wallet | Variable | Role on the LP vault factory | Needs on the exchange | Job |
|---|---|---|---|---|
| Deployer | `DEPLOYER_ADDRESS` | None | Nothing | Pays the deployment gas. The script gives it no role. |
| Admin | `ADMIN_ADDRESS` | Admin, set by the constructor | Nothing | Adds and removes Operators and Admins, sets the Oracle, pauses a vault, sets the default emergency timelock, and schedules implementation upgrades. |
| Oracle | `ORACLE_ADDRESS` | Oracle, set by the constructor | The exchange's `oracle()` or an exchange Admin, to call `registerToken` | Calls `createVault`, `setMinimumFirstLiquidity`, `startWindDown`, and `redeemOutcomeTokens`. |
| Operator | `OPERATOR_ADDRESS` | Operator, set by the constructor | An exchange operator (`isOperator`) when the same wallet submits `matchOrders` | The Prophet server calls `depositForIntent`, `mintPositionFor`, `reclaimDepositFor`, and `burnPositionFor`. The keeper calls `updateTick`, `mergePositions`, and `heartbeat`, and signs vault orders. |

Rules:

- The Oracle and the Operator must be different wallets. The constructor reverts with `RoleSeparation()` when they are equal, and `addOperator` and `setOracle` keep the rule later.
- The Admin, the Oracle, and the Operator each need POL for their own transactions.
- For mainnet, we recommend a hardware wallet or a Safe multisig for the Admin, because the Admin controls the Operator list and the implementation pointer. A Safe can hold the role: section 14.6 transfers the role to it after the deployment.
- The deployer only pays gas. Use a separate deployer account for each chain.

---

## 4. Install the tools and get the code

| Tool | Version | Why |
|---|---|---|
| Foundry (`forge`, `cast`) | Tested with 1.7.1 | Build, test, deploy, and read the chain |
| Git | 2.30 or later | Get the code and its submodule |
| `jq` | Any | Read the deployment record in section 9.6 |

Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version
```

Get the code at the commit you deploy:

```bash
git clone git@github.com:ProphetMarket/lp-vaults.git
cd lp-vaults
git checkout <release commit or tag>
git submodule update --init --recursive
git rev-parse HEAD   # write this commit in the deployment record (section 18)
```

`lib/forge-std` is committed in the repository. `lib/ctf-exchange` is a git submodule, and the tests read the Conditional Tokens bytecode from it.

---

## 5. Build and test the commit you deploy

```bash
forge build
forge build --sizes --skip test --skip script
forge test
forge fmt --check
```

Each command must exit 0:

- `forge build --sizes --skip test --skip script` prints the runtime size of `LPVault` and `LPVaultFactory`. Both must stay below 24,576 bytes, the contract size limit. `forge test` does not check this limit, so run the size check.
- `forge test` must pass every test.
- `forge fmt --check` must report no change.

### Compiler settings

`foundry.toml` sets Solidity 0.8.20, the optimizer on at 100 runs, and `via_ir` off. Do not change `foundry.toml` between the build, the deployment, and the explorer verification: the explorer compiles the source with these settings and compares the bytecode. Deployment records under `broadcast/` made before these settings hold different bytecode.

---

## 6. Configure the environment

Create `.env` from the example:

```bash
cp .env.example .env
```

Fill in every value. Leave a role's account empty only when that role signs nothing on this chain. `.gitignore` excludes `.env`, so the file never reaches git. The file holds addresses and keystore account names only. It holds no private key.

| Variable | Read by | Amoy | Mainnet |
|---|---|---|---|
| `USDC_ADDRESS` | Deploy script | Section 2 | Section 2 |
| `EXCHANGE_ADDRESS` | Deploy script | Section 2 | Section 2 |
| `CTF_ADDRESS` | Deploy script | Section 2 | Section 2 |
| `SAFE_FACTORY_ADDRESS` | Deploy script | Section 2 | Section 2 |
| `ADMIN_ADDRESS` | Deploy script | Your Amoy Admin | Your mainnet Admin |
| `ORACLE_ADDRESS` | Deploy script | Your Amoy Oracle | Your mainnet Oracle |
| `OPERATOR_ADDRESS` | Deploy script | Your Amoy Operator | Your mainnet Operator |
| `ETHERSCAN_API_KEY` | `--verify` | One Etherscan key | The same key |
| `RPC_URL` | The commands in this guide | Section 2 | Your private RPC |
| `EXPECTED_CHAIN_ID` | The checks in this guide | `80002` | `137` |
| `EXPECTED_SAFE_HASH` | The checks in this guide | Section 2 | Section 2 |
| `EXPECTED_TEST_SAFE` | The checks in this guide | Section 2 | Section 2 |
| `DEPLOYER_ADDRESS` | The broadcast, as `--sender` | Section 7 | Section 7 |
| `DEPLOYER_ACCOUNT`, `ADMIN_ACCOUNT`, `ORACLE_ACCOUNT`, `OPERATOR_ACCOUNT` | The commands in this guide | Section 7 | Section 7 |

Keep one `.env` per chain, for example `.env.amoy` and `.env.polygon`, and copy the one you need to `.env`.

Load the file into the shell, and export every variable so that `forge` and `cast` both see it:

```bash
set -a; source .env; set +a
```

---

## 7. Create the keystore accounts

Foundry's keystore stores an encrypted private key on your machine, under `~/.foundry/keystores/`, so no command ever carries a raw key. Each role that signs in this guide needs one keystore account:

| Role | `.env` variable | Signs in |
|---|---|---|
| Deployer | `DEPLOYER_ACCOUNT` | Sections 9.5, 10.5, and 15 |
| Admin | `ADMIN_ACCOUNT` | Sections 14.1, 14.2, 14.6, 14.7, and 15 |
| Oracle | `ORACLE_ACCOUNT` | Sections 12.5, 14.5, and 14.8 |
| Operator | `OPERATOR_ACCOUNT` | Section 14.3 |

```bash
cast wallet import deployer-amoy --interactive   # paste the key, then choose a password
cast wallet list
cast wallet address --account deployer-amoy
```

Write each account name in the role's variable, for example `DEPLOYER_ACCOUNT=deployer-amoy`, and write the deployer's printed address in `DEPLOYER_ADDRESS`. Foundry 1.7.1 prints each name in `cast wallet list` with `0x` in front, as in `0xdeployer-amoy (Local)`. The account name has no `0x`. Cast asks for the keystore password on every signed command.

A broadcast passes `--account` and `--sender`. `--account` signs the transactions. `--sender` names the address the simulation uses, and it must equal the account's address. Section 8 checks both.

With a hardware wallet, replace `--account $<ROLE>_ACCOUNT` with `--ledger` or `--trezor`, and keep `--sender $DEPLOYER_ADDRESS` on a broadcast.

---

## 8. Pre-flight checks

Run these checks in the shell where you loaded `.env`, before every deployment. They send no transaction. Define the helper once:

```bash
check() {
  got=$(printf '%s' "$2" | awk '{print $1}' | tr 'A-F' 'a-f')
  want=$(printf '%s' "$3" | awk '{print $1}' | tr 'A-F' 'a-f')
  if [ "$got" = "$want" ]; then echo "OK        $1"; else echo "MISMATCH  $1: chain says $2, expected $3"; fi
}
```

Run the checks:

```bash
check "chain ID" "$(cast chain-id --rpc-url $RPC_URL)" "$EXPECTED_CHAIN_ID"
check "USDC is the exchange collateral" "$(cast call $EXCHANGE_ADDRESS 'getCollateral()(address)' --rpc-url $RPC_URL)" "$USDC_ADDRESS"
check "CTF is the exchange CTF" "$(cast call $EXCHANGE_ADDRESS 'getCtf()(address)' --rpc-url $RPC_URL)" "$CTF_ADDRESS"
check "Safe factory is the exchange Safe factory" "$(cast call $EXCHANGE_ADDRESS 'getSafeFactory()(address)' --rpc-url $RPC_URL)" "$SAFE_FACTORY_ADDRESS"
check "Safe proxy bytecode hash" "$(cast keccak $(cast call $SAFE_FACTORY_ADDRESS 'getContractBytecode()(bytes)' --rpc-url $RPC_URL))" "$EXPECTED_SAFE_HASH"
check "Safe of the test key" "$(cast call $SAFE_FACTORY_ADDRESS 'computeProxyAddress(address)(address)' 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7 --rpc-url $RPC_URL)" "$EXPECTED_TEST_SAFE"
check "USDC has 6 decimals" "$(cast call $USDC_ADDRESS 'decimals()(uint8)' --rpc-url $RPC_URL)" "6"
check "exchange is not paused" "$(cast call $EXCHANGE_ADDRESS 'paused()(bool)' --rpc-url $RPC_URL)" "false"
check "Oracle differs from Operator" "$([ "$ORACLE_ADDRESS" = "$OPERATOR_ADDRESS" ] && echo same || echo different)" "different"
check "exchange lists the Operator (when it submits matches)" "$(cast call $EXCHANGE_ADDRESS 'isOperator(address)(bool)' $OPERATOR_ADDRESS --rpc-url $RPC_URL)" "true"
check "exchange oracle is the Oracle (when it registers tokens)" "$(cast call $EXCHANGE_ADDRESS 'oracle()(address)' --rpc-url $RPC_URL)" "$ORACLE_ADDRESS"
echo "Deployer balance: $(cast balance $DEPLOYER_ADDRESS --ether --rpc-url $RPC_URL) POL"
```

Check that each keystore account signs as its role's address. Cast asks for each keystore password. Skip a role that signs nothing on this chain.

```bash
check "Deployer account" "$(cast wallet address --account $DEPLOYER_ACCOUNT)" "$DEPLOYER_ADDRESS"
check "Admin account" "$(cast wallet address --account $ADMIN_ACCOUNT)" "$ADMIN_ADDRESS"
check "Oracle account" "$(cast wallet address --account $ORACLE_ACCOUNT)" "$ORACLE_ADDRESS"
check "Operator account" "$(cast wallet address --account $OPERATOR_ACCOUNT)" "$OPERATOR_ADDRESS"
```

What a mismatch means:

| Check | A mismatch means | Action |
|---|---|---|
| The first seven checks | A wrong chain, a wrong address, or a retired contract | Stop. Correct `.env` from section 2. Never deploy with a mismatch here. |
| Exchange is not paused | An exchange Admin paused trading | The deployment works, but no vault order fills until the exchange unpauses. |
| Oracle differs from Operator | The same wallet in both variables | Stop. The constructor reverts with `RoleSeparation()`. |
| An account check | The keystore account holds another key, or `.env` names another address | Stop. Correct the account or the address. A deployment with a wrong role address gives that role to a key that your account does not hold. |
| The last two checks | Another wallet submits matches or registers tokens | Not a blocker, if that other wallet holds the exchange role. |

The deployer needs POL for about 8.5 million gas. See the budget in sections 9.2 and 10.2.

---

## 9. Deploy to Polygon Amoy

### 9.1 Configure

Fill `.env` with the Amoy column of section 6 and the Amoy values of section 2, then load it:

```bash
set -a; source .env; set +a
```

### 9.2 Fund the deployer

Get Amoy POL for `DEPLOYER_ADDRESS` from https://faucet.polygon.technology. The dry run of 2026-09-15 estimated 8,443,809 gas, which cost 2.88 POL at 341 gwei. Hold at least twice the estimate that your own dry run prints.

### 9.3 Run the pre-flight checks

Run section 8. Every check in the first group must print `OK`.

### 9.4 Dry run

The dry run executes the script against the live chain state and sends nothing:

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --sender $DEPLOYER_ADDRESS
```

The output ends with the Safe inputs, the two predicted addresses, and a gas estimate:

```
Safe factory: 0x5aa054022E1Fd277246026a05908071C1d6342A1
Safe master copy: 0x6C9385AE09fC4Bc3511c2C651961b016a300B46A
Safe proxy bytecode hash:
0x429fab1122fd10e23ed01de931c34fa9a6c84298f2324ae9f17f770ad9cdf548
LPVault implementation: 0x...
LPVaultFactory: 0x...
...
Estimated total gas used for script: 8443809
SIMULATION COMPLETE.
```

Compare the printed hash with `EXPECTED_SAFE_HASH`. They must be equal. The dry run writes its record under `broadcast/Deploy.s.sol/80002/dry-run/`, which git ignores.

### 9.5 Broadcast

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --account $DEPLOYER_ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

Foundry asks for the keystore password. It sends two transactions, the implementation first and the factory second, and then verifies both contracts on Amoy Polygonscan.

> **Etherscan V2.** Polygonscan uses Etherscan's unified V2 API (`https://api.etherscan.io/v2/api?chainid=<id>`), and one Etherscan key works for every chain. Without `ETHERSCAN_API_KEY`, the broadcast still succeeds and the verification does not run. Section 16 verifies by hand.

### 9.6 Record the addresses

```bash
REC=broadcast/Deploy.s.sol/80002/run-latest.json
jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractName) \(.contractAddress) \(.hash)"' $REC
export IMPL_ADDRESS=$(jq -r '.transactions[] | select(.contractName=="LPVault") | .contractAddress' $REC)
export FACTORY_ADDRESS=$(jq -r '.transactions[] | select(.contractName=="LPVaultFactory") | .contractAddress' $REC)
```

Fill in the deployment record in section 18. Commit `broadcast/Deploy.s.sol/80002/run-latest.json`: git tracks broadcast records (except dry runs and local chain 31337), and the file is the deployment's proof. The same run also writes `cache/Deploy.s.sol/80002/run-latest.json`, which git ignores.

### 9.7 Check the deployment

Run section 11.

### 9.8 Create a test vault and run the smoke test

Run section 12 for a test market, then section 13.

---

## 10. Deploy to Polygon mainnet

The steps match Amoy. The differences: the release conditions in 10.1, a private RPC, `--slow` on the broadcast, and chain ID `137` in every command.

### 10.1 Release conditions

Deploy to mainnet only when every item is true:

- [ ] The commit you deploy is the commit that the auditors reviewed, or its difference was reviewed.
- [ ] The same commit is deployed on Amoy, and the Amoy smoke test in section 13 passed on it.
- [ ] `forge test`, the size check, and `forge fmt --check` pass on that commit (section 5).
- [ ] The Admin, Oracle, and Operator wallets are final, and each wallet's owner confirmed its address.
- [ ] The deployer keystore or hardware wallet sent one low-value mainnet transaction successfully.
- [ ] Every account check in section 8 prints `OK` with the mainnet accounts.
- [ ] `.env` holds the mainnet values of section 2, and `RPC_URL` points to a private RPC.
- [ ] The Prophet server, the keeper, and the Oracle service are ready to receive the new factory address.

### 10.2 Fund the deployer

Send real POL to `DEPLOYER_ADDRESS`. The dry run of 2026-09-15 estimated 8,443,793 gas, which cost 4.76 POL at 564 gwei. Polygon gas prices move quickly, so hold at least twice the estimate that your own dry run prints.

### 10.3 Run the pre-flight checks

```bash
set -a; source .env; set +a
```

Run section 8. Every check in the first group must print `OK`.

### 10.4 Dry run

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --sender $DEPLOYER_ADDRESS
```

The printed values must be:

```
Safe factory: 0xD0d6655B69d5589402593a854836bbe5305ab09B
Safe master copy: 0x0b71A0e839474D7eCF2ED1546fBB1D0603D19760
Safe proxy bytecode hash:
0x4b856c0ca50349cc4a9add5f9bfa9cb369b54f8b87f90023a3fb45b49eadec50
```

### 10.5 Broadcast

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --account $DEPLOYER_ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=137" \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

`--slow` sends the second transaction only after the first one is confirmed. If the run stops after the first transaction, do not start again from zero. Run the same command with `--resume` in place of `--broadcast`, so Foundry finishes the recorded run.

### 10.6 Record the addresses

```bash
REC=broadcast/Deploy.s.sol/137/run-latest.json
jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractName) \(.contractAddress) \(.hash)"' $REC
export IMPL_ADDRESS=$(jq -r '.transactions[] | select(.contractName=="LPVault") | .contractAddress' $REC)
export FACTORY_ADDRESS=$(jq -r '.transactions[] | select(.contractName=="LPVaultFactory") | .contractAddress' $REC)
```

Fill in section 18 and commit `broadcast/Deploy.s.sol/137/run-latest.json`.

### 10.7 Check the deployment

Run section 11. Every check must print `OK`.

### 10.8 Hand over

- Give `FACTORY_ADDRESS` and `IMPL_ADDRESS` to the Prophet server, the keeper, the event listener, and the Oracle service.
- If the Admin must be a Safe multisig, transfer the role now (section 14.6).

---

## 11. Check the deployed factory

Run in the same shell, with `IMPL_ADDRESS` and `FACTORY_ADDRESS` exported and the `check` helper from section 8 defined:

```bash
F=$FACTORY_ADDRESS
check "implementation" "$(cast call $F 'implementation()(address)' --rpc-url $RPC_URL)" "$IMPL_ADDRESS"
check "implementation version" "$(cast call $F 'implementationVersion()(uint256)' --rpc-url $RPC_URL)" "1"
check "no scheduled implementation" "$(cast call $F 'pendingImplementation()(address)' --rpc-url $RPC_URL)" "0x0000000000000000000000000000000000000000"
check "USDC" "$(cast call $F 'usdc()(address)' --rpc-url $RPC_URL)" "$USDC_ADDRESS"
check "exchange" "$(cast call $F 'exchange()(address)' --rpc-url $RPC_URL)" "$EXCHANGE_ADDRESS"
check "CTF" "$(cast call $F 'conditionalTokens()(address)' --rpc-url $RPC_URL)" "$CTF_ADDRESS"
check "Safe factory" "$(cast call $F 'safeFactory()(address)' --rpc-url $RPC_URL)" "$SAFE_FACTORY_ADDRESS"
check "Safe proxy bytecode hash" "$(cast call $F 'safeProxyBytecodeHash()(bytes32)' --rpc-url $RPC_URL)" "$EXPECTED_SAFE_HASH"
check "Admin registered" "$(cast call $F 'admins(address)(uint256)' $ADMIN_ADDRESS --rpc-url $RPC_URL)" "1"
check "one Admin" "$(cast call $F 'adminCount()(uint256)' --rpc-url $RPC_URL)" "1"
check "Oracle" "$(cast call $F 'oracle()(address)' --rpc-url $RPC_URL)" "$ORACLE_ADDRESS"
check "Operator registered" "$(cast call $F 'operators(address)(uint256)' $OPERATOR_ADDRESS --rpc-url $RPC_URL)" "1"
check "Oracle is not an Operator" "$(cast call $F 'operators(address)(uint256)' $ORACLE_ADDRESS --rpc-url $RPC_URL)" "0"
check "default emergency timelock is 7 days" "$(cast call $F 'defaultEmergencyCancelTimelock()(uint32)' --rpc-url $RPC_URL)" "604800"
```

Check that the implementation cannot become a vault. This call must revert:

```bash
cast call $IMPL_ADDRESS \
  "initialize(bytes32,address,address,address,int24,address,uint128,uint256,bytes32,uint256,uint256)" \
  0x0000000000000000000000000000000000000000000000000000000000000001 $USDC_ADDRESS $EXCHANGE_ADDRESS $CTF_ADDRESS \
  10 $FACTORY_ADDRESS 1 1 0x0000000000000000000000000000000000000000000000000000000000000001 1 2 \
  --from $FACTORY_ADDRESS --rpc-url $RPC_URL
```

On the block explorer, both contracts must show "Contract Source Code Verified". If one does not, run section 16.

---

## 12. Create a market vault

The Oracle creates one vault per market. `createVault` checks the outcome token identity against the Conditional Tokens contract before it deploys the clone, because a vault can never correct its identity later.

### 12.1 Prerequisites

- The market's condition is prepared on the Conditional Tokens contract with exactly two outcomes. The Prophet Oracle service does this through the `Resolution` contract when it creates the market.
- The exchange has the market's two tokens registered (section 12.4).
- `ORACLE_ACCOUNT` is the keystore account of the LP vault factory's Oracle, and its account check in section 8 prints `OK`.

### 12.2 Choose the parameters

| Parameter | Meaning | Rule |
|---|---|---|
| `MARKET_ID` | The market's identifier, as `bytes32` | One vault per market ID. A second `createVault` with the same ID reverts with `DuplicateMarket()`. |
| `CONDITION_ID` | The market's condition ID on the Conditional Tokens contract | Must not be zero, and the condition must have two outcomes |
| `TICK_SPACING` | The width of one price level, in ticks. One tick is one basis point of price, and the price scale is 0 to 10,000. | Above zero. Every position range must start and end on a multiple of it. Example: `10` makes levels of 0.001 USDC. |
| `MIN_FIRST_LIQUIDITY` | The smallest liquidity the vault's first position may have. It applies once, to the first mint only. | Above zero |

Liquidity is `usdcAmount × 10^18 ÷ (tickUpper − tickLower)`, where `usdcAmount` is in USDC's 6-decimal units. Example: to require at least 100 USDC over the full range [0, 10000] for the first position, set `MIN_FIRST_LIQUIDITY` to `100,000,000 × 10^18 ÷ 10,000 = 10^22`, which is `10000000000000000000000`.

### 12.3 Compute the outcome token IDs

YES is index set 1 and NO is index set 2, with USDC as collateral and a zero parent collection:

```bash
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
check "condition has two outcomes" "$(cast call $CTF_ADDRESS 'getOutcomeSlotCount(bytes32)(uint256)' $CONDITION_ID --rpc-url $RPC_URL)" "2"
YES_COLLECTION=$(cast call $CTF_ADDRESS 'getCollectionId(bytes32,bytes32,uint256)(bytes32)' $ZERO $CONDITION_ID 1 --rpc-url $RPC_URL)
NO_COLLECTION=$(cast call $CTF_ADDRESS 'getCollectionId(bytes32,bytes32,uint256)(bytes32)' $ZERO $CONDITION_ID 2 --rpc-url $RPC_URL)
export YES_TOKEN_ID=$(cast call $CTF_ADDRESS 'getPositionId(address,bytes32)(uint256)' $USDC_ADDRESS $YES_COLLECTION --rpc-url $RPC_URL | awk '{print $1}')
export NO_TOKEN_ID=$(cast call $CTF_ADDRESS 'getPositionId(address,bytes32)(uint256)' $USDC_ADDRESS $NO_COLLECTION --rpc-url $RPC_URL | awk '{print $1}')
echo "YES $YES_TOKEN_ID"; echo "NO  $NO_TOKEN_ID"
```

### 12.4 Confirm the exchange registration

```bash
check "exchange knows the NO token as YES's complement" "$(cast call $EXCHANGE_ADDRESS 'getComplement(uint256)(uint256)' $YES_TOKEN_ID --rpc-url $RPC_URL)" "$NO_TOKEN_ID"
check "exchange maps YES to the condition" "$(cast call $EXCHANGE_ADDRESS 'getConditionId(uint256)(bytes32)' $YES_TOKEN_ID --rpc-url $RPC_URL)" "$CONDITION_ID"
```

If either check fails, the tokens are not registered. The exchange's Admin or oracle registers them with `registerToken(YES_TOKEN_ID, NO_TOKEN_ID, CONDITION_ID, QUESTION_ID)`, where `QUESTION_ID` is the question the condition was prepared for. The Prophet Oracle service normally does this at market creation. A vault can exist before the registration, but no order fills until the registration exists.

### 12.5 Create the vault

```bash
cast send $FACTORY_ADDRESS \
  "createVault(bytes32,int24,uint128,bytes32,uint256,uint256)" \
  $MARKET_ID $TICK_SPACING $MIN_FIRST_LIQUIDITY $CONDITION_ID $YES_TOKEN_ID $NO_TOKEN_ID \
  --rpc-url $RPC_URL \
  --account $ORACLE_ACCOUNT

export VAULT=$(cast call $FACTORY_ADDRESS 'vaultForMarket(bytes32)(address)' $MARKET_ID --rpc-url $RPC_URL)
echo "Vault: $VAULT"
```

### 12.6 Check the vault

```bash
MAX_UINT=115792089237316195423570985008687907853269984665640564039457584007913129639935
check "phase is Active (1)" "$(cast call $VAULT 'phase()(uint8)' --rpc-url $RPC_URL)" "1"
check "factory" "$(cast call $VAULT 'factory()(address)' --rpc-url $RPC_URL)" "$FACTORY_ADDRESS"
check "market ID" "$(cast call $VAULT 'marketId()(bytes32)' --rpc-url $RPC_URL)" "$MARKET_ID"
check "USDC" "$(cast call $VAULT 'usdc()(address)' --rpc-url $RPC_URL)" "$USDC_ADDRESS"
check "exchange" "$(cast call $VAULT 'exchange()(address)' --rpc-url $RPC_URL)" "$EXCHANGE_ADDRESS"
check "CTF" "$(cast call $VAULT 'conditionalTokens()(address)' --rpc-url $RPC_URL)" "$CTF_ADDRESS"
check "condition" "$(cast call $VAULT 'conditionId()(bytes32)' --rpc-url $RPC_URL)" "$CONDITION_ID"
check "YES token" "$(cast call $VAULT 'yesTokenId()(uint256)' --rpc-url $RPC_URL)" "$YES_TOKEN_ID"
check "NO token" "$(cast call $VAULT 'noTokenId()(uint256)' --rpc-url $RPC_URL)" "$NO_TOKEN_ID"
check "tick spacing" "$(cast call $VAULT 'tickSpacing()(int24)' --rpc-url $RPC_URL)" "$TICK_SPACING"
check "emergency timelock" "$(cast call $VAULT 'emergencyCancelTimelock()(uint32)' --rpc-url $RPC_URL)" "$(cast call $FACTORY_ADDRESS 'defaultEmergencyCancelTimelock()(uint32)' --rpc-url $RPC_URL)"
check "USDC allowance to the exchange" "$(cast call $USDC_ADDRESS 'allowance(address,address)(uint256)' $VAULT $EXCHANGE_ADDRESS --rpc-url $RPC_URL)" "$MAX_UINT"
check "outcome token approval to the exchange" "$(cast call $CTF_ADDRESS 'isApprovedForAll(address,address)(bool)' $VAULT $EXCHANGE_ADDRESS --rpc-url $RPC_URL)" "true"
check "ERC-1155 receiver interface" "$(cast call $VAULT 'supportsInterface(bytes4)(bool)' 0x4e2312e0 --rpc-url $RPC_URL)" "true"
check "EIP-1271 interface" "$(cast call $VAULT 'supportsInterface(bytes4)(bool)' 0x1626ba7e --rpc-url $RPC_URL)" "true"
```

A vault is an EIP-1167 clone, so it has no source code of its own to verify. The explorer shows it as a minimal proxy of the implementation. If it does not, open the vault on the explorer and use "More", then "Is this a proxy?".

### 12.7 Before the first deposit

- The keeper reports the market price with `updateTick` before the first mint, because a position records the vault's current tick as its mint tick.
- The Prophet app relays `USDC.approve(<vault>, <amount>)` from the LP's Safe before the deposit. Prophet adds that call and `USDC.approve(<vault>, 0)` to the relay allow list, so an LP can also revoke.
- The self-service exits `reclaimDeposit(bytes32)` and `burnPosition(uint256)` are Safe transactions that the owner key signs. Prophet adds them to the relay allow list, or the LP submits them through another relayer or the Safe app when the Operator does not cooperate.
- The keeper builds vault orders with `signer = maker = vault` and `signatureType = POLY_1271`, and signs them with a key the factory lists as an Operator. The vault answers the exchange only while the vault is Active and not paused.

---

## 13. Smoke test on Amoy

Run one full market through the new Amoy factory before any mainnet deployment. An LP signature needs a Safe owner key, so run the LP steps through the Prophet app on Amoy. Fund a test Safe with test USDC through the token's public `faucet(address,uint256)`.

| # | Actor | Action | What to check |
|---|---|---|---|
| 1 | Oracle | `createVault` (section 12) | `VaultCreated`, and every check in 12.6 prints `OK` |
| 2 | Keeper | `updateTick(<current price tick>)` | `TickUpdated`, and `currentTick()` equals the price |
| 3 | LP and server | Safe approval, then `depositForIntent` | `DepositEscrowed`, and `totalEscrowed()` rises by the amount |
| 4 | Server | `mintPositionFor` with the same six fields | `PositionMinted` with the mint tick, and `totalEscrowed()` falls by the amount |
| 5 | LP and server | A second deposit, then `reclaimDeposit` from the Safe | `DepositReclaimed`, and the Safe receives the amount |
| 6 | Keeper and exchange | A vault buy order fills against a taker | The exchange's `OrderFilled` names the vault as maker, and the vault holds outcome tokens |
| 7 | Keeper | `updateTick` to the new price | `TickUpdated`, and `totalYesOwed()` or `totalNoOwed()` changes |
| 8 | Keeper | A fill back to the start, then `mergeCompleteSets()` | `CompleteSetsMerged`, and `SpreadCredited` when the round trip left spread |
| 9 | Keeper | `heartbeat()` | `lastOperatorActivityTimestamp()` updates |
| 10 | Admin | `pauseTrading()`, then `unpauseTrading()` on the vault | `TradingPaused` and `TradingUnpaused`. While paused, a vault order fails at the exchange, and the LP's burn still works. |
| 11 | LP | `burnPosition` from the Safe on a second position | `PositionBurned` with owed and paid amounts, and the Safe receives USDC and any token leg |
| 12 | Oracle | `startWindDown()` | `VaultWindDownStarted`, and `phase()` is 2 |
| 13 | Oracle service | Resolve the market through `Resolution`, then `redeemOutcomeTokens()` | `OutcomeTokensRedeemed`, and `payoutNumerators()` is not `(0, 0)` |
| 14 | LP | Burn the last position | `PositionBurned` and `ResidueSwept`, and the vault's USDC balance equals `totalEscrowed()` |

---

## 14. Operations

Every command signs with the keystore account of the role that the function requires (section 7).

### 14.1 Operators and the Oracle

```bash
cast send $FACTORY_ADDRESS "addOperator(address)" <operator> --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
cast send $FACTORY_ADDRESS "removeOperator(address)" <operator> --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
cast send $FACTORY_ADDRESS "setOracle(address)" <oracle> --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
```

- Vaults read the roles from the factory at call time, so a change applies to every vault in the same block.
- Removing an Operator also makes every unfilled vault order that key signed fail at the exchange.
- `addOperator` reverts with `RoleSeparation()` for the current Oracle, and `setOracle` reverts for a current Operator.
- `setOracle` emits no event. Read `oracle()` to confirm the change.

### 14.2 Pause and unpause a vault

```bash
cast send $VAULT "pauseTrading()" --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
cast send $VAULT "unpauseTrading()" --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
```

A pause stops `depositForIntent`, `mintPositionFor`, `updateTick`, and `mergePositions`, and the vault approves no order. Every LP exit keeps working. The keeper cancels its resting orders when it sees `TradingPaused`.

### 14.3 The Operator heartbeat

The emergency freeze becomes callable by any address after the Operator is silent for the vault's `emergencyCancelTimelock()` (7 days by default). Every Operator call refreshes the timer. While a vault is paused or wound down, `updateTick` reverts, so the keeper calls `heartbeat()` instead:

```bash
cast send $VAULT "heartbeat()" --rpc-url $RPC_URL --account $OPERATOR_ACCOUNT
```

### 14.4 The emergency freeze

After the timelock, any address can call `emergencyCancelAll()`. It sets the phase to Cancelled (3) and moves no funds. Every LP exit keeps working after it, and the vault approves no new order. The freeze is final. The keeper cancels its resting orders when it sees `EmergencyCancelExecuted`.

### 14.5 End of a market

1. The Oracle calls `startWindDown()` when the market closes. New deposits, mints, and tick reports stop, and exits continue.
2. After `Resolution` reports the result to the Conditional Tokens contract, the Oracle calls `redeemOutcomeTokens()`. It reverts while the vault is Active or before the result exists.
3. If outcome tokens reach the vault later, the Oracle calls `redeemOutcomeTokens()` again.

```bash
cast send $VAULT "startWindDown()" --rpc-url $RPC_URL --account $ORACLE_ACCOUNT
cast send $VAULT "redeemOutcomeTokens()" --rpc-url $RPC_URL --account $ORACLE_ACCOUNT
```

### 14.6 Admin changes

Transfer the Admin role, for example to a Safe multisig:

```bash
cast send $FACTORY_ADDRESS "transferAdmin(address)" <new admin> --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
# the new admin calls acceptAdmin(), from the Safe app when the new admin is a Safe
cast send $FACTORY_ADDRESS "renounceAdminRole()" --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
```

A transfer adds the new Admin and keeps the old one. The old Admin must call `renounceAdminRole()`, or another Admin must call `removeAdmin(<old admin>)`. Until then the old key keeps full Admin rights on the factory and on every vault. Neither function can remove the last Admin. `addAdmin(address)` grants the role in one step.

### 14.7 Default emergency timelock

```bash
cast send $FACTORY_ADDRESS "setDefaultEmergencyCancelTimelock(uint32)" <seconds> --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
```

The value must be above 0 and at most 2,592,000 (30 days). It applies only to vaults created after the change. Each existing vault keeps the value it copied at creation, and nothing can change that value.

### 14.8 Minimum first liquidity

```bash
cast send $VAULT "setMinimumFirstLiquidity(uint128)" <liquidity> --rpc-url $RPC_URL --account $ORACLE_ACCOUNT
```

The value matters only before the vault's first mint.

---

## 15. Upgrade the implementation for new vaults

A deployed vault never changes its code. The factory's implementation pointer changes after a 7-day timelock, and only vaults created after the change use the new code.

Rules for a new implementation:

- Its `initialize` must keep the same eleven parameters in the same order, because the factory calls it: `(bytes32 marketId, address usdc, address exchange, address conditionalTokens, int24 tickSpacing, address factory, uint128 minimumFirstLiquidity, uint256 version, bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId)`.
- Its constructor must disable `initialize`.
- It must pass sections 5 and 13 on Amoy, and its difference must be reviewed before mainnet.

Steps:

```bash
# 1. Deploy and verify the new implementation
forge create src/LPVault.sol:LPVault \
  --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast \
  --verify --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$EXPECTED_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY
export NEW_IMPL=<the "Deployed to" address>

# 2. Schedule it
cast send $FACTORY_ADDRESS "scheduleImplementation(address)" $NEW_IMPL --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
cast call $FACTORY_ADDRESS "implementationUnlockAt()(uint256)" --rpc-url $RPC_URL

# 3. After the unlock time, apply it
cast send $FACTORY_ADDRESS "applyImplementation()" --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
check "implementation" "$(cast call $FACTORY_ADDRESS 'implementation()(address)' --rpc-url $RPC_URL)" "$NEW_IMPL"
cast call $FACTORY_ADDRESS "implementationVersion()(uint256)" --rpc-url $RPC_URL
```

To stop a scheduled upgrade before it applies:

```bash
cast send $FACTORY_ADDRESS "cancelScheduledImplementation()" --rpc-url $RPC_URL --account $ADMIN_ACCOUNT
```

Only one schedule can be pending. A second `scheduleImplementation` reverts with `ScheduleAlreadyPending()`.

---

## 16. Verify on the explorer by hand

Use this section when `--verify` did not run. Run it at the deployed commit, with an unchanged `foundry.toml`.

```bash
# The factory
forge verify-contract $FACTORY_ADDRESS src/LPVaultFactory.sol:LPVaultFactory \
  --chain $EXPECTED_CHAIN_ID \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$EXPECTED_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address,address,bytes32)" \
    $IMPL_ADDRESS $USDC_ADDRESS $EXCHANGE_ADDRESS $CTF_ADDRESS $ADMIN_ADDRESS $ORACLE_ADDRESS $OPERATOR_ADDRESS \
    $SAFE_FACTORY_ADDRESS $EXPECTED_SAFE_HASH) \
  --watch

# The implementation (no constructor arguments)
forge verify-contract $IMPL_ADDRESS src/LPVault.sol:LPVault \
  --chain $EXPECTED_CHAIN_ID \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$EXPECTED_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

The constructor arguments must be the values the factory holds. Section 11 confirms them.

---

## 17. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `MISMATCH  USDC is the exchange collateral` | A wrong USDC, often the bridged USDC.e on mainnet | Use the exchange's `getCollateral()`: native USDC on mainnet, the test USDC on Amoy |
| `MISMATCH  Safe factory is the exchange Safe factory` | The retired Amoy Safe factory, or a wrong chain | Use the Safe factory of section 2 |
| `MISMATCH  Safe proxy bytecode hash` | The Safe factory address is wrong for the chain | Stop. Never deploy with a wrong hash. |
| `401 API key disabled` from `polygon-rpc.com` | The public endpoint no longer serves requests | Use a private RPC, or the publicnode endpoint for reads |
| `ZeroAddress("X")` from the script | Variable `X` is unset or zero | Load `.env` with `set -a; source .env; set +a`, then check `X` |
| `ZeroBytecodeHash()`, or a revert that reads the Safe factory | The Safe factory has no code on this chain | Check `SAFE_FACTORY_ADDRESS` and `RPC_URL` |
| `RoleSeparation()` at deployment | `ORACLE_ADDRESS` equals `OPERATOR_ADDRESS` | Use two wallets |
| The verification does not run | `ETHERSCAN_API_KEY` is unset or empty | Set it and run section 16 |
| Verification fails with a bytecode mismatch | The source or `foundry.toml` differs from the deployed build | Check out the deployed commit, run `forge build`, and verify again |
| `--account` not found | The keystore account does not exist, or its name carries the `0x` that `cast wallet list` prints | `cast wallet import <name> --interactive`, and write the name without `0x` |
| `MISMATCH  <role> account` | The keystore account holds a key for another address | Correct the role's account or its address in `.env` before any transaction |
| `insufficient funds` | The deployer has too little POL | Fund it (sections 9.2 and 10.2) |
| `transaction underpriced`, or a transaction stays pending | The gas price moved | Add `--with-gas-price <wei>` and `--priority-gas-price <wei>`, then run again with `--resume` |
| `nonce too low` after a stopped run | Foundry sent part of the run | Run the same command with `--resume` in place of `--broadcast` |
| `NotOracle()` on `createVault` | The sender is not the factory's Oracle | Sign with `--account $ORACLE_ACCOUNT`, and check that the Oracle account check in section 8 prints `OK` |
| `DuplicateMarket()` on `createVault` | A vault exists for this market ID | Read `vaultForMarket(<market ID>)` on the factory |
| `ZeroFloor()` on `createVault` | `MIN_FIRST_LIQUIDITY` is zero | Pass a value above zero (section 12.2) |
| `InvalidTickSpacing()` on `createVault` | `TICK_SPACING` is zero or negative | Pass a positive spacing |
| `ZeroConditionId()` on `createVault` | `CONDITION_ID` is zero | Pass the market's condition ID |
| `ZeroTokenId()` on `createVault` | A token ID is zero | Compute both IDs (section 12.3) |
| `DuplicateTokenId()` on `createVault` | YES and NO are the same ID | Pass index set 1 as YES and index set 2 as NO |
| `NotBinaryCondition()` on `createVault` | The condition is not prepared, or it has more than two outcomes | `getOutcomeSlotCount(<condition>)` must return `2` |
| `TokenIdMismatch()` on `createVault` | The IDs belong to another condition, YES and NO are swapped, or `USDC_ADDRESS` is not the exchange collateral | Compute the IDs again from the vault factory's `usdc()` (section 12.3) |
| `NotAdmin()` | The sender is not a factory Admin | Sign with `--account $ADMIN_ACCOUNT`, and check that the Admin account check in section 8 prints `OK` |
| `ZeroTimelock()` or `TimelockTooLong()` | The default timelock is 0 or above 30 days | Pass a value in (0, 2592000] |
| `TimelockNotElapsed()` on `applyImplementation` | Seven days have not passed since the schedule | Wait until `implementationUnlockAt()` |
| `ScheduleAlreadyPending()` | Another upgrade is scheduled | Apply it, or `cancelScheduledImplementation()` first |
| A vault order fails with `InvalidSignature()` at the exchange | The vault is paused, wound down, or frozen, or the signer is not a factory Operator | Check `phase()`, `paused()`, and `operators(<signer>)` |
| `MarketNotResolved()` on `redeemOutcomeTokens` | The result is not on the Conditional Tokens contract yet | Wait for `Resolution` to report it |
| `VaultStillActive()` on `redeemOutcomeTokens` | The vault is still Active | Call `startWindDown()` first |

---

## 18. Deployment record

Copy this table into the pull request or the release notes for every deployment.

| Field | Value |
|---|---|
| Date | |
| Chain (ID) | |
| Repository commit | |
| Deployer | |
| `LPVault` implementation | |
| `LPVaultFactory` | |
| Implementation transaction | |
| Factory transaction | |
| Safe factory | |
| Safe proxy bytecode hash | |
| Admin | |
| Oracle | |
| Operator | |
| Keystore account or hardware wallet of each role | |
| Explorer verification (both contracts) | |
| Section 11 checks all `OK` | |
| Broadcast record committed | |
