---
id: UC-TVS1
name: Update Current Tick
feature: FEAT-TVS0
status: implemented
version: 3
actor: Operator
---

# UC-TVS1: Update Current Tick

> The Operator synchronizes the vault's price tick with the off-chain CLOB mid-price, crossing all initialized ticks in between so fee distributions split correctly between in-range and out-of-range positions.

## Preconditions

- Vault is in Active phase
- Caller holds the Operator role

## Trigger

Operator calls `updateTick(int24 newTick)` on the vault.

The `lastOperatorActivityTimestamp` refresh named in the scenarios below is the shared Operator-liveness mechanism owned by FEAT-JXQO (FR-JXQS): every successful Operator-gated call refreshes it, and a reverted call does not. A `SameTick` revert (SC-TVS7) therefore leaves the timer untouched -- which is why `heartbeat()` exists for markets whose tick does not move.

---

### SC-TVS2: Price increases crossing initialized ticks

**Given:**
- currentTick = 100
- Initialized ticks at 150 (liquidityNet = +50e18, feeGrowthOutsideX128 = 200) and 200 (liquidityNet = -30e18, feeGrowthOutsideX128 = 100)
- activeLiquidity = 400e18
- feeGrowthGlobalX128 = 1000

**Steps:**
1. Operator calls updateTick(250)
2. System locates next initialized tick (150) via TickBitmap
3. System crosses tick 150: flips feeGrowthOutsideX128 to 800 (1000 - 200), adds +50e18 to activeLiquidity
4. System locates next initialized tick (200) via TickBitmap
5. System crosses tick 200: flips feeGrowthOutsideX128 to 900 (1000 - 100), adds -30e18 to activeLiquidity
6. System stores currentTick = 250 and lastOperatorActivityTimestamp = block.timestamp
7. System emits TickUpdated(100, 250, 2)

**Outcomes:**
- currentTick is 250
- activeLiquidity is 420e18 (400 + 50 - 30)
- Tick 150 feeGrowthOutsideX128 = 800
- Tick 200 feeGrowthOutsideX128 = 900

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=250, ticksCrossed=2`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- `ticks[150].feeGrowthOutsideX128` flipped to 800
- `ticks[200].feeGrowthOutsideX128` flipped to 900
- `activeLiquidity` storage updated to 420e18

---

### SC-TVS3: Price decreases crossing initialized ticks

**Given:**
- currentTick = 250
- Initialized ticks at 200 (liquidityNet = -30e18) and 150 (liquidityNet = +50e18)
- activeLiquidity = 420e18
- feeGrowthGlobalX128 = 1500

**Steps:**
1. Operator calls updateTick(100)
2. System crosses tick 200 right-to-left: flips feeGrowthOutsideX128, subtracts liquidityNet (-30e18) from activeLiquidity (net effect: +30e18)
3. System crosses tick 150 right-to-left: flips feeGrowthOutsideX128, subtracts liquidityNet (+50e18) from activeLiquidity (net effect: -50e18)
4. System stores currentTick = 100 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(250, 100, 2)

**Outcomes:**
- currentTick is 100
- activeLiquidity is 400e18 (420 + 30 - 50)
- Both ticks' feeGrowthOutsideX128 flipped against feeGrowthGlobalX128

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=250, newTick=100, ticksCrossed=2`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- `ticks[200].feeGrowthOutsideX128` flipped
- `ticks[150].feeGrowthOutsideX128` flipped
- `activeLiquidity` storage updated to 400e18

---

### SC-TVS4: No initialized ticks in range

**Given:**
- currentTick = 100
- No initialized ticks between 100 and 300

**Steps:**
1. Operator calls updateTick(300)
2. System queries TickBitmap over the words spanning 100 to 300 only, and finds no initialized ticks in range
3. System stores currentTick = 300 and lastOperatorActivityTimestamp = block.timestamp
4. System emits TickUpdated(100, 300, 0)

**Outcomes:**
- currentTick is 300
- activeLiquidity unchanged

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=300, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified

---

### SC-TVS5: Too many initialized ticks to cross

**Given:**
- currentTick = 0
- 257 initialized ticks between currentTick and newTick

**Steps:**
1. Operator calls updateTick(500)
2. System detects more than 256 initialized ticks to cross

**Outcomes:**
- Call reverts with TooManyTicksCrossed

**Side Effects:**
- No state changes
- No events emitted

---

### SC-TVS6: Non-operator caller

**Given:**
- Caller does not hold the Operator role

**Steps:**
1. Non-operator calls updateTick(200)

**Outcomes:**
- Call reverts with NotOperator

**Side Effects:**
- No state changes
- No events emitted

---

### SC-TVS7: Same tick

**Given:**
- currentTick = 100

**Steps:**
1. Operator calls updateTick(100)

**Outcomes:**
- Call reverts with SameTick

**Side Effects:**
- No state changes
- No events emitted

---

### SC-TVS8: Vault not in Active phase

**Given:**
- Vault phase = WindDown

**Steps:**
1. Operator calls updateTick(200)

**Outcomes:**
- Call reverts with VaultNotActive

**Side Effects:**
- No state changes
- No events emitted

---

### SC-5IDH: Initialized tick far above the target is never searched

**Given:**
- currentTick = 100
- A single initialized tick at 8388600 (near the int24 maximum), initialized by an earlier mint
- No initialized ticks between 100 and 300

**Steps:**
1. Operator calls updateTick(300)
2. System searches for the next initialized tick only across the bitmap words spanning 100 to 300, stopping at the word containing 300 rather than continuing toward the extreme
3. System finds no initialized tick within that bounded range
4. System stores currentTick = 300 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(100, 300, 0)

**Outcomes:**
- currentTick is 300
- activeLiquidity unchanged
- The tick at 8388600 is not crossed and its state is untouched
- The call completes within the block gas limit regardless of how far above the target that tick sits

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=300, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified
- `ticks[8388600]` is neither read as a crossing candidate nor written

---

### SC-5IDI: Initialized tick far below the target is never searched

**Given:**
- currentTick = 300
- A single initialized tick at -8388600 (near the int24 minimum), initialized by an earlier mint
- No initialized ticks between 100 and 300

**Steps:**
1. Operator calls updateTick(100)
2. System searches for the next initialized tick only across the bitmap words spanning 300 down to 100, stopping at the word containing 100 rather than continuing toward the extreme
3. System finds no initialized tick within that bounded range
4. System stores currentTick = 100 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(300, 100, 0)

**Outcomes:**
- currentTick is 100
- activeLiquidity unchanged
- The tick at -8388600 is not crossed and its state is untouched
- The call completes within the block gas limit regardless of how far below the target that tick sits

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=300, newTick=100, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified
- `ticks[-8388600]` is neither read as a crossing candidate nor written

---

### SC-5IDJ: Initialized tick inside the target's own word is still crossed

**Given:**
- currentTick = 100
- An initialized tick at 260 (liquidityNet = +50e18), which shares a bitmap word with the target tick 300
- activeLiquidity = 400e18

**Steps:**
1. Operator calls updateTick(300)
2. System searches up to and including the bitmap word containing 300 and locates the initialized tick at 260
3. System crosses tick 260: flips feeGrowthOutsideX128, adds +50e18 to activeLiquidity
4. System stores currentTick = 300 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(100, 300, 1)

**Outcomes:**
- currentTick is 300
- activeLiquidity is 450e18
- Tick 260 was crossed — the search bound includes the target's own word rather than stopping short of it

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=300, ticksCrossed=1`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- `ticks[260].feeGrowthOutsideX128` flipped
- `activeLiquidity` storage updated to 450e18

---

### SC-5IDL: Target at the extreme bitmap word with no initialized ticks

**Given:**
- currentTick = 8388000, near the int24 maximum, so the target's bitmap word is the highest addressable word
- No initialized ticks at or above currentTick

**Steps:**
1. Operator calls updateTick(8388600)
2. System searches toward the target, reaches the extreme bitmap word, checks it, and stops there without advancing past it
3. System reports no initialized tick found rather than reverting with an arithmetic panic
4. System stores currentTick = 8388600 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(8388000, 8388600, 0)

**Outcomes:**
- currentTick is 8388600
- activeLiquidity unchanged
- The call succeeds — reaching the extreme word is reported as "not found", never as a revert
- The symmetric downward case at the int24 minimum behaves the same way

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=8388000, newTick=8388600, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified

---
