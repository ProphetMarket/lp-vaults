---
id: UC-REQ1
name: Create Vault for Market
feature: FEAT-REPZ
status: implemented
version: 6
actor: Oracle
---

# UC-REQ1: Create Vault for Market

> Oracle deploys a per-market LP vault so that LPs can deposit USDC and provide liquidity for a specific prediction market.

## Preconditions

- LPVaultFactory is deployed and initialized (UC-REQ0 completed)

## Trigger

Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` on the LPVaultFactory, or calls `setMinimumFirstLiquidity(newMin)` on an existing vault to adjust its first-LP floor.

---

### SC-REQ6: Successful vault creation

**Given:**
- marketId has no existing vault in the registry
- tickSpacing > 0
- minimumFirstLiquidity > 0
- conditionId is non-zero and its condition is prepared on the ConditionalTokens contract
- yesTokenId and noTokenId are non-zero, distinct, and are the two ERC-1155 position IDs that derive from `conditionId` with USDC as collateral

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` on the factory
2. System deploys an EIP-1167 minimal-proxy clone of the implementation contract
3. System calls `initialize(marketId, usdc, exchange, conditionalTokens, tickSpacing, factory, minimumFirstLiquidity, version, conditionId, yesTokenId, noTokenId)` on the clone
4. Clone validates the outcome-token identity: rejects a zero conditionId, a zero or duplicated token ID, and any pair that does not derive from `conditionId` (SC-5XY4, SC-5XY5)
5. Clone stores all config in storage (not immutable -- EIP-1167 constraint), sets `phase = Active`, sets `activeLiquidity = 0`, sets `minimumFirstLiquidity` to the passed value, and records `conditionId`, `yesTokenId`, `noTokenId`
6. Clone approves CTF Exchange for unlimited USDC spending and calls `setApprovalForAll` on ConditionalTokens for the exchange
7. System registers `vaultForMarket[marketId] = cloneAddress`

**Outcomes:**
- A new vault clone exists and is registered in the factory
- The vault is in Active phase with `activeLiquidity == 0`, ready for the Operator to credit the first position
- The vault delegates operator, oracle, and admin authorization to the factory contract -- no local role state is stored
- The minimum-first-liquidity floor is set to the Oracle-supplied value
- The vault can name the two outcome token IDs it is allowed to hold and the `conditionId` a complete-set split requires -- readable as `conditionId`, `yesTokenId`, `noTokenId`
- The vault can receive those two ERC-1155 outcome tokens from its ConditionalTokens contract and rejects every other token ID (SC-3WLL, SC-3WLM, SC-5XY6)

**Side Effects:**
- `VaultCreated(marketId, vaultAddress, minimumFirstLiquidity)` event emitted by the factory
- Two `getCollectionId` and two `getPositionId` view calls made against the ConditionalTokens contract during initialization -- no state written on that contract
- No `PositionMinted` event -- no position is minted at vault creation
- No USDC transferred
- ERC-20 approval set: vault -> exchange for USDC
- ERC-1155 approval set: vault -> exchange for ConditionalTokens

---

### SC-REQ7: Duplicate marketId reverts

**Given:**
- marketId M already has a registered vault (SC-REQ6 completed for M)

**Steps:**
1. Oracle calls `createVault(M, tickSpacing)`
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
1. Non-Oracle address calls `createVault(marketId, tickSpacing)`
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
2. System checks the `onlyFactory` modifier

**Outcomes:**
- The call reverts with an onlyFactory error

**Side Effects:**
- No state changes

---

### SC-RG74: createVault reverts when minimumFirstLiquidity is zero

**Given:**
- marketId has no existing vault in the registry
- Oracle passes `minimumFirstLiquidity = 0`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, 0)`
2. System validates the floor parameter

**Outcomes:**
- The call reverts with a zero-floor error

**Side Effects:**
- No clone deployed
- No state changes
- No events emitted

---

### SC-5XY4: createVault reverts on a malformed outcome-token identity

**Given:**
- marketId has no existing vault in the registry
- tickSpacing > 0 and minimumFirstLiquidity > 0
- The Oracle passes one of: `conditionId = bytes32(0)`; `yesTokenId = 0`; `noTokenId = 0`; or `yesTokenId == noTokenId`

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System validates the outcome-token identity during `initialize()`

**Outcomes:**
- The call reverts -- with a zero-condition error for a zero conditionId, a zero-token-id error for either zero ID, and a duplicate-token-id error when both IDs are the same
- No vault exists for that marketId, so the Oracle can retry with the correct identity

**Side Effects:**
- No clone registered in `vaultForMarket`
- No approvals granted to the exchange
- No events emitted

---

### SC-5XY5: createVault reverts when the token IDs do not derive from the conditionId

**Given:**
- marketId has no existing vault in the registry
- conditionId, yesTokenId, and noTokenId are all non-zero and the two IDs are distinct
- At least one of the two IDs is not a position ID of `conditionId` under USDC collateral -- for example a valid ID pair belonging to a different market's condition

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)`
2. System derives the expected pair from the ConditionalTokens contract using `conditionId` and the vault's USDC collateral
3. System compares the supplied pair against the derived pair as a set

**Outcomes:**
- The call reverts with a token-id-mismatch error
- A vault can never be created holding an identity that names one market's condition and another market's tokens
- Supplying the correct pair in either argument order succeeds; the order the Oracle passes them in is what names which ID is YES

**Side Effects:**
- No clone registered in `vaultForMarket`
- No approvals granted to the exchange
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
- Future mints while `activeLiquidity == 0` are gated by the new value

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

### SC-3WLL: Vault accepts a single ERC-1155 outcome token transfer

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The ConditionalTokens contract holds outcome tokens for the vault's market on behalf of some holder

**Steps:**
1. The holder calls `safeTransferFrom(holder, vault, yesTokenId, amount, "")` on the ConditionalTokens contract
2. ConditionalTokens credits the vault's balance and invokes `onERC1155Received` on the vault
3. The vault checks that `msg.sender` is its configured `conditionalTokens` address
4. The vault checks that the transferred ID is its own `yesTokenId` or `noTokenId`
5. The vault returns the ERC-1155 single-transfer acknowledgement value

**Outcomes:**
- The transfer completes without reverting
- `onERC1155Received` returns `0xf23a6e61`
- The vault's ERC-1155 balance for `yesTokenId` increased by `amount`
- The same holds for a transfer of `noTokenId`

**Side Effects:**
- No change to `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, or any position or tick record
- No USDC transferred
- No vault events emitted -- only the ConditionalTokens `TransferSingle` event

---

### SC-3WLM: Vault accepts a batch ERC-1155 outcome token transfer

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The ConditionalTokens contract holds YES and NO outcome tokens for the vault's market on behalf of some holder

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

### SC-5XY6: Receiver hook rejects a token ID outside the vault's market

**Given:**
- A vault has been created and initialized (SC-REQ6 completed)
- The caller is the vault's own configured `conditionalTokens` contract -- the caller check of SC-3WLN passes
- The token ID being transferred is neither `yesTokenId` nor `noTokenId` -- an outcome token of a different market's condition on the same ConditionalTokens contract

**Steps:**
1. A holder calls `safeTransferFrom(holder, vault, foreignTokenId, amount, "")` on the ConditionalTokens contract
2. ConditionalTokens invokes `onERC1155Received` on the vault
3. The vault compares the ID against its own `yesTokenId` and `noTokenId`
4. The same is attempted as a batch: `safeBatchTransferFrom(holder, vault, [yesTokenId, foreignTokenId], [amountA, amountB], "")`

**Outcomes:**
- Both the single and the batch transfer revert with an unknown-token-id error, so neither transfer settles
- The batch reverts even though one of its two IDs is valid -- a foreign ID anywhere in the batch rejects the whole transfer
- The vault's balance for the foreign ID stays zero, and the vault's balances for its own two IDs are unchanged
- The blanket `setApprovalForAll` the vault grants the exchange is now backed by an enforced check rather than by the absence of an entry point: the vault holds outcome tokens for exactly one market because it refuses every other ID

**Side Effects:**
- No state changes on the vault
- No events emitted by the vault
- No ERC-1155 `TransferSingle` or `TransferBatch` event, since the originating transfer reverts

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

---
