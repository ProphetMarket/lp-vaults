---
id: UC-REQ1
name: Create Vault for Market
feature: FEAT-REPZ
status: pending
version: 3
actor: Oracle
---

# UC-REQ1: Create Vault for Market

> Oracle deploys a per-market LP vault so that LPs can deposit USDC and provide liquidity for a specific prediction market.

## Preconditions

- LPVaultFactory is deployed and initialized (UC-REQ0 completed)

## Trigger

Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity)` on the LPVaultFactory, or calls `setMinimumFirstLiquidity(newMin)` on an existing vault to adjust its first-LP floor.

---

### SC-REQ6: Successful vault creation

**Given:**
- marketId has no existing vault in the registry
- tickSpacing > 0
- minimumFirstLiquidity > 0

**Steps:**
1. Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity)` on the factory
2. System deploys an EIP-1167 minimal-proxy clone of the implementation contract
3. System calls `initialize(marketId, usdc, exchange, conditionalTokens, oracle, tickSpacing, factory, minimumFirstLiquidity, operators, admins)` on the clone
4. Clone stores all config in storage (not immutable -- EIP-1167 constraint), sets `phase = Active`, sets `activeLiquidity = 0`, sets `minimumFirstLiquidity` to the passed value
5. Clone approves CTF Exchange for unlimited USDC spending and calls `setApprovalForAll` on ConditionalTokens for the exchange
6. System registers `vaultForMarket[marketId] = cloneAddress`

**Outcomes:**
- A new vault clone exists and is registered in the factory
- The vault is in Active phase with `activeLiquidity == 0`, ready for the Operator to credit the first position
- The minimum-first-liquidity floor is set to the Oracle-supplied value, so any non-Operator caller cannot create positions and the first Operator-driven mint must produce `liquidity >= minimumFirstLiquidity`

**Side Effects:**
- `VaultCreated(marketId, vaultAddress, minimumFirstLiquidity)` event emitted by the factory
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
