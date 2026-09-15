---
id: UC-6HBO
name: Merge Complete Sets
feature: FEAT-6HBN
status: implemented
version: 4
actor: Any Wallet
---

# UC-6HBO: Merge Complete Sets

> Any wallet turns the vault's matched YES and NO tokens into USDC held by the vault.

## Preconditions

- The vault was created with a verified outcome-token identity (UC-REQ1), so `conditionId`, `yesTokenId`, and `noTokenId` name its market

## Trigger

Any wallet calls `mergeCompleteSets()` on the vault, usually the keeper after fills.

Since R18 the call also reads the vault's USDC balance and credits the measured spread to the liquidity in range before it merges (FEAT-E943 UC-E944). The scenarios below assert the merge; UC-E944 asserts what the credit computes. A scenario whose vault holds no live position in range writes no growth and emits no `SpreadCredited`, and its surplus stays measurable for the next credit that finds liquidity (FEAT-E943 FR-E949). A scenario that does hold one names the credit in its side effects, because a donated or earned USDC balance above what the ledger owes is exactly what the measurement is for.

---

### SC-6HC9: Any wallet merges the vault's matched pairs into USDC

**Given:**
- The vault is in Active phase
- The vault holds 100 YES, 60 NO, and B USDC
- No live position holds a band, so `totalYesOwed()` and `totalNoOwed()` are both 0

**Steps:**
1. A wallet calls `mergeCompleteSets()`
2. The vault reads its YES and NO balances on the ConditionalTokens contract and the two owed totals
3. The vault computes the free pairs, `amount = min(100 − 0, 60 − 0) = 60`
4. The vault reads its USDC balance, computes the surplus above escrow, above the principal it owes, and above the spread it already credited, counting the 60 pairs as USDC, and credits it to the liquidity in range (FEAT-E943 FR-E945, FR-E946)
5. The vault calls `mergePositions(usdc, bytes32(0), conditionId, [1, 2], 60)`
6. ConditionalTokens burns 60 YES and 60 NO and transfers 60 USDC to the vault

**Outcomes:**
- The vault holds 40 YES, 0 NO, and B + 60 USDC
- The caller's balances do not change

**Side Effects:**
- `SpreadCredited(amount, spreadGrowthGlobalX128)` emitted before `CompleteSetsMerged(caller, 60)`, when the surplus is above zero and liquidity is in range
- `CompleteSetsMerged(caller, 60)` emitted by the vault
- `PositionsMerge` emitted by ConditionalTokens
- No receiver hook runs, because a burn calls no hook
- `spreadGrowthGlobalX128` and `totalSpreadOwedX128` written when the surplus is above zero, and nothing else: phase, positions, ticks, and `lastOperatorActivityTimestamp` keep their values

---

### SC-DFDV: The merge leaves every claim's band token in the vault

**Given:**
- The vault is in Active phase and holds B USDC before any fill
- Safe A holds the R9 example (300 USDC over `[5500, 6500)`, `liquidity = 3e23`) minted at 6000, and Safe B holds the same range minted at 5500
- The keeper's drift-free fills moved the vault to 5700: the fall to 5500 bought 150 YES for 86,242,500 USDC units on A's levels, and the rise to 5700 bought 60 NO on A's levels and 60 NO on B's for 52,806,000 units
- The vault holds 150 YES, 120 NO, and B + 460,951,500 USDC units, and the ledger owes 90 YES (A), 60 NO (B), and 520,951,500 USDC

**Steps:**
1. Any wallet calls `mergeCompleteSets()`
2. The vault computes the free pairs `min(150 − 90, 120 − 60) = 60`
3. The vault merges 60 pairs

**Outcomes:**
- The vault holds 90 YES, 60 NO, and B + 520,951,500 USDC: above B, exactly what the ledger owes
- A second call merges nothing
- Both positions are in range at 5700, so the call also credits everything the vault holds above what the ledger owes, which here is the donated base B plus the fills' margin, to A and B in proportion to their liquidity (FEAT-E943 FR-E946). A second call credits nothing, because the first one made the surplus owed

**Side Effects:**
- `SpreadCredited(amount, spreadGrowthGlobalX128)` emitted once, before `CompleteSetsMerged`
- `CompleteSetsMerged(caller, 60)` emitted once
- `spreadGrowthGlobalX128` and `totalSpreadOwedX128` written; no other vault storage written

---

### SC-DFDW: A donated token merges nothing when no pair is free

**Given:**
- The vault at 5700 holds one R9 position minted at 6000, so the ledger owes 90 YES, and the vault holds exactly 90 YES and 0 NO from the keeper's drift-free fill
- A stranger sends 50 NO to the vault through the receiver hook

**Steps:**
1. The stranger calls `mergeCompleteSets()`
2. The vault computes the free pairs `min(90 − 90, 50 − 0) = 0`

**Outcomes:**
- No `mergePositions` call and no `CompleteSetsMerged` event
- The vault still holds 90 YES and 50 NO
- The position's burn pays the 90 YES in full
- The position is in range at 5700 and both token balances cover their owed totals, so the call still credits the USDC the vault holds above what the ledger owes, the donated base B plus the fall's margin (FEAT-E943 FR-E946). The donated 50 NO is not credited, because a token is not USDC and no pair is free

**Side Effects:**
- `SpreadCredited(amount, spreadGrowthGlobalX128)` emitted, and `spreadGrowthGlobalX128` and `totalSpreadOwedX128` written
- No `mergePositions` call and no `CompleteSetsMerged` event

---

### SC-6HCA: Nothing to merge changes nothing

**Given:**
- The vault is in Active phase
- Case A: the vault holds 50 YES and 0 NO
- Case B: the vault holds 0 YES and 0 NO

**Steps:**
1. A wallet calls `mergeCompleteSets()`
2. The vault reads both balances and computes `amount = 0`

**Outcomes:**
- The call does not revert
- The vault's YES, NO, and USDC balances do not change

**Side Effects:**
- No `mergePositions` call
- No `CompleteSetsMerged` event

---

### SC-6HCB: Merge works for any wallet in WindDown, in Cancelled, and while paused, without a heartbeat refresh

**Given:**
- The vault holds 10 YES and 10 NO
- Case A: phase is WindDown
- Case B: phase is Active and trading is paused
- Case C: phase is Cancelled (3)
- The caller is the Operator in one run and an address with no role in another

**Steps:**
1. The caller calls `mergeCompleteSets()`

**Outcomes:**
- Every run merges 10 pairs and the vault gains 10 USDC
- `lastOperatorActivityTimestamp` keeps its value, including when the Operator calls

**Side Effects:**
- `CompleteSetsMerged(caller, 10)` emitted in each run
- No change to `phase` or `paused`

---

### SC-6HCC: Merge works after an emergency cancel

**Given:**
- The vault is in Cancelled phase (3) after `emergencyCancelAll()`
- The vault holds 10 YES and 10 NO

**Steps:**
1. A wallet calls `mergeCompleteSets()`
2. The vault applies no phase check and merges the 10 pairs

**Outcomes:**
- The vault gains 10 USDC and holds 0 YES and 0 NO
- The freeze changes nothing about the merge (decision C9)

**Side Effects:**
- `CompleteSetsMerged(caller, 10)` emitted
- `PositionsMerge` emitted by ConditionalTokens
- No change to `phase`

---
