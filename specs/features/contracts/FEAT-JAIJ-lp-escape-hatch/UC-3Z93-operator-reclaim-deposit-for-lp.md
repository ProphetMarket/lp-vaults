---
id: UC-3Z93
name: Operator Reclaim Deposit for LP
feature: FEAT-JAIJ
status: implemented
version: 1
actor: Operator
---

# UC-3Z93: Operator Reclaim Deposit for LP

> An Operator relays the owner key's signed reclaim authorization to refund that Safe's escrowed USDC, giving a voluntary cancellation the same gas-sponsored path as every other action on the platform.

## Preconditions

- Vault is deployed and initialized, in any phase, paused or not
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- An escrow exists for `intentId`, recorded for Safe S (FEAT-3ZRI UC-3Z92)
- The intentId has NOT been consumed by `mintPositionFor` or by a reclaim (`usedIntents[intentId] == false`)
- The owner key of S signed `ReclaimIntent(lp = S, intentId, deadline)` with the vault's EIP-712 domain -- a struct with its own typehash, distinct from MintIntent

## Trigger

Operator calls `reclaimDepositFor(lp, intentId, deadline, signature)` on the vault.

---

### SC-3Z9D: Refund in one call

**Given:**
- `pendingDeposits[X] = (S, 600, hash)` and `usedIntents[X] == false`
- The owner key of S signed a valid ReclaimIntent for X with a deadline in the future

**Steps:**
1. Operator submits the signed reclaim authorization to `reclaimDepositFor`
2. System checks the deadline, recovers the owner key, and confirms the Safe derived from it equals `lp`
3. System checks `usedIntents[X]` is false, the escrow exists, and the recorded Safe equals `lp`
4. System marks `usedIntents[X] = true`, deletes the escrow, and subtracts 600 from totalEscrowed
5. System transfers 600 USDC to S

**Outcomes:**
- S's USDC balance increases by exactly the escrowed 600
- The Operator paid the gas and received nothing -- the USDC goes to the recorded Safe, never to msg.sender
- intentId X is permanently marked as used

**Side Effects:**
- `DepositReclaimed(X, S, 600)` event emitted
- `usedIntents[X]` set to `true`; `pendingDeposits[X]` deleted; `totalEscrowed` decreased by 600
- USDC transferred from vault to S
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No position created
- No USDC sent to `msg.sender`

---

### SC-3Z9F: Revert when nothing is escrowed for the intent

**Given:**
- No escrow exists for X -- the intent was never funded
- The owner key of S signed a valid ReclaimIntent for X

**Steps:**
1. Operator submits the signed reclaim authorization
2. System verifies the signature and reads no escrow for X

**Outcomes:**
- Call reverts with DepositNotEscrowed error
- The relayed path offers no way around the escrow requirement

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-45IH: Revert when the escrow belongs to a different Safe

**Given:**
- Safe A funded intentId X: `pendingDeposits[X].lp == A`
- The owner key of Safe B signed a valid ReclaimIntent naming B over the same intentId X

**Steps:**
1. Operator submits B's signed reclaim authorization for X
2. System verifies the signature, which derives B and matches the named `lp`
3. System reads the escrow for X and finds it recorded for A, not B

**Outcomes:**
- Call reverts with NotIntentOwner error
- A's escrow is untouched, and A can still mint or reclaim it
- A compromised Operator key with an attacker's signature still cannot move A's funds

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still `(A, amount, hash)`
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9G: Revert when a mint authorization is replayed as a reclaim

**Given:**
- `pendingDeposits[X] = (S, 600, hash)` and the intent is unused
- The Operator holds only the owner key's MintIntent signature for X
- The owner key has signed no ReclaimIntent

**Steps:**
1. Operator submits the MintIntent signature to `reclaimDepositFor`
2. System recovers a signer against the ReclaimIntent typehash and derives a Safe that is not S, because the signature was produced over a different struct

**Outcomes:**
- Call reverts with InvalidSignature error
- An Operator holding a mint authorization cannot cancel that Safe's pending deposit (ADR-4029)

**Side Effects:**
- No state changes
- The escrow of 600 stays intact and mintable
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9H: Revert on non-operator caller

**Given:**
- Caller is not a registered Operator (an arbitrary address, Admin, Oracle, or the Safe itself)
- The caller holds a valid owner-key ReclaimIntent and the escrow exists

**Steps:**
1. Non-operator calls `reclaimDepositFor`
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The Safe's own `reclaimDeposit` (UC-JAIK) remains available

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-3Z9I: Revert when the intent has already been used

**Given:**
- Intent X was already consumed, by a successful `mintPositionFor` or by a completed reclaim through either entry point
- `usedIntents[X] == true` and the escrow is deleted

**Steps:**
1. Operator submits a valid reclaim authorization for X
2. System checks `usedIntents[X]` and finds it true

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- The two reclaim entry points and the mint path share one `usedIntents` namespace, so no intent settles twice

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-9OYF: Revert after the deadline

**Given:**
- The owner key of S signed a valid ReclaimIntent for X with deadline = T
- The escrow exists

**Steps:**
1. Operator calls `reclaimDepositFor` at `block.timestamp = T + 1`
2. System detects `block.timestamp > deadline`

**Outcomes:**
- Call reverts with IntentExpired error
- The same call at `block.timestamp = T` succeeds
- The Safe's own `reclaimDeposit` has no deadline and remains available

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-9OYG: Revert when the owner key derives a different Safe

**Given:**
- The escrow is recorded for Safe S
- A key whose derived Safe is not S signed a ReclaimIntent naming S, OR the signature names the signer's own address as `lp`, OR the signature has a high `s`, a `v` outside {27, 28}, or a wrong length

**Steps:**
1. Operator submits the signature to `reclaimDepositFor`
2. System recovers the signer, derives its Safe, and finds it is not `lp`, or the signature fails the malleability or length check

**Outcomes:**
- Call reverts with InvalidSignature error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-9OYH: Works while paused, in WindDown, and after the freeze

**Given:**
- The Operator escrowed Safe S's USDC against intentId X, and the owner key signed a valid ReclaimIntent

**Steps:**
1. The Admin pauses the vault, and the Operator calls `reclaimDepositFor`
2. On a second vault with an escrow, the Oracle calls `startWindDown`, and the Operator calls `reclaimDepositFor`
3. On a third vault with an escrow, `emergencyCancelAll` runs and sets phase 3, and the Operator calls `reclaimDepositFor`

**Outcomes:**
- Every call refunds the escrow to S as in SC-3Z9D

**Side Effects:**
- Same as SC-3Z9D on each vault

---
