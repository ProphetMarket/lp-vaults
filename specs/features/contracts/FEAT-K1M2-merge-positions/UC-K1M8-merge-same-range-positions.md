---
id: UC-K1M8
name: Merge Same-Range Positions
feature: FEAT-K1M2
status: implemented
version: 1
actor: Operator
---

# UC-K1M8: Merge Same-Range Positions

> Operator combines two or more LP positions that share the same owner, tickLower, and tickUpper into a single position, preserving total liquidity and accrued fees.

## Preconditions

- Vault is initialized and in Active phase
- At least two positions exist with the same owner, tickLower, and tickUpper

## Trigger

Operator calls `mergePositions(uint256[] calldata positionIds)` on the vault.

---

### SC-K1M9: Successful merge of two same-range positions

**Given:**
- Two positions owned by the same LP with range [0, 100), each with 500 liquidity
- Fees have been distributed via `notifyFees`

**Steps:**
1. Operator calls `mergePositions([posA, posB])`
2. System validates all positions share the same owner, tickLower, and tickUpper
3. System computes accrued fees for both positions
4. System sums liquidity into the first position (posA)
5. System zeroes the consumed position (posB)

**Outcomes:**
- posA.liquidity == 1000 (sum of both)
- posB.liquidity == 0

**Side Effects:**
- `PositionsMerged(uint256[] positionIds, uint256 survivorId)` event emitted
- Tick `liquidityGross` unchanged (net liquidity on the range is the same)
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
