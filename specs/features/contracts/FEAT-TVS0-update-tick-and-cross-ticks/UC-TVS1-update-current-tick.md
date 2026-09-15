---
id: UC-TVS1
name: Update Current Tick
feature: FEAT-TVS0
status: implemented
version: 8
actor: Operator
---

# UC-TVS1: Update Current Tick

> The Operator synchronizes the vault's price tick with the off-chain CLOB mid-price, crossing all initialized ticks in between so the claim model values every position at the reported price.

## Preconditions

- Vault is in Active phase
- Vault is not paused
- Caller holds the Operator role

## Trigger

Operator calls `updateTick(int24 newTick)` on the vault.

The `lastOperatorActivityTimestamp` refresh named in the scenarios below is the shared Operator-liveness mechanism owned by FEAT-JXQO (FR-JXQS): every successful Operator-gated call refreshes it, and a reverted call does not. A report with the current tick (SC-TVS7) succeeds and refreshes the timer, so the keeper's 60-second report is proof of life on a market whose price does not move. `updateTick` keeps its pause and phase checks, so while the vault is paused or wound down the keeper calls `heartbeat()` instead.

Since R11 every move also shifts the three totals of the solvency ledger (FEAT-9BQZ) for each segment it traverses, and an interior mint tick is crossed like a boundary and counted in `ticksCrossed`. The scenarios below assert the tick state; the totals are asserted in UC-9BR1.

Since R18 a moving report also measures the vault's surplus after the ledger shift, credits it per segment to the liquidity that was in range there, and merges the vault's free pairs as its one external call (FEAT-E943, UC-E944). Each crossed tick's `spreadGrowthOutsideX128` is flipped by the crossing and then gains the growth credited before it was crossed. The scenarios below assert the tick state; the credit is asserted in UC-E944.

---

### SC-TVS2: Price increases crossing initialized ticks

**Given:**
- currentTick = 100
- Initialized ticks at 150 (liquidityNet = +50e18) and 200 (liquidityNet = -30e18)
- activeLiquidity = 400e18

**Steps:**
1. Operator calls updateTick(250)
2. System locates next initialized tick (150) via TickBitmap
3. System crosses tick 150: adds +50e18 to activeLiquidity
4. System locates next initialized tick (200) via TickBitmap
5. System crosses tick 200: adds -30e18 to activeLiquidity
6. System stores currentTick = 250 and lastOperatorActivityTimestamp = block.timestamp
7. System emits TickUpdated(100, 250, 2)

**Outcomes:**
- currentTick is 250
- activeLiquidity is 420e18 (400 + 50 - 30)

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=250, ticksCrossed=2`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- `activeLiquidity` storage updated to 420e18

---

### SC-TVS3: Price decreases crossing initialized ticks

**Given:**
- currentTick = 250
- Initialized ticks at 200 (liquidityNet = -30e18) and 150 (liquidityNet = +50e18)
- activeLiquidity = 420e18

**Steps:**
1. Operator calls updateTick(100)
2. System crosses tick 200 right-to-left: subtracts liquidityNet (-30e18) from activeLiquidity (net effect: +30e18)
3. System crosses tick 150 right-to-left: subtracts liquidityNet (+50e18) from activeLiquidity (net effect: -50e18)
4. System stores currentTick = 100 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(250, 100, 2)

**Outcomes:**
- currentTick is 100
- activeLiquidity is 400e18 (420 + 30 - 50)

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=250, newTick=100, ticksCrossed=2`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
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

### SC-TVS7: Same tick refreshes only the heartbeat

**Given:**
- currentTick = 100
- Initialized ticks exist on both sides of it
- Vault is Active and not paused

**Steps:**
1. Operator calls updateTick(100)
2. System checks the phase
3. System reads currentTick, finds it equal to newTick, and returns

**Outcomes:**
- The call succeeds
- currentTick is 100
- lastOperatorActivityTimestamp is block.timestamp
- The call reads no balance and credits no spread. A round trip that ends where it began is credited by `mergeCompleteSets()` instead, which the keeper already calls when it sees free pairs (FEAT-E943 SC-E94J, ADR-E94V). The user chose this on 2026-09-15 after measuring the unchanged report against a version that checks whether either token balance is above its owed total: the checked path costs roughly twice the plain one, so the quiet report keeps its cost

**Side Effects:**
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No `TickUpdated` event emitted and no `SpreadCredited` event emitted
- No tick crossed and no `tickBitmap` word read
- No balance read on USDC or on the ConditionalTokens contract, and no merge call
- No change to `currentTick`, `activeLiquidity`, any tick record, `spreadGrowthGlobalX128`, or `totalSpreadOwedX128`
- The reentrancy guard slot is written twice and ends at its starting value

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
- Ticks 8388590 and 8388600 are initialized in bitmap word 32767, planted in storage (`liquidityGross = 1` and the bitmap bit) because a mint is bounded to the price scale [0, 10000] (FEAT-T7AF FR-T7B2)
- No initialized ticks between 100 and 300

**Steps:**
1. Operator calls updateTick(300)
2. System searches for the next initialized tick only across the bitmap words spanning 100 to 300, and stops at the word containing 300 instead of continuing toward the extreme
3. System finds no initialized tick within that bounded range
4. System stores currentTick = 300 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(100, 300, 0)

**Outcomes:**
- currentTick is 300
- activeLiquidity is unchanged
- The ticks at 8388590 and 8388600 are not crossed and their state is untouched
- The call completes within the block gas limit whatever the distance to the planted tick

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=300, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified
- `ticks[8388590]` and `ticks[8388600]` are neither read as crossing candidates nor written

---

### SC-5IDI: Initialized tick far below the target is never searched

**Given:**
- currentTick = 300
- Ticks -8388600 and -8388590 are initialized in bitmap word -32768, planted in storage (`liquidityGross = 1` and the bitmap bit) because a mint is bounded to the price scale [0, 10000] (FEAT-T7AF FR-T7B2)
- No initialized ticks between 100 and 300

**Steps:**
1. Operator calls updateTick(100)
2. System searches for the next initialized tick only across the bitmap words spanning 300 down to 100, and stops at the word containing 100 instead of continuing toward the extreme
3. System finds no initialized tick within that bounded range
4. System stores currentTick = 100 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(300, 100, 0)

**Outcomes:**
- currentTick is 100
- activeLiquidity is unchanged
- The ticks at -8388600 and -8388590 are not crossed and their state is untouched
- The call completes within the block gas limit whatever the distance to the planted tick

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=300, newTick=100, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified
- `ticks[-8388600]` and `ticks[-8388590]` are neither read as crossing candidates nor written

---

### SC-5IDJ: Initialized tick inside the target's own word is still crossed

**Given:**
- currentTick = 100
- A position at [260, 600), minted with 3400 USDC, so liquidity = 10e18 and tick 260 has liquidityNet = +10e18
- Tick 260 shares bitmap word 1 with the target tick 300
- activeLiquidity = 0

**Steps:**
1. Operator calls updateTick(300)
2. System searches up to and including the bitmap word containing 300 and locates the initialized tick at 260
3. System crosses tick 260: adds +10e18 to activeLiquidity
4. System stores currentTick = 300 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(100, 300, 1)

**Outcomes:**
- currentTick is 300
- activeLiquidity is 10e18
- Tick 260 was crossed, because the search bound includes the target's own word
- Tick 600 was not crossed

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=100, newTick=300, ticksCrossed=1`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- `activeLiquidity` storage updated to 10e18

---

### SC-5IDL: Target in the highest bitmap word with no initialized ticks

**Given:**
- currentTick = 8388000, in bitmap word 32765, below the highest bitmap word (32767)
- The target 8388600 sits in the highest bitmap word
- No initialized ticks at or above currentTick

**Steps:**
1. Operator calls updateTick(8388600)
2. System searches toward the target, steps into the highest bitmap word, checks it, and stops there without stepping past it
3. System reports no initialized tick found instead of reverting with an arithmetic panic
4. System stores currentTick = 8388600 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(8388000, 8388600, 0)

**Outcomes:**
- currentTick is 8388600
- activeLiquidity is unchanged
- The call succeeds: reaching the highest word is reported as "not found", never as a revert

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=8388000, newTick=8388600, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified

---

### SC-A2ZT: Start inside the lowest bitmap word with no initialized ticks

**Given:**
- currentTick = -8388400, inside the lowest bitmap word (-32768)
- No initialized ticks at or below currentTick

**Steps:**
1. Operator calls updateTick(-8388600)
2. System checks the start word, finds no set bit at or below the start, finds that the start word is the lowest word, and stops without stepping below it
3. System reports no initialized tick found instead of reverting with an arithmetic panic
4. System stores currentTick = -8388600 and lastOperatorActivityTimestamp = block.timestamp
5. System emits TickUpdated(-8388400, -8388600, 0)

**Outcomes:**
- currentTick is -8388600
- activeLiquidity is unchanged
- The call succeeds: the step before the loop is guarded at the lowest word

**Side Effects:**
- `TickUpdated` event emitted with payload `oldTick=-8388400, newTick=-8388600, ticksCrossed=0`
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No tick state modified

---
