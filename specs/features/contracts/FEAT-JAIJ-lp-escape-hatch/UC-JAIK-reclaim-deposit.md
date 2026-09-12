---
id: UC-JAIK
name: Reclaim Deposit
feature: FEAT-JAIJ
status: implemented
version: 2
actor: LP
---

# UC-JAIK: Reclaim Deposit

> The LP's Safe recovers the USDC that the Operator escrowed against a mint intent and did not mint, in one call.

## Preconditions

- Vault is deployed and initialized, in any phase, paused or not
- The Operator escrowed the Safe's USDC against `intentId` through `depositForIntent` (FEAT-3ZRI UC-3Z92), so `pendingDeposits[intentId]` names the Safe and the amount
- The intentId has NOT been consumed by `mintPositionFor` or by a reclaim (`usedIntents[intentId] == false`)

## Trigger

The Safe calls `reclaimDeposit(intentId)` on the vault, through a Safe transaction that the owner key signed.

---

### SC-JAIL: Successful reclaim in one call

**Given:**
- The Operator escrowed 600 USDC from Safe S against intentId X, so `pendingDeposits[X] = (S, 600, hash)`
- `usedIntents[X] == false`
- No Operator has acted since

**Steps:**
1. Safe S calls `reclaimDeposit(X)`
2. System checks `usedIntents[X]` is false, the escrow exists, and the recorded Safe equals msg.sender
3. System marks `usedIntents[X] = true`, deletes the escrow, and subtracts 600 from totalEscrowed
4. System transfers 600 USDC to S

**Outcomes:**
- S's USDC balance increases by 600 in the same block, with no wait
- intentId X is permanently marked as used

**Side Effects:**
- `usedIntents[X]` set to `true` in storage
- `pendingDeposits[X]` deleted
- `totalEscrowed` decreased by 600
- USDC transferred from vault to S
- `DepositReclaimed(X, S, 600)` event emitted
- No position created
- No `lastOperatorActivityTimestamp` change

---

### SC-3Z9L: Revert when nothing is escrowed for the intent

**Given:**
- No escrow exists for intentId X and `usedIntents[X] == false`

**Steps:**
1. Any address calls `reclaimDeposit(X)`
2. System reads the escrow and finds no recorded Safe

**Outcomes:**
- Call reverts with DepositNotEscrowed error
- A caller who deposited nothing gets nothing, whatever it signed (audit issue 6.1 from the reclaim side)

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-45IG: Revert when the caller is not the recorded Safe

**Given:**
- An escrow is recorded for Safe A under intentId X

**Steps:**
1. Safe B, the owner key of A, or any other address calls `reclaimDeposit(X)`
2. System reads the escrow and finds it recorded for A, not the caller

**Outcomes:**
- Call reverts with NotIntentOwner error
- A's escrow is untouched and A can still mint or reclaim it

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still `(A, amount, hash)`
- No USDC transferred
- No events emitted

---

### SC-JAIN: Revert when intent already fulfilled by mintPositionFor

**Given:**
- Operator already called mintPositionFor with intentId X, which set `usedIntents[X] = true` and deleted the escrow

**Steps:**
1. Safe S calls `reclaimDeposit(X)`
2. System checks `usedIntents[X]` and finds it true

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- No USDC transferred

**Side Effects:**
- No state changes

---

### SC-3ZA0: Reclaim succeeds with no registered operators

**Given:**
- The Operator escrowed Safe S's USDC against intentId X
- The Admin then removed every Operator from the factory

**Steps:**
1. Safe S calls `reclaimDeposit(X)`
2. System refunds the escrow as in SC-JAIL

**Outcomes:**
- S's USDC balance increases by the escrowed amount
- The exit did not depend on the Operator registry (audit issue 6.13)

**Side Effects:**
- Same as SC-JAIL

---

### SC-JAIP: Revert on replay (intentId already reclaimed)

**Given:**
- Safe S already reclaimed intentId X
- `usedIntents[X] == true` and the escrow is deleted

**Steps:**
1. S calls `reclaimDeposit(X)` again
2. System checks `usedIntents[X]` and finds it true

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- No USDC transferred

**Side Effects:**
- No state changes

---

### SC-9OYE: Reclaim works in every phase and while paused

**Given:**
- The Operator escrowed Safe S's USDC against intentId X

**Steps:**
1. The Admin pauses the vault, and S calls `reclaimDeposit(X)`
2. On a second vault with an escrow, the Oracle calls `startWindDown`, and S calls `reclaimDeposit`
3. On a third vault with an escrow, `emergencyCancelAll` runs and sets phase 3, and S calls `reclaimDeposit`

**Outcomes:**
- Every call refunds the escrow as in SC-JAIL
- The Cancelled phase never locks a pending deposit (audit issue 6.7)

**Side Effects:**
- Same as SC-JAIL on each vault

---
