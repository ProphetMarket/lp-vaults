---
id: UC-9BR1
name: Accumulate Principal Shift
feature: FEAT-9BQZ
status: pending
version: 1
actor: Operator
---

# UC-9BR1: Accumulate Principal Shift

> When the Operator moves the price, the vault records how much principal that move converted between asset sides -- for every span the price traversed, not only the ticks it landed on -- so the principal totals still match what each position is owed after the move.

## Preconditions

- Vault is deployed, initialized, and in the Active phase
- One or more positions are live, so `activeLiquidity` is nonzero across at least part of the traversed span
- Principal totals reflect the pre-move split of every live position

## Trigger

Operator calls `updateTick(newTick)` with a tick different from `currentTick`.

---

### SC-9BS8: Price move crossing several initialized ticks accumulates each segment

**Given:**
- Initialized ticks at several points between the old tick and the new tick
- Different amounts of liquidity active across the spans between them

**Steps:**
1. Operator calls `updateTick` with a new tick beyond the last of those initialized ticks
2. System crosses each initialized tick in turn
3. System accumulates the principal shift for each span as it reaches that span's end
4. System accumulates the remaining span after the last crossing

**Outcomes:**
- Every span between the old tick and the new tick contributes its own shift
- Each span's shift is measured against the liquidity that was actually active across that span, not against the liquidity active at the end of the move
- The principal totals after the move equal the sum of every live position's split at the new price

**Side Effects:**
- Principal totals storage: shifted between assets once per traversed span
- `ticks[T].feeGrowthOutsideX128` storage: flipped at each crossed tick, as before
- `activeLiquidity` storage: adjusted at each crossed tick, as before
- `currentTick` storage: set to the new tick
- No principal created or destroyed in token terms

---

### SC-9BS9: Price move crossing zero initialized ticks still accumulates

**Given:**
- The old tick and the new tick both sit inside the same gap between initialized ticks
- Live positions span that gap, so `activeLiquidity` is nonzero across it

**Steps:**
1. Operator calls `updateTick` with the new tick inside the same gap
2. System finds no initialized tick to cross
3. System accumulates the principal shift for the single span from the old tick to the new tick

**Outcomes:**
- The principal totals change even though no tick was crossed
- The shift matches what the same span would have contributed had it been part of a longer move
- A move inside a gap redistributes the principal of every position spanning it exactly as a longer move does, so treating "crossed nothing" as "changed nothing" would silently understate the conversion

**Side Effects:**
- Principal totals storage: shifted between assets once, for the traversed span
- No tick crossed, so no `feeGrowthOutsideX128` write and no `activeLiquidity` write
- `currentTick` storage: set to the new tick

---

### SC-9BSA: New tick off an initialized tick leaves a nonzero trailing segment

**Given:**
- At least one initialized tick between the old tick and the new tick
- The new tick does not coincide with any initialized tick

**Steps:**
1. Operator calls `updateTick` with that new tick
2. System crosses the initialized ticks in the path
3. System accumulates the trailing span from the last crossed tick to the new tick after the crossing loop ends

**Outcomes:**
- The trailing span contributes a nonzero shift of its own
- The principal totals account for the full distance travelled, not just the distance to the last initialized tick
- Because most moves do not land exactly on an initialized tick, accumulating only inside the crossing loop would be wrong on the common case rather than on an edge case

**Side Effects:**
- Principal totals storage: shifted for each crossed span and once more for the trailing span
- `currentTick` storage: set to the new tick

---

### SC-9BSB: Each segment is accumulated before its tick's liquidity change is applied

**Given:**
- An initialized tick carrying a large liquidity change
- Liquidity active across the span ending at that tick that differs sharply from the liquidity active after it

**Steps:**
1. Operator calls `updateTick` past that tick
2. System accumulates the span ending at the tick, measured against the liquidity active before the tick's change is applied
3. System then applies the tick's liquidity change and continues

**Outcomes:**
- The span's shift reflects the liquidity that was actually active across it
- Applying the tick's liquidity change first would attribute the span to liquidity that was not active across it, and the resulting error is silent -- nothing reverts, no event looks wrong, and the totals simply drift away from what the vault owes
- The principal totals after the move still equal the sum of every live position's split at the new price

**Side Effects:**
- Principal totals storage: shifted using the pre-change active liquidity for that span
- `activeLiquidity` storage: changed only after that span's accumulation

---
