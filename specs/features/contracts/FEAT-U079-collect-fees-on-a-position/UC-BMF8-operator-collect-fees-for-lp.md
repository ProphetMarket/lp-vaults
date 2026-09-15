---
id: UC-BMF8
name: Operator Collect Fees for LP
feature: FEAT-U079
status: deprecated
version: 3
actor: Operator
---

# UC-BMF8: Operator Collect Fees for LP

Deprecated on 2026-09-14 (step R17 in `audits/audit-fixes-ranged.md`): the Prophet server computes and pays each maker's fees off-chain, so the vault carries no fee accounting. The text below is the audit trail of the deleted code.

> The Operator relays the owner key's signed collect authorization to pay that Safe its accrued fees, so a fee withdrawal has the same gas-sponsored path as every other action on the platform.

## Preconditions

- Vault is deployed and initialized, in any phase
- The Operator is registered on the factory (`operators[operator] == 1`)
- The LP's Safe owns a position with a valid positionId
- The owner key has signed an EIP-712 `CollectIntent(address lp,uint256 positionId,uint256 nonce,uint256 deadline)` naming its Safe as `lp`, a struct with its own typehash, distinct from `MintIntent`, `ReclaimIntent`, and `BurnIntent`

## Trigger

The Operator calls `collectFor(lp, positionId, nonce, deadline, signature)` on the vault.

---

### SC-BMFG: Operator collect pays the LP its fees, never the caller

**Given:**
- The Safe's in-range position has accrued F > 0 in fees since its mint
- The owner key signed a valid `CollectIntent` with nonce 1

**Steps:**
1. Operator submits the signed collect authorization to `collectFor`
2. System verifies that the Safe derived from the signer equals `lp`, and that `lp` owns the position
3. System computes owed = F, writes the snapshot, and transfers F to the Safe

**Outcomes:**
- The Safe's USDC balance increases by F, the same amount `collect` would pay
- The Operator's USDC balance is unchanged
- `lastOperatorActivityTimestamp == block.timestamp`

**Side Effects:**
- `FeesCollected(positionId, safe, F, F)` emitted
- `usedCollectAuthorizations[structHash]` storage: set to true
- Position storage: `feeGrowthInsideLastX128` updated, `tokensOwed = 0`
- USDC transferred from vault to the Safe
- `lastOperatorActivityTimestamp` storage: refreshed
- No USDC sent to `msg.sender`

---

### SC-BMFH: A second collect with a new nonce pays only the new fees

**Given:**
- The Operator relayed a collect with nonce 1 that paid F1
- More fees accrued since, so the position is owed F2
- The owner key signed a `CollectIntent` with nonce 2

**Steps:**
1. Operator submits the second authorization
2. System finds the new struct hash unused and executes the collect

**Outcomes:**
- The Safe receives exactly F2, not F1 + F2

**Side Effects:**
- `FeesCollected(positionId, safe, F2, F2)` emitted
- `usedCollectAuthorizations` storage: both struct hashes set to true
- Position storage: `feeGrowthInsideLastX128` updated

---

### SC-BMFI: Revert when the nonce is replayed

**Given:**
- The Operator already executed a successful `collectFor` with this exact `CollectIntent`
- More fees accrued since

**Steps:**
1. Operator submits the same signed authorization a second time
2. System checks `usedCollectAuthorizations` and finds the struct hash consumed

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- The new fees stay collectible with a new nonce

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-BMFJ: Revert when the deadline passed

**Given:**
- The owner key signed a `CollectIntent` whose `deadline` is `block.timestamp − 1`

**Steps:**
1. Operator submits the signed authorization
2. System compares `block.timestamp` with `deadline` before any other check

**Outcomes:**
- Call reverts with IntentExpired error
- The same signature with `deadline == block.timestamp` succeeds

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-BMFK: Revert when the signature does not derive lp

**Given:**
- The Safe owns a position with accrued fees
- Case A: a different owner key signed the `CollectIntent` naming the Safe as `lp`
- Case B: the signature is empty, has 64 bytes, has a high `s`, or has `v` outside {27, 28}

**Steps:**
1. Operator submits the signature to `collectFor`
2. System checks the length and the malleability bounds, recovers the signer, and derives its Safe

**Outcomes:**
- Call reverts with InvalidSignature error in every case

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-BMFL: Revert when lp is not the owner

**Given:**
- Safe A owns the position
- Safe B's owner key signed a valid `CollectIntent` naming Safe B as `lp` for A's positionId

**Steps:**
1. Operator submits B's authorization
2. System verifies the signature derives B, then finds `position.owner == A`

**Outcomes:**
- Call reverts with NotPositionOwner error
- A valid signature never proves ownership of a position; the recorded owner does

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-BMFM: Revert on a non-Operator caller

**Given:**
- The caller is not a registered Operator: an arbitrary address, the Admin, or the Oracle
- The caller holds a valid owner-key `CollectIntent`

**Steps:**
1. Non-operator calls `collectFor`
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The owner's own `collect` (UC-U07A) stays available

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-BMG6: Revert when a mint, reclaim, or burn authorization is reused as a collect

**Given:**
- The Safe owns a position with accrued fees
- The Operator holds the owner key's `MintIntent` signature, a `ReclaimIntent` signature, or a `BurnIntent` signature
- The owner key has signed no `CollectIntent`

**Steps:**
1. Operator submits the other signature to `collectFor`
2. System recovers the signer against the `CollectIntent` typehash and derives a Safe that is not `lp`

**Outcomes:**
- Call reverts with InvalidSignature error
- The four authorizations form four disjoint namespaces

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---
