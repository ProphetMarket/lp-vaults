---
id: UC-T7AG
name: Operator Mint Position for LP
feature: FEAT-T7AF
status: implemented
version: 4
actor: Operator
---

# UC-T7AG: Operator Mint Position for LP

> An Operator executes an LP's signed EIP-712 mint intent to create a concentrated-liquidity position, initializing tick state and anchoring the fee snapshot so the position earns only future fees.

## Preconditions

- A vault has been deployed and initialized for a market (FEAT-REPZ UC-REQ1)
- The vault is in Active phase (phase == 1)
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The intent's USDC is already held by the vault as per-intent escrow: `pendingDeposits[intentId] == usdcAmount`, recorded by a prior `depositForIntent` call (FEAT-3ZRI UC-3Z92). Mint moves no tokens; it converts escrow the vault already holds into a position.

## Trigger

Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, signature)` on the vault.

---

### SC-T7AH: Successful in-range mint with fresh ticks

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 1000
- LP signed a valid MintIntent: lp = LP address, tickLower = 20, tickUpper = 80, usdcAmount = 600, intentId = unique value
- The Operator already escrowed that intent: `pendingDeposits[intentId] == 600`, and the vault holds the 600 USDC
- Ticks 20 and 80 have never been used (liquidityGross == 0 on both)

**Steps:**
1. Operator submits the LP's signed mint intent to `mintPositionFor`
2. System verifies the EIP-712 signature matches the LP's address using the cached domain separator
3. System validates: tickLower (20) < tickUpper (80), both divisible by tickSpacing (10), phase == Active, usdcAmount > 0
4. System confirms the escrow covers the intent exactly: `pendingDeposits[intentId] == 600`
5. System records intentId as used in the usedIntents mapping and clears the escrow entry
6. System initializes tick 20: feeGrowthOutsideX128 = feeGrowthGlobalX128 (1000), since tick 20 <= currentTick (50)
7. System initializes tick 80: feeGrowthOutsideX128 = 0, since tick 80 > currentTick (50)
8. System updates tick state: liquidityGross += liquidity on ticks 20 and 80; liquidityNet += liquidity on tick 20, liquidityNet -= liquidity on tick 80
9. System computes liquidity = 600 * PRECISION / (80 - 20)
10. System creates position at nextPositionId with owner = LP, tickLower = 20, tickUpper = 80, computed liquidity, feeGrowthInsideLastX128 = feeGrowthInside([20, 80]), tokensOwed = 0
11. System adds liquidity to activeLiquidity (position is in-range: 20 <= 50 < 80)

**Outcomes:**
- Position record exists at positionId with owner = LP, liquidity > 0, feeGrowthInsideLastX128 set
- `pendingDeposits[intentId] == 0` -- the escrow has been converted into the position and can no longer be reclaimed
- LP's USDC balance is unchanged by this call, and the vault's USDC balance is unchanged: the 600 moved at escrow time, not here
- activeLiquidity increased by the position's liquidity
- nextPositionId incremented by 1

**Side Effects:**
- `PositionMinted(positionId, lp, 20, 80, liquidity, 600, intentId)` event emitted
- `positions[positionId]` storage: new record created
- `pendingDeposits[intentId]` storage: deleted
- No USDC transferred -- mint performs no external token call at all
- `ticks[20]` storage: initialized with feeGrowthOutsideX128 = feeGrowthGlobalX128, liquidityGross and liquidityNet updated
- `ticks[80]` storage: initialized with feeGrowthOutsideX128 = 0, liquidityGross and liquidityNet updated
- `usedIntents[intentId]` storage: set to true
- `nextPositionId` storage: incremented
- `activeLiquidity` storage: increased by liquidity
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful mint is proof the Operator is alive (FEAT-JXQO)
- No fee distribution triggered
- No tick crossing triggered

---

### SC-T7AI: Successful out-of-range mint (above current tick)

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 2000
- LP signed a valid MintIntent: tickLower = 60, tickUpper = 90, usdcAmount = 300, unique intentId
- The Operator already escrowed that intent: `pendingDeposits[intentId] == 300`
- Ticks 60 and 90 have never been used

**Steps:**
1. Operator submits the LP's signed mint intent
2. System verifies signature and validates inputs
3. System confirms the escrow covers the intent exactly and records intentId as used, clearing the escrow entry
4. System initializes tick 60: feeGrowthOutsideX128 = 0 (tick 60 > currentTick 50)
5. System initializes tick 90: feeGrowthOutsideX128 = 0 (tick 90 > currentTick 50)
6. System updates tick state on both ticks
7. System computes liquidity and creates position with feeGrowthInsideLastX128 snapshot
8. System does NOT modify activeLiquidity (currentTick 50 < tickLower 60, position is out-of-range)

**Outcomes:**
- Position exists with owner = LP but is out-of-range
- `pendingDeposits[intentId] == 0`
- activeLiquidity unchanged
- Position will start earning fees when currentTick enters [60, 90) via future updateTick calls

**Side Effects:**
- `PositionMinted(positionId, lp, 60, 90, liquidity, 300, intentId)` event emitted
- Position and tick storage updated
- `usedIntents[intentId]` set to true
- `pendingDeposits[intentId]` storage: deleted
- No change to `activeLiquidity` storage
- No USDC transferred

---

### SC-T7AJ: Second position on existing tick

**Given:**
- Vault with currentTick = 50, tickSpacing = 10
- Tick 20 already initialized with liquidityGross = 100, feeGrowthOutsideX128 = 500 (from a previous mint)
- Tick 60 never used
- LP signed a valid MintIntent: tickLower = 20, tickUpper = 60, usdcAmount = 400, unique intentId
- The Operator already escrowed that intent: `pendingDeposits[intentId] == 400`

**Steps:**
1. Operator submits the LP's signed mint intent
2. System verifies signature and validates inputs
3. System confirms the escrow covers the intent exactly and records intentId as used, clearing the escrow entry
4. System finds tick 20 already initialized (liquidityGross > 0) -- skips feeGrowthOutsideX128 initialization
5. System initializes tick 60 (feeGrowthOutsideX128 = 0, since 60 > currentTick 50)
6. System accumulates liquidityGross on tick 20 (existing 100 + new liquidity)
7. System creates position with feeGrowthInsideLastX128 snapshot
8. System adds liquidity to activeLiquidity (20 <= 50 < 60)

**Outcomes:**
- Tick 20's liquidityGross increased by the new position's liquidity
- Tick 20's feeGrowthOutsideX128 unchanged (preserved at 500, not re-initialized)
- New position created with correct feeGrowthInsideLastX128
- `pendingDeposits[intentId] == 0`

**Side Effects:**
- `PositionMinted` event emitted
- `ticks[20].liquidityGross` storage: increased additively; `feeGrowthOutsideX128` preserved
- `ticks[60]` storage: initialized
- Position and intent storage updated
- `pendingDeposits[intentId]` storage: deleted
- No USDC transferred

---

### SC-T7AK: Inverted range revert

**Given:**
- LP signed a MintIntent with tickLower = 80, tickUpper = 20

**Steps:**
1. Operator submits the LP's signed mint intent
2. System detects tickLower (80) >= tickUpper (20)

**Outcomes:**
- Call reverts with InvalidRange error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AL: Misaligned tick revert

**Given:**
- Vault with tickSpacing = 10
- LP signed a MintIntent with tickLower = 15, tickUpper = 80

**Steps:**
1. Operator submits the LP's signed mint intent
2. System detects tickLower (15) % tickSpacing (10) != 0

**Outcomes:**
- Call reverts with TickNotAligned error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AM: Non-active vault revert

**Given:**
- Vault in WindDown phase (phase != 1)
- LP signed a valid MintIntent with correct range and amount

**Steps:**
1. Operator submits the LP's signed mint intent
2. System detects phase != Active

**Outcomes:**
- Call reverts with VaultNotActive error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AN: Non-operator caller revert

**Given:**
- Caller is not a registered Operator (e.g., the LP themselves, Admin, Oracle, or an arbitrary address)
- LP signed a valid MintIntent

**Steps:**
1. Non-operator calls `mintPositionFor` with the LP's valid signed intent
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AO: First mint below minimum liquidity

**Given:**
- Vault with activeLiquidity == 0 and minimumFirstLiquidity = 1000 * PRECISION
- LP signed a MintIntent that would produce liquidity < minimumFirstLiquidity (e.g., small usdcAmount with wide range)

**Steps:**
1. Operator submits the LP's signed mint intent
2. System verifies signature and validates range/ticks
3. System computes liquidity from usdcAmount and range width
4. System detects activeLiquidity == 0 and computed liquidity < minimumFirstLiquidity

**Outcomes:**
- Call reverts with BelowMinimumFirstLiquidity error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AP: Duplicate intentId revert

**Given:**
- intentId 0xabc... has already been used in a previous successful mint (usedIntents[0xabc...] == true)
- LP signed a new MintIntent reusing the same intentId

**Steps:**
1. Operator submits the mint intent with the already-used intentId
2. System detects usedIntents[intentId] == true

**Outcomes:**
- Call reverts with IntentAlreadyUsed error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AQ: Invalid signature revert

**Given:**
- LP signed a MintIntent, but Operator submits it with a different LP address than the actual signer
- OR: signature has been tampered with (wrong v, high-s, or modified fields)

**Steps:**
1. Operator submits the mint intent
2. System recovers the signer from the EIP-712 signature
3. System detects recovered signer != specified LP address, or signature fails malleability check

**Outcomes:**
- Call reverts with InvalidSignature error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AR: Zero amount revert

**Given:**
- LP signed a MintIntent with usdcAmount = 0

**Steps:**
1. Operator submits the LP's signed mint intent
2. System detects usdcAmount == 0

**Outcomes:**
- Call reverts with ZeroAmount error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-3Z9J: Revert when no deposit is escrowed for the intent

**Given:**
- Vault in Active phase, currentTick = 50, tickSpacing = 10
- LP signed a valid MintIntent with a well-formed range and usdcAmount = 600, intentId = X
- No `depositForIntent` has ever been called for X, so `pendingDeposits[X] == 0`

**Steps:**
1. Operator submits the LP's signed mint intent to `mintPositionFor`
2. System verifies the signature and validates the range, tick alignment, phase, and amount
3. System reads `pendingDeposits[X]` and finds 0

**Outcomes:**
- Call reverts with DepositNotEscrowed error
- No position is created against USDC the vault never collected -- an unfunded intent cannot mint liquidity out of thin air

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged -- a failed call is not proof of life

---

### SC-3Z9K: Revert when the escrowed amount does not match the intent

**Given:**
- Vault in Active phase
- `pendingDeposits[X] == 400` from a prior `depositForIntent` against an intent for 400 USDC
- Operator submits a MintIntent for the same intentId X but with usdcAmount = 600, validly signed by the LP

**Steps:**
1. Operator submits the LP's signed mint intent to `mintPositionFor`
2. System verifies the signature and validates the range, tick alignment, phase, and amount
3. System reads `pendingDeposits[X]` and finds 400, which is not equal to the intent's 600

**Outcomes:**
- Call reverts with DepositNotEscrowed error
- The position's liquidity can never exceed the USDC actually collected for it, and no partial remainder is silently stranded in escrow

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still 400, still reclaimable by the LP
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-45IE: Revert when the escrow belongs to a different LP

**Given:**
- Vault in Active phase, currentTick = 50, tickSpacing = 10
- LP A funded intentId X: `pendingDeposits[X].lp == A`, `.amount == 600`
- LP B validly signs their own MintIntent naming themselves, over the same intentId X and the same 600
- The Operator submits B's intent

**Steps:**
1. Operator submits B's signed mint intent to `mintPositionFor`
2. System verifies the EIP-712 signature, which recovers to B and matches the named LP B
3. System reads the escrow for X and finds it is recorded against A, not B

**Outcomes:**
- Call reverts with NotIntentOwner error
- No position is created for B, and A's escrow of 600 is untouched and still mintable
- A valid signature over an intentId does not entitle the signer to that intentId's escrow: anyone can sign over any intentId, so the recorded depositor is what settles ownership

**Side Effects:**
- No state changes
- `pendingDeposits[X]` still `(A, 600)`
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3XU5: Successful mint refreshes the Operator silence timer

**Given:**
- Vault is in Active phase and the Operator holds a valid LP mint intent
- `lastOperatorActivityTimestamp` is old enough that the emergency-cancel timelock would otherwise be within reach

**Steps:**
1. Operator submits the LP's signed mint intent to `mintPositionFor`
2. The mint completes as in SC-T7AH
3. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`

**Outcomes:**
- `lastOperatorActivityTimestamp == block.timestamp`
- Processing LP deposits now counts as proof of life, where previously it did not

**Side Effects:**
- All the normal side effects of a successful mint (SC-T7AH)
- `lastOperatorActivityTimestamp` storage refreshed

---

### SC-3XU6: Reverted mint leaves the Operator silence timer untouched

**Given:**
- Vault is in Active phase
- `lastOperatorActivityTimestamp` holds some earlier value T

**Steps:**
1. Operator submits a mint that fails validation -- for example a duplicate `intentId` (SC-T7AP) or an inverted range (SC-T7AK)
2. The whole transaction reverts

**Outcomes:**
- The call reverts with the relevant error
- `lastOperatorActivityTimestamp` is still T -- a failed call is not proof of life

**Side Effects:**
- No state changes at all
- No events emitted

---
