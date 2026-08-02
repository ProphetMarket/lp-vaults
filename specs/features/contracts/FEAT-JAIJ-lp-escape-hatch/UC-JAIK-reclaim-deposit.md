---
id: UC-JAIK
name: Reclaim Deposit
feature: FEAT-JAIJ
status: dirty
version: 3
actor: LP
---

# UC-JAIK: Reclaim Deposit

> LP recovers their escrowed USDC without any Operator involvement, after the Operator fails to fulfill a signed mint intent within RECLAIM_TIMELOCK.

## Preconditions

- Vault is deployed and initialized
- The LP signed an EIP-712 MintIntent, and the Operator escrowed it via `depositForIntent`, so `pendingDeposits[intentId] > 0` (FEAT-3ZRI UC-3Z92)
- The intentId has NOT been fulfilled by `mintPositionFor` (`usedIntents[intentId] == false`)
- No Operator signature, Operator action, or registered Operator is required at any point in this use case -- that independence is what makes this an escape hatch

## Trigger

LP calls `reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature)` on the vault.

---

### SC-JAIL: Successful reclaim after timelock

**Given:**
- LP signed a MintIntent with intentId X, and the Operator escrowed it: `pendingDeposits[X] == 600`
- The LP already made the Phase 1 submission call, recording `intentTimestamps[X]`
- RECLAIM_TIMELOCK has elapsed since that submission
- `usedIntents[X] == false` (not fulfilled, not reclaimed)

**Steps:**
1. LP calls reclaimDeposit with their signed intent
2. System confirms the caller is the LP named in the intent
3. System verifies the LP's EIP-712 signature over the MintIntent
4. System confirms `usedIntents[X]` is false and reads the escrowed amount as 600
5. System confirms RECLAIM_TIMELOCK has elapsed since the Phase 1 submission
6. System marks `usedIntents[X] = true` and clears the escrow entry
7. System transfers 600 USDC back to the LP

**Outcomes:**
- LP's USDC balance increases by exactly the escrowed 600, not by whatever amount the signed intent claimed
- `pendingDeposits[X] == 0` and intentId X is permanently marked as used
- No Operator was involved at any step

**Side Effects:**
- `usedIntents[X]` set to `true` in storage
- `pendingDeposits[X]` storage: deleted
- USDC transferred from vault to LP
- `DepositReclaimed` event emitted with `intentId, lp, usdcAmount`
- No position created
- `lastOperatorActivityTimestamp` unchanged -- an LP self-service exit is not evidence the Operator is alive

---

### SC-3Z9L: Revert when nothing is escrowed for the intent

**Given:**
- A caller holds a validly self-signed MintIntent for intentId X claiming usdcAmount = 1,000,000
- No `depositForIntent` was ever executed for X, so `pendingDeposits[X] == 0`
- The vault holds substantial USDC belonging to other LPs' positions and escrows
- The caller has already made the Phase 1 submission and RECLAIM_TIMELOCK has elapsed

**Steps:**
1. Caller calls reclaimDeposit with their validly signed intent
2. System confirms the caller is the LP named in the intent and verifies the signature
3. System reads `pendingDeposits[X]` and finds 0

**Outcomes:**
- Call reverts with NothingToReclaim error
- No USDC leaves the vault
- Signing an intent for an arbitrary amount grants no claim on the vault's balance -- only USDC actually escrowed under this intentId can ever be refunded

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-45IG: Revert when the escrow belongs to a different LP

**Given:**
- LP A funded intentId X: `pendingDeposits[X].lp == A`, `.amount == 600`. A's deposit is still pending a mint
- Attacker B read intentId X out of the public `DepositEscrowed` log
- B signed their own MintIntent naming themselves over intentId X, for any amount they like
- B has deposited nothing and holds no escrow

**Steps:**
1. B calls reclaimDeposit naming themselves as the LP, with their own valid signature over X
2. System confirms the caller is the LP named in the intent -- B is indeed B, so this passes
3. System verifies B's EIP-712 signature, which recovers to B -- this also passes
4. System reads the escrow for X and finds it recorded against A, not B

**Outcomes:**
- Call reverts with NotIntentOwner error
- No USDC leaves the vault, and A's escrow of 600 is untouched
- A is not locked out: `usedIntents[X]` stays false and `intentTimestamps[X]` is not set on B's behalf, so A can still mint or reclaim normally
- Waiting out RECLAIM_TIMELOCK does not help B, because the check is on recorded ownership and not on elapsed time

**Why this scenario exists:** neither the `msg.sender == lp` gate nor the signature check stops B, because B genuinely is B and genuinely signed. `_verifyMintIntent` compares the recovered signer against a caller-supplied `lp` argument, so a valid signature over an intentId proves only that *someone* signed it, never that they funded it. The escrow's recorded depositor is the only thing standing between a published intentId and an unprivileged drain of the deposit behind it.

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still `(A, 600)`
- No USDC transferred
- No events emitted

---

### SC-JAIM: Revert before timelock elapses

**Given:**
- Intent X is escrowed and the LP has made the Phase 1 submission
- RECLAIM_TIMELOCK has NOT elapsed since that submission

**Steps:**
1. LP calls reclaimDeposit
2. System checks elapsed time and finds it below RECLAIM_TIMELOCK
3. System reverts with TimelockNotElapsed

**Outcomes:**
- No USDC transferred
- intentId remains unused and the escrow is untouched, so the Operator can still mint the position during the window

**Side Effects:**
- No state changes
- No events emitted

---

### SC-JAIN: Revert when intent already fulfilled by mintPositionFor

**Given:**
- Operator already called mintPositionFor with intentId X
- `usedIntents[X] == true` and `pendingDeposits[X] == 0` (the mint consumed the escrow)

**Steps:**
1. LP calls reclaimDeposit with intentId X
2. System checks `usedIntents[X]` and finds it true
3. System reverts with IntentAlreadyUsed

**Outcomes:**
- No USDC transferred
- The LP cannot be paid twice for one deposit: they hold the position that deposit funded

**Side Effects:**
- No state changes

---

### SC-3ZA0: Reclaim succeeds with no registered operators

**Given:**
- Intent X is escrowed (`pendingDeposits[X] == 600`) and unfulfilled
- The Admin has removed every operator from the registry, so no address satisfies `operators[addr] == 1`
- The LP has made the Phase 1 submission and RECLAIM_TIMELOCK has elapsed

**Steps:**
1. LP calls reclaimDeposit with their signed intent
2. System verifies the LP's signature and the escrow, consulting no Operator registry state
3. System transfers 600 USDC back to the LP

**Outcomes:**
- The reclaim completes normally
- Removing an operator cannot strand an LP's deposit -- there is no live Operator signature for the removal to invalidate

**Side Effects:**
- Same side effects as SC-JAIL
- No read of the `operators` mapping occurs on this path

---

### SC-JAIP: Revert on replay (intentId already reclaimed)

**Given:**
- LP already reclaimed intentId X successfully
- `usedIntents[X] == true` and `pendingDeposits[X] == 0`

**Steps:**
1. LP calls reclaimDeposit with intentId X again
2. System checks `usedIntents[X]` and finds it true
3. System reverts with IntentAlreadyUsed

**Outcomes:**
- No USDC transferred

**Side Effects:**
- No state changes

---
