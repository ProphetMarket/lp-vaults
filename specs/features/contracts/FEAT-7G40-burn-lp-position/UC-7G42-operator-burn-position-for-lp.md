---
id: UC-7G42
name: Operator Burn Position for LP
feature: FEAT-7G40
status: implemented
version: 3
actor: Operator
---

# UC-7G42: Operator Burn Position for LP

> The Operator relays the owner key's signed burn authorization to close that Safe's position and deliver the claim to the Safe, so a position exit has the same gas-sponsored path as every other action on the platform.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`conditionId`, `yesTokenId`, `noTokenId`)
- The Operator is registered on the factory (`operators[operator] == 1`)
- The position is live: `positions[positionId].owner` is the LP's Safe and `liquidity > 0`
- The owner key has signed an EIP-712 `BurnIntent(address lp,uint256 positionId,uint256 deadline)` naming its Safe as `lp`, a struct with its own typehash, distinct from `MintIntent` and `ReclaimIntent`

## Trigger

The Operator calls `burnPositionFor(lp, positionId, deadline, signature)` on the vault.

---

### SC-7G4C: Operator burn at the mint tick pays the LP the whole principal in USDC

**Given:**
- The Safe owns a position of 300 USDC over `[5500, 6500)` minted at tick 6000, and `currentTick == 6000`
- The owner key signed a valid `BurnIntent` for this positionId

**Steps:**
1. Operator submits the signed burn authorization to `burnPositionFor`
2. System verifies that the Safe derived from the signer equals `lp`, and that `lp` owns the position
3. System values the claim as USDC only
4. System removes the position's liquidity from both boundary ticks and deletes the position record
5. System transfers 300 USDC to the Safe

**Outcomes:**
- The Safe's USDC balance increases by 300 USDC, matching SC-7G43 exactly, because both entry points run the same internal body
- The Operator paid the gas and received nothing
- `activeLiquidity` decreases by the position's liquidity

**Side Effects:**
- `PositionBurned(positionId, safe, 300000000, 300000000, 0, 0, 0)` emitted
- `usedBurnAuthorizations[structHash]` storage: set to true
- `positions[positionId]` storage: deleted
- `ticks[5500]` and `ticks[6500]` storage: liquidity removed
- USDC transferred from vault to the Safe
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No USDC sent to `msg.sender`
- No ERC-1155 transfer

---

### SC-7G4D: Operator burn after the price fell pays the LP USDC plus YES, never the caller

**Given:**
- The Safe owns the position of SC-7G4C, the tick is 5700, and the vault holds 90 YES
- The owner key signed a valid `BurnIntent` for this positionId

**Steps:**
1. Operator submits the signed burn authorization
2. System verifies the signature and the owner
3. System values the claim as 247.3545 USDC plus 90 YES
4. System removes the liquidity, deletes the record, and pays the Safe

**Outcomes:**
- The Safe receives 247,354,500 USDC units and 90 YES, matching SC-7G44
- Every asset lands with `position.owner`, never with `msg.sender`

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)` emitted
- `usedBurnAuthorizations[structHash]` storage: set to true
- `positions[positionId]` storage: deleted
- USDC and ERC-1155 YES transferred from vault to the Safe
- `lastOperatorActivityTimestamp` storage: refreshed
- No asset sent to `msg.sender`

---

### SC-7G4E: Operator burn after the price rose pays the LP USDC plus NO

**Given:**
- The Safe owns the position of SC-7G4C, the tick is 6300, and the vault holds 90 NO
- The owner key signed a valid `BurnIntent` for this positionId

**Steps:**
1. Operator submits the signed burn authorization
2. System verifies the signature and the owner
3. System values the claim as 265.3455 USDC plus 90 NO
4. System removes the liquidity, deletes the record, and pays the Safe

**Outcomes:**
- The Safe receives 265,345,500 USDC units and 90 NO, matching SC-7G45
- The Operator's balances are unchanged

**Side Effects:**
- `PositionBurned(positionId, safe, 265345500, 265345500, noTokenId, 90000000, 90000000)` emitted
- `usedBurnAuthorizations[structHash]` storage: set to true
- `positions[positionId]` storage: deleted
- USDC and ERC-1155 NO transferred from vault to the Safe
- `lastOperatorActivityTimestamp` storage: refreshed

---

### SC-7G4F: Revert when the burn authorization is missing

**Given:**
- The Safe owns a live position and the owner key has signed nothing
- The Operator submits an empty signature

**Steps:**
1. Operator calls `burnPositionFor` with empty bytes
2. System finds the signature is not 65 bytes

**Outcomes:**
- Call reverts with InvalidSignature error
- Operator authority alone never closes a position

**Side Effects:**
- No state changes
- The position stays live and burnable by its owner
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4G: Revert when the burn authorization is malformed

**Given:**
- The Safe owns a live position
- Case A: the signature's `s` value is above secp256k1n/2
- Case B: the signature's `v` is outside {27, 28}
- Case C: the signature has 64 bytes
- Case D: the signature is valid but from a key whose derived Safe is not `lp`

**Steps:**
1. Operator submits the signature to `burnPositionFor`
2. System checks the length and the malleability bounds, recovers the signer, and derives its Safe

**Outcomes:**
- Call reverts with InvalidSignature error in every case
- A malleable form would give a replayed burn a second encoding the used-authorization record has never seen

**Side Effects:**
- No state changes
- The position stays live
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4H: Revert when a burn authorization is replayed

**Given:**
- The Operator already executed a successful `burnPositionFor` with this exact `BurnIntent`
- The position was deleted by that burn and the struct hash was recorded as used

**Steps:**
1. Operator submits the same signed burn authorization a second time
2. System checks `usedBurnAuthorizations` and finds the struct hash consumed

**Outcomes:**
- Call reverts with IntentAlreadyUsed error, before the position check, so a replay is distinguishable from a burn of a position that never existed

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4I: Revert when a mint or reclaim authorization is reused as a burn

**Given:**
- The Safe owns a live position minted through `mintPositionFor`
- The Operator holds the owner key's `MintIntent` signature or a `ReclaimIntent` signature
- The owner key has signed no `BurnIntent`

**Steps:**
1. Operator submits the other signature to `burnPositionFor`
2. System recovers the signer against the `BurnIntent` typehash and derives a Safe that is not `lp`

**Outcomes:**
- Call reverts with InvalidSignature error
- The three authorizations form three disjoint namespaces, and a `BurnIntent` signature is rejected by `depositForIntent` and `reclaimDepositFor`

**Side Effects:**
- No state changes
- The position stays live with its liquidity intact
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4J: Revert on a non-Operator caller

**Given:**
- The caller is not a registered Operator: an arbitrary address, the Admin, or the Oracle
- The caller holds a valid owner-key `BurnIntent` for a live position

**Steps:**
1. Non-operator calls `burnPositionFor`
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The owner's own `burnPosition` (UC-7G41) stays available

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4K: Operator burn in WindDown succeeds identically to Active

**Given:**
- The Oracle has called `startWindDown` and the vault's phase is WindDown
- The Safe owns a live in-range position and the owner key signed a valid `BurnIntent`

**Steps:**
1. Operator submits the signed burn authorization
2. System applies no phase gate to the burn path
3. System values the claim, updates tick and liquidity state, and pays the Safe

**Outcomes:**
- The `PositionBurned` amounts, the tick updates, and the `activeLiquidity` delta are identical to the same relayed burn in Active phase
- The gas-sponsored exit stays available through wind-down

**Side Effects:**
- `PositionBurned` emitted
- `usedBurnAuthorizations[structHash]` storage: set to true
- `positions[positionId]` storage: deleted
- USDC transferred from vault to the Safe
- `lastOperatorActivityTimestamp` storage: refreshed
- No phase change; the vault stays in WindDown

---

### SC-BMF4: Revert when the deadline passed

**Given:**
- The Safe owns a live position
- The owner key signed a `BurnIntent` whose `deadline` is `block.timestamp − 1`

**Steps:**
1. Operator submits the signed burn authorization
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

### SC-BMF5: Operator burn refreshes the heartbeat

**Given:**
- The Safe owns a live position and the owner key signed a valid `BurnIntent`
- `lastOperatorActivityTimestamp` is older than the current block

**Steps:**
1. Operator submits the signed burn authorization
2. System executes the burn

**Outcomes:**
- `lastOperatorActivityTimestamp == block.timestamp` after the call

**Side Effects:**
- `lastOperatorActivityTimestamp` storage: written to `block.timestamp`
- `PositionBurned` emitted

---
