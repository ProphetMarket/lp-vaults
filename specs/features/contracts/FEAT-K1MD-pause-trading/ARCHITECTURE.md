---
id: FEAT-K1MD
name: Pause Trading
use_cases: [UC-K1MK]
scenarios: [SC-K1ML, SC-K1MM, SC-K1MN, SC-K1MO, SC-K1MP]
last_update: 2026-07-02
---

# Architecture: Pause Trading

## System Context (C4 L1)

```mermaid
C4Context
    title Pause Trading -- System Context
    Person(admin, "Admin", "Pauses/unpauses vault trading")
    Person(operator, "Operator", "Trading functions gated while paused")
    Person(lp, "LP", "Exit paths remain live while paused")
    System(vault, "LPVault (clone)", "Per-market vault with pause toggle")
    System(factory, "LPVaultFactory", "Admin registry for auth delegation")
    Rel(admin, vault, "pauseTrading/unpauseTrading", "contract call")
    Rel(vault, factory, "onlyAdmin check", "cross-contract call")
```

## Container View (C4 L2)

```mermaid
C4Container
    title Pause Trading -- Container View
    Person(admin, "Admin")
    Container(vault, "LPVault (clone)", "Solidity", "Pause flag + gated entry points")
    Container(factory, "LPVaultFactory", "Solidity", "Admin registry")
    Rel(admin, vault, "pauseTrading()/unpauseTrading()", "tx")
    Rel(vault, factory, "admins()", "STATICCALL for auth check")
```

## Data Model

```mermaid
erDiagram
    LPVAULT {
        bool paused "false by default; toggled by Admin"
    }
```

**Invariants:**
- `paused` does not affect the vault's phase (Active/WindDown/Cancelled)
- While `paused == true`: `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions` revert
- While `paused == true`: `collect`, `reclaimDeposit`, `emergencyCancelAll` succeed
- `paused` is toggled only by Admin addresses

## Component Inventory

| File | Role | Key Exports |
|------|------|-------------|
| `src/LPVault.sol` | Vault with pause toggle | `pauseTrading()`, `unpauseTrading()`, `paused` flag, `TradingPaused`/`TradingUnpaused` events; `whenNotPaused` modifier on gated functions |
| `src/LPVaultFactory.sol` | Admin registry | `admins()` (read by vault's `onlyAdmin`) |

## Event Topology

| Event | Publisher | Payload | Condition | Consumers |
|-------|-----------|---------|-----------|-----------|
| `TradingPaused(address indexed caller)` | LPVault | `caller` | On successful `pauseTrading()` | Off-chain monitoring |
| `TradingUnpaused(address indexed caller)` | LPVault | `caller` | On successful `unpauseTrading()` | Off-chain monitoring |

**Non-events (explicit):**
- Failed pause/unpause (non-admin): no events emitted
- Gated function reverts while paused: no events emitted

## API Surface

| Method | Path | Handler | Auth | Request Shape | Response Shape | Error Codes |
|--------|------|---------|------|---------------|----------------|-------------|
| call | `LPVault.pauseTrading()` | `pauseTrading` | onlyAdmin | none | void | NotAdmin |
| call | `LPVault.unpauseTrading()` | `unpauseTrading` | onlyAdmin | none | void | NotAdmin |

## Integration Points

| System | Protocol | Direction | Purpose |
|--------|----------|-----------|---------|
| LPVaultFactory | STATICCALL `admins()` | outbound | Admin address verification for `onlyAdmin` check |

## Code Map

| Spec ID | Spec Name | Implementation Files |
|---------|-----------|---------------------|
| UC-K1MK | Pause and Unpause Vault | `src/LPVault.sol:pauseTrading()`, `src/LPVault.sol:unpauseTrading()` |
| SC-K1ML | Admin pauses + gated reverts | `src/LPVault.sol:pauseTrading()`, `whenNotPaused` modifier |
| SC-K1MM | Unpause returns to normal | `src/LPVault.sol:unpauseTrading()` |
| SC-K1MN | Non-admin revert | `src/LPVault.sol:pauseTrading()`, `src/LPVault.sol:unpauseTrading()` |
| SC-K1MO | Collect works while paused | `src/LPVault.sol:collect()` (no pause check) |
| SC-K1MP | ReclaimDeposit works while paused | `src/LPVault.sol:reclaimDeposit()` (no pause check) |

## Architecture Decisions

_None — pause follows the standard circuit-breaker pattern with a boolean flag and modifier._

## Testing Decisions

| Service/Pattern | Decision | Reason |
|-----------------|----------|--------|
| LPVaultFactory (Admin registry) | e2e | Vault delegates `onlyAdmin` to factory; test with real factory instance |
