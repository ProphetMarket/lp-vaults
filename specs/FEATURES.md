# Feature Inventory

> The permanent catalog of all product features.
> Features are never removed -- they accumulate use cases over their lifetime.

## Status Key

- `pending` -- Spec written, not yet implemented
- `implemented` -- Code exists that fulfills this spec
- `dirty` -- Spec changed after implementation; code needs to catch up
- `deprecated` -- No longer active; retained for audit trail

## @vault

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-REPZ | Deploy LP Vault for a Market | Factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones with factory-delegated authorization | implemented |
| FEAT-J92H | Deploy Contracts | Foundry deploy script that deploys LPVault implementation and LPVaultFactory with env-var-driven configuration for Polygon Amoy and mainnet | implemented |
| FEAT-JGE7 | Vault Wind-Down Lifecycle | Oracle-driven phase transition from Active to WindDown that gates off new mints while keeping exit paths open for existing LPs | implemented |
| FEAT-JXQO | Emergency Cancel All Positions | Position-holder-triggered force-close of all positions after operator-silence timelock, distributing principal + fees and entering terminal Cancelled state | implemented |

## @positions

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-T7AF | Mint LP Position | Operator-gated concentrated-liquidity position creation with EIP-712 signed intents, v3-style tick initialization, and fee-snapshot anchoring | implemented |
| FEAT-U079 | Collect Fees on a Position | LP withdraws accumulated trading fees from a position using the v3 feeGrowthInside accumulator with snapshot-based double-counting prevention | implemented |
| FEAT-JAIJ | LP Escape Hatch | LP-initiated USDC recovery when the Operator fails to fulfill a signed mint intent within RECLAIM_TIMELOCK | pending |

## @fees

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TOGR | Notify and Distribute Fees | Operator-driven Q128 fee accumulator update that distributes trading fee revenue proportionally across in-range LP positions | implemented |

## @ticks

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TVS0 | Update Tick and Cross Ticks | Operator-driven tick synchronization that crosses initialized ticks, flips per-tick fee accumulators, and adjusts active liquidity for correct fee distribution | implemented |
