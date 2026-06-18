---
id: UC-TVS1-001
name: update-tick-with-crossing
use_case: UC-TVS1
feature: FEAT-TVS0
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [updateTick, _crossTick, _nextInitializedTick, tickBitmap, lastOperatorActivityTimestamp]
entry_type: contract-call
covers: [SC-TVS2, SC-TVS3, SC-TVS4, SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8, FR-TVS9, FR-TVSA, FR-TVSB, FR-TVSC, FR-TVSD, FR-TVSE, FR-TVSF, FR-TVSG, FR-TVSH, FR-TVSI, FR-TVSJ]
last_update: 2026-06-18
---

# UC-TVS1-001: Update Tick with Crossing

## Rationale

Implements `updateTick(int24 newTick)` — the on-chain entry point for price synchronization between the off-chain CLOB and the vault's accounting state. Adds a TickBitmap structure (one uint256 word per 256 ticks) for O(1) initialized-tick lookup, integrates bitmap tracking into the existing `_initializeTick`, implements the tick-crossing loop that flips `feeGrowthOutsideX128` and applies `liquidityNet` deltas to `activeLiquidity`, and records `lastOperatorActivityTimestamp` for feature 8's operator-silence detection. Gas-bounded at 256 initialized-tick crossings per call. Closes all seven scenarios in UC-TVS1.

## Contracts

### Types

```solidity
// TickBitmap — one word per 256 consecutive ticks.
// Word position = tick / 256 (int16), bit position = tick % 256.
// Bit N is 1 if the tick at (wordPosition * 256 + N) is initialized.
mapping(int16 => uint256) public tickBitmap;

// Operator activity tracking for feature 8's silence detection.
uint256 public lastOperatorActivityTimestamp;

// Errors
error TooManyTicksCrossed();
error SameTick();

// Events
event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

// Constants
uint256 internal constant MAX_TICK_CROSSINGS = 256;
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `updateTick` | `(int24 newTick) external` | `onlyOperator nonReentrant` | Crosses initialized ticks between currentTick and newTick. Reverts if >256 crossings, same tick, non-operator, or non-Active phase. |

### Behavior

- **Preconditions:** phase == 1 (Active), `operators[msg.sender] == 1`, newTick != currentTick
- **Postconditions:** currentTick == newTick, lastOperatorActivityTimestamp == block.timestamp, all crossed ticks' feeGrowthOutsideX128 flipped via `feeGrowthGlobalX128 - old`, activeLiquidity adjusted by cumulative liquidityNet (added L-to-R, subtracted R-to-L), TickUpdated event emitted
- **Invariants:** activeLiquidity == sum of position.liquidity for all positions where tickLower <= currentTick < tickUpper; no partial crossing state observable (all or revert)
- **Error modes:** `NotOperator` (wrong caller), `VaultNotActive` (phase != 1), `SameTick` (newTick == currentTick), `TooManyTicksCrossed` (>256 initialized ticks), `Reentrancy` (re-entered)
- **Side effect on existing code:** `_initializeTick(int24 tick)` gains a `_setTickBitmapBit(tick)` call inside the `liquidityGross == 0` branch, so future mints automatically register ticks in the bitmap

## Tests

- **SC-TVS2: Price increases crossing initialized ticks**
  - Given vault with currentTick=100, two positions creating initialized ticks at 150 (liquidityNet=+L1) and 200 (liquidityNet=-L2), feeGrowthGlobalX128 set via notifyFees
    - When Operator calls updateTick(250)
      - Then currentTick == 250
      - And activeLiquidity == previous + L1 - L2
      - And ticks[150].feeGrowthOutsideX128 == feeGrowthGlobalX128 - old_feeGrowthOutside_150
      - And ticks[200].feeGrowthOutsideX128 == feeGrowthGlobalX128 - old_feeGrowthOutside_200
      - And TickUpdated event emitted with (100, 250, 2)
      - And lastOperatorActivityTimestamp == block.timestamp

- **SC-TVS3: Price decreases crossing initialized ticks**
  - Given vault with currentTick=250, positions creating initialized ticks at 200 and 150, activeLiquidity reflects in-range positions
    - When Operator calls updateTick(100)
      - Then currentTick == 100
      - And activeLiquidity adjusted by subtracting liquidityNet at each crossed tick (reverse direction)
      - And both ticks' feeGrowthOutsideX128 flipped
      - And TickUpdated event emitted with (250, 100, 2)
      - And lastOperatorActivityTimestamp == block.timestamp

- **SC-TVS4: No initialized ticks in range**
  - Given vault with currentTick=100, no initialized ticks between 100 and 300
    - When Operator calls updateTick(300)
      - Then currentTick == 300
      - And activeLiquidity unchanged
      - And TickUpdated event emitted with (100, 300, 0)
      - And lastOperatorActivityTimestamp == block.timestamp

- **SC-TVS5: Too many initialized ticks to cross**
  - Given vault with more than 256 initialized ticks between currentTick and newTick
    - When Operator calls updateTick(target)
      - Then reverts with TooManyTicksCrossed
      - And no state changes persist

- **SC-TVS6: Non-operator caller**
  - Given caller does not hold Operator role
    - When non-operator calls updateTick(200)
      - Then reverts with NotOperator

- **SC-TVS7: Same tick**
  - Given currentTick == 100
    - When Operator calls updateTick(100)
      - Then reverts with SameTick

- **SC-TVS8: Vault not in Active phase**
  - Given vault phase != Active (simulated via storage manipulation since wind-down is not yet implemented)
    - When Operator calls updateTick(200)
      - Then reverts with VaultNotActive

- **FR-TVSJ: TickBitmap tracks initialized ticks**
  - Given ticks initialized at specific positions via mintPositionFor
    - Then tickBitmap word at the correct int16 position has the expected bits set
    - And _nextInitializedTick returns the correct tick in both directions
    - And _nextInitializedTick skips uninitialized gaps efficiently
