---
id: UC-9BR0
name: Maintain Solvency Totals
feature: FEAT-9BQZ
status: implemented
version: 4
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
2. System computes the scaled claim at 5700 once, before any effect: `3e23 × 8,245,150` USDC-scaled and `3e23 × 300` YES-scaled
3. System debits `totalUsdcOwedScaled` and `totalYesOwedScaled` by those amounts, then pays

**Outcomes:**
- `totalUsdcOwed()` falls by 247,354,500 and `totalYesOwed()` by 90,000,000, exactly what `PositionBurned` reports as `usdcOwed` and `tokenOwed`
- Both totals read zero afterwards, because the position was the only claim
- The debit matches the claim at burn time, not the deposit at mint

**Side Effects:**
- `totalUsdcOwedScaled` and `totalYesOwedScaled` storage: each decreased by the scaled claim
- `noSideLiquidity` storage: unchanged, because the position sat on the YES side of its mint tick at 5700
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)` emitted

---

### SC-9BS6: A merge leaves every total unchanged

**Given:**
- Two live positions of the same Safe over `[5500, 6500)` minted at 6000
- Every total at a known value

**Steps:**
1. Operator calls `mergePositions` for the two positions
2. System sums the liquidity into the survivor and zeroes the consumed record's liquidity

**Outcomes:**
- `totalUsdcOwedScaled`, `totalYesOwedScaled`, and `totalNoOwedScaled` read identically before and after, because the claim is linear in liquidity and both positions share the range and the mint tick

**Side Effects:**
- No total written
- No token transfer
- `PositionsMerged(positionIds, survivorId)` emitted

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

**Side Effects:**
- The three scaled totals storage: back at zero
- `PositionBurned` emitted with the claim at 6120

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
