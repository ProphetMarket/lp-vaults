---
id: UC-REQ1
name: Create Vault for Market
feature: FEAT-REPZ
status: implemented
version: 10
actor: Oracle
---

# UC-REQ1: Create Vault for Market

> Oracle deploys a per-market LP vault so that LPs can deposit USDC and provide liquidity for a specific prediction market.

## Preconditions

- LPVaultFactory is deployed and initialized (UC-REQ0 completed)

## Trigger

Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` on the LPVaultFactory, or calls `setMinimumFirstLiquidity(newMin)` on an existing vault to adjust its first-LP floor. An Admin calls `setDefaultEmergencyCancelTimelock(newTimelock)` on the LPVaultFactory to set the emergency-cancel timelock that later vaults copy.

---

### SC-REQ6: Successful vault creation

**Given:**
- marketId has no existing vault in the registry
- tickSpacing > 0
- minimumFirstLiquidity > 0
- conditionId is a prepared 2-outcome condition on the ConditionalTokens contract
- yesTokenId is the index set 1 position ID and noTokenId is the index set 2 position ID of `(usdc, conditionId)`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` on the factory
2. System checks the identity: non-zero values, distinct IDs, outcome slot count 2, and the index set 1 and index set 2 position IDs
3. System deploys an EIP-1167 minimal-proxy clone of the implementation contract
4. System calls `initialize(marketId, usdc, exchange, conditionalTokens, tickSpacing, factory, minimumFirstLiquidity, version, conditionId, yesTokenId, noTokenId)` on the clone
5. Clone stores all config in storage (not immutable -- EIP-1167 constraint), sets `phase = Active`, sets `activeLiquidity = 0`, sets `minimumFirstLiquidity` to the passed value, records `conditionId`, `yesTokenId`, and `noTokenId`, and reads `defaultEmergencyCancelTimelock()` from the factory once into `emergencyCancelTimelock`
6. Clone approves CTF Exchange for unlimited USDC spending and calls `setApprovalForAll` on ConditionalTokens for the exchange
7. System registers `vaultForMarket[marketId] = cloneAddress`

**Outcomes:**
- A new vault clone exists and is registered in the factory
- The vault is in Active phase with `activeLiquidity == 0`, ready for the Operator to credit the first position
- The vault delegates operator, oracle, and admin authorization to the factory contract -- no local role state is stored
- The minimum-first-liquidity floor is set to the Oracle-supplied value
- `conditionId`, `yesTokenId`, and `noTokenId` are readable on the vault
- `emergencyCancelTimelock()` on the vault equals the factory's `defaultEmergencyCancelTimelock()` at the moment of the call (7 days on a fresh factory)
- The vault can receive its two ERC-1155 outcome tokens from its ConditionalTokens contract and rejects every other token ID (SC-3WLL, SC-3WLM, SC-6HBY)

**Side Effects:**
- `VaultCreated(marketId, vaultAddress, minimumFirstLiquidity)` event emitted by the factory
- One `getOutcomeSlotCount`, two `getCollectionId`, and two `getPositionId` view calls made by the factory against the ConditionalTokens contract -- no state written on that contract
- No `PositionMinted` event -- no position is minted at vault creation
- No USDC transferred
- ERC-20 approval set: vault -> exchange for USDC
- ERC-1155 approval set: vault -> exchange for ConditionalTokens

---

### SC-REQ7: Duplicate marketId reverts

**Given:**
- marketId M already has a registered vault (SC-REQ6 completed for M)

**Steps:**
1. Oracle calls `createVault(M, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System checks `vaultForMarket[M]`

**Outcomes:**
- The call reverts with a duplicate-market error

**Side Effects:**
- No clone deployed
- No USDC transferred
- No events emitted

---

### SC-REQ8: Non-Oracle caller reverts

**Given:**
- Caller is an Operator, Admin, or any non-Oracle address

**Steps:**
1. Non-Oracle address calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System checks the `onlyOracle` modifier

**Outcomes:**
- The call reverts with an access control error

**Side Effects:**
- No clone deployed
- No state changes

---

### SC-REQ9: Re-initialization of vault clone reverts

**Given:**
- A vault clone has been created and initialized (SC-REQ6 completed)

**Steps:**
1. Any address calls `initialize()` on the vault clone
2. System checks the one-shot initializer guard

**Outcomes:**
- The call reverts

**Side Effects:**
- No state changes on the vault clone

---

### SC-REQA: Only factory can call initialize

**Given:**
- A fresh vault clone exists (deployed but not yet initialized)

**Steps:**
1. A non-factory address calls `initialize()` on the vault clone
2. System checks `msg.sender == factory_` inline, because `factory` is not yet stored when a clone is initialized (no `onlyFactory` modifier exists; finding CV-05 of `audits/code-validation-round-1.md`)

**Outcomes:**
- The call reverts with `NotFactory`

**Side Effects:**
- No state changes

---

### SC-RG74: createVault reverts when minimumFirstLiquidity is zero

**Given:**
- marketId has no existing vault in the registry
- Oracle passes `minimumFirstLiquidity = 0`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, 0, conditionId, yesTokenId, noTokenId)`
2. System validates the floor parameter

**Outcomes:**
- The call reverts with a zero-floor error

**Side Effects:**
- No clone deployed
- No state changes
- No events emitted

---

### SC-6HBV: createVault reverts on a malformed outcome-token identity

**Given:**
- marketId has no existing vault in the registry
- tickSpacing > 0 and minimumFirstLiquidity > 0
- The Oracle passes one of: `conditionId = bytes32(0)`, `yesTokenId = 0`, `noTokenId = 0`, or `yesTokenId == noTokenId`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System checks the identity values before it deploys a clone and before it calls the ConditionalTokens contract

**Outcomes:**
- The call reverts with `ZeroConditionId` for a zero condition ID, `ZeroTokenId` for either zero token ID, and `DuplicateTokenId` for equal IDs
- No vault exists for that marketId, so the Oracle can call again with the correct identity

**Side Effects:**
- No clone deployed
- Nothing registered in `vaultForMarket`
- No approvals granted
- No events emitted
- No call to the ConditionalTokens contract

---

### SC-6HBW: createVault reverts when the condition is not a prepared binary condition

**Given:**
- marketId has no existing vault in the registry
- conditionId, yesTokenId, and noTokenId are non-zero and the IDs are distinct
- `getOutcomeSlotCount(conditionId)` on the ConditionalTokens contract returns 0 (condition not prepared) or 3 (a 3-outcome condition)

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System reads the outcome slot count of `conditionId`

**Outcomes:**
- The call reverts with `NotBinaryCondition` in both cases

**Side Effects:**
- No clone deployed
- Nothing registered in `vaultForMarket`
- No approvals granted
- No events emitted

---

### SC-6HBX: createVault reverts when the token IDs do not match the condition's index sets

**Given:**
- marketId has no existing vault in the registry
- conditionId is a prepared 2-outcome condition
- Case A: yesTokenId and noTokenId are the valid pair of a different condition
- Case B: yesTokenId is the index set 2 ID and noTokenId is the index set 1 ID of `conditionId` (the correct pair, swapped)

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System derives the index set 1 and index set 2 position IDs from USDC and `conditionId`
3. System compares `yesTokenId` with the index set 1 ID and `noTokenId` with the index set 2 ID

**Outcomes:**
- Both cases revert with `TokenIdMismatch`
- No vault can be created that names one market's condition and another market's tokens, or that labels NO as YES

**Side Effects:**
- No clone deployed
- Nothing registered in `vaultForMarket`
- No approvals granted
- No events emitted

---

### SC-RG75: Oracle updates minimumFirstLiquidity successfully

**Given:**
- A vault exists with `minimumFirstLiquidity == M` (set at createVault time)
- Caller is the Oracle

**Steps:**
1. Oracle calls `setMinimumFirstLiquidity(newMin)` on the vault, with `newMin > 0`
2. System checks the `onlyOracle` modifier
3. System validates `newMin > 0`
4. System updates the vault's `minimumFirstLiquidity` to `newMin`

**Outcomes:**
- The vault's `minimumFirstLiquidity == newMin`
- The first mint, when none has happened yet (`nextPositionId == 0`), is gated by the new value
- After the first mint the value is stored and no mint reads it

**Side Effects:**
- `MinimumFirstLiquidityUpdated(oldMin, newMin)` event emitted by the vault
- No state changes to positions, ticks, or fee accumulators

---

### SC-RG76: Non-Oracle caller cannot update minimumFirstLiquidity

**Given:**
- A vault exists with `minimumFirstLiquidity == M`
- Caller is an Operator, Admin, LP, or any non-Oracle address

**Steps:**
1. Non-Oracle address calls `setMinimumFirstLiquidity(newMin)` on the vault
2. System checks the `onlyOracle` modifier

**Outcomes:**
- The call reverts with an access control error
- `minimumFirstLiquidity` remains == M

**Side Effects:**
- No state changes
- No events emitted

---

### SC-RG77: setMinimumFirstLiquidity reverts when newMin is zero

**Given:**
- A vault exists with `minimumFirstLiquidity == M`
- Caller is the Oracle

**Steps:**
1. Oracle calls `setMinimumFirstLiquidity(0)` on the vault
2. System validates `newMin > 0`

**Outcomes:**
- The call reverts with a zero-floor error
- `minimumFirstLiquidity` remains == M

**Side Effects:**
- No state changes
- No events emitted

---

### SC-BZC2: Admin changes the default timelock, and only later vaults copy it

**Given:**
- A factory with `defaultEmergencyCancelTimelock == 7 days` and one vault V1 created from it
- The caller is an Admin

**Steps:**
1. Admin calls `setDefaultEmergencyCancelTimelock(14 days)` on the factory
2. System checks the `onlyAdmin` modifier and the bounds
3. System stores the new default
4. Oracle calls `createVault` for a second market, V2

**Outcomes:**
- `defaultEmergencyCancelTimelock() == 14 days`
- `V1.emergencyCancelTimelock() == 7 days`, unchanged
- `V2.emergencyCancelTimelock() == 14 days`
- On V1 the freeze succeeds after 7 days of silence; on V2 it reverts `TimelockNotElapsed` at 7 days and succeeds at 14

**Side Effects:**
- `DefaultEmergencyCancelTimelockUpdated(7 days, 14 days)` emitted by the factory
- `VaultCreated` for V2
- No state change on V1

---

### SC-BZC3: The default timelock setter rejects zero and a value above 30 days

**Given:**
- A factory with `defaultEmergencyCancelTimelock == 7 days`
- The caller is an Admin

**Steps:**
1. Admin calls `setDefaultEmergencyCancelTimelock(0)`
2. System reverts `ZeroTimelock`
3. Admin calls `setDefaultEmergencyCancelTimelock(30 days + 1)`
4. System reverts `TimelockTooLong`
5. Admin calls `setDefaultEmergencyCancelTimelock(30 days)`
6. System stores it

**Outcomes:**
- After steps 2 and 4 the default is still 7 days
- After step 6 it is 30 days

**Side Effects:**
- No event from the reverted calls
- `DefaultEmergencyCancelTimelockUpdated(7 days, 30 days)` from step 6

---

### SC-BZC4: Non-Admin cannot change the default timelock

**Given:**
- A factory with `defaultEmergencyCancelTimelock == 7 days`
- The caller is the Operator, the Oracle, an LP's Safe, or an arbitrary address

**Steps:**
1. The caller calls `setDefaultEmergencyCancelTimelock(14 days)`
2. System checks the `onlyAdmin` modifier

**Outcomes:**
- The call reverts `NotAdmin`
- The default stays 7 days

**Side Effects:**
- No state change
- No event emitted

---

### SC-3WLL: Vault accepts a single ERC-1155 outcome token transfer

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The ConditionalTokens contract holds the vault market's YES and NO tokens on behalf of some holder

**Steps:**
1. The holder calls `safeTransferFrom(holder, vault, yesTokenId, amount, "")` on the ConditionalTokens contract
2. ConditionalTokens credits the vault's balance and invokes `onERC1155Received` on the vault
3. The vault checks that `msg.sender` is its configured `conditionalTokens` address
4. The vault checks that the ID is its own `yesTokenId` or `noTokenId`
5. The vault returns the ERC-1155 single-transfer acknowledgement value

**Outcomes:**
- The transfer completes without reverting
- `onERC1155Received` returns `0xf23a6e61`
- The vault's ERC-1155 balance for `yesTokenId` increased by `amount`
- The same holds for a transfer of `noTokenId`

**Side Effects:**
- No change to `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, or any position or tick record
- No USDC transferred
- No merge
- No vault events emitted -- only the ConditionalTokens `TransferSingle` event

---

### SC-3WLM: Vault accepts a batch ERC-1155 outcome token transfer

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The ConditionalTokens contract holds the vault market's YES and NO tokens on behalf of some holder

**Steps:**
1. The holder calls `safeBatchTransferFrom(holder, vault, [yesTokenId, noTokenId], [amountA, amountB], "")` on the ConditionalTokens contract
2. ConditionalTokens credits the vault's balances and invokes `onERC1155BatchReceived` on the vault
3. The vault checks that `msg.sender` is its configured `conditionalTokens` address
4. The vault checks every ID in the batch against its own `yesTokenId` and `noTokenId`
5. The vault returns the ERC-1155 batch-transfer acknowledgement value

**Outcomes:**
- The transfer completes without reverting
- `onERC1155BatchReceived` returns `0xbc197c81`
- The vault's ERC-1155 balances for both token IDs increased by the transferred amounts

**Side Effects:**
- No change to `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, or any position or tick record
- No USDC transferred
- No merge
- No vault events emitted -- only the ConditionalTokens `TransferBatch` event

---

### SC-3WLN: Receiver hook called by a non-ConditionalTokens address reverts

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The caller is any address other than the vault's configured `conditionalTokens` -- an LP, the Operator, the Oracle, an arbitrary EOA, or an unrelated ERC-1155 contract

**Steps:**
1. The caller invokes `onERC1155Received(operator, from, id, value, "")` directly on the vault
2. The vault checks `msg.sender` against its configured `conditionalTokens` address
3. The same is attempted with `onERC1155BatchReceived(operator, from, ids, values, "")`

**Outcomes:**
- Both calls revert with a not-conditional-tokens error
- Neither hook returns an acknowledgement value, so an unrelated ERC-1155 contract cannot push foreign token IDs into the vault via a safe transfer

**Side Effects:**
- No state changes on the vault
- No events emitted

---

### SC-6HBY: Receiver hook rejects a token ID outside the vault's market

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The caller is the vault's own configured `conditionalTokens` contract, so the caller check of SC-3WLN passes
- The holder owns tokens of a second condition on the same ConditionalTokens contract

**Steps:**
1. The holder calls `safeTransferFrom(holder, vault, foreignTokenId, amount, "")`
2. ConditionalTokens invokes `onERC1155Received` on the vault
3. The vault compares the ID with `yesTokenId` and `noTokenId`
4. The holder calls `safeBatchTransferFrom(holder, vault, [yesTokenId, foreignTokenId], [amountA, amountB], "")`

**Outcomes:**
- Both the single and the batch transfer revert with `UnknownTokenId`
- The batch reverts although one of its two IDs is valid
- The vault's balance of the foreign ID stays zero and its balances of its own two IDs do not change

**Side Effects:**
- No state changes on the vault
- No vault events
- No ERC-1155 `TransferSingle` or `TransferBatch` event, because the transfer reverts

---

### SC-3WLO: Vault reports ERC-1155 receiver interface support

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)

**Steps:**
1. A caller invokes `supportsInterface` with the `IERC1155Receiver` interface identifier `0x4e2312e0`
2. A caller invokes `supportsInterface` with the ERC-165 interface identifier `0x01ffc9a7`
3. A caller invokes `supportsInterface` with `0xffffffff`

**Outcomes:**
- The first two calls return `true`
- The third returns `false`
- Callers that gate transfers on an ERC-165 check will proceed to transfer outcome tokens to the vault

**Side Effects:**
- None -- `supportsInterface` is a pure view

---

### SC-DU2Y: createVault reverts when tickSpacing is zero or negative

**Given:**
- marketId has no existing vault in the registry
- Oracle passes `tickSpacing = 0`, or `tickSpacing = -10`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System validates the spacing beside the floor, before the duplicate-market check and the identity check

**Outcomes:**
- The call reverts with `InvalidTickSpacing`
- No vault is registered for marketId
- A zero spacing would make every `depositForIntent` revert with a division-by-zero panic in the alignment check, and a negative spacing reads wrong in every document (finding CV-12 of `audits/code-validation-round-1.md`)

**Side Effects:**
- No clone deployed
- No state changes
- No events emitted

---

---
