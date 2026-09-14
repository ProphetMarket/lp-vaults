---
id: UC-U07A
name: Collect Position Fees
feature: FEAT-U079
status: implemented
version: 5
actor: LP
---

# UC-U07A: Collect Position Fees

> LP withdraws accumulated trading fees from their position without removing it.

## Preconditions

- Vault is initialized, in any phase
- LP's Safe has an existing position with a valid positionId
- The vault's fee accumulators (feeGrowthGlobalX128, per-tick feeGrowthOutsideX128) reflect the current fee state

## Trigger

The LP's Safe calls `collect(positionId)`.

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
- `FeesCollected(positionId, owner, amount, amount)` event emitted
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
- `FeesCollected(positionId, owner, amount, amount)` event emitted
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
- `FeesCollected(positionId, owner, newFeesOnly, newFeesOnly)` event emitted
- Position storage: `feeGrowthInsideLastX128` updated from G1 to G2
- USDC transfer reflects only the delta, proving no double-counting
- No previous collect's fees are re-paid

---

### SC-8L1D: Immediate collect on a wrapped snapshot owes zero

**Given:**
- The state of "Mint over a stale shared tick succeeds" (SC-8L1C in UC-T7AG) after the mint: LP holds P3 = [50, 100) with feeGrowthInsideLastX128 = 2^256 - (G2 - G1), currentTick = 150, feeGrowthGlobalX128 = G2
- No notifyFees call since the mint

**Steps:**
1. LP calls collect(P3)
2. System verifies caller is position.owner
3. System computes feeGrowthInsideX128 = G2 - G2 - (G2 - G1) inside `unchecked`, which equals the snapshot
4. System calculates owed = liquidity * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128 inside `unchecked` = 0

**Outcomes:**
- LP receives no USDC
- Transaction succeeds without revert

**Side Effects:**
- No USDC transfer
- No FeesCollected event emitted
- Position snapshot unchanged (same value written)

---

### SC-8L1E: Collect after the price re-enters the wrapped range pays growth since mint

**Given:**
- The state of "Mint over a stale shared tick succeeds" (SC-8L1C in UC-T7AG) after the mint
- The Operator called updateTick(75), which crossed tick 100 right-to-left and set ticks[100].feeGrowthOutsideX128 = G2 - G1, so P1 = [0, 300) and P3 = [50, 100) are in range
- The Operator called notifyFees(F), so feeGrowthGlobalX128 = G3 = G2 + F * Q128 / (L1 + L3), where L1 and L3 are the liquidity of P1 and P3

**Steps:**
1. LP calls collect(P3)
2. System verifies caller is position.owner
3. System computes feeGrowthInsideX128 = G3 - G2 - (G2 - G1) inside `unchecked`
4. System calculates owed = L3 * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128 inside `unchecked` = L3 * (G3 - G2) / Q128, because both operands wrapped by the same offset
5. System sets position.feeGrowthInsideLastX128 = feeGrowthInsideX128
6. System transfers owed USDC to the LP

**Outcomes:**
- LP receives exactly L3 * (G3 - G2) / Q128 USDC, the growth since the mint and nothing else

**Side Effects:**
- `FeesCollected(P3, owner, owed, owed)` event emitted
- Position storage: `feeGrowthInsideLastX128` updated
- USDC balance: vault decreases by `owed`, LP increases by `owed`

---

### SC-BMFD: Collect in the Cancelled phase pays the accrued fees

**Given:**
- Any address called `emergencyCancelAll` after the timelock, so the vault phase is Cancelled (3) and every position keeps its liquidity and its fee snapshot
- The Safe owns a position with 499 USDC of accrued fees (500 reported over its liquidity, rounded down)

**Steps:**
1. The Safe calls collect(positionId)
2. System applies no phase check and verifies the caller is position.owner
3. System computes the fees owed from the intact record, merges any pairs, and pays the Safe

**Outcomes:**
- Transaction succeeds
- The Safe receives 499 USDC, the same amount as the identical collect in Active phase

**Side Effects:**
- USDC transferred to the Safe
- `FeesCollected(positionId, safe, 499, 499)` emitted
- `tokensOwed == 0` and the snapshot advanced
- No phase change

---

### SC-BMFE: Collect merges the vault's pairs first

**Given:**
- The Safe's in-range position has accrued F > 0 in fees
- The vault holds 50 YES and 50 NO from earlier round trips

**Steps:**
1. The Safe calls collect(positionId)
2. System computes owed = F and reads both token balances
3. System writes the snapshot, then merges the 50 pairs through the ConditionalTokens contract
4. System transfers F USDC to the Safe

**Outcomes:**
- The vault holds 0 YES and 0 NO after the call
- LP receives F in USDC

**Side Effects:**
- `CompleteSetsMerged(safe, 50)` emitted before `FeesCollected(positionId, safe, F, F)` in the log
- `PositionsMerge` emitted by ConditionalTokens
- USDC balance: vault gains 50 from the merge and pays F

---

### SC-COEZ: Collect pays its share and settles

**Given:**
- The Safe's position is owed 10 USDC in fees
- Case A: the USDC ratio is 0.4, because the vault holds above `totalEscrowed` 40 percent of `totalUsdcOwed() + totalFeesOwed()` (FEAT-9BQZ FR-9BRM)
- Case B: the vault's USDC balance is below `totalEscrowed`

**Steps:**
1. The Safe calls collect(positionId)
2. System computes owed = 10 and the USDC ratio, 0.4 (case A) or 0 (case B)
3. System writes the snapshot, sets `tokensOwed` to zero, and debits `totalFeesOwedX128` by the full scaled claim
4. System transfers the paid amount, when it is above zero, and emits the event with both amounts

**Outcomes:**
- Case A: LP receives 4 USDC, `tokensOwed == 0`, and a later collect owes only the fees that grew since
- Case B: LP receives nothing, the call does not revert, and `tokensOwed == 0`
- The cut is final (ADR-COEN in FEAT-9BQZ): the call never reverts on the comparison, and escrowed USDC is never paid (decision C7)

**Side Effects:**
- Case A: `FeesCollected(positionId, safe, 10, 4)` emitted; position storage: `tokensOwed = 0`, `feeGrowthInsideLastX128` updated
- Case B: `FeesCollected(positionId, safe, 10, 0)` emitted, no USDC transfer; position storage: `tokensOwed = 0`, `feeGrowthInsideLastX128` updated
- `totalFeesOwedX128` storage: decreased by the full scaled fee claim in both cases
- `totalEscrowed` unchanged

---
