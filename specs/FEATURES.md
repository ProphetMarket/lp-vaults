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
| FEAT-REPZ | Deploy LP Vault for a Market | Factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones with ghost position anti-griefing | pending |

## @positions

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-T7AF | Mint LP Position | Operator-gated concentrated-liquidity position creation with EIP-712 signed intents, v3-style tick initialization, and fee-snapshot anchoring | implemented |

## @fees

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TOGR | Notify and Distribute Fees | Operator-driven Q128 fee accumulator update that distributes trading fee revenue proportionally across in-range LP positions | implemented |

## @ticks

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TVS0 | Update Tick and Cross Ticks | Operator-driven tick synchronization that crosses initialized ticks, flips per-tick fee accumulators, and adjusts active liquidity for correct fee distribution | implemented |
