---
id: FEAT-KX5N
name: Upgradeable Vault Implementation Pointer
use_cases: [UC-KX5O]
scenarios: [SC-KX5P, SC-KX5Q, SC-KX5R, SC-KX5S, SC-KX5T, SC-KX5U, SC-KX5V, SC-KX5W]
last_update: 2026-07-02
---

# Architecture: Upgradeable Vault Implementation Pointer

## System Context (C4 L1)

```mermaid
C4Context
    title Upgradeable Vault Implementation Pointer -- System Context
    Person(admin, "Admin", "Schedules/applies/cancels implementation upgrades")
    Person(oracle, "Oracle", "Creates vaults using current implementation")
    System(factory, "LPVaultFactory", "Stores implementation pointer + version counter")
    System(vault, "LPVault (clone)", "Stores implementationVersion from initialize")
    Rel(admin, factory, "schedule/apply/cancel", "contract call")
    Rel(oracle, factory, "createVault", "contract call")
    Rel(factory, vault, "initialize(…, version)", "clone deploy + init")
```

## Container View (C4 L2)

```mermaid
C4Container
    title Upgradeable Impl Pointer -- Container View
    Person(admin, "Admin")
    Person(oracle, "Oracle")
    Container(factory, "LPVaultFactory", "Solidity", "implementation, pendingImplementation, implementationUnlockAt, implementationVersion")
    Container(vault, "LPVault (clone)", "Solidity", "implementationVersion (from initialize)")
    Rel(admin, factory, "schedule/apply/cancel", "tx")
    Rel(oracle, factory, "createVault", "tx")
    Rel(factory, vault, "initialize(version)", "internal call")
```

## Data Model

```mermaid
erDiagram
    LPVAULTFACTORY {
        address implementation "current impl; updated by applyImplementation"
        address pendingImplementation "scheduled impl; cleared on apply/cancel"
        uint256 implementationUnlockAt "timestamp after which apply succeeds"
        uint256 implementationVersion "counter incremented on each apply"
    }
    LPVAULT {
        uint256 implementationVersion "set once in initialize; identifies clone's code version"
    }
```

**Invariants:**
- `pendingImplementation != address(0)` iff a schedule is active
- `implementationVersion` is monotonically increasing on the factory
- Existing vaults' `implementationVersion` never changes after initialize
- `implementation` address is never address(0)

## Component Inventory

| File | Role | Key Exports |
|------|------|-------------|
| `src/LPVaultFactory.sol` | Factory with timelocked impl upgrade | `scheduleImplementation()`, `applyImplementation()`, `cancelScheduledImplementation()`, `pendingImplementation`, `implementationUnlockAt`, `implementationVersion` |
| `src/LPVault.sol` | Vault stores version from initialize | `implementationVersion` storage field |

## Event Topology

| Event | Publisher | Payload | Condition | Consumers |
|-------|-----------|---------|-----------|-----------|
| `ImplementationScheduled(address indexed newImpl, uint256 unlockAt)` | LPVaultFactory | `newImpl, unlockAt` | On successful `scheduleImplementation()` | Off-chain monitoring |
| `ImplementationApplied(address indexed newImpl, uint256 version)` | LPVaultFactory | `newImpl, version` | On successful `applyImplementation()` | Off-chain monitoring |
| `ImplementationCancelled(address indexed cancelledImpl)` | LPVaultFactory | `cancelledImpl` | On successful `cancelScheduledImplementation()` | Off-chain monitoring |

**Non-events (explicit):**
- Failed schedule/apply/cancel (non-admin, timelock not elapsed): no events emitted
- createVault does not emit new events beyond existing VaultCreated

## API Surface

| Method | Path | Handler | Auth | Request Shape | Response Shape | Error Codes |
|--------|------|---------|------|---------------|----------------|-------------|
| call | `LPVaultFactory.scheduleImplementation(address)` | `scheduleImplementation` | onlyAdmin | `newImpl` | void | NotAdmin, ZeroAddress, ScheduleAlreadyPending |
| call | `LPVaultFactory.applyImplementation()` | `applyImplementation` | onlyAdmin | none | void | NotAdmin, NoPendingSchedule, TimelockNotElapsed |
| call | `LPVaultFactory.cancelScheduledImplementation()` | `cancelScheduledImplementation` | onlyAdmin | none | void | NotAdmin, NoPendingSchedule |

## Integration Points

_None — implementation upgrade is a pure storage operation on the factory._

## Code Map

| Spec ID | Spec Name | Implementation Files |
|---------|-----------|---------------------|
| UC-KX5O | Schedule and Apply Implementation Upgrade | `src/LPVaultFactory.sol` |
| SC-KX5P | Admin schedules new implementation | `src/LPVaultFactory.sol:scheduleImplementation()` |
| SC-KX5Q | Admin applies after timelock | `src/LPVaultFactory.sol:applyImplementation()` |
| SC-KX5R | New vault uses updated implementation | `src/LPVaultFactory.sol:createVault()`, `src/LPVault.sol:initialize()` |
| SC-KX5S | Admin cancels pending schedule | `src/LPVaultFactory.sol:cancelScheduledImplementation()` |
| SC-KX5T | Apply reverts before timelock | `src/LPVaultFactory.sol:applyImplementation()` |
| SC-KX5U | Revert when no pending schedule | `src/LPVaultFactory.sol:applyImplementation()`, `cancelScheduledImplementation()` |
| SC-KX5V | Revert on zero address | `src/LPVaultFactory.sol:scheduleImplementation()` |
| SC-KX5W | Non-admin callers revert | `src/LPVaultFactory.sol` |

## Architecture Decisions

_None — follows the standard two-step timelock pattern for admin-gated upgrades._

## Testing Decisions

| Service/Pattern | Decision | Reason |
|-----------------|----------|--------|
| LPVaultFactory (Admin registry) | e2e | Use real factory instance for admin auth checks |
| Timelock | injection | Use `vm.warp` to advance past IMPLEMENTATION_TIMELOCK |
