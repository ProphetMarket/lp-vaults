# LP Vaults

On-chain Solidity contracts for Prophet's LP provisioning engine — per-market Uniswap v3-style vaults that let external LPs pool USDC into specific prediction markets, choose their own price range, and earn trading fees proportional to their in-range liquidity.

## Overview

Prophet runs a CLOB prediction market built on top of the Polymarket CTF Exchange. This repository implements the on-chain layer for external liquidity provisioning:

- **`LPVaultFactory`** — deploys per-market `LPVault` clones (EIP-1167 minimal proxies) and manages the factory-level role registry (Admin, Operator, Oracle).
- **`LPVault`** — per-market vault holding USDC and ERC-1155 outcome tokens. Manages concentrated-liquidity positions, per-tick fee accumulators (`feeGrowthOutsideX128`), a global accumulator (`feeGrowthGlobalX128`), and Q128 fixed-point fee math.

The contracts are the on-chain foundation only. The off-chain keeper, event listener, and server integrations live in separate repositories.

## Features

| Feature | Status | Summary |
|---------|--------|---------|
| Deploy LP Vault for a Market | implemented | Factory + role registry + per-market clone deploy |
| Deploy Contracts | implemented | Foundry deploy script with env-var-driven configuration |
| Vault Wind-Down Lifecycle | implemented | Oracle-driven Active → WindDown transition |
| Emergency Cancel All Positions | implemented | Position-holder force-close after operator-silence timelock |
| Pause Trading | implemented | Admin-callable circuit breaker on trading entry points |
| Upgradeable Vault Implementation Pointer | implemented | Admin two-step 7-day timelocked upgrade of the factory's implementation pointer |
| Mint LP Position | implemented | Operator-gated EIP-712 signed intent flow |
| Collect Fees on a Position | implemented | LP fee withdrawal via v3 feeGrowthInside snapshot |
| Merge Positions | implemented | Operator housekeeping to combine same-range same-owner positions |
| Notify and Distribute Fees | implemented | Operator-driven Q128 accumulator update |
| Update Tick and Cross Ticks | implemented | Operator tick sync with per-tick accumulator flip |
| LP Escape Hatch | pending | LP-initiated USDC recovery for unfulfilled mint intents |

Full specs are under `specs/features/`. Feature index: [specs/FEATURES.md](specs/FEATURES.md).

## Roles

| Role | Authority | Notes |
|------|-----------|-------|
| **Admin** | Registry-only: add/remove operators, set oracle, pause trading, schedule/apply/cancel implementation upgrades, two-step admin transfer | Cannot call user-facing vault functions |
| **Operator** | Transactional: `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions` | Multiple addresses allowed; must be separate from Oracle |
| **Oracle** | Lifecycle: `createVault` (factory), `startWindDown` (vault) | Single wallet; must be separate from Operator |
| **LP** | Any wallet: `mintPosition`, `collect`, `burnPosition`, `reclaimDeposit` on their own positions | |
| **Keeper** | Off-chain bot holding an Operator key — no on-chain role | Not a contract concept |

See `specs/ACTORS.md` for full role details and `CLAUDE.md` for the security checklist enforced on every PR.

## Architecture

- **EIP-1167 minimal-proxy clones.** Each market gets a fresh vault clone from the factory. Per-vault config lives in storage (not `immutable`) since clones share the implementation's bytecode.
- **Factory-delegated authorization.** Vault modifiers (`onlyAdmin`, `onlyOperator`, `onlyOracle`) read role state from the factory at call time. Role rotation on the factory propagates immediately to all deployed vaults.
- **Uniswap v3 fee math.** Q128 global and per-tick accumulators; positions snapshot `feeGrowthInsideLastX128` at mint to prevent retroactive fee claims.
- **Two-step timelocked upgrades.** Factory's implementation pointer can be swapped after a 7-day delay. Existing clones stay pinned to their original bytecode by EIP-1167 construction; new clones use the current pointer.
- **Inlined patterns.** Reentrancy guard, safe transfers, mulDiv, safe casts, EIP-712 domain separator, and EIP-1167 clone deployment are all inlined per the pattern policy in `CLAUDE.md` — no library imports beyond OpenZeppelin interfaces.

Per-feature architecture diagrams (C4 L1/L2, data model, event topology, code map) live under `specs/features/*/ARCHITECTURE.md`.

## Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full step-by-step guide covering:

- Foundry installation and dependency setup
- Building the sources
- Environment variables (with the mandatory `ETHERSCAN_API_KEY` for contract verification)
- Setting up a Foundry keystore account (`cast wallet import --account`, not `--sender`)
- Deploying to Polygon Amoy testnet
- Deploying to Polygon mainnet
- Manual verification and post-deployment steps
- Troubleshooting

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Solidity 0.8.20 (pinned)

### Setup

```bash
git clone <repo-url>
cd lp-vaults
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test               # unit + fuzz + invariant tests
forge test -vvv          # with call traces
forge coverage           # coverage report
```

The test suite includes 300+ integration tests scoped to `test/features/FEAT-*/UC-*/*.t.sol`, plus fuzz tests on Q128 math and invariant tests on tick state.

### Format

```bash
forge fmt
```

## Project Structure

```
lp-vaults/
├── src/                    # Solidity sources
│   ├── LPVault.sol         # Per-market vault (EIP-1167 clone target)
│   └── LPVaultFactory.sol  # Factory + role registry + implementation upgrade
├── script/
│   └── Deploy.s.sol        # Foundry deploy script (address-env-var driven)
├── test/
│   └── features/           # Integration tests, mirroring specs/features/ layout
├── specs/                  # Molcajete spec tree (features, use cases, architecture, actors)
├── lib/                    # Foundry submodule dependencies (forge-std, ctf-exchange)
├── CLAUDE.md               # Repository rules — PR-blocking (security, patterns, roles)
├── DEPLOYMENT.md           # Deployment guide for Polygon Amoy and mainnet
├── FLOWS.md                # Sequence diagrams for lifecycle, transactional, emergency, admin flows
├── REFERENCE.md            # Per-function reference (signature, params, events, reverts)
└── README.md               # This file
```

## References

- [CLAUDE.md](CLAUDE.md) — repository rules, pattern policy, security checklist, and role authority matrix (auto-loaded by Claude Code).
- [DEPLOYMENT.md](DEPLOYMENT.md) — end-to-end deployment guide for Polygon Amoy and mainnet.
- [FLOWS.md](FLOWS.md) — sequence diagrams for the main contract flows, grouped by lifecycle, transactional, emergency, and admin operations.
- [REFERENCE.md](REFERENCE.md) — per-function reference with signature, actor, parameters, events, and revert conditions.
- [specs/](specs/) — full spec tree (PROJECT, MODULES, DOMAINS, ACTORS, FEATURES, TECH-STACK, GLOSSARY, and per-feature REQUIREMENTS / ARCHITECTURE / USE-CASES).
- [Foundry Book](https://book.getfoundry.sh/) — Foundry documentation.
