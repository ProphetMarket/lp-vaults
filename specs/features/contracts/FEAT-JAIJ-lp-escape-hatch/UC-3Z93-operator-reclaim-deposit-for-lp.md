---
id: UC-3Z93
name: Operator Reclaim Deposit for LP
feature: FEAT-JAIJ
status: implemented
version: 2
actor: Operator
---

# UC-3Z93: Operator Reclaim Deposit for LP

> An Operator relays an LP's signed reclaim authorization to refund that LP's escrowed USDC, giving a voluntary cancellation the same gas-sponsored path as every other action on the platform.

## Preconditions

- Vault is deployed and initialized
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The intent's USDC is escrowed: `pendingDeposits[intentId] > 0` (FEAT-3ZRI UC-3Z92)
- The intentId has NOT been fulfilled by `mintPositionFor` (`usedIntents[intentId] == false`)
- The LP has signed an EIP-712 ReclaimIntent -- a struct with its own typehash, distinct from MintIntent

## Trigger

Operator calls `reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature)` on the vault.

---

### SC-3Z9C: Phase 1 records the reclaim submission

**Given:**
- `pendingDeposits[X] == 600`, `usedIntents[X] == false`, `intentTimestamps[X] == 0`
- LP signed a valid ReclaimIntent for intentId X

**Steps:**
1. Operator submits the LP's signed reclaim authorization to `reclaimDepositFor`
2. System verifies the LP's EIP-712 ReclaimIntent signature
3. System confirms intent X is escrowed and unused
4. System finds no prior submission timestamp and records one

**Outcomes:**
- `intentTimestamps[X] == block.timestamp`
- No USDC has moved yet; the timelock clock has started
- The escrow is untouched, so the Operator can still mint the position during the window

**Side Effects:**
- `ReclaimSubmitted(intentId, lp, usdcAmount)` event emitted
- `intentTimestamps[X]` storage: set once
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No USDC transferred
- No `usedIntents` write
- No `pendingDeposits` change

---

### SC-3Z9D: Phase 2 refunds the LP after the timelock

**Given:**
- `pendingDeposits[X] == 600`, `usedIntents[X] == false`
- Phase 1 recorded `intentTimestamps[X]` and RECLAIM_TIMELOCK has elapsed since
- LP signed a valid ReclaimIntent for intentId X

**Steps:**
1. Operator submits the LP's signed reclaim authorization
2. System verifies the signature, the escrow, and that the intent is unused
3. System confirms RECLAIM_TIMELOCK has elapsed since Phase 1
4. System marks `usedIntents[X] = true` and clears the escrow entry
5. System transfers 600 USDC to the LP

**Outcomes:**
- The LP's USDC balance increases by exactly the escrowed 600
- The Operator paid the gas but received nothing -- funds go to the LP named in the intent, never to the caller
- `pendingDeposits[X] == 0` and intentId X is permanently marked as used

**Side Effects:**
- `DepositReclaimed(intentId, lp, usdcAmount)` event emitted
- `usedIntents[X]` set to `true`; `pendingDeposits[X]` deleted
- USDC transferred from vault to LP
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No position created
- No USDC sent to `msg.sender`

---

### SC-3Z9E: Revert before the timelock elapses

**Given:**
- Phase 1 recorded `intentTimestamps[X]` less than RECLAIM_TIMELOCK ago
- Escrow and signature are otherwise valid

**Steps:**
1. Operator submits the reclaim authorization again
2. System finds the elapsed time below RECLAIM_TIMELOCK

**Outcomes:**
- Call reverts with TimelockNotElapsed error
- The Operator cannot shortcut the same waiting period the LP faces

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9F: Revert when nothing is escrowed for the intent

**Given:**
- `pendingDeposits[X] == 0` -- the intent was never funded
- LP signed a valid ReclaimIntent for X claiming usdcAmount = 1,000,000
- Phase 1 was submitted and RECLAIM_TIMELOCK has elapsed

**Steps:**
1. Operator submits the LP's signed reclaim authorization
2. System verifies the signature and reads `pendingDeposits[X]` as 0

**Outcomes:**
- Call reverts with NothingToReclaim error
- The relayed path offers no way around the escrow requirement, so it cannot be used to drain other LPs' funds

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-45IH: Revert when the escrow belongs to a different LP

**Given:**
- LP A funded intentId X: `pendingDeposits[X].lp == A`, `.amount == 600`
- LP B validly signed a ReclaimIntent naming themselves over the same intentId X
- The Operator submits B's authorization, whether by mistake or in collusion

**Steps:**
1. Operator submits B's signed reclaim authorization for intentId X
2. System verifies the ReclaimIntent signature, which recovers to B and matches the named LP B
3. System reads the escrow for X and finds it recorded against A, not B

**Outcomes:**
- Call reverts with NotIntentOwner error
- A's escrow of 600 is untouched and A remains able to mint or reclaim it
- The relayed path grants the Operator no ability to redirect one LP's deposit to another, so a compromised Operator key colluding with an attacker's signature still cannot move A's funds

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still `(A, 600)`
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9G: Revert when a mint authorization is replayed as a reclaim

**Given:**
- `pendingDeposits[X] == 600` and the intent is unused
- The Operator holds only the LP's original MintIntent signature for X -- the one that authorized the escrow and the mint
- The LP has signed no ReclaimIntent

**Steps:**
1. Operator submits the MintIntent signature to `reclaimDepositFor`
2. System recovers the signer against the ReclaimIntent typehash
3. System detects the recovered address is not the named LP, because the signature was produced over a different struct

**Outcomes:**
- Call reverts with InvalidSignature error
- An Operator holding a mint authorization cannot unilaterally cancel that LP's pending deposit; cancelling requires the LP to have signed a reclaim specifically

**Side Effects:**
- No state changes
- The escrow of 600 remains intact and still mintable
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9H: Revert on non-operator caller

**Given:**
- Caller is not a registered Operator (an arbitrary address, Admin, or Oracle)
- The caller holds a genuinely valid LP-signed ReclaimIntent, escrow is present, and the timelock has elapsed

**Steps:**
1. Non-operator calls `reclaimDepositFor`
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The LP's own permissionless `reclaimDeposit` (UC-JAIK) remains available and is unaffected by this gate

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-3Z9I: Revert when the intent has already been used

**Given:**
- Intent X was already consumed, by a successful `mintPositionFor` or by a completed reclaim through either entry point
- `usedIntents[X] == true` and `pendingDeposits[X] == 0`

**Steps:**
1. Operator submits a valid reclaim authorization for X
2. System checks `usedIntents[X]` and finds it true

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- The two reclaim entry points and the mint path share one `usedIntents` namespace, so no intent can be settled twice by mixing paths

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---
