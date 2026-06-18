---
id: UC-TVS1
name: Update Current Tick
feature: FEAT-TVS0
status: implemented
version: 1
actor: Operator
---

# UC-TVS1: Update Current Tick

> The Operator synchronizes the vault's price tick with the off-chain CLOB mid-price, crossing all initialized ticks in between so fee distributions split correctly between in-range and out-of-range positions.

## Preconditions

- Vault is in Active phase
- Caller holds the Operator role

## Trigger

Operator calls `updateTick(int24 newTick)` on the vault.

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
2. System queries TickBitmap and finds no initialized ticks in range
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
