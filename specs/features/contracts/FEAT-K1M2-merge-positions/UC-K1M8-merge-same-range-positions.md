---
id: UC-K1M8
name: Merge Same-Range Positions
feature: FEAT-K1M2
status: implemented
version: 3
actor: Operator
---

# UC-K1M8: Merge Same-Range Positions

> Operator combines two or more LP positions that share the same owner, tickLower, tickUpper, and mint tick into a single position, preserving total liquidity and accrued fees. This merge joins LP position records. It is not the complete-set merge of YES and NO tokens into USDC, which is `mergeCompleteSets()` (decision C26, audit-fix step R9).

## Preconditions

- Vault is initialized and in Active phase
- At least two positions exist with the same owner, tickLower, tickUpper, and mintTick, and the call names each of them once

## Trigger

Operator calls `mergePositions(uint256[] calldata positionIds)` on the vault.

---

### SC-K1M9: Successful merge of two same-range positions

**Given:**
- Two positions owned by the same LP with range [0, 100), each with 500 liquidity, both minted at currentTick = 0, so both hold mintTick = 0
- Fees have been distributed via `notifyFees`

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. System checks that no position ID repeats in the array
3. System validates all positions share the same owner, tickLower, tickUpper, and mintTick
4. System computes accrued fees for both positions
5. System sums liquidity into the first position (posA)
6. System zeroes the consumed position (posB)

**Outcomes:**
- posA.liquidity == 1000 (sum of both)
- posB.liquidity == 0

**Side Effects:**
- `PositionsMerged(uint256[] positionIds, uint256 survivorId)` event emitted
- Tick `liquidityGross` unchanged (net liquidity on the range is the same)
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful merge is proof the Operator is alive (FEAT-JXQO)
- No USDC transferred (fees rolled into tokensOwed on survivor)

---

### SC-K1MA: Revert on mismatched ranges

**Given:**
- Two positions with different tick ranges (posA: [0, 100), posB: [0, 200))

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. System validates ranges match
3. System reverts

**Outcomes:**
- Transaction reverts with range mismatch error

**Side Effects:**
- No state change
- No event emitted

---

### SC-K1MB: Revert on empty or single-item input

**Given:**
- positionIds array has 0 or 1 elements

**Steps:**
1. Operator calls `mergePositions([])` or `mergePositions([posA])`
2. System validates at least two positions provided
3. System reverts

**Outcomes:**
- Transaction reverts with insufficient positions error

**Side Effects:**
- No state change
- No event emitted

---

### SC-AFPQ: Revert on a repeated position ID

**Given:**
- Position posA owned by an LP over [0, 100) with liquidity L

**Steps:**
1. Operator calls `mergePositions([posA, posA])`
2. System compares every pair of IDs and finds index 0 equal to index 1, before it reads any position
3. System reverts

**Outcomes:**
- Transaction reverts with `DuplicatePositionId`
- posA still holds liquidity L
- Before this change the call wrote 2L into posA with no new capital (audit issue 6.14)

**Side Effects:**
- No state change
- No event emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-AFPR: Revert on a different mint tick

**Given:**
- posA over [0, 100) minted at currentTick = 0, so mintTick = 0
- The Operator then called updateTick(50)
- posB over [0, 100) minted at currentTick = 50, so mintTick = 50
- Both owned by the same LP

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. System finds the IDs distinct and the owner and range equal
3. System finds posB.mintTick (50) different from posA.mintTick (0)
4. System reverts

**Outcomes:**
- Transaction reverts with `MintTickMismatch`
- Both positions unchanged
- Under the claim model (C26) the two positions hold different assets, so one record cannot represent both

**Side Effects:**
- No state change
- No event emitted

---

### SC-K1MC: Fee accounting preserved after merge

**Given:**
- Two positions with different accrued fees (posA has accrued ~300 USDC, posB has accrued ~200 USDC)
- Both positions share the same range and owner

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. System computes uncollected fees for each position
3. System rolls all uncollected fees into the survivor's tokensOwed
4. System sets the survivor's feeGrowthInsideLastX128 to the current value

**Outcomes:**
- Survivor's tokensOwed includes both positions' accrued fees (~500 total)
- Survivor's feeGrowthInsideLastX128 is set to the current feeGrowthInside value
- Subsequent collect on survivor returns the correct total

**Side Effects:**
- No fees lost
- No double-counting possible on next collect

---

### SC-3XUP: Successful merge refreshes the Operator silence timer

**Given:**
- Vault is in Active phase with two same-range positions owned by the same LP
- `lastOperatorActivityTimestamp` is old enough that the emergency-cancel timelock would otherwise be within reach

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. The merge completes as in SC-K1M9
3. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`

**Outcomes:**
- `lastOperatorActivityTimestamp == block.timestamp`
- Position housekeeping now counts as proof of life, where previously it did not

**Side Effects:**
- All the normal side effects of a successful merge (SC-K1M9)
- `lastOperatorActivityTimestamp` storage refreshed

---

### SC-3XUQ: Reverted merge leaves the Operator silence timer untouched

**Given:**
- Vault is in Active phase
- `lastOperatorActivityTimestamp` holds some earlier value T

**Steps:**
1. Operator calls `mergePositions` with input that fails validation -- for example mismatched ranges (SC-K1MA), a single-item array (SC-K1MB), a repeated ID (SC-AFPQ), or a different mint tick (SC-AFPR)
2. The whole transaction reverts

**Outcomes:**
- The call reverts with the relevant error
- `lastOperatorActivityTimestamp` is still T -- a failed call is not proof of life

**Side Effects:**
- No state changes at all
- No events emitted

---
