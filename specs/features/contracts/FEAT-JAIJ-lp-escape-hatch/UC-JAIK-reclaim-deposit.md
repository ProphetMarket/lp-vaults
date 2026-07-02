---
id: UC-JAIK
name: Reclaim Deposit
feature: FEAT-JAIJ
status: implemented
version: 1
actor: LP
---

# UC-JAIK: Reclaim Deposit

> LP recovers USDC by presenting a signed mint intent after the Operator fails to fulfill it within RECLAIM_TIMELOCK.

## Preconditions

- Vault is deployed and initialized (Active phase)
- LP has previously signed an EIP-712 MintIntent and wired USDC to the vault as part of the deposit-then-credit flow
- The Operator acknowledged the deposit by co-signing the intent
- The intentId has NOT been fulfilled by mintPositionFor

## Trigger

LP calls `reclaimDeposit(intent, operatorSig)` on the vault.

---

### SC-JAIL: Successful reclaim after timelock

**Given:**
- LP signed a MintIntent with intentId X and wired usdcAmount to the vault
- The Operator co-signed intent X (valid operator signature)
- RECLAIM_TIMELOCK has elapsed since the intent was submitted
- `usedIntents[X] == false` (not fulfilled, not reclaimed)

**Steps:**
1. LP calls reclaimDeposit with the signed intent and operator signature
2. System verifies the LP's EIP-712 signature over the MintIntent
3. System verifies the operator's signature and confirms the signer is a registered operator
4. System confirms RECLAIM_TIMELOCK has elapsed since intent submission
5. System marks `usedIntents[X] = true`
6. System transfers usdcAmount back to the LP

**Outcomes:**
- LP's USDC balance increases by usdcAmount
- intentId X is permanently marked as used

**Side Effects:**
- `usedIntents[X]` set to `true` in storage
- USDC transferred from vault to LP
- `DepositReclaimed` event emitted with `intentId, lp, usdcAmount`
- No position created

---

### SC-JAIM: Revert before timelock elapses

**Given:**
- Valid intent and operator signature
- RECLAIM_TIMELOCK has NOT elapsed since the intent was submitted

**Steps:**
1. LP calls reclaimDeposit
2. System checks elapsed time and finds it below RECLAIM_TIMELOCK
3. System reverts with TimelockNotElapsed

**Outcomes:**
- No USDC transferred
- intentId remains unused

**Side Effects:**
- No state changes
- No events emitted

---

### SC-JAIN: Revert when intent already fulfilled by mintPositionFor

**Given:**
- Operator already called mintPositionFor with intentId X
- `usedIntents[X] == true`

**Steps:**
1. LP calls reclaimDeposit with intentId X
2. System checks `usedIntents[X]` and finds it true
3. System reverts with IntentAlreadyUsed

**Outcomes:**
- No USDC transferred

**Side Effects:**
- No state changes

---

### SC-JAIO: Revert on invalid operator signature

**Given:**
- LP provides a valid self-signed intent
- The operator signature does not recover to a registered operator address

**Steps:**
1. LP calls reclaimDeposit with the invalid operator signature
2. System recovers the signer from the operator signature
3. System checks `operators[signer]` and finds it is not 1
4. System reverts with InvalidSignature

**Outcomes:**
- No USDC transferred
- intentId remains unused

**Side Effects:**
- No state changes

---

### SC-JAIP: Revert on replay (intentId already reclaimed)

**Given:**
- LP already reclaimed intentId X successfully
- `usedIntents[X] == true`

**Steps:**
1. LP calls reclaimDeposit with intentId X again
2. System checks `usedIntents[X]` and finds it true
3. System reverts with IntentAlreadyUsed

**Outcomes:**
- No USDC transferred

**Side Effects:**
- No state changes

---
