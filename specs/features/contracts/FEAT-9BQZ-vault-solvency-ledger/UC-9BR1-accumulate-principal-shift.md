---
id: UC-9BR1
name: Accumulate Principal Shift
feature: FEAT-9BQZ
status: implemented
version: 3
actor: Operator
---

# UC-9BR1: Accumulate Principal Shift

> When the Operator moves the price, the vault moves the totals for every segment the price traversed, with the liquidity split as it stood in that segment, so the totals still match what each position is owed after the move.

## Preconditions

- Vault is deployed, initialized, and in the Active phase
- One or more positions are live, so `activeLiquidity` is nonzero across at least part of the traversed span
- The totals reflect every live position's claim at the old tick
- Unless a scenario says otherwise, position A is the R9 example: 300 USDC over `[5500, 6500)` minted with the vault at 6000, so `liquidity = 3e23` and `mintTick = 6000`, and tick 6000 is an initialized interior mint tick

## Trigger

Operator calls `updateTick(newTick)` with a tick different from `currentTick`.

---

### SC-9BS8: A move across several initialized ticks accrues each segment with its own split

**Given:**
- Position B: 300 USDC over `[5500, 6000)` minted with the vault at 5800, so `liquidity = 6e23` and `mintTick = 5800`, then the Operator moved the tick to 6000 and minted position A
- At 6000: `totalUsdcOwed()` reads 550,794,000 (300,000,000 for A, 250,794,000 for B's NO band `[5800, 6000)`), `totalNoOwed()` reads 120,000,000, `totalYesOwed()` reads zero, `noSideLiquidity == 3e23` (A only; B is out of range)

**Steps:**
1. Operator calls `updateTick(5700)`
2. System crosses tick 6000 (B's upper bound and A's mint tick) after an empty segment: B enters the range, A moves to the YES side, so `activeLiquidity = 9e23` and `noSideLiquidity = 6e23`
3. System accrues the segment `[5800, 6000)` with that split: A's 200 levels buy YES, B's 200 levels return NO to USDC
4. System crosses tick 5800 (B's mint tick): B moves to the YES side, so `noSideLiquidity = 0`
5. System accrues the trailing segment `[5700, 5800)`: both positions' 100 levels buy YES
6. System writes each changed total once and stores `currentTick = 5700`

**Outcomes:**
- `totalYesOwed()` reads 150,000,000: 90 for A's band `[5700, 6000)` and 60 for B's band `[5700, 5800)`
- `totalNoOwed()` reads zero: B's NO band is gone
- `totalUsdcOwed()` reads 512,857,500: 247,354,500 for A and 265,503,000 for B, each position's claim at 5700
- Each segment's shift used the liquidity that was in range across it, not the split at the end of the move

**Side Effects:**
- `totalUsdcOwedScaled`, `totalYesOwedScaled`, `totalNoOwedScaled` storage: each written once with the sum of its segment deltas
- `activeLiquidity` storage: 9e23; `noSideLiquidity` storage: 0
- `currentTick` storage: 5700
- `TickUpdated(6000, 5700, 2)` emitted

---

### SC-9BS9: A move that crosses no tick still moves the totals

**Given:**
- Position A alone, the vault at 6000, `totalUsdcOwed() == 300,000,000`

**Steps:**
1. Operator calls `updateTick(6300)`
2. System finds no initialized tick in `(6000, 6300]`
3. System accrues the one segment `[6000, 6300)` with `noSideLiquidity == 3e23`: 300 levels buy NO at `1 − t / 10000`
4. Operator calls `updateTick(6100)`
5. System finds no initialized tick in `(6100, 6300]` and accrues the segment `[6100, 6300)` in reverse

**Outcomes:**
- After the first move `totalNoOwed()` reads 90,000,000 and `totalUsdcOwed()` reads 265,345,500, the claim of SC-7G45
- After the second move `totalNoOwed()` reads 30,000,000 and `totalUsdcOwed()` reads 288,148,500, the claim at 6100
- A move inside a gap redistributes the principal of every position spanning it exactly as a longer move does

**Side Effects:**
- `totalNoOwedScaled` and `totalUsdcOwedScaled` storage: shifted once per call
- No tick crossed, so no `activeLiquidity` write and no `noSideLiquidity` write
- `TickUpdated(6000, 6300, 0)` then `TickUpdated(6300, 6100, 0)` emitted

---

### SC-9BSA: A move that ends between ticks accrues its trailing segment

**Given:**
- The two positions of SC-9BS8 at 6000

**Steps:**
1. Operator calls `updateTick(5750)`
2. System crosses 6000 and 5800 as in SC-9BS8 and accrues `[5800, 6000)`
3. System accrues the trailing segment `[5750, 5800)` after the loop, with both positions on the YES side

**Outcomes:**
- `totalYesOwed()` reads 105,000,000: 75 for A's band `[5750, 6000)` and 30 for B's band `[5750, 5800)`
- `totalUsdcOwed()` reads 538,617,750: 255,941,250 for A and 282,676,500 for B
- Without the trailing segment the totals would stop at the values for 5800 (60,000,000 YES and 564,603,000 USDC), which no position's claim matches

**Side Effects:**
- The totals storage: shifted for each crossed segment and once more for the trailing segment
- `currentTick` storage: 5750
- `TickUpdated(6000, 5750, 2)` emitted

---

### SC-9BSB: Each segment is accrued before its tick's liquidity change is applied

**Given:**
- Position A alone, the vault at 6000

**Steps:**
1. Operator calls `updateTick(5400)`
2. System crosses tick 6000 after an empty segment, so `noSideLiquidity = 0`
3. System accrues the segment `[5500, 6000)` against `activeLiquidity == 3e23`, then crosses tick 5500, which takes `activeLiquidity` to zero
4. System skips the trailing segment `[5400, 5500)`, because nothing is in range across it

**Outcomes:**
- `totalYesOwed()` reads 150,000,000 and `totalUsdcOwed()` reads 213,757,500, the claim of a position whose whole range the price fell through
- Applying the tick's `liquidityNet` first would attribute the segment to zero liquidity and leave the totals at their mint values, a silent drift that no event shows

**Side Effects:**
- `totalYesOwedScaled` and `totalUsdcOwedScaled` storage: shifted for `[5500, 6000)` only
- `activeLiquidity` storage: 0, written after the segment's accrual
- `TickUpdated(6000, 5400, 2)` emitted

---

### SC-COEQ: Three chunks equal one call, and a reversal restores the mint totals

**Given:**
- Position A alone, the vault at 6000, the three scaled totals at their mint values

**Steps:**
1. Operator calls `updateTick(5700)` and the totals read the SC-7G44 claim
2. Operator calls `updateTick(6000)`
3. Operator calls `updateTick(5900)`, then `updateTick(5750)`, then `updateTick(5700)`

**Outcomes:**
- After step 2 `totalUsdcOwedScaled` reads its mint value and `totalYesOwedScaled` reads zero
- After step 3 `totalUsdcOwedScaled` and `totalYesOwedScaled` read exactly the values after step 1
- `totalUsdcOwed()` reads 247,354,500 and `totalYesOwed()` reads 90,000,000, the truncated getters

**Side Effects:**
- The totals storage: shifted on every call, with no rounding between the chunks, because every product is exact in the scaled unit
- `TickUpdated` emitted on every call

---

### SC-COER: A mint tick is crossed like a boundary

**Given:**
- Position A alone, the vault at 6000, `noSideLiquidity == 3e23`

**Steps:**
1. Operator calls `updateTick(5990)`
2. System crosses tick 6000, an interior mint tick with `liquidityGross == 3e23`, `liquidityNet == 0`, and `noLiquidityNet == 3e23`
3. Operator calls `updateTick(6000)`

**Outcomes:**
- After step 1 `noSideLiquidity` reads zero and `activeLiquidity` still reads 3e23: the position stays in range and moves to the YES side
- After step 3 `noSideLiquidity` reads 3e23 again
- `TickUpdated.ticksCrossed` counts the mint tick each time

**Side Effects:**
- `noSideLiquidity` storage: 0 after step 1, 3e23 after step 3
- `TickUpdated(6000, 5990, 1)` then `TickUpdated(5990, 6000, 1)` emitted

---

### SC-COES: A clamped mint enters the range on the side its mint tick gives

**Given:**
- The Operator reported tick 5000 before the mint, so position A holds `mintTick = 5500` and is out of range, with `noSideLiquidity == 0` and `activeLiquidity == 0`
- Tick 5500 holds `noLiquidityNet == 3e23` and tick 6500 holds `noLiquidityNet == −3e23`; no interior mint tick exists, because the mint tick equals the lower bound

**Steps:**
1. Operator calls `updateTick(5800)`
2. System skips the segment `[5000, 5500)`, because nothing is in range across it
3. System crosses tick 5500: `activeLiquidity = 3e23` and `noSideLiquidity = 3e23`
4. System accrues the trailing segment `[5500, 5800)` with every level on the NO side

**Outcomes:**
- `totalNoOwed()` reads 90,000,000 and `totalUsdcOwed()` reads 260,845,500, the SC-BMF3 claim
- A mint below its range holds an empty YES side and a NO side that is the whole range, and the clamp is what keeps the two sub-ranges a partition of the range

**Side Effects:**
- `totalNoOwedScaled` and `totalUsdcOwedScaled` storage: shifted for `[5500, 5800)`
- `activeLiquidity` and `noSideLiquidity` storage: 3e23
- `TickUpdated(5000, 5800, 1)` emitted

---
