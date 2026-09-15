---
id: FEAT-TVS0
name: Update Tick and Cross Ticks
use_cases: [UC-TVS1]
scenarios: [SC-TVS2, SC-TVS3, SC-TVS4, SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8, SC-5IDH, SC-5IDI, SC-5IDJ, SC-5IDL, SC-A2ZT]
last_update: 2026-09-15
---

# Architecture: Update Tick and Cross Ticks

## System Context (C4 L1)

> Operator (Keeper) reports CLOB price changes to the vault, which adjusts its internal tick pointer and accounting state.

```mermaid
C4Context
    title Update Tick and Cross Ticks -- System Context
    Person(keeper, "Keeper", "Off-chain bot monitoring CLOB mid-price, signs with Operator key")
    System(vault, "LPVault", "Per-market vault tracking tick state and active liquidity")
    System_Ext(clob, "ProphetCTFExchange", "CLOB providing the mid-price the Keeper reads")
    Rel(keeper, vault, "updateTick(newTick)", "contract-call")
    Rel(keeper, clob, "reads mid-price", "off-chain")
```

## Container View (C4 L2)

> updateTick mutates tick state and active liquidity within LPVault. Since R18 a moving report also reads the vault's two outcome-token balances and its USDC balance, credits the measured spread per segment, and merges the vault's free pairs as its one external call. The unchanged-tick path still reads no balance and makes no call.

```mermaid
C4Container
    title Update Tick and Cross Ticks -- Container View
    Person(operator, "Operator")
    Container(vault, "LPVault", "Solidity", "updateTick entry point, tick crossing loop, TickBitmap lookups, the report's settlement tail")
    ContainerDb(tickState, "Tick Storage", "Solidity mapping", "ticks[int24] => TickInfo (liquidityGross, liquidityNet, noLiquidityNet, spreadGrowthOutsideX128)")
    ContainerDb(ledger, "Solvency ledger (FEAT-9BQZ)", "Solidity storage", "three scaled totals, shifted once per call from the accrued segments")
    ContainerDb(spread, "Spread accumulator (FEAT-E943)", "Solidity storage", "spreadGrowthGlobalX128 and totalSpreadOwedX128, credited once per segment with liquidity")
    ContainerDb(bitmap, "TickBitmap", "Solidity mapping", "tickBitmap[int16] => uint256 word tracking initialized ticks")
    System_Ext(ctf, "ConditionalTokens", "balanceOf x2, mergePositions")
    System_Ext(usdc, "USDC", "balanceOf")
    Rel(operator, vault, "updateTick(newTick)", "contract-call")
    Rel(vault, tickState, "reads/writes per-tick state")
    Rel(vault, bitmap, "queries next initialized tick")
    Rel(vault, ledger, "applies the segment shift")
    Rel(vault, spread, "credits each segment's share")
    Rel(vault, ctf, "reads both balances, merges the free pairs")
    Rel(vault, usdc, "reads the balance")
```

## Data Model

> State touched by updateTick. Tick and bitmap structures are initialized by mint (FEAT-T7AF) and deinitialized by burn.

```mermaid
erDiagram
    LPVAULT {
        int24 currentTick "current price tick"
        uint128 activeLiquidity "sum of liquidity from in-range positions"
        uint128 noSideLiquidity "in-range liquidity whose mintTick <= currentTick; packs with currentTick"
        uint256 lastOperatorActivityTimestamp "block.timestamp of most recent operator action"
        uint8 phase "Active or WindDown"
    }
    TICK_INFO {
        uint128 liquidityGross "total liquidity referencing this tick"
        int128 liquidityNet "net liquidity change when crossed L-to-R"
        int128 noLiquidityNet "net of the NO sub-ranges [mintTick, tickUpper) at this tick"
        uint256 spreadGrowthOutsideX128 "FEAT-E943: growth away from currentTick, flipped at each crossing"
    }
    TICK_BITMAP {
        int16 wordPosition "tick index divided by 256"
        uint256 word "bit n = 1 if tick (wordPosition * 256 + n) is initialized"
    }
    LPVAULT ||--o{ TICK_INFO : "ticks mapping"
    LPVAULT ||--o{ TICK_BITMAP : "tickBitmap mapping"
```

**Invariants:**
- `activeLiquidity` after any updateTick equals the sum of `position.liquidity` for all positions where `tickLower <= currentTick < tickUpper`, and `noSideLiquidity` equals the same sum over the positions whose `mintTick <= currentTick`
- An interior mint tick (`tickLower < mintTick < tickUpper`) is initialized while a position references it, counts that position's liquidity in `liquidityGross`, holds its `noLiquidityNet`, and is crossed like a boundary
- Every segment a move traverses, the trailing one included, shifts the three ledger totals of FEAT-9BQZ with the split as it stood in that segment (UC-9BR1)
- `currentTick` is updated atomically with all tick crossings — partial crossing state is never observable
- `lastOperatorActivityTimestamp` is monotonically non-decreasing
- The number of initialized ticks crossed in a single call never exceeds 256
- A tick's bitmap bit is set if and only if `ticks[t].liquidityGross > 0`; a burn that takes `liquidityGross` to zero clears the bit through `_clearTickBitmapBit` (FEAT-7G40 FR-7G4P, `invariant_zeroLiquidityTickHasNoBit` in `test/invariants/TickState.t.sol`)
- A crossing flips `spreadGrowthOutsideX128` to `spreadGrowthGlobalX128 − spreadGrowthOutsideX128`, and a tick the same call credits before also gains that growth; a deleted tick record reads a zero snapshot (FEAT-E943)

## Component Inventory

| File | Role | Key Exports |
|------|------|-------------|
| `src/LPVault.sol` | Business logic | `updateTick(int24)`, `_settleReport(...)`, `_crossTick(int24, bool)`, `_nextInitializedTick(int24 tick, bool searchRight, int24 targetTick)`, `_setTickBitmapBit(int24)`, `_clearTickBitmapBit(int24)`, `tickBitmap`, `lastOperatorActivityTimestamp`, `Shift`, `_accrueSegment(Shift memory, int24 from, int24 to, bool up)`, `_segmentSpend(int24 from, int24 to, bool up)`, `_applyShift(Shift memory)`, `noSideLiquidity` |
| `src/LPVault.sol` | Existing (modified) | `_addTickReference(int24)` — gains `_setTickBitmapBit` call inside `liquidityGross == 0` branch |
| `test/features/FEAT-TVS0-update-tick-and-cross-ticks/UC-TVS1-update-current-tick.t.sol` | Test | Integration tests for all 12 scenarios, and the fuzz tests of the bounded search (`BoundedTickSearchTestBase`, `BoundedTickSearchFuzzTest`) |
| `test/fixtures/VaultStorage.sol` | Test fixture | `setCurrentTick()` writes `currentTick` for a search test that starts inside an extreme bitmap word; it moves no liquidity |
| `test/invariants/TickState.t.sol` | Invariant test for the tick state machine | `TickStateHandler`, `invariant_activeLiquidityEqualsInRangeLiquidity`, `invariant_liquidityGrossEqualsReferencingLiquidity`, `invariant_updateTickRevertsOnlyForDocumentedReasons`, `invariant_zeroCrossingMoveGasStaysBounded` |

## Event Topology

| Event | Publisher | Payload | Condition | Consumers |
|-------|-----------|---------|-----------|-----------|
| `TickUpdated(int24 oldTick, int24 newTick, uint256 ticksCrossed)` | `LPVault.updateTick` | `oldTick, newTick, ticksCrossed` | Every successful updateTick call whose newTick differs from currentTick | Off-chain indexer, Keeper |
| `SpreadCredited(uint256 amount, uint256 spreadGrowthGlobalX128)` | `LPVault.updateTick` (FEAT-E943) | the USDC credited, and the global growth after it | Once per segment the report credits above zero | Off-chain indexer |
| `CompleteSetsMerged(address indexed caller, uint256 amount)` | `LPVault.updateTick` (FEAT-6HBN) | `caller, amount` | When the report finds free pairs to merge | Off-chain indexer, Keeper |

**Non-events (explicit):**
- SC-TVS5, SC-TVS6, SC-TVS8: no event emitted (call reverts)
- SC-TVS7: no event emitted (the call succeeds and only refreshes the heartbeat); it reads no balance, so it can emit neither `SpreadCredited` nor `CompleteSetsMerged`
- A moving report with no surplus, with a short token balance, or with nothing in range emits no `SpreadCredited`

## API Surface

| Method | Path | Handler | Auth | Request Shape | Response Shape | Error Codes |
|--------|------|---------|------|---------------|----------------|-------------|
| contract-call | `LPVault.updateTick(int24 newTick)` | `updateTick` | `onlyOperator` | `newTick: int24` | `void` (emits TickUpdated when the tick changes; refreshes only the heartbeat when it does not) | `NotOperator`, `TradingIsPaused`, `VaultNotActive`, `TooManyTicksCrossed` |

## Integration Points

| System | Protocol | Direction | Purpose |
|--------|----------|-----------|---------|
| ProphetCTFExchange | off-chain read | inbound | Keeper reads CLOB mid-price off-chain, then calls updateTick on-chain |
| Gnosis ConditionalTokens | contract call | outbound | A moving report reads both outcome-token balances for the measurement (FEAT-E943) and merges the vault's free pairs (FEAT-6HBN) |
| USDC (ERC-20) | contract call | outbound | A moving report reads the vault's USDC balance for the measurement (FEAT-E943) |

## Code Map

| Spec ID | Spec Name | Implementation Files |
|---------|-----------|---------------------|
| UC-TVS1 | Update Current Tick | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_accrueSegment()`, `src/LPVault.sol:_applyShift()`, `src/LPVault.sol:_settleReport()` |
| SC-TVS2 | Price increases crossing initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_crossTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS3 | Price decreases crossing initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_crossTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS4 | No initialized ticks in range | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-TVS5 | Too many initialized ticks to cross | `src/LPVault.sol:updateTick()` |
| SC-TVS6 | Non-operator caller | `src/LPVault.sol:updateTick()` |
| SC-TVS7 | Same tick refreshes only the heartbeat | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:touchesHeartbeat` |
| SC-TVS8 | Vault not in Active phase | `src/LPVault.sol:updateTick()` |
| SC-5IDH | Initialized tick far above the target is never searched | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-5IDI | Initialized tick far below the target is never searched | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-5IDJ | Initialized tick inside the target's own word is still crossed | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()`, `src/LPVault.sol:_crossTick()` |
| SC-5IDL | Target in the highest bitmap word with no initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |
| SC-A2ZT | Start inside the lowest bitmap word with no initialized ticks | `src/LPVault.sol:updateTick()`, `src/LPVault.sol:_nextInitializedTick()` |

## Architecture Decisions

**ADR-TVUV:** TickBitmap for O(1) initialized-tick lookup
In the context of iterating from currentTick to newTick, facing the risk that a naive linear scan over every tick in the range would make gas cost proportional to the tick gap (not the number of initialized ticks), we decided to use an inline TickBitmap structure (one uint256 word per 256 consecutive ticks, bit N set when tick N is initialized) to achieve O(1) per-word next-initialized-tick lookup, accepting the additional storage writes on tick initialization/deinitialization in mint and burn.

**ADR-TVUW:** 256 max initialized-tick crossings per call
In the context of large price moves that could cross hundreds of initialized ticks, facing the risk of gas griefing or block-limit exhaustion, we decided to cap initialized-tick crossings at 256 per updateTick call and revert with TooManyTicksCrossed if exceeded, forcing the Keeper to chunk into multiple calls, accepting the operational complexity of multi-call chunking for extreme price movements.

**ADR-9J43:** An unchanged tick report refreshes the heartbeat and returns
In the context of the keeper reporting the tick every 60 seconds and after fills, on markets that mostly keep the same price, facing the fact that a `SameTick` revert cost about 23,600 gas, refreshed nothing, and forced a second `heartbeat()` transaction, we decided that `updateTick` with `newTick == currentTick` returns after the phase check with no crossing, no bitmap read, no event, and no storage write other than the heartbeat and the reentrancy guard toggle, which ends at its starting value, to achieve one report per interval at about 20,500 gas net against 15,600 for `heartbeat()`, accepting that the guards stay as modifiers, so the guard slot is written twice on the unchanged path and the report costs about 4,900 gas more than `heartbeat()`. The user decided this on 2026-09-11 (decision C11 in `audits/audit-fixes-ranged.md`), and it replaces the part of ADR-3XU3 in FEAT-JXQO that kept the revert. `notifyFees` keeps its `ZeroAmount` revert, because an income report of zero is a caller bug and not a normal case. Since 2026-09-14 (step R17) `notifyFees` does not exist.
Qualified on 2026-09-15 (step R18, ADR-E94V in FEAT-E943): a version that reads both token balances before returning, so an unchanged report could credit a round trip with no net move, was measured against this path and rejected, because it costs roughly twice as much. The round trip is credited in `mergeCompleteSets()` instead. The unchanged path keeps this decision exactly.

**ADR-5IDK:** Target-bounded next-initialized-tick search
In the context of the bitmap search that updateTick runs between currentTick and newTick, facing the risk that the crossing cap (ADR-TVUW) bounds only the number of ticks crossed and not the cost of scanning the empty words between them, so that an LP could sign a mint intent at an extreme tick and force a later legitimate updateTick to scan tens of thousands of empty words and exceed the block gas limit (76,618,321 gas for a move of 200 ticks, measured on 2026-09-12), we decided to pass the target tick into `_nextInitializedTick` as a third parameter, to stop both the upward and the downward scan at the bitmap word that contains the target, inclusive, and to make each loop test for the extreme word before it steps, in both directions, to achieve a scan cost that follows the Operator's reported move and a search that reports "not found" at both ends of the scale, accepting that the bound is only as tight as the Operator's reported newTick, which is already a trusted input under NFR-TVSM, so control of the scan cost moves from any third party to the one actor the vault already trusts, and that chunking of large jumps stays an operational practice and not an on-chain rule. The user chose this on 2026-09-11 (decision C13 in `audits/audit-fixes-ranged.md`) from the auditors' recommendation for issues 6.10 and 6.12. For any target inside `int24`, the target's word check already stops the loop at the extreme word, so the extreme-word test is defense in depth that the decision keeps on purpose: it costs one comparison per word and it holds even if a later caller passes a target the current caller cannot.

**ADR-COEW:** A mint tick is a crossable tick
In the context of the solvency ledger (FEAT-9BQZ) needing the liquidity split at every level the price moves through, because a crossing turns USDC into NO for the positions minted at or below it and YES into USDC for the positions minted above it (decision C26), facing a per-position walk on every move or a per-tick record, we decided that an interior mint tick (`tickLower < mintTick < tickUpper`) counts its positions' liquidity in `liquidityGross` and holds their `noLiquidityNet` as a fourth `TickInfo` field, so the bitmap keeps its one meaning (a set bit means liquidity behind it) and `_crossTick` moves both `activeLiquidity` and `noSideLiquidity`, to achieve an O(segments) ledger inside the existing 256-crossing cap (ADR-TVUW), accepting about 7,500 gas per mint tick the price crosses, one storage slot and a bitmap bit per interior mint tick, and a fee-growth flip on a tick no position bounds, which is harmless because `feeGrowthOutside` is read only at a position's own boundaries. `_addTickReference` and `_removeTickReference` hold the reference count and the bitmap rule in one place for the boundary ticks and the mint tick alike. The user chose this on 2026-09-14 (the per-mint-tick slot of the R11 prompt). Since 2026-09-14 (step R17) a crossing flips nothing, so that accepted cost is gone.
Reinstated on 2026-09-15 (step R18, ADR-E94R in FEAT-E943): an interior mint tick again carries a growth snapshot and flips it at each crossing, and the flip is again harmless for the same reason, because `_spreadGrowthInside` reads a position's two bounds only.

**Rejected alternative -- check the unchanged tick before the reentrancy guard:** it removes the guard's 2,300 gas net but gives one function a hand-written guard, which is a review cost that security outranks. It is Part 7 candidate 6 in `audits/audit-fixes-ranged.md`.

