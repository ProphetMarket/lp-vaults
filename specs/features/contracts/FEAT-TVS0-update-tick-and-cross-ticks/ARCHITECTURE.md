---
id: FEAT-TVS0
name: Update Tick and Cross Ticks
use_cases: [UC-TVS1]
scenarios: [SC-TVS2, SC-TVS3, SC-TVS4, SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8]
last_update: 2026-06-18
---

# Architecture: Update Tick and Cross Ticks

## System Context (C4 L1)

> Operator (Keeper) reports CLOB price changes to the vault, which adjusts its internal tick pointer and accounting state.

```mermaid
C4Context
    title Update Tick and Cross Ticks -- System Context
    Person(keeper, "Keeper", "Off-chain bot monitoring CLOB mid-price, signs with Operator key")
    System(vault, "LPVault", "Per-market vault tracking tick state, fee accumulators, and active liquidity")
    System_Ext(clob, "ProphetCTFExchange", "CLOB providing the mid-price the Keeper reads")
    Rel(keeper, vault, "updateTick(newTick)", "contract-call")
    Rel(keeper, clob, "reads mid-price", "off-chain")
```

## Container View (C4 L2)

> updateTick mutates tick state and active liquidity within LPVault. No external calls or token transfers.

```mermaid
C4Container
    title Update Tick and Cross Ticks -- Container View
    Person(operator, "Operator")
    Container(vault, "LPVault", "Solidity", "updateTick entry point, tick crossing loop, TickBitmap lookups")
    ContainerDb(tickState, "Tick Storage", "Solidity mapping", "ticks[int24] => TickInfo (liquidityGross, liquidityNet, feeGrowthOutsideX128)")
    ContainerDb(bitmap, "TickBitmap", "Solidity mapping", "tickBitmap[int16] => uint256 word tracking initialized ticks")
    Rel(operator, vault, "updateTick(newTick)", "contract-call")
    Rel(vault, tickState, "reads/writes per-tick state")
    Rel(vault, bitmap, "queries next initialized tick")
```

## Data Model

> State touched by updateTick. Tick and bitmap structures are initialized by mint (FEAT-T7AF) and deinitialized by burn.

```mermaid
erDiagram
    LPVAULT {
        int24 currentTick "current price tick"
        uint128 activeLiquidity "sum of liquidity from in-range positions"
        uint256 feeGrowthGlobalX128 "Q128 cumulative fee per unit of liquidity (read-only for this feature)"
        uint256 lastOperatorActivityTimestamp "block.timestamp of most recent operator action"
        uint8 phase "Active or WindDown"
    }
    TICK_INFO {
        uint128 liquidityGross "total liquidity referencing this tick"
        int128 liquidityNet "net liquidity change when crossed L-to-R"
        uint256 feeGrowthOutsideX128 "Q128 fee growth on the other side of this tick"
    }
    TICK_BITMAP {
        int16 wordPosition "tick index divided by 256"
        uint256 word "bit n = 1 if tick (wordPosition * 256 + n) is initialized"
    }
    LPVAULT ||--o{ TICK_INFO : "ticks mapping"
    LPVAULT ||--o{ TICK_BITMAP : "tickBitmap mapping"
```

**Invariants:**
- `activeLiquidity` after any updateTick equals the sum of `position.liquidity` for all positions where `tickLower <= currentTick < tickUpper`
- `feeGrowthOutsideX128` at a tick, combined with `feeGrowthGlobalX128`, must produce correct `feeGrowthInsideX128` for any position spanning that tick
- `currentTick` is updated atomically with all tick crossings — partial crossing state is never observable
- `lastOperatorActivityTimestamp` is monotonically non-decreasing
- The number of initialized ticks crossed in a single call never exceeds 256

## Component Inventory

| File | Role | Key Exports |
|------|------|-------------|
| `src/LPVault.sol` | Business logic | `updateTick(int24)`, `_crossTick(int24, bool)`, `_nextInitializedTick(int24, bool)`, `_setTickBitmapBit(int24)`, `_clearTickBitmapBit(int24)`, `tickBitmap`, `lastOperatorActivityTimestamp` |
| `src/LPVault.sol` | Existing (modified) | `_initializeTick(int24)` — gains `_setTickBitmapBit` call inside `liquidityGross == 0` branch |
| `test/features/FEAT-TVS0-update-tick-and-cross-ticks/UC-TVS1-update-current-tick/` | Test | Integration tests for all 7 scenarios |

## Event Topology

| Event | Publisher | Payload | Condition | Consumers |
|-------|-----------|---------|-----------|-----------|
| `TickUpdated(int24 oldTick, int24 newTick, uint256 ticksCrossed)` | `LPVault.updateTick` | `oldTick, newTick, ticksCrossed` | Every successful updateTick call | Off-chain indexer, Keeper |

**Non-events (explicit):**
- SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8: no event emitted (call reverts)

## API Surface

| Method | Path | Handler | Auth | Request Shape | Response Shape | Error Codes |
|--------|------|---------|------|---------------|----------------|-------------|
| contract-call | `LPVault.updateTick(int24 newTick)` | `updateTick` | `onlyOperator` | `newTick: int24` | `void` (emits TickUpdated event) | `NotOperator`, `VaultNotActive`, `SameTick`, `TooManyTicksCrossed` |

## Integration Points

| System | Protocol | Direction | Purpose |
|--------|----------|-----------|---------|
| ProphetCTFExchange | off-chain read | inbound | Keeper reads CLOB mid-price off-chain, then calls updateTick on-chain |

## Code Map

| Spec ID | Spec Name | Implementation Files |
|---------|-----------|---------------------|
| UC-TVS1 | Update Current Tick | `src/LPVault.sol:updateTick()` |
| SC-TVS2 | Price increases crossing initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_crossTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS3 | Price decreases crossing initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_crossTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS4 | No initialized ticks in range | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS5 | Too many initialized ticks to cross | `src/LPVault.sol:updateTick()` |
| SC-TVS6 | Non-operator caller | `src/LPVault.sol:updateTick()` |
| SC-TVS7 | Same tick | `src/LPVault.sol:updateTick()` |
| SC-TVS8 | Vault not in Active phase | `src/LPVault.sol:updateTick()` |

## Architecture Decisions

**ADR-TVUV:** TickBitmap for O(1) initialized-tick lookup
In the context of iterating from currentTick to newTick, facing the risk that a naive linear scan over every tick in the range would make gas cost proportional to the tick gap (not the number of initialized ticks), we decided to use an inline TickBitmap structure (one uint256 word per 256 consecutive ticks, bit N set when tick N is initialized) to achieve O(1) per-word next-initialized-tick lookup, accepting the additional storage writes on tick initialization/deinitialization in mint and burn.

**ADR-TVUW:** 256 max initialized-tick crossings per call
In the context of large price moves that could cross hundreds of initialized ticks, facing the risk of gas griefing or block-limit exhaustion, we decided to cap initialized-tick crossings at 256 per updateTick call and revert with TooManyTicksCrossed if exceeded, forcing the Keeper to chunk into multiple calls, accepting the operational complexity of multi-call chunking for extreme price movements.
