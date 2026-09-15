---
id: UC-9BR0
name: Maintain Solvency Totals
feature: FEAT-9BQZ
status: implemented
version: 5
actor: Operator
---

# UC-9BR0: Maintain Solvency Totals

> Every vault operation that changes what the vault owes moves the matching scaled total in the same call, so the ledger answers what the vault owes, per asset, at any moment without iterating a position.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`yesTokenId`, `noTokenId`)
- The vault's phase is Active unless a scenario states otherwise
- The three scaled totals and the three truncating getters are readable through public views
- USDC and every outcome token have six decimals in every amount below

## Trigger

Any vault operation that creates, discharges, or transforms an obligation: a mint, a burn, a merge, or a freeze. A tick move is the trigger of UC-9BR1.

Since R18 the ledger carries a fourth total, `totalSpreadOwedX128`, and two of these operations touch it. A mint and a burn credit the measured spread before anything else, so a vault holding more USDC than the ledger owes turns that surplus into an obligation (FEAT-E943 UC-E944). A burn whose debit takes `totalUsdcOwedScaled` to zero is the last live position's burn and also sweeps the residue (FEAT-E943 FR-E94C). `PositionBurned` carries nine fields, with `spreadOwed` and `spreadPaid` after `usdcPaid`.

---

### SC-9BRZ: Mint credits the USDC total by the whole deposit

**Given:**
- Every total is zero
- The Operator reported tick 6000 and escrowed 300 USDC for a Safe's intent over `[5500, 6500)`

**Steps:**
1. Operator calls `mintPositionFor` for the intent
2. System creates the position with `liquidity = 3e23` and `mintTick = 6000`
3. System raises `totalUsdcOwedScaled` by `3e23 × 1000 × 10000`

**Outcomes:**
- `totalUsdcOwed()` reads 300,000,000, the whole deposit
- `totalYesOwed()` and `totalNoOwed()` read zero, because the band is empty at the mint
- Reading a total costs no iteration over `positions`

**Side Effects:**
- `totalUsdcOwedScaled` storage: increased by `3e23 × 10,000,000`
- `noSideLiquidity` storage: increased by `3e23`, because an in-range mint enters on the NO side (`mintTick == currentTick`)
- No token total written
- No price or oracle read

---

### SC-9BS0: Burn debits the totals by the claim at the current tick

**Given:**
- The position of SC-9BRZ is live and the Operator moved the tick to 5700, so `totalUsdcOwed()` reads 247,354,500 and `totalYesOwed()` reads 90,000,000 (UC-9BR1)
- The vault holds 90 YES

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System measures the surplus, `300,000,000 − 247,354,500 = 52,645,500` units, because the vault still holds the whole deposit and its 90 YES cover what it owes, and credits 52,645,499 of it to the only liquidity in range, one unit below the measurement because the growth is floored per unit of liquidity
3. System computes the scaled claim at 5700 once, before any other effect: `3e23 × 8,245,150` USDC-scaled and `3e23 × 300` YES-scaled
4. System debits `totalUsdcOwedScaled`, `totalYesOwedScaled`, and `totalSpreadOwedX128` by the full scaled amounts, then pays

**Outcomes:**
- `totalUsdcOwed()` falls by 247,354,500 and `totalYesOwed()` by 90,000,000, exactly what `PositionBurned` reports as `usdcOwed` and `tokenOwed`
- The Safe receives 300,000,000 USDC units in one transfer: the principal, the 52,645,499 of credited spread, and the one unit the closing sweep carries. It also receives its 90 YES
- All four totals read zero afterwards, because the position was the only claim
- The debit matches the claim at burn time, not the deposit at mint

**Side Effects:**
- `totalUsdcOwedScaled` and `totalYesOwedScaled` storage: each decreased by the scaled claim; `totalSpreadOwedX128` decreased by the position's full X128 spread, to zero
- `noSideLiquidity` storage: unchanged, because the position sat on the YES side of its mint tick at 5700
- `SpreadCredited(52645499, spreadGrowthGlobalX128)`, then `ResidueSwept(positionId, safe, 1, 0, 0)` because this burn takes the USDC total to zero and the growth floor left one unit, then `PositionBurned(positionId, safe, 247354500, 247354500, 52645499, 52645499, yesTokenId, 90000000, 90000000)` emitted

---

### SC-9BS6: A merge leaves the principal totals unchanged and debits the spread dust

**Given:**
- Two live positions of the same Safe over `[5500, 6500)` minted at 6000, with liquidity `L_a` and `L_b`
- Every total at a known value, and each position holding its own spread claim `x_a` and `x_b` in X128 units, because the two were minted at different moments

**Steps:**
1. Operator calls `mergePositions` for the two positions
2. System sums the liquidity into the survivor and zeroes the consumed record's liquidity
3. System computes both spread claims, writes the survivor's snapshot as `inside − floor((x_a + x_b) ÷ (L_a + L_b))`, and zeroes the consumed record's snapshot
4. System debits `totalSpreadOwedX128` by the dust the floor dropped

**Outcomes:**
- `totalUsdcOwedScaled`, `totalYesOwedScaled`, and `totalNoOwedScaled` read identically before and after, because the principal claim is linear in liquidity and both positions share the range and the mint tick
- The survivor's spread claim equals `x_a + x_b` less a dust below `L_a + L_b` X128 units, which is below one USDC unit
- `totalSpreadOwedX128` fell by exactly that dust, so the fourth total still equals the sum of live claims

**Side Effects:**
- One total written, `totalSpreadOwedX128`; no principal total written
- No token transfer
- `PositionsMerged(positionIds, survivorId)` emitted, and no `SpreadCredited`

---

### SC-9BS7: Opposing bands are reported separately, never netted

**Given:**
- One position minted at 6000 over `[5500, 6500)` with the vault later at 5700, whose band holds YES
- One position minted at 5500 over `[5500, 6500)` (the Operator reported 5000 before its mint) with the vault at 5700, whose band holds NO
- The vault holds neither token in the amounts the positions are owed

**Steps:**
1. An observer reads `totalYesOwed()` and `totalNoOwed()`

**Outcomes:**
- `totalYesOwed()` reads 90,000,000 and `totalNoOwed()` reads 60,000,000, each in full, and neither is reduced by the other
- Under a single signed net the two would partly cancel and a vault holding neither token would look covered

**Side Effects:**
- No storage written; both reads are views
- No price or valuation read

---

### SC-COEO: A mint and its burn cancel exactly with a deposit that does not divide by the width

**Given:**
- Every total is zero and the Operator reported tick 6000
- A Safe's intent for 123,456,789 units over `[5500, 6500)`, so `liquidity = 123,456,789 × 1e18 / 1000` truncates

**Steps:**
1. Operator mints the intent
2. Operator moves the tick to 5713, then to 6120
3. The Safe burns the position

**Outcomes:**
- `totalUsdcOwedScaled` reads zero after the burn, exactly where it started
- `totalYesOwedScaled` and `totalNoOwedScaled` read zero
- A ledger held in truncated units would have drifted by up to one unit per booking; the scaled unit cancels exactly (FR-9BR4)
- The burn credits nothing: at 6120 the claim's band is NO, the vault holds no NO, and the token-cover check withholds every credit while a token balance is short (FEAT-E943 FR-E948)
- The Safe receives its whole 123,456,789 units back: the burn pays `usdcOwed` at a ratio of 1, and the closing sweep pays the rest, because no fill ever happened and this is the only position

**Side Effects:**
- The four scaled totals storage: back at zero
- No `SpreadCredited`
- `ResidueSwept(positionId, safe, usdcResidue, 0, 0)` emitted, carrying the USDC the claim at 6120 did not name, then `PositionBurned` with the claim at 6120 and `spreadOwed = spreadPaid = 0`

---

### SC-COEP: The freeze leaves every total unchanged

**Given:**
- Two live positions, one in range on the NO side of its mint tick
- The three scaled totals and `noSideLiquidity` at known nonzero values
- The Operator has been silent for the vault's emergency-cancel timelock

**Steps:**
1. Any address calls `emergencyCancelAll`
2. System sets the phase to Cancelled and changes nothing else (FEAT-JXQO FR-JXQP)

**Outcomes:**
- `totalUsdcOwedScaled`, `totalYesOwedScaled`, `totalNoOwedScaled`, and `noSideLiquidity` read as before
- A burn after the freeze debits the totals as in Active phase

**Side Effects:**
- `phase` storage: set to 3
- No total written
- No `noSideLiquidity` write
- `EmergencyCancelExecuted(caller)` emitted

---
