---
id: UC-T7AG
name: Operator Mint Position for LP
feature: FEAT-T7AF
status: implemented
version: 4
actor: Operator
---

# UC-T7AG: Operator Mint Position for LP

> An Operator mints the concentrated-liquidity position that an escrowed mint intent authorizes, initializing tick state and anchoring the fee snapshot so the position earns only future fees.

## Preconditions

- A vault has been deployed and initialized for a market (FEAT-REPZ UC-REQ1)
- The vault is in Active phase (phase == 1)
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The Operator escrowed the LP's USDC against `intentId` through `depositForIntent` (FEAT-3ZRI UC-3Z92), so `pendingDeposits[intentId]` names the LP's Safe, the amount, and the intent hash

## Trigger

Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, deadline)` on the vault.

---

### SC-T7AH: Successful in-range mint with fresh ticks

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 1000
- The Operator escrowed 600 USDC from the LP's Safe against intentId (UC-3Z92), so `pendingDeposits[intentId] = (Safe, 600, hash)` and the vault holds the 600 USDC
- The MintIntent: lp = the Safe, tickLower = 20, tickUpper = 80, usdcAmount = 600, intentId = unique value, deadline = the signed deadline
- Ticks 20 and 80 have never been used (liquidityGross == 0 on both)

**Steps:**
1. Operator calls `mintPositionFor(Safe, 20, 80, 600, intentId, deadline)`
2. System validates: phase == Active, usdcAmount > 0, tickLower (20) < tickUpper (80), both divisible by tickSpacing (10)
3. System checks `usedIntents[intentId]` is false, that the escrow's recorded Safe equals `lp`, and that the recorded hash equals the hash recomputed from the six arguments
4. System records intentId as used, deletes the escrow, and subtracts 600 from totalEscrowed
5. System initializes tick 20: feeGrowthOutsideX128 = feeGrowthGlobalX128 (1000), since tick 20 <= currentTick (50)
6. System initializes tick 80: feeGrowthOutsideX128 = 0, since tick 80 > currentTick (50)
7. System updates tick state: liquidityGross += liquidity on ticks 20 and 80; liquidityNet += liquidity on tick 20, liquidityNet -= liquidity on tick 80
8. System computes liquidity = 600 * PRECISION / (80 - 20)
9. System creates position at nextPositionId with owner = the Safe, tickLower = 20, tickUpper = 80, computed liquidity, feeGrowthInsideLastX128 = feeGrowthInside([20, 80]), tokensOwed = 0
10. System adds liquidity to activeLiquidity (position is in-range: 20 <= 50 < 80)
11. System makes no external call

**Outcomes:**
- Position record exists at positionId with owner = the Safe, liquidity > 0, feeGrowthInsideLastX128 set
- The vault's USDC balance is unchanged by the mint
- `pendingDeposits[intentId]` is deleted and totalEscrowed decreased by 600
- activeLiquidity increased by the position's liquidity
- nextPositionId incremented by 1

**Side Effects:**
- `PositionMinted(positionId, Safe, 20, 80, liquidity, 600, intentId)` event emitted
- `positions[positionId]` storage: new record created
- `ticks[20]` storage: initialized with feeGrowthOutsideX128 = feeGrowthGlobalX128, liquidityGross and liquidityNet updated
- `ticks[80]` storage: initialized with feeGrowthOutsideX128 = 0, liquidityGross and liquidityNet updated
- `usedIntents[intentId]` storage: set to true
- `pendingDeposits[intentId]` storage: deleted
- `totalEscrowed` storage: decreased by 600
- `nextPositionId` storage: incremented
- `activeLiquidity` storage: increased by liquidity
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful mint is proof the Operator is alive (FEAT-JXQO)
- No USDC transferred
- No fee distribution triggered
- No tick crossing triggered

---

### SC-T7AI: Successful out-of-range mint (above current tick)

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 2000
- The Operator escrowed 300 USDC from the LP's Safe against a unique intentId, and the MintIntent names the Safe, tickLower = 60, tickUpper = 90, 300, the intentId, and a deadline
- Ticks 60 and 90 have never been used

**Steps:**
1. Operator calls `mintPositionFor` with the intent's six fields
2. System validates inputs and requires the recorded Safe and the recorded hash
3. System records intentId as used
4. System initializes tick 60: feeGrowthOutsideX128 = 0 (tick 60 > currentTick 50)
5. System initializes tick 90: feeGrowthOutsideX128 = 0 (tick 90 > currentTick 50)
6. System updates tick state on both ticks
7. System computes liquidity and creates position with feeGrowthInsideLastX128 snapshot
8. System does NOT modify activeLiquidity (currentTick 50 < tickLower 60, position is out-of-range)
9. System deletes the escrow and subtracts 300 from totalEscrowed; no USDC moves

**Outcomes:**
- Position exists with owner = the Safe but is out-of-range
- activeLiquidity unchanged
- Position will start earning fees when currentTick enters [60, 90) via future updateTick calls

**Side Effects:**
- `PositionMinted(positionId, Safe, 60, 90, liquidity, 300, intentId)` event emitted
- Position and tick storage updated
- `usedIntents[intentId]` set to true
- `pendingDeposits[intentId]` deleted; `totalEscrowed` decreased by 300
- No USDC transferred
- No change to `activeLiquidity` storage

---

### SC-T7AJ: Second position on existing tick

**Given:**
- Vault with currentTick = 50, tickSpacing = 10
- Tick 20 already initialized with liquidityGross = 100, feeGrowthOutsideX128 = 500 (from a previous mint)
- Tick 60 never used
- The Operator escrowed 400 USDC from the LP's Safe against a unique intentId, and the MintIntent names the Safe, tickLower = 20, tickUpper = 60, 400, the intentId, and a deadline

**Steps:**
1. Operator calls `mintPositionFor` with the intent's six fields
2. System validates inputs and requires the recorded Safe and the recorded hash
3. System records intentId as used
4. System finds tick 20 already initialized (liquidityGross > 0) -- skips feeGrowthOutsideX128 initialization
5. System initializes tick 60 (feeGrowthOutsideX128 = 0, since 60 > currentTick 50)
6. System accumulates liquidityGross on tick 20 (existing 100 + new liquidity)
7. System creates position with feeGrowthInsideLastX128 snapshot
8. System adds liquidity to activeLiquidity (20 <= 50 < 60)
9. System deletes the escrow and subtracts 400 from totalEscrowed; no USDC moves

**Outcomes:**
- Tick 20's liquidityGross increased by the new position's liquidity
- Tick 20's feeGrowthOutsideX128 unchanged (preserved at 500, not re-initialized)
- New position created with correct feeGrowthInsideLastX128

**Side Effects:**
- `PositionMinted` event emitted
- `ticks[20].liquidityGross` storage: increased additively; `feeGrowthOutsideX128` preserved
- `ticks[60]` storage: initialized
- Position and intent storage updated
- `pendingDeposits[intentId]` deleted; `totalEscrowed` decreased by 400
- No USDC transferred

---

### SC-8L1C: Mint over a stale shared tick succeeds

**Given:**
- Vault with tickSpacing = 10 and currentTick = 0
- LP holds P1 = [0, 300) and P2 = [100, 200), both minted at currentTick = 0, so ticks 100, 200, and 300 initialized with feeGrowthOutsideX128 = 0
- The Operator called notifyFees, so feeGrowthGlobalX128 = G1 > 0
- The Operator called updateTick(150), which crossed tick 100 and set ticks[100].feeGrowthOutsideX128 = G1
- The Operator called notifyFees again, so feeGrowthGlobalX128 = G2 > G1
- Tick 50 has never been used
- The Operator escrowed 500 USDC from the LP's Safe against a unique intentId, and the MintIntent names the Safe, tickLower = 50, tickUpper = 100, 500, the intentId, and a deadline

**Steps:**
1. Operator calls `mintPositionFor` with the intent's six fields
2. System validates inputs and requires the recorded Safe and the recorded hash
3. System records intentId as used
4. System initializes tick 50 with feeGrowthOutsideX128 = G2, since 50 <= currentTick (150)
5. System finds tick 100 already initialized and keeps feeGrowthOutsideX128 = G1
6. System computes feeGrowthInside([50, 100)) = G2 - G2 - (G2 - G1), which wraps modulo 2^256 to 2^256 - (G2 - G1), inside `unchecked`
7. System creates the position with feeGrowthInsideLastX128 = that wrapped value
8. System does NOT modify activeLiquidity (currentTick 150 >= tickUpper 100, position is out of range)
9. System deletes the escrow and subtracts 500 from totalEscrowed; no USDC moves

**Outcomes:**
- The mint does not revert
- Position exists with owner = the Safe, liquidity > 0, and feeGrowthInsideLastX128 = 2^256 - (G2 - G1)
- activeLiquidity unchanged

**Side Effects:**
- `PositionMinted` event emitted
- `ticks[50]` storage: initialized with feeGrowthOutsideX128 = G2
- `ticks[100]` storage: feeGrowthOutsideX128 preserved at G1, liquidityGross increased
- Position and intent storage updated
- `pendingDeposits[intentId]` deleted; `totalEscrowed` decreased by 500
- No USDC transferred
- No fee distribution triggered
- No tick crossing triggered

---

### SC-T7AK: Inverted range revert

**Given:**
- The Operator calls `mintPositionFor` with tickLower = 80, tickUpper = 20

**Steps:**
1. Operator submits the mint call
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
- The Operator calls `mintPositionFor` with tickLower = 15, tickUpper = 80

**Steps:**
1. Operator submits the mint call
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
- An escrow exists for the intent, with a correct range and amount

**Steps:**
1. Operator submits the mint call
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
- Caller is not a registered Operator (e.g., the LP's Safe, Admin, Oracle, or an arbitrary address)
- An escrow exists for the intent

**Steps:**
1. Non-operator calls `mintPositionFor` with the intent's six fields
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
- The Operator escrowed an intent that would produce liquidity < minimumFirstLiquidity (e.g., small usdcAmount with wide range)

**Steps:**
1. Operator submits the mint call
2. System validates range/ticks and requires the recorded Safe and hash
3. System computes liquidity from usdcAmount and range width
4. System detects activeLiquidity == 0 and computed liquidity < minimumFirstLiquidity

**Outcomes:**
- Call reverts with BelowMinimumFirstLiquidity error
- The escrow stays in place, so the Safe can reclaim it

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-T7AP: Duplicate intentId revert

**Given:**
- intentId 0xabc... has already been used in a previous successful mint or reclaim (usedIntents[0xabc...] == true), and no escrow exists for it

**Steps:**
1. Operator calls `mintPositionFor` with the already-used intentId
2. System detects usedIntents[intentId] == true before it reads the escrow

**Outcomes:**
- Call reverts with IntentAlreadyUsed error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-3Z9J: Revert when no deposit is escrowed for the intent

**Given:**
- No escrow exists for intentId X (`pendingDeposits[X].lp == address(0)`) and `usedIntents[X] == false`

**Steps:**
1. Operator calls `mintPositionFor` for X
2. System reads the escrow and finds no recorded Safe

**Outcomes:**
- Call reverts with DepositNotEscrowed error
- No position exists without recorded USDC (audit issue 6.1 from the mint side)

**Side Effects:**
- No state changes
- No position created
- No tick change
- `usedIntents[X]` unchanged
- No events emitted

---

### SC-45IE: Revert when the escrow belongs to a different Safe

**Given:**
- An escrow is recorded for Safe A under intentId X

**Steps:**
1. Operator calls `mintPositionFor` naming Safe B with the same intentId X and the same other fields
2. System reads the escrow and finds it recorded for A, not B

**Outcomes:**
- Call reverts with NotIntentOwner error
- A's escrow is untouched

**Side Effects:**
- No state changes
- No events emitted

---

### SC-3Z9K: Revert when the recorded hash does not match the arguments

**Given:**
- An escrow is recorded for (Safe, 20, 80, 600, intentId, deadline)

**Steps:**
1. Operator calls `mintPositionFor` with a different range, a different amount, or a different deadline
2. System recomputes the struct hash from the six arguments and finds it differs from the recorded hash

**Outcomes:**
- Call reverts with IntentMismatch error
- The escrow stays in place with its recorded terms

**Side Effects:**
- No state changes
- No events emitted

---

### SC-T7AR: Zero amount revert

**Given:**
- The Operator calls `mintPositionFor` with usdcAmount = 0

**Steps:**
1. Operator submits the mint call
2. System detects usdcAmount == 0

**Outcomes:**
- Call reverts with ZeroAmount error

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted

---

### SC-3XU5: Successful mint refreshes the Operator silence timer

**Given:**
- Vault is in Active phase and the Operator escrowed an LP's intent
- `lastOperatorActivityTimestamp` is old enough that the emergency-cancel timelock would otherwise be within reach

**Steps:**
1. Operator calls `mintPositionFor` with the intent's six fields
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
