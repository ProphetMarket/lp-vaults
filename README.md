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
| Emergency Cancel All Positions | implemented | Any-address freeze after the vault's operator-silence timelock; every exit stays open |
| Pause Trading | implemented | Admin-callable circuit breaker on trading entry points |
| Upgradeable Vault Implementation Pointer | implemented | Admin two-step 7-day timelocked upgrade of the factory's implementation pointer |
| Escrow Deposit for Mint Intent | implemented | Operator escrows an LP's USDC from the LP's Safe against a signed mint intent |
| Mint LP Position | implemented | Operator-gated mint that consumes a per-intent escrow |
| Collect Fees on a Position | implemented | LP fee withdrawal via v3 feeGrowthInside snapshot, by the Safe or relayed, merging the vault's free pairs first and paying its share at the ledger's USDC ratio |
| Burn LP Position | implemented | LP exit by the Safe or relayed: the claim from the mint tick (decision C26), USDC plus one outcome token, each at the ledger's ratio per asset |
| Vault Solvency Ledger | implemented | Running totals of what the vault owes per asset, moved on every booking and every tick segment, and the per-asset ratio every payout applies (decision O2) |
| Complete-Set Merge and Resolution Redemption | implemented | Any wallet merges the vault's free YES and NO pairs (the pairs above what the ledger owes in both tokens) into USDC, in every phase, and the Oracle's redemption after resolution switches every later payout to USDC |
| Merge Positions | implemented | Operator housekeeping to combine same-range same-owner positions |
| Notify and Distribute Fees | implemented | Operator-driven Q128 accumulator update |
| Update Tick and Cross Ticks | implemented | Operator tick sync with per-tick accumulator flip |
| LP Escape Hatch | implemented | One-call reclaim of an escrow the Operator did not mint, by the Safe or relayed |

Full specs are under `specs/features/`. Feature index: [specs/FEATURES.md](specs/FEATURES.md).

## Roles

| Role | Authority | Notes |
|------|-----------|-------|
| **Admin** | Registry-only: `addOperator`, `removeOperator`, `setOracle`, `pauseTrading`, `unpauseTrading`, `scheduleImplementation`, `applyImplementation`, `cancelScheduledImplementation`, `transferAdmin`, `acceptAdmin`, `addAdmin`, `removeAdmin`, `renounceAdminRole`, `setDefaultEmergencyCancelTimelock` | Cannot call user-facing vault functions |
| **Operator** | Transactional: `depositForIntent`, `mintPositionFor`, `reclaimDepositFor`, `burnPositionFor`, `collectFor`, `notifyFees`, `updateTick`, `mergePositions`, `heartbeat` | Multiple addresses allowed; must be separate from Oracle |
| **Oracle** | Lifecycle: `createVault` (factory), `startWindDown`, `redeemOutcomeTokens`, and `setMinimumFirstLiquidity` (vault) | Single wallet; must be separate from Operator |
| **LP** | A Safe wallet; the owner key signs `MintIntent`, `ReclaimIntent`, `BurnIntent`, and `CollectIntent`, and the Safe calls `reclaimDeposit`, `collect`, `burnPosition` on its own escrows and positions, in every phase | The vault accepts an owner key only when the Safe it derives equals the named Safe |
| **Keeper** | Off-chain bot holding an Operator key — no on-chain role | Not a contract concept; merges the vault's free pairs through `mergeCompleteSets`, which any wallet may call |

See `specs/ACTORS.md` for full role details and `CLAUDE.md` for the security checklist enforced on every PR.

## Architecture

- **EIP-1167 minimal-proxy clones.** Each market gets a fresh vault clone from the factory. Per-vault config lives in storage (not `immutable`) since clones share the implementation's bytecode.
- **Factory-delegated authorization.** Vault modifiers (`onlyAdmin`, `onlyOperator`, `onlyOracle`) read role state from the factory at call time. Role rotation on the factory propagates immediately to all deployed vaults.
- **Uniswap v3 fee math.** Q128 global and per-tick accumulators; positions snapshot `feeGrowthInsideLastX128` at mint to prevent retroactive fee claims.
- **The claim model (decision C26).** One tick is one basis point and every range lies inside [0, 10000]. Liquidity is the token count on every tick of a range, each tick funded with 1 USDC per token. A level below the mint tick buys YES when the price falls through it, a level at or above it buys NO when the price rises through it, and a round trip leaves a pair that merges back into 1 USDC. A burn values the claim in closed form from the liquidity, the range, the mint tick, and the current tick, merges the vault's free pairs first (the pairs above what the ledger owes in both tokens, read before the burn's own claim is debited; R14), and pays each asset's owed amount times the smaller of 1 and what the vault holds over what it owes, from the solvency ledger's running totals (decision O2, pro-rata); every payout debits the full owed amount, so a shortfall is a cut every claimant takes alike.
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

The test suite includes 800+ integration tests, one file per use case at `test/features/FEAT-*/UC-*.t.sol`, plus fuzz tests on Q128 math and invariant tests on tick state, the solvency ledger, the escrow, and fee accounting under `test/invariants/`.

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
│   ├── features/           # Integration tests, mirroring specs/features/ layout
│   ├── invariants/         # Invariant suites (tick state, solvency ledger, escrow, fee accounting)
│   ├── fixtures/           # Shared fixtures: the real ConditionalTokens and exchange deployers, the ERC-20 mock, storage helpers, the keeper fill simulator
│   └── artifacts/          # Vendored build artifacts this repo cannot compile (ProphetCTFExchange.json)
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
