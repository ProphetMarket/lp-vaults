---
id: UC-7G41
name: Burn Position
feature: FEAT-7G40
status: implemented
version: 1
actor: LP
---

# UC-7G41: Burn Position

> An LP closes a position they own and takes delivery of whatever it actually holds -- USDC, outcome tokens, or both, plus accrued fees -- without needing the Operator to cooperate, or to exist.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`yesTokenId`, `noTokenId`)
- The LP holds a live position: `positions[positionId].owner == LP` and `liquidity > 0`
- The vault's phase is Active or WindDown
- No Operator action, Operator signature, or Operator registry state is required by anything in this use case

## Trigger

LP calls `burnPosition(positionId)` on the vault.

---

### SC-7G43: Burn below range pays entirely in USDC

**Given:**
- LP owns a position with range [200, 400] and liquidity L
- `currentTick == 150`, below `tickLower`
- The position has accrued no fees since mint

**Steps:**
1. LP calls `burnPosition` for their position
2. System confirms the caller owns the live position
3. System determines the position sits entirely below the current tick and computes the payout as USDC only
4. System removes the position's liquidity from ticks 200 and 400 and clears the position record
5. System transfers the USDC to the LP

**Outcomes:**
- The LP's USDC balance increases by the position's full USDC-side value
- The LP receives zero outcome tokens
- The position no longer exists and cannot be burned or collected again
- `activeLiquidity` is unchanged, because the position was never in range

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with `outcomeTokenAmount == 0`
- `positions[positionId]` storage: zeroed
- `ticks[200]` and `ticks[400]` storage: `liquidityGross` decreased by L; `liquidityNet` decreased by L at 200 and increased by L at 400
- USDC transferred from vault to LP
- No ERC-1155 transfer
- No `activeLiquidity` write
- No call to the CTF Exchange
- No `lastOperatorActivityTimestamp` write

---

### SC-7G44: Burn above range pays entirely in outcome tokens

**Given:**
- LP owns a position with range [200, 400] and liquidity L
- `currentTick == 450`, at or above `tickUpper`
- The position has accrued no fees since mint

**Steps:**
1. LP calls `burnPosition` for their position
2. System confirms the caller owns the live position
3. System determines the position sits entirely below the current tick on the outcome-token side and computes the payout as outcome tokens only
4. System removes the position's liquidity from both boundary ticks and clears the position record
5. System transfers the outcome tokens to the LP

**Outcomes:**
- The LP receives outcome tokens and zero USDC principal
- The vault performs no conversion on the LP's behalf; the LP decides whether to sell through the exchange or hold to resolution and redeem 1:1 through the Conditional Tokens contract
- The position no longer exists
- `activeLiquidity` is unchanged, because the position was out of range

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with `usdcAmount == 0`
- `positions[positionId]` storage: zeroed
- `ticks[200]` and `ticks[400]` storage: liquidity removed as in SC-7G43
- ERC-1155 outcome tokens transferred from vault to LP
- No USDC principal transferred
- No order placed, matched, or settled on the CTF Exchange
- No `activeLiquidity` write

---

### SC-7G45: Burn in range pays a split of both assets

**Given:**
- LP owns a position with range [200, 400] and liquidity L
- `currentTick == 300`, strictly inside the range
- `activeLiquidity` includes this position's L

**Steps:**
1. LP calls `burnPosition` for their position
2. System confirms the caller owns the live position
3. System determines the current tick sits inside the range and computes a split payout of USDC and outcome tokens
4. System removes the position's liquidity from both boundary ticks and from `activeLiquidity`, then clears the position record
5. System transfers both assets to the LP

**Outcomes:**
- The LP receives a nonzero amount of USDC and a nonzero amount of outcome tokens
- The payout is not the USDC amount originally deposited; it is what the position holds at the tick where the market currently sits
- `activeLiquidity` decreases by exactly L
- The position no longer exists

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with both asset amounts nonzero
- `positions[positionId]` storage: zeroed
- `ticks[200]` and `ticks[400]` storage: liquidity removed
- `activeLiquidity` storage: decreased by L
- USDC transferred from vault to LP
- ERC-1155 outcome tokens transferred from vault to LP
- No call to the CTF Exchange

---

### SC-7G46: Burn pays accrued fees alongside principal

**Given:**
- LP owns an in-range position that has accrued F in fees through `notifyFees` since it was minted
- The LP has not called `collect` since the fees accrued

**Steps:**
1. LP calls `burnPosition` for their position
2. System computes the position's accrued fees from the fee-growth accumulators for its range
3. System computes the principal payout for the current tick
4. System clears the position and transfers principal and fees together

**Outcomes:**
- The LP receives principal and F in one call; no separate `collect` is needed to recover the fees
- A subsequent `collect` on the same positionId reverts, because the position is gone
- No fees are stranded in the vault by closing the position

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted with `feesAmount == F`
- `positions[positionId]` storage: zeroed, including `feeGrowthInsideLastX128` and `tokensOwed`
- USDC transferred from vault to LP covering both the USDC-side principal and the fees
- No separate `FeesCollected` event emitted -- the burn event carries the fee amount

---

### SC-7G47: Burning the last position at a tick deinitializes it

**Given:**
- LP owns the only remaining position referencing tick 400
- Tick 400 is initialized: `liquidityGross > 0` and its bitmap bit is set
- Tick 200 is still referenced by another LP's live position

**Steps:**
1. LP calls `burnPosition` for their position
2. System decrements `liquidityGross` on both boundary ticks
3. System finds `ticks[400].liquidityGross == 0` and deletes the tick's state
4. System clears the bitmap bit for tick 400
5. System finds `ticks[200].liquidityGross > 0` and leaves tick 200 intact

**Outcomes:**
- Tick 400 is deinitialized and its bitmap bit reads zero, so later `updateTick` traversals skip it instead of crossing a tick with no liquidity behind it
- Tick 200 remains initialized with its bitmap bit set and its `feeGrowthOutsideX128` preserved for the other LP's position
- The LP receives their payout as in the range-dependent scenarios above

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted
- `ticks[400]` storage: deleted
- Tick bitmap word containing tick 400: bit cleared
- `ticks[200]` storage: `liquidityGross` and `liquidityNet` decremented, tick otherwise preserved
- No bitmap write for tick 200

---

### SC-7G48: Revert when the caller is not the position owner

**Given:**
- LP A owns positionId N with a live, in-range position
- LP B holds no claim on N

**Steps:**
1. LP B calls `burnPosition(N)`
2. System reads `positions[N].owner` and finds A, not the caller

**Outcomes:**
- Call reverts with NotPositionOwner error
- A's position is untouched and A can still burn or collect it
- B cannot force A's exit at a tick of B's choosing; because the payout composition depends on `currentTick` at call time, letting a third party trigger the burn would lock A into a split A never chose, even with the funds correctly landing at A

**Side Effects:**
- No state changes
- No USDC transferred
- No ERC-1155 transferred
- No events emitted

---

### SC-7G49: Burn in WindDown phase succeeds identically to Active

**Given:**
- The Oracle has called `startWindDown` and the vault's phase is WindDown
- LP owns a live in-range position identical to the one in SC-7G45

**Steps:**
1. LP calls `burnPosition` for their position
2. System applies no phase gate to the burn path
3. System computes the payout, updates tick and liquidity state, and transfers both assets

**Outcomes:**
- The payout composition, tick updates, and `activeLiquidity` delta are identical to the same burn executed in Active phase
- Wind-down closes off new mints without closing off exits, satisfying the exit-path guarantee FEAT-JGE7 UC-JGEE describes but could not previously demonstrate for burn

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted
- `positions[positionId]` storage: zeroed
- `ticks` and `activeLiquidity` storage: updated as in Active phase
- USDC and ERC-1155 outcome tokens transferred from vault to LP
- No phase change; the vault stays in WindDown

---

### SC-7G4A: Burn succeeds with zero registered operators

**Given:**
- The Admin has removed every operator: `operators[x] == 0` for all addresses
- No emergency or cancellation has been declared; the vault is simply unattended
- LP owns a live position

**Steps:**
1. LP calls `burnPosition` for their position
2. System reads no operator registry state and requires no signature
3. System computes the payout, updates tick and liquidity state, and transfers the assets

**Outcomes:**
- The LP exits in full without any Operator participation
- This is the concrete guarantee that LP capital is not trapped when the Operator becomes unresponsive or hostile: the path stays open with no emergency to declare, no timelock to wait out, and nobody to ask
- Any future change that gives this path a dependency on Operator liveness voids that guarantee

**Side Effects:**
- `PositionBurned(positionId, owner, usdcAmount, outcomeTokenAmount, feesAmount)` event emitted
- `positions[positionId]` storage: zeroed
- `ticks` storage: liquidity removed from both boundary ticks
- USDC and/or ERC-1155 outcome tokens transferred from vault to LP
- No operator registry read
- No signature verification
- No `lastOperatorActivityTimestamp` write

---

### SC-7G4B: Revert on a nonexistent or already-burned position

**Given:**
- PositionId M was either never minted, or was burned in an earlier transaction and its record zeroed

**Steps:**
1. LP calls `burnPosition(M)`
2. System reads `positions[M]` and finds no live position

**Outcomes:**
- Call reverts with PositionNotFound error
- A double burn cannot drain a second payout from a position that was already settled
- No positionId is ever reassigned, so a stale reference resolves to nothing rather than to a different LP's position

**Side Effects:**
- No state changes
- No USDC transferred
- No ERC-1155 transferred
- No events emitted

---
