---
id: UC-T7AG
name: Operator Mint Position for LP
feature: FEAT-T7AF
status: implemented
version: 1
actor: Operator
---

# UC-T7AG: Operator Mint Position for LP

> An Operator executes an LP's signed EIP-712 mint intent to create a concentrated-liquidity position, initializing tick state and anchoring the fee snapshot so the position earns only future fees.

## Preconditions

- A vault has been deployed and initialized for a market (FEAT-REPZ UC-REQ1)
- The vault is in Active phase (phase == 1)
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The LP has approved the vault contract to spend their USDC (`IERC20(usdc).approve(vault, amount)`)

## Trigger

Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, signature)` on the vault.

---

### SC-T7AH: Successful in-range mint with fresh ticks

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 1000
- LP has sufficient USDC and has approved the vault for >= 600
- LP signed a valid MintIntent: lp = LP address, tickLower = 20, tickUpper = 80, usdcAmount = 600, intentId = unique value
- Ticks 20 and 80 have never been used (liquidityGross == 0 on both)

**Steps:**
1. Operator submits the LP's signed mint intent to `mintPositionFor`
2. System verifies the EIP-712 signature matches the LP's address using the cached domain separator
3. System validates: tickLower (20) < tickUpper (80), both divisible by tickSpacing (10), phase == Active, usdcAmount > 0
4. System records intentId as used in the usedIntents mapping
5. System initializes tick 20: feeGrowthOutsideX128 = feeGrowthGlobalX128 (1000), since tick 20 <= currentTick (50)
6. System initializes tick 80: feeGrowthOutsideX128 = 0, since tick 80 > currentTick (50)
7. System updates tick state: liquidityGross += liquidity on ticks 20 and 80; liquidityNet += liquidity on tick 20, liquidityNet -= liquidity on tick 80
8. System computes liquidity = 600 * PRECISION / (80 - 20)
9. System creates position at nextPositionId with owner = LP, tickLower = 20, tickUpper = 80, computed liquidity, feeGrowthInsideLastX128 = feeGrowthInside([20, 80]), tokensOwed = 0
10. System adds liquidity to activeLiquidity (position is in-range: 20 <= 50 < 80)
11. System pulls 600 USDC from LP's wallet via transferFrom

**Outcomes:**
- Position record exists at positionId with owner = LP, liquidity > 0, feeGrowthInsideLastX128 set
- LP's USDC balance decreased by 600; vault's USDC balance increased by 600
- activeLiquidity increased by the position's liquidity
- nextPositionId incremented by 1

**Side Effects:**
- `PositionMinted(positionId, lp, 20, 80, liquidity, 600, intentId)` event emitted
- `positions[positionId]` storage: new record created
- `ticks[20]` storage: initialized with feeGrowthOutsideX128 = feeGrowthGlobalX128, liquidityGross and liquidityNet updated
- `ticks[80]` storage: initialized with feeGrowthOutsideX128 = 0, liquidityGross and liquidityNet updated
- `usedIntents[intentId]` storage: set to true
- `nextPositionId` storage: incremented
- `activeLiquidity` storage: increased by liquidity
- No fee distribution triggered
- No tick crossing triggered

---

### SC-T7AI: Successful out-of-range mint (above current tick)

**Given:**
- Vault with currentTick = 50, tickSpacing = 10, feeGrowthGlobalX128 = 2000
- LP signed a valid MintIntent: tickLower = 60, tickUpper = 90, usdcAmount = 300, unique intentId
- Ticks 60 and 90 have never been used

**Steps:**
1. Operator submits the LP's signed mint intent
2. System verifies signature and validates inputs
3. System records intentId as used
4. System initializes tick 60: feeGrowthOutsideX128 = 0 (tick 60 > currentTick 50)
5. System initializes tick 90: feeGrowthOutsideX128 = 0 (tick 90 > currentTick 50)
6. System updates tick state on both ticks
7. System computes liquidity and creates position with feeGrowthInsideLastX128 snapshot
8. System does NOT modify activeLiquidity (currentTick 50 < tickLower 60, position is out-of-range)
9. System pulls 300 USDC from LP's wallet

**Outcomes:**
- Position exists with owner = LP but is out-of-range
- activeLiquidity unchanged
- Position will start earning fees when currentTick enters [60, 90) via future updateTick calls

**Side Effects:**
- `PositionMinted(positionId, lp, 60, 90, liquidity, 300, intentId)` event emitted
- Position and tick storage updated
- `usedIntents[intentId]` set to true
- No change to `activeLiquidity` storage

---

### SC-T7AJ: Second position on existing tick

**Given:**
- Vault with currentTick = 50, tickSpacing = 10
- Tick 20 already initialized with liquidityGross = 100, feeGrowthOutsideX128 = 500 (from a previous mint)
- Tick 60 never used
- LP signed a valid MintIntent: tickLower = 20, tickUpper = 60, usdcAmount = 400, unique intentId

**Steps:**
1. Operator submits the LP's signed mint intent
2. System verifies signature and validates inputs
3. System records intentId as used
4. System finds tick 20 already initialized (liquidityGross > 0) -- skips feeGrowthOutsideX128 initialization
5. System initializes tick 60 (feeGrowthOutsideX128 = 0, since 60 > currentTick 50)
6. System accumulates liquidityGross on tick 20 (existing 100 + new liquidity)
7. System creates position with feeGrowthInsideLastX128 snapshot
8. System adds liquidity to activeLiquidity (20 <= 50 < 60)
9. System pulls 400 USDC from LP

**Outcomes:**
- Tick 20's liquidityGross increased by the new position's liquidity
- Tick 20's feeGrowthOutsideX128 unchanged (preserved at 500, not re-initialized)
- New position created with correct feeGrowthInsideLastX128

**Side Effects:**
- `PositionMinted` event emitted
- `ticks[20].liquidityGross` storage: increased additively; `feeGrowthOutsideX128` preserved
- `ticks[60]` storage: initialized
- Position and intent storage updated

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
