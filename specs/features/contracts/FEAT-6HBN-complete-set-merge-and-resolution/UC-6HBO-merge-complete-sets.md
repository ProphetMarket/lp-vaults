---
id: UC-6HBO
name: Merge Complete Sets
feature: FEAT-6HBN
status: implemented
version: 2
actor: Any Wallet
---

# UC-6HBO: Merge Complete Sets

> Any wallet turns the vault's matched YES and NO tokens into USDC held by the vault.

## Preconditions

- The vault was created with a verified outcome-token identity (UC-REQ1), so `conditionId`, `yesTokenId`, and `noTokenId` name its market

## Trigger

Any wallet calls `mergeCompleteSets()` on the vault, usually the keeper after fills.

---

### SC-6HC9: Any wallet merges the vault's matched pairs into USDC

**Given:**
- The vault is in Active phase
- The vault holds 100 YES, 60 NO, and B USDC

**Steps:**
1. A wallet calls `mergeCompleteSets()`
2. The vault reads its YES and NO balances on the ConditionalTokens contract
3. The vault computes `amount = min(100, 60) = 60`
4. The vault calls `mergePositions(usdc, bytes32(0), conditionId, [1, 2], 60)`
5. ConditionalTokens burns 60 YES and 60 NO and transfers 60 USDC to the vault

**Outcomes:**
- The vault holds 40 YES, 0 NO, and B + 60 USDC
- The caller's balances do not change

**Side Effects:**
- `CompleteSetsMerged(caller, 60)` emitted by the vault
- `PositionsMerge` emitted by ConditionalTokens
- No receiver hook runs, because a burn calls no hook
- No vault storage written: phase, positions, ticks, and `lastOperatorActivityTimestamp` keep their values

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
