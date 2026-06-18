---
id: UC-U07A
name: Collect Position Fees
feature: FEAT-U079
status: implemented
version: 1
actor: LP
---

# UC-U07A: Collect Position Fees

> LP withdraws accumulated trading fees from their position without removing it.

## Preconditions

- Vault is initialized and in Active or WindDown phase
- LP has an existing position with a valid positionId
- The vault's fee accumulators (feeGrowthGlobalX128, per-tick feeGrowthOutsideX128) reflect the current fee state

## Trigger

LP calls `collect(positionId)`.

---

### SC-U07B: First collect with accrued fees

**Given:**
- LP has a position where tickLower <= currentTick < tickUpper (in range)
- At least one notifyFees call has occurred since the position was minted
- feeGrowthInsideX128 > position.feeGrowthInsideLastX128

**Steps:**
1. LP calls collect(positionId)
2. System verifies caller is position.owner
3. System computes feeGrowthInsideX128 for [tickLower, tickUpper]
4. System calculates owed = liquidity * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128
5. System sets position.feeGrowthInsideLastX128 = feeGrowthInsideX128
6. System transfers owed USDC to the LP via inline _safeTransfer

**Outcomes:**
- LP receives owed amount in USDC
- Position remains active with updated fee snapshot

**Side Effects:**
- `FeesCollected(positionId, owner, amount)` event emitted
- Position storage: `feeGrowthInsideLastX128` updated to current `feeGrowthInsideX128`
- USDC balance: vault decreases by `amount`, LP increases by `amount`
- No position deletion or liquidity change

---

### SC-U07C: Zero fees owed

**Given:**
- LP has a position
- No notifyFees calls since mint (or last collect)
- feeGrowthInsideX128 == position.feeGrowthInsideLastX128

**Steps:**
1. LP calls collect(positionId)
2. System verifies caller is position.owner
3. System computes feeGrowthInsideX128 (equals feeGrowthInsideLastX128)
4. System calculates owed = 0

**Outcomes:**
- LP receives no USDC
- Transaction succeeds without revert

**Side Effects:**
- No USDC transfer
- No FeesCollected event emitted
- Position snapshot unchanged (same value written)

---

### SC-U07D: Non-owner caller rejected

**Given:**
- A valid position exists owned by LP address A
- Caller is address B (B != A)

**Steps:**
1. Address B calls collect(positionId)
2. System checks caller != position.owner

**Outcomes:**
- Transaction reverts with NotPositionOwner error

**Side Effects:**
- No state changes
- No USDC transfer

---

### SC-U07E: Position not found

**Given:**
- positionId does not correspond to any existing position

**Steps:**
1. Caller calls collect(positionId)
2. System looks up position storage

**Outcomes:**
- Transaction reverts with PositionNotFound error

**Side Effects:**
- No state changes

---

### SC-U07F: Collect during wind-down

**Given:**
- Vault phase is WindDown (market has resolved)
- LP has a position with accumulated fees from before wind-down

**Steps:**
1. LP calls collect(positionId)
2. System verifies caller is position.owner
3. System computes fees using the same logic as Active phase
4. System transfers owed USDC to the LP

**Outcomes:**
- LP receives owed USDC despite vault being in WindDown
- Position remains active with updated fee snapshot

**Side Effects:**
- `FeesCollected(positionId, owner, amount)` event emitted
- Position storage: `feeGrowthInsideLastX128` updated
- USDC transferred from vault to LP
- No vault phase change

---

### SC-U07G: Second collect only pays new fees

**Given:**
- LP has a position that was collected previously at feeGrowthInsideX128 = G1
- Additional fees have been distributed via notifyFees, feeGrowthInsideX128 is now G2 (G2 > G1)

**Steps:**
1. LP calls collect(positionId) a second time
2. System computes current feeGrowthInsideX128 = G2
3. System calculates owed = liquidity * (G2 - G1) / Q128
4. System updates snapshot to G2 and transfers owed USDC

**Outcomes:**
- LP receives only fees accrued between the two collects (G2 - G1), not total lifetime fees
- The snapshot ensures any future collect starts from G2

**Side Effects:**
- `FeesCollected(positionId, owner, newFeesOnly)` event emitted
- Position storage: `feeGrowthInsideLastX128` updated from G1 to G2
- USDC transfer reflects only the delta, proving no double-counting
- No previous collect's fees are re-paid

---
