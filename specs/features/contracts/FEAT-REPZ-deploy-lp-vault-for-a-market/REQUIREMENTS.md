---
id: FEAT-REPZ
name: Deploy LP Vault for a Market
module: contracts
domain: "@vault"
status: implemented
version: 4
refs: []
---

# Deploy LP Vault for a Market

> Provides the factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones, with established role gating (Admin, Operator, Oracle) and a ghost position to prevent first-LP inflation griefing.

## Non-Goals

- Does not handle LP position minting beyond the factory-seeded ghost position -- see feature 2
- Does not handle fee distribution, tick updates, or fee collection -- see features 3-5
- Does not handle position burning or deposit-then-credit orchestration -- see features 6-7
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not maintain vault-level role registries -- vaults delegate all operator, oracle, and admin authorization to the factory contract at call time

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Factory Owner | Deploys LPVaultFactory with implementation address and initial role assignments | One-time deployment; after deployment, role management passes to Admin |
| Oracle | Calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` to deploy per-market vaults | Single wallet (`address public oracle`); MUST be separate from Operator |
| Admin | Manages role registry on factory: add/remove operators, set oracle, two-step admin transfer, pause | Registry-only; cannot call user-facing vault functions |
| Operator | Registered in role registry for transactional use by later features | Not invoked in this feature; gated by `onlyOperator` modifier |

## Functional Requirements

### Factory Deployment

**FR-REQI** `When the Factory Owner deploys the LPVaultFactory, the system shall initialize the role registry with the provided Admin, Oracle, and Operator wallets, store the implementation contract address, USDC address, CTF Exchange address, and ConditionalTokens address, and set adminCount to 1.`
Fit Criterion: Given valid constructor arguments, `admins[initialAdmin] == 1`, `oracle == initialOracle`, `operators[initialOperator] == 1`, `adminCount == 1`, and all address storage variables match.
Linked to: UC-REQ0

**FR-REQJ** `When the Factory Owner deploys the LPVaultFactory, the system shall call _disableInitializers() in the implementation contract's constructor to prevent direct initialization of the implementation.`
Fit Criterion: Given the implementation contract is deployed, calling `initialize()` directly on it reverts.
Linked to: UC-REQ0

### Vault Creation

**FR-REQK** `When the Oracle calls createVault with a marketId, tickSpacing, minimumFirstLiquidity, and the market's outcome-token identity (conditionId, yesTokenId, noTokenId), the system shall deploy an EIP-1167 minimal-proxy clone of the implementation contract, call initialize() on the clone with those values, and register the clone address in the marketId-to-vault mapping.`
Fit Criterion: Given a valid unregistered marketId, `vaultForMarket[marketId]` returns the clone address, a `VaultCreated` event is emitted, and the clone's storage matches initialization parameters -- including `conditionId`, `yesTokenId`, and `noTokenId`.
Linked to: UC-REQ1

**FR-REQL** `If the Oracle calls createVault with a marketId that already has a registered vault, then the system shall revert.`
Fit Criterion: Given marketId M already has a vault, `createVault(M, tickSpacing)` reverts.
Linked to: UC-REQ1

**FR-REQM** `If a non-Oracle address calls createVault, then the system shall revert.`
Fit Criterion: Given a non-Oracle address, `createVault(...)` reverts with an access control error.
Linked to: UC-REQ1

### Vault Initialization

**FR-REQN** `When initialize() is called on a new vault clone, the system shall store marketId, USDC address, CTF Exchange address, ConditionalTokens address, tickSpacing, factory address, conditionId, yesTokenId, and noTokenId in storage, and set the vault phase to Active.`
Fit Criterion: Given a freshly initialized clone, all storage variables match factory-provided values, `phase == Active`, and the vault's `factory` address matches the deploying factory. `conditionId`, `yesTokenId`, and `noTokenId` are readable from the vault and identify the two ERC-1155 outcome tokens the vault is allowed to hold. Every one of these is storage, never `immutable` -- EIP-1167 clones share the implementation's bytecode.
Linked to: UC-REQ1

**FR-5XY1** `If initialize() is called with a zero conditionId, a zero yesTokenId, a zero noTokenId, or with yesTokenId equal to noTokenId, then the system shall revert.`
Fit Criterion: Given `createVault` is called with `conditionId == bytes32(0)`, the call reverts with a zero-condition error. Given `yesTokenId == 0` or `noTokenId == 0`, the call reverts with a zero-token-id error. Given `yesTokenId == noTokenId`, the call reverts with a duplicate-token-id error. No clone is registered in any of these cases. The identity of a clone cannot be corrected after `initialize()` -- clones are not upgradable -- so a misconfigured vault must be unreachable rather than fixable.
Linked to: UC-REQ1

**FR-5XY2** `When initialize() is called, the system shall derive the market's two position IDs from the collateral token and conditionId via the ConditionalTokens contract, and shall revert unless the supplied yesTokenId and noTokenId are exactly that pair.`
Fit Criterion: Given a conditionId C and collateral USDC, the vault computes `getPositionId(usdc, getCollectionId(bytes32(0), C, 1))` and `getPositionId(usdc, getCollectionId(bytes32(0), C, 2))`. Initialization succeeds when `{yesTokenId, noTokenId}` equals that pair as a set -- the caller's argument order is what names which of the two is YES. Initialization reverts with a token-id-mismatch error when either supplied ID is not in the derived pair, including when both IDs are individually valid position IDs of some other condition. The derivation assumes a binary market with `parentCollectionId == bytes32(0)` and USDC as collateral.
Linked to: UC-REQ1

**FR-REQO** `When initialize() is called on a new vault clone, the system shall grant the CTF Exchange unlimited ERC-20 approval for USDC and call setApprovalForAll on the ConditionalTokens contract for the CTF Exchange.`
Fit Criterion: Given a freshly initialized vault, `USDC.allowance(vault, exchange) == type(uint256).max` and `ConditionalTokens.isApprovedForAll(vault, exchange) == true`.
Linked to: UC-REQ1

**FR-REQP** `If initialize() is called on a vault clone that has already been initialized, then the system shall revert.`
Fit Criterion: Given an already-initialized vault, a second `initialize()` call reverts.
Linked to: UC-REQ1

**FR-REQQ** `If a non-factory address calls initialize() on a vault clone, then the system shall revert.`
Fit Criterion: Given any address != factory, calling `initialize()` reverts with an onlyFactory error.
Linked to: UC-REQ1

### ERC-1155 Receiver Compatibility

**FR-3WLI** `When the vault's configured ConditionalTokens contract transfers the vault's own outcome tokens (yesTokenId or noTokenId) to the vault via safeTransferFrom or safeBatchTransferFrom, the system shall accept the transfer by returning the ERC-1155 receiver acknowledgement values.`
Fit Criterion: Given an initialized vault, `onERC1155Received(...)` called by `conditionalTokens` for `yesTokenId` or `noTokenId` returns `0xf23a6e61`, and `onERC1155BatchReceived(...)` called by `conditionalTokens` for a batch drawn from those two IDs returns `0xbc197c81`. A `safeTransferFrom` and a `safeBatchTransferFrom` of those IDs from the ConditionalTokens contract to the vault both complete without reverting, and the vault's token balances reflect the transferred amounts. Neither hook mutates position, tick, or fee-accumulator state -- vault bookkeeping is driven by mint, burn, and collect, not by inbound transfers.
Linked to: UC-REQ1

**FR-5XY3** `If a receiver hook is invoked for any token ID other than the vault's yesTokenId or noTokenId, then the system shall revert.`
Fit Criterion: Given an initialized vault, `onERC1155Received(...)` called by `conditionalTokens` with an ID outside `{yesTokenId, noTokenId}` reverts with an unknown-token-id error, so the originating `safeTransferFrom` reverts and the foreign token never lands in the vault. `onERC1155BatchReceived(...)` reverts when **any** element of `ids` is outside that set, including a batch whose other elements are valid. Together with FR-3WLJ this replaces the previously documented "no entry point exists for foreign token IDs" assumption behind the blanket `setApprovalForAll` with an on-chain check: the vault holds outcome tokens for exactly one market because it rejects everything else, not because nothing happens to send it anything else.
Linked to: UC-REQ1

**FR-3WLJ** `If any address other than the vault's configured ConditionalTokens contract calls onERC1155Received or onERC1155BatchReceived, then the system shall revert.`
Fit Criterion: Given an initialized vault and any caller address != `conditionalTokens`, both `onERC1155Received(...)` and `onERC1155BatchReceived(...)` revert. Inside an ERC-1155 receiver hook `msg.sender` is the token contract, so this enforces on-chain that the vault only ever acknowledges tokens from its own market's ConditionalTokens contract, rather than relying on the documented no-other-entry-point assumption alone.
Linked to: UC-REQ1

**FR-3WLK** `When supportsInterface is called on a vault with the IERC1155Receiver or ERC-165 interface identifier, the system shall return true, and false for any other identifier.`
Fit Criterion: Given an initialized vault, `supportsInterface(0x4e2312e0)` (IERC1155Receiver) returns `true`, `supportsInterface(0x01ffc9a7)` (ERC-165) returns `true`, and `supportsInterface(0xffffffff)` returns `false`.
Linked to: UC-REQ1

### Factory-Delegated Authorization

**FR-FKD0** `When any vault function requires operator authorization, the system shall read the caller's operator status from the factory contract's operator registry.`
Fit Criterion: Given a vault with factory F, `onlyOperator` reverts unless `F.operators(msg.sender) == 1`. After `F.addOperator(addr)`, addr is immediately authorized on all vaults deployed by F. After `F.removeOperator(addr)`, addr is immediately rejected on all vaults deployed by F.
Linked to: UC-REQ2

**FR-FKD1** `When any vault function requires oracle authorization, the system shall read the oracle address from the factory contract.`
Fit Criterion: Given a vault with factory F, `onlyOracle` reverts unless `msg.sender == F.oracle()`. After `F.setOracle(newOracle)`, the new oracle is immediately authorized on all vaults deployed by F and the old oracle is immediately rejected.
Linked to: UC-REQ2

**FR-FKD2** `When any vault function requires admin authorization, the system shall read the caller's admin status from the factory contract's admin registry.`
Fit Criterion: Given a vault with factory F, `onlyAdmin` reverts unless `F.admins(msg.sender) == 1`.
Linked to: UC-REQ2

**FR-FKD3** `The vault shall not store operator, oracle, or admin registry state in its own storage.`
Fit Criterion: Given a freshly initialized vault clone, no storage is written for `operators`, `oracle`, `admins`, `pendingAdmin`, or `adminCount`. All role authorization is resolved by querying the factory contract at call time.
Linked to: UC-REQ1

### First-LP Inflation Protection

**FR-RFS6** `If any caller other than a registered Operator attempts to create an LP position on a vault, then the system shall revert.`
Fit Criterion: Given a non-Operator caller (including LPs directly, Admin, Oracle, Factory Owner, and arbitrary addresses), every position-creation entry point on the vault reverts with an access control error.
Linked to: UC-REQ1

**FR-RFS7** `When a position is minted on a vault while activeLiquidity == 0, the system shall reject the mint if the resulting liquidity is below the vault's current minimumFirstLiquidity.`
Fit Criterion: Given a vault with `activeLiquidity == 0` and `minimumFirstLiquidity == M`, a mint that would produce `liquidity < M` reverts; a mint that would produce `liquidity >= M` succeeds and `activeLiquidity > 0` thereafter. `minimumFirstLiquidity` is supplied by the Oracle as a parameter to `createVault(marketId, tickSpacing, minimumFirstLiquidity)` and stored on the vault clone at `initialize()` time. The check applies whenever `activeLiquidity == 0` -- both the very first mint and any subsequent mint after every position has been burned.
Linked to: UC-REQ1

**FR-RG4W** `When the Oracle calls setMinimumFirstLiquidity(uint128 newMin) on a vault, the system shall update the vault's minimumFirstLiquidity to newMin.`
Fit Criterion: Given the Oracle calls `setMinimumFirstLiquidity(newMin)` on a vault, the vault's `minimumFirstLiquidity == newMin` after the call. Subsequent mints while `activeLiquidity == 0` are gated by the new value. The setter is callable regardless of current `activeLiquidity`, but only changes the enforced floor for future zero-liquidity states.
Linked to: UC-REQ1

**FR-RG4X** `If any caller other than the Oracle calls setMinimumFirstLiquidity, then the system shall revert.`
Fit Criterion: Given a non-Oracle caller, `setMinimumFirstLiquidity(newMin)` reverts with an access control error.
Linked to: UC-REQ1

**FR-RG4Y** `If initialize() is called with minimumFirstLiquidity == 0, or setMinimumFirstLiquidity is called with newMin == 0, then the system shall revert.`
Fit Criterion: Given `minimumFirstLiquidity == 0` in `createVault`, the call reverts. Given `newMin == 0` in `setMinimumFirstLiquidity`, the call reverts. The vault's `minimumFirstLiquidity` is never zero in any reachable state.
Linked to: UC-REQ1

### Role Management

**FR-REQS** `When an Admin calls addOperator with a valid address, the system shall register that address as an operator.`
Fit Criterion: Given an Admin calls `addOperator(addr)`, `operators[addr] == 1`.
Linked to: UC-REQ2

**FR-REQT** `When an Admin calls removeOperator with an existing operator address, the system shall remove that address from the operator set.`
Fit Criterion: Given an Admin calls `removeOperator(addr)`, `operators[addr] == 0`.
Linked to: UC-REQ2

**FR-REQU** `When an Admin calls setOracle with a new address, the system shall update the oracle to the new address.`
Fit Criterion: Given an Admin calls `setOracle(newOracle)`, `oracle == newOracle`.
Linked to: UC-REQ2

**FR-REQV** `If an Admin calls setOracle with an address that is currently an operator, then the system shall revert to enforce role separation.`
Fit Criterion: Given addr is an operator, `setOracle(addr)` reverts.
Linked to: UC-REQ2

**FR-REQW** `If an Admin calls addOperator with an address that is the current oracle, then the system shall revert to enforce role separation.`
Fit Criterion: Given addr is the oracle, `addOperator(addr)` reverts.
Linked to: UC-REQ2

**FR-REQX** `When an Admin calls transferAdmin with a proposed address, the system shall store the pending admin without granting the role.`
Fit Criterion: Given an Admin calls `transferAdmin(newAdmin)`, `pendingAdmin == newAdmin` and `admins[newAdmin] == 0`.
Linked to: UC-REQ2

**FR-REQY** `When the pending admin calls acceptAdmin, the system shall grant them the admin role, increment adminCount, and clear pendingAdmin.`
Fit Criterion: Given the pending admin calls `acceptAdmin()`, `admins[caller] == 1`, `adminCount` incremented, and `pendingAdmin == address(0)`.
Linked to: UC-REQ2

**FR-REQZ** `If a non-Admin address calls addOperator, removeOperator, setOracle, or transferAdmin, then the system shall revert.`
Fit Criterion: Given a non-Admin caller, the call reverts with a NotAdmin error.
Linked to: UC-REQ2

## Non-Functional Requirements

**NFR-RER0** Gas: `When the Oracle creates a vault, the total gas cost for clone deployment + initialization + ghost position minting shall remain below 500,000 gas on Polygon.`

**NFR-RER1** Security: `The system shall enforce that the same address cannot simultaneously hold the Operator role and the Oracle role on any single contract instance.`

**NFR-RER2** Security: `The system shall use an inline nonReentrant modifier on every external state-changing function that performs an external call or token transfer.`

**NFR-RFS8** Security: `The system shall route all position creation through Operator-gated entry points so that no caller can bypass the Operator to mint the first position with attacker-chosen size, eliminating the first-LP inflation manipulation vector at the architectural level.`

## Acceptance

> The feature is complete when all of the following are true:

- All use cases (Deploy Factory, Create Vault for Market, Manage Roles on Factory) pass with full scenario coverage
- Role separation tests verify Operator cannot call Oracle-gated functions and vice versa
- Non-Operator callers cannot create the first position on a vault (verified by invariant test against every position-creation entry point)
- Mints below `MINIMUM_FIRST_LIQUIDITY` revert when `activeLiquidity == 0` (verified by fuzz test)
- EIP-1167 clones use storage for all per-vault config (no `immutable` usage in LPVault)
- Implementation contract cannot be initialized directly
- The vault accepts inbound ERC-1155 transfers of its own two outcome token IDs from its own ConditionalTokens contract, and rejects both receiver-hook calls from every other address and foreign token IDs from that contract
- A vault cannot be created with a zero conditionId, a zero or duplicated outcome token ID, or a token ID pair that does not derive from its conditionId
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- Factory role rotation (addOperator, removeOperator, setOracle, transferAdmin/acceptAdmin) propagates immediately to all existing vaults deployed by that factory
- Vault clones contain no local role state (operators, oracle, admins, pendingAdmin, adminCount) -- all authorization delegated to factory
- FEATURES.md status is `implemented`
