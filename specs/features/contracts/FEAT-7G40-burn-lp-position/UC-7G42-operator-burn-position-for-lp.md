---
id: UC-7G42
name: Operator Burn Position for LP
feature: FEAT-7G40
status: implemented
version: 1
actor: Operator
---

# UC-7G42: Operator Burn Position for LP

> An Operator relays an LP's signed burn authorization to close that LP's position and deliver the payout to them, giving position exit the same gas-sponsored path as every other action on the platform.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`yesTokenId`, `noTokenId`)
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The position is live: `positions[positionId].owner` is the LP and `liquidity > 0`
- The LP has signed an EIP-712 BurnIntent -- a struct with its own typehash, distinct from MintIntent and ReclaimIntent
- The vault's phase is Active or WindDown

## Trigger

Operator calls `burnPositionFor(positionId, lpSignature)` on the vault.

---

### SC-7G4C: Operator burn below range pays the LP entirely in USDC

**Given:**
- The LP owns a position with range [200, 400] and liquidity L
- `currentTick == 150`, below `tickLower`
- The LP signed a valid BurnIntent for this positionId

**Steps:**
1. Operator submits the LP's signed burn authorization to `burnPositionFor`
2. System verifies the BurnIntent signature recovers to the position's recorded owner
3. System determines the position sits entirely below the current tick and computes the payout as USDC only
4. System removes the position's liquidity from both boundary ticks and clears the position record
5. System transfers the USDC to the LP

**Outcomes:**
- The LP's USDC balance increases by the position's full USDC-side value; the payout matches SC-7G43 exactly, because both entry points run the same internal implementation
- The Operator paid the gas and received nothing -- no assets go to `msg.sender`
- `activeLiquidity` is unchanged, because the position was out of range

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with `outcomeTokenAmount == 0`
- Burn authorization recorded as used
- `positions[positionId]` storage: zeroed
- `ticks[200]` and `ticks[400]` storage: liquidity removed
- USDC transferred from vault to the LP
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No USDC sent to `msg.sender`
- No ERC-1155 transfer

---

### SC-7G4D: Operator burn above range pays the LP entirely in outcome tokens

**Given:**
- The LP owns a position with range [200, 400] and liquidity L
- `currentTick == 450`, at or above `tickUpper`
- The LP signed a valid BurnIntent for this positionId

**Steps:**
1. Operator submits the LP's signed burn authorization
2. System verifies the signature against the position's recorded owner
3. System computes the payout as outcome tokens only
4. System removes the liquidity from both boundary ticks and clears the position record
5. System transfers the outcome tokens to the LP

**Outcomes:**
- The LP receives outcome tokens and zero USDC principal, matching SC-7G44
- The vault sells nothing on the LP's behalf; relaying the burn does not authorize the Operator to convert the LP's outcome tokens
- The position no longer exists

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with `usdcAmount == 0`
- Burn authorization recorded as used
- `positions[positionId]` storage: zeroed
- ERC-1155 outcome tokens transferred from vault to the LP
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No order placed, matched, or settled on the CTF Exchange
- No outcome tokens sent to `msg.sender`

---

### SC-7G4E: Operator burn in range pays the LP a split, never the caller

**Given:**
- The LP owns a position with range [200, 400] and liquidity L, with F in accrued fees
- `currentTick == 300`, strictly inside the range
- The LP signed a valid BurnIntent for this positionId

**Steps:**
1. Operator submits the LP's signed burn authorization
2. System verifies the signature against the position's recorded owner
3. System computes a split payout of USDC and outcome tokens plus the accrued fees F
4. System removes the liquidity from both boundary ticks and from `activeLiquidity`, then clears the position record
5. System transfers both assets and the fees to the LP

**Outcomes:**
- The LP receives a nonzero amount of each asset plus F, matching SC-7G45 and SC-7G46
- Every asset lands with `position.owner`, read from the position record and never from `msg.sender` or a caller-supplied address
- `activeLiquidity` decreases by exactly L

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with all three amounts nonzero
- Burn authorization recorded as used
- `positions[positionId]` storage: zeroed
- `activeLiquidity` storage: decreased by L
- USDC and ERC-1155 outcome tokens transferred from vault to the LP
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No assets sent to `msg.sender`

---

### SC-7G4F: Revert when the burn authorization is missing

**Given:**
- The LP owns a live position and has signed nothing
- The Operator submits an empty or absent signature

**Steps:**
1. Operator calls `burnPositionFor` without a valid LP signature
2. System attempts to recover a signer from the supplied bytes and fails to match the position's owner

**Outcomes:**
- Call reverts with InvalidSignature error
- Operator authority alone never closes a position; the Operator can pay for an exit the LP asked for, not decide that an exit happens

**Side Effects:**
- No state changes
- The position remains live and burnable by its owner
- No USDC transferred
- No ERC-1155 transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4G: Revert when the burn authorization is malformed

**Given:**
- The LP owns a live position
- The Operator holds a signature whose `s` value is above secp256k1n/2, or whose `v` is outside {27, 28}

**Steps:**
1. Operator submits the malleable signature to `burnPositionFor`
2. System checks the malleability bounds before recovering the signer

**Outcomes:**
- Call reverts with InvalidSignature error
- Accepting the malleable form would yield a second distinct encoding of the same authorization, giving a replayed burn a signature the used-authorization guard has never seen

**Side Effects:**
- No state changes
- The position remains live
- No USDC transferred
- No ERC-1155 transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4H: Revert when a burn authorization is replayed

**Given:**
- The Operator already executed a successful `burnPositionFor` with this exact BurnIntent
- The position was zeroed by that burn and the authorization was recorded as used

**Steps:**
1. Operator submits the same signed burn authorization a second time
2. System checks the used-authorization record and finds it already consumed

**Outcomes:**
- Call reverts with an already-used error, rather than being absorbed silently by the zeroed position record
- The check is explicit so the rejection does not depend on the position record happening to be empty -- and so a replay is distinguishable from a burn of a position that never existed

**Side Effects:**
- No state changes
- No USDC transferred
- No ERC-1155 transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4I: Revert when a mint or reclaim authorization is reused as a burn

**Given:**
- The LP owns a live position minted through `mintPositionFor`
- The Operator holds only the LP's original MintIntent signature, or a ReclaimIntent signature from an unrelated deposit
- The LP has signed no BurnIntent

**Steps:**
1. Operator submits the MintIntent or ReclaimIntent signature to `burnPositionFor`
2. System recovers the signer against the BurnIntent typehash
3. System finds the recovered address is not the position's owner, because the signature was produced over a different struct

**Outcomes:**
- Call reverts with InvalidSignature error
- An Operator holding an LP's mint authorization cannot turn it into an exit; closing a position requires the LP to have signed a burn specifically
- The converse holds too: a BurnIntent signature is rejected by `depositForIntent`, `mintPositionFor`, and `reclaimDepositFor`, so the three authorizations form three disjoint namespaces

**Side Effects:**
- No state changes
- The position remains live and its liquidity intact
- No USDC transferred
- No ERC-1155 transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4J: Revert on non-operator caller

**Given:**
- The caller is not a registered Operator -- an arbitrary address, the Admin, or the Oracle
- The caller holds a genuinely valid LP-signed BurnIntent for a live position

**Steps:**
1. Non-operator calls `burnPositionFor`
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The gas-sponsored relay is an Operator privilege; a third party cannot use a leaked authorization to time an LP's exit
- The owner's own `burnPosition` (UC-7G41) remains available and is unaffected by this gate

**Side Effects:**
- No state changes
- The position remains live
- No USDC transferred
- No ERC-1155 transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-7G4K: Operator burn in WindDown phase succeeds identically to Active

**Given:**
- The Oracle has called `startWindDown` and the vault's phase is WindDown
- The LP owns a live in-range position and signed a valid BurnIntent

**Steps:**
1. Operator submits the LP's signed burn authorization
2. System applies no phase gate to the burn path
3. System computes the payout, updates tick and liquidity state, and transfers both assets to the LP

**Outcomes:**
- The payout composition, tick updates, and `activeLiquidity` delta are identical to the same operator-relayed burn in Active phase
- The gas-sponsored exit stays available through wind-down, so an LP with no gas is not pushed onto the self-service path just because the market resolved

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted
- Burn authorization recorded as used
- `positions[positionId]` storage: zeroed
- `ticks` and `activeLiquidity` storage: updated as in Active phase
- USDC and ERC-1155 outcome tokens transferred from vault to the LP
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp`
- No phase change; the vault stays in WindDown

---
