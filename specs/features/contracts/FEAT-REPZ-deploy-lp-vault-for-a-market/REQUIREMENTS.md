---
id: FEAT-REPZ
name: Deploy LP Vault for a Market
module: contracts
domain: "@vault"
status: implemented
version: 11
refs: []
---

# Deploy LP Vault for a Market

> Provides the factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones, with established role gating (Admin, Operator, Oracle).

## Non-Goals

- Does not handle LP position minting -- see feature 2
- Does not handle tick updates or position exits -- see FEAT-TVS0 and FEAT-7G40
- Does not handle position burning or deposit-then-credit orchestration -- see features 6-7
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not maintain vault-level role registries -- vaults delegate all operator, oracle, and admin authorization to the factory contract at call time

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Factory Owner | Deploys LPVaultFactory with implementation address and initial role assignments | One-time deployment; after deployment, role management passes to Admin |
| Oracle | Calls `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` to deploy per-market vaults | Single wallet (`address public oracle`); MUST be separate from Operator |
| Admin | Manages role registry on factory: add/remove operators, set oracle, two-step admin transfer, add/remove/renounce admins, pause; sets the factory's default emergency-cancel timelock | Registry-only; cannot call user-facing vault functions |
| Operator | Registered in role registry for transactional use by later features | Not invoked in this feature; gated by `onlyOperator` modifier |

## Functional Requirements

### Factory Deployment

**FR-REQI** `When the Factory Owner deploys the LPVaultFactory, the system shall initialize the role registry with the provided Admin, Oracle, and Operator wallets, store the implementation contract address, USDC address, CTF Exchange address, ConditionalTokens address, Safe factory address, and Safe proxy bytecode hash, set adminCount to 1, and set the default emergency-cancel timelock to 7 days.`
Fit Criterion: Given valid constructor arguments, `admins[initialAdmin] == 1`, `oracle == initialOracle`, `operators[initialOperator] == 1`, `adminCount == 1`, `defaultEmergencyCancelTimelock == 7 days`, and all address storage variables match. `safeFactory` and `safeProxyBytecodeHash` are `immutable`, and no function changes them. A zero `safeFactory` reverts with `ZeroAddress`, and a zero hash reverts with `ZeroBytecodeHash`. The constructor takes no timelock argument: the default starts at 7 days (decision C10), so the deploy script and its environment variables do not change.
Linked to: UC-REQ0

**FR-REQJ** `When the Factory Owner deploys the LPVaultFactory, the system shall call _disableInitializers() in the implementation contract's constructor to prevent direct initialization of the implementation.`
Fit Criterion: Given the implementation contract is deployed, calling `initialize()` directly on it reverts.
Linked to: UC-REQ0

### Vault Creation

**FR-REQK** `When the Oracle calls createVault with a marketId, a tickSpacing, a minimumFirstLiquidity, and the market's outcome-token identity (conditionId, yesTokenId, noTokenId), the system shall verify the identity, deploy an EIP-1167 minimal-proxy clone of the implementation contract, call initialize() on the clone with those values, and register the clone address in the marketId-to-vault mapping.`
Fit Criterion: Given a valid unregistered marketId and a valid identity, `vaultForMarket[marketId]` returns the clone address, a `VaultCreated` event is emitted, and the clone's storage matches the initialization parameters, including `conditionId`, `yesTokenId`, `noTokenId`, and `emergencyCancelTimelock == defaultEmergencyCancelTimelock` as the factory held it at the moment of the call, because initialize() reads it from the factory (FR-REQN). The `createVault` signature, the `initialize` signature, and the `VaultCreated` event do not change: the vault exposes `emergencyCancelTimelock()`.
Linked to: UC-REQ1

**FR-REQL** `If the Oracle calls createVault with a marketId that already has a registered vault, then the system shall revert.`
Fit Criterion: Given marketId M already has a vault, `createVault(M, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` reverts.
Linked to: UC-REQ1

**FR-REQM** `If a non-Oracle address calls createVault, then the system shall revert.`
Fit Criterion: Given a non-Oracle address, `createVault(...)` reverts with an access control error.
Linked to: UC-REQ1

**FR-6HBQ** `If the Oracle calls createVault with a zero conditionId, a zero yesTokenId, a zero noTokenId, or a yesTokenId equal to noTokenId, then the system shall revert.`
Fit Criterion: A zero `conditionId` reverts with `ZeroConditionId`. A zero token ID reverts with `ZeroTokenId`. Equal token IDs revert with `DuplicateTokenId`. No clone is deployed and `vaultForMarket[marketId]` stays zero. These three checks are redundant for safety: a zero condition also fails `NotBinaryCondition` (FR-6HBR), and a zero or duplicated ID also fails `TokenIdMismatch` (FR-6HBS). They exist so that an operator error reverts before any external call and with a name that points at the wrong argument.
Linked to: UC-REQ1

**FR-6HBR** `If the Oracle calls createVault with a conditionId whose outcome slot count on the ConditionalTokens contract is not 2, then the system shall revert.`
Fit Criterion: `getOutcomeSlotCount(conditionId) != 2` reverts with `NotBinaryCondition`. This covers an unprepared condition, which returns 0, and a condition with 3 or more outcomes. No clone is deployed. The complete-set merge and the redemption use the partition `[1, 2]`, and on a 3-outcome condition `mergePositions` with that partition mints a third token instead of paying USDC. Prophet's `Resolution.sol` prepares only 2-outcome conditions.
Linked to: UC-REQ1

**FR-6HBS** `When the Oracle calls createVault, the system shall derive the position IDs of index set 1 and index set 2 from the USDC address and conditionId through the ConditionalTokens contract, and shall revert unless yesTokenId equals the index set 1 position ID and noTokenId equals the index set 2 position ID.`
Fit Criterion: The expected YES ID is `getPositionId(usdc, getCollectionId(bytes32(0), conditionId, 1))` and the expected NO ID uses index set 2. A pair that belongs to another condition reverts with `TokenIdMismatch`. The correct pair in swapped order also reverts with `TokenIdMismatch`. The derivation assumes a binary market with `parentCollectionId == bytes32(0)` and USDC as collateral. Index set 1 means YES in Prophet's `Resolution.sol` (payout `[1,0]` means YES wins) and in the Prophet server (`indexSetYES = 1`).
Linked to: UC-REQ1

### Vault Initialization

**FR-REQN** `When initialize() is called on a new vault clone, the system shall store marketId, USDC address, CTF Exchange address, ConditionalTokens address, conditionId, yesTokenId, noTokenId, tickSpacing, emergencyCancelTimelock, and factory address in storage, and set the vault phase to Active.`
Fit Criterion: Given a freshly initialized clone, all storage variables match factory-provided values, `phase == Active`, and the vault's `factory` address matches the deploying factory. `conditionId`, `yesTokenId`, `noTokenId`, and `emergencyCancelTimelock` are public, and each is storage, never `immutable`, because EIP-1167 clones share the implementation's bytecode. `emergencyCancelTimelock` is a `uint32` that packs into the slot of `tickSpacing` and `minimumFirstLiquidity`; `initialize()` reads it from the calling factory's `defaultEmergencyCancelTimelock()` once, and no function writes it afterwards. `initialize()` does not verify the identity or the timelock: only the factory can call it (FR-REQQ), and the factory verifies both before it deploys the clone. `initialize` keeps eleven parameters: a twelfth does not compile under `forge coverage`, which turns the optimizer off (stack too deep in the ABI decoder, measured in R10), so the timelock is a read and not an argument.
Linked to: UC-REQ1

**FR-REQO** `When initialize() is called on a new vault clone, the system shall grant the CTF Exchange unlimited ERC-20 approval for USDC and call setApprovalForAll on the ConditionalTokens contract for the CTF Exchange.`
Fit Criterion: Given a freshly initialized vault, `USDC.allowance(vault, exchange) == type(uint256).max` and `ConditionalTokens.isApprovedForAll(vault, exchange) == true`.
Linked to: UC-REQ1

**FR-REQP** `If initialize() is called on a vault clone that has already been initialized, then the system shall revert.`
Fit Criterion: Given an already-initialized vault, a second `initialize()` call reverts.
Linked to: UC-REQ1

**FR-REQQ** `If a non-factory address calls initialize() on a vault clone, then the system shall revert.`
Fit Criterion: Given any address != factory, calling `initialize()` reverts with `NotFactory`. The check is inline, `msg.sender != factory_`, because `factory` is not yet stored when a clone is initialized; no `onlyFactory` modifier exists (finding CV-05 of `audits/code-validation-round-1.md` deleted the unused one).
Linked to: UC-REQ1

### ERC-1155 Receiver Compatibility

**FR-3WLI** `When the vault's configured ConditionalTokens contract transfers the vault's own outcome tokens (yesTokenId or noTokenId) to the vault via safeTransferFrom or safeBatchTransferFrom, the system shall accept the transfer by returning the ERC-1155 receiver acknowledgement values.`
Fit Criterion: Given an initialized vault, `onERC1155Received(...)` called by `conditionalTokens` for `yesTokenId` or `noTokenId` returns `0xf23a6e61`, and `onERC1155BatchReceived(...)` called by `conditionalTokens` for a batch drawn from those two IDs returns `0xbc197c81`. A `safeTransferFrom` and a `safeBatchTransferFrom` of those IDs from the ConditionalTokens contract to the vault both complete without reverting, and the vault's token balances reflect the transferred amounts. Neither hook mutates position or tick state, and neither hook merges tokens -- vault bookkeeping is driven by mint, burn, and updateTick, not by inbound transfers, and a hook runs inside the exchange's settlement transaction, so a revert there reverts the match.
Linked to: UC-REQ1

**FR-3WLJ** `If any address other than the vault's configured ConditionalTokens contract calls onERC1155Received or onERC1155BatchReceived, then the system shall revert.`
Fit Criterion: Given an initialized vault and any caller address != `conditionalTokens`, both `onERC1155Received(...)` and `onERC1155BatchReceived(...)` revert. Inside an ERC-1155 receiver hook `msg.sender` is the token contract, so this enforces on-chain that the vault only ever acknowledges tokens from its own market's ConditionalTokens contract, rather than relying on the documented no-other-entry-point assumption alone.
Linked to: UC-REQ1

**FR-6HBT** `If a receiver hook is invoked for any token ID other than the vault's yesTokenId or noTokenId, then the system shall revert.`
Fit Criterion: `onERC1155Received(...)` called by `conditionalTokens` with an ID outside `{yesTokenId, noTokenId}` reverts with `UnknownTokenId`, so the originating `safeTransferFrom` reverts and the token never reaches the vault. `onERC1155BatchReceived(...)` reverts when any element of `ids` is outside that set, including a batch whose other elements are valid. With FR-3WLJ, this turns the one-market assumption behind the unscoped `setApprovalForAll` into an on-chain check on both the token contract and the token ID.
Linked to: UC-REQ1

**FR-3WLK** `When supportsInterface is called on a vault with the IERC1155Receiver, ERC-165, or EIP-1271 interface identifier, the system shall return true, and false for any other identifier.`
Fit Criterion: Given an initialized vault, `supportsInterface(0x4e2312e0)` (IERC1155Receiver) returns `true`, `supportsInterface(0x01ffc9a7)` (ERC-165) returns `true`, `supportsInterface(0x1626ba7e)` (EIP-1271, the order maker's interface, FR-C0DZ in FEAT-C0DJ) returns `true`, and `supportsInterface(0xffffffff)` returns `false`.
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

**FR-9OYI** `When any vault function verifies an LP's owner-key signature, the system shall read the Safe factory address and the Safe proxy bytecode hash from the factory contract at call time.`
Fit Criterion: Given a vault with factory F, the Safe that the vault derives for an owner key equals `keccak256(0xff ++ F.safeFactory() ++ keccak256(abi.encode(ownerKey)) ++ F.safeProxyBytecodeHash())` truncated to 20 bytes. The vault stores neither value. `initialize` with 13 parameters does not compile, and the factory already serves the roles this way (FR-FKD0 to FR-FKD3), so the vault extends the same pattern (ADR-9OYP in FEAT-T7AF).
Linked to: UC-3Z92

### First-LP Inflation Protection

**FR-RFS6** `If any caller other than a registered Operator attempts to create an LP position on a vault, then the system shall revert.`
Fit Criterion: Given a non-Operator caller (including LPs directly, Admin, Oracle, Factory Owner, and arbitrary addresses), every position-creation entry point on the vault reverts with an access control error.
Linked to: UC-REQ1

**FR-RFS7** `When a position is minted on a vault while nextPositionId == 0, the system shall reject the mint if the resulting liquidity is below the vault's current minimumFirstLiquidity.`
Fit Criterion: Given a vault with `nextPositionId == 0` and `minimumFirstLiquidity == M`, a mint that would produce `liquidity < M` reverts; a mint that would produce `liquidity >= M` succeeds and `nextPositionId == 1` thereafter. Given `nextPositionId > 0`, a mint that would produce `liquidity < M` succeeds, even when `activeLiquidity == 0` because the price sits in a range with no position. `minimumFirstLiquidity` is supplied by the Oracle as a parameter to `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` and stored on the vault clone at `initialize()` time. The check applies exactly once in the vault's history, because position IDs are never reused, even after a burn (audit issue 6.9, decision C15 in `audits/audit-fixes-ranged.md`).
Linked to: UC-REQ1

**FR-RG4W** `When the Oracle calls setMinimumFirstLiquidity(uint128 newMin) on a vault, the system shall update the vault's minimumFirstLiquidity to newMin.`
Fit Criterion: Given the Oracle calls `setMinimumFirstLiquidity(newMin)` on a vault, the vault's `minimumFirstLiquidity == newMin` after the call. The new value gates the first mint when no position has been minted yet (`nextPositionId == 0`). Once `nextPositionId > 0` the setter still succeeds and still emits its event, and it changes a value that no later mint reads. The user chose on 2026-09-12 to keep the setter unchanged, because the auditors asked for decision C15 and nothing more. Rejected alternative, recorded for a later step if the Oracle service needs a hard stop: revert the setter once `nextPositionId > 0`.
Linked to: UC-REQ1

**FR-RG4X** `If any caller other than the Oracle calls setMinimumFirstLiquidity, then the system shall revert.`
Fit Criterion: Given a non-Oracle caller, `setMinimumFirstLiquidity(newMin)` reverts with an access control error.
Linked to: UC-REQ1

**FR-RG4Y** `If the Oracle calls createVault with minimumFirstLiquidity == 0, or setMinimumFirstLiquidity is called with newMin == 0, then the system shall revert.`
Fit Criterion: Given `minimumFirstLiquidity == 0` in `createVault`, the call reverts. Given `newMin == 0` in `setMinimumFirstLiquidity`, the call reverts. The vault's `minimumFirstLiquidity` is never zero in any reachable state.
Linked to: UC-REQ1

**FR-DU2Z** `If the Oracle calls createVault with tickSpacing <= 0, then the system shall revert.`
Fit Criterion: Given `tickSpacing == 0` or `tickSpacing == -10` in `createVault`, the call reverts with `InvalidTickSpacing` and no vault is registered. A vault's `tickSpacing` is positive in every reachable state, so the alignment check `tickLower % tickSpacing` in `_requireValidRange` never divides by zero (finding CV-12 of `audits/code-validation-round-1.md`).
Linked to: UC-REQ1

### Default Emergency-Cancel Timelock

**FR-BZC0** `When an Admin calls setDefaultEmergencyCancelTimelock(newTimelock) with a value above zero and at most 30 days, the system shall store it as the factory's default emergency-cancel timelock and emit DefaultEmergencyCancelTimelockUpdated.`
Fit Criterion: Given an Admin calls `setDefaultEmergencyCancelTimelock(14 days)`, `defaultEmergencyCancelTimelock() == 14 days` and `DefaultEmergencyCancelTimelockUpdated(7 days, 14 days)` is emitted. A vault created after the call has `emergencyCancelTimelock() == 14 days`. A vault created before the call keeps its own value, because the vault reads its storage and never the factory (decision C10, ADR-BZC5). The setter is Admin-only: a protocol-wide default is factory configuration, the Admin's registry role, not the Oracle's market-lifecycle role.
Linked to: UC-REQ1

**FR-BZC1** `If an Admin calls setDefaultEmergencyCancelTimelock with zero, or with a value above 30 days, then the system shall revert.`
Fit Criterion: `setDefaultEmergencyCancelTimelock(0)` reverts `ZeroTimelock`, and `setDefaultEmergencyCancelTimelock(30 days + 1)` reverts `TimelockTooLong`; `setDefaultEmergencyCancelTimelock(30 days)` succeeds. The maximum is the constant `MAX_EMERGENCY_CANCEL_TIMELOCK = 30 days`. A zero timelock would let any address freeze a vault in the block after any Operator call, and a timelock above 30 days would hold LPs to a silent Operator for longer than the product accepts. The user chose both bounds on 2026-09-11 (decision C10, round 1 finding V1-17 of the plan validation).
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

**FR-REQZ** `If a non-Admin address calls addOperator, removeOperator, setOracle, transferAdmin, addAdmin, removeAdmin, renounceAdminRole, or setDefaultEmergencyCancelTimelock, then the system shall revert.`
Fit Criterion: Given a non-Admin caller (an Operator, the Oracle, an LP, or an arbitrary address), the call reverts with a NotAdmin error and `defaultEmergencyCancelTimelock` is unchanged.
Linked to: UC-REQ2, UC-REQ1

**FR-5UJ8** `When an Admin calls addAdmin with a non-zero address that does not hold the admin role, the system shall grant that address the admin role and increment adminCount.`
Fit Criterion: Given Y does not hold the admin role, after an Admin calls `addAdmin(Y)`, `admins[Y] == 1`, `adminCount` has increased by 1, and `NewAdmin(Y, caller)` is emitted. Given X already holds the admin role, `addAdmin(X)` leaves `adminCount` unchanged and still emits `NewAdmin(X, caller)`.
Linked to: UC-REQ2

**FR-5UJ9** `If an Admin calls addAdmin with the zero address, then the system shall revert.`
Fit Criterion: Given an Admin calls `addAdmin(address(0))`, the call reverts with `ZeroAddress` and `adminCount` is unchanged.
Linked to: UC-REQ2

**FR-5UJA** `When an Admin calls removeAdmin with an address that holds the admin role, the system shall revoke that role and decrement adminCount.`
Fit Criterion: Given admins A and X with `adminCount == 2`, after A calls `removeAdmin(X)`, `admins[X] == 0`, `adminCount == 1`, and `RemovedAdmin(X, A)` is emitted. In the next call, X is rejected by `onlyAdmin` on the factory and on every vault that the factory deployed. Given Y does not hold the admin role, `removeAdmin(Y)` does not revert, leaves `adminCount` unchanged, and still emits `RemovedAdmin(Y, caller)`.
Linked to: UC-REQ2

**FR-5UJB** `When an Admin calls renounceAdminRole, the system shall revoke the caller's admin role and decrement adminCount.`
Fit Criterion: Given admins A and X with `adminCount == 2`, after X calls `renounceAdminRole()`, `admins[X] == 0`, `adminCount == 1`, and `RemovedAdmin(X, X)` is emitted.
Linked to: UC-REQ2

**FR-5UJC** `If removeAdmin or renounceAdminRole would revoke the role of the only remaining admin, then the system shall revert.`
Fit Criterion: Given `adminCount == 1`, `removeAdmin(onlyAdmin)` and `renounceAdminRole()` both revert with `CannotRemoveLastAdmin`. `adminCount >= 1` in every reachable state.
Linked to: UC-REQ2

**FR-5UJD** `When an Admin calls removeAdmin or renounceAdminRole for an address that is the pending admin, the system shall clear pendingAdmin.`
Fit Criterion: Given `pendingAdmin == X`, after `removeAdmin(X)` or after X calls `renounceAdminRole()`, `pendingAdmin == address(0)` and `acceptAdmin()` from X reverts with `NotPendingAdmin`. The rule applies whether or not X holds the admin role.
Linked to: UC-REQ2

**FR-5UJE** `If the pending admin calls acceptAdmin while it already holds the admin role, then the system shall revert.`
Fit Criterion: Given `pendingAdmin == X` and `admins[X] == 1`, `acceptAdmin()` from X reverts with `AlreadyAdmin`, `adminCount` is unchanged, and `pendingAdmin` stays X.
Linked to: UC-REQ2

## Non-Functional Requirements

**NFR-RER0** Gas: `When the Oracle creates a vault, the execution gas of createVault, covering the identity check, clone deployment, and initialization, shall remain below 650,000 gas.` A Polygon transaction adds 21,000 base gas plus calldata gas to this figure. A fuzz test over condition IDs checks the limit, because the ConditionalTokens `getCollectionId` call searches for a curve point in a loop and costs a different amount for each condition. The E3 exploration measured 398,718 gas for `createVault` with the optimizer off and at most 145,055 more gas for the identity check over 64 conditions, which gives 546,773 gas with a 3,000 gas calldata allowance. With the optimizer at 200 runs, `createVault` cost 393,262 gas before the identity check.

**NFR-RER1** Security: `The system shall enforce that the same address cannot simultaneously hold the Operator role and the Oracle role on any single contract instance.`

**NFR-RER2** Security: `The system shall use an inline nonReentrant modifier on every external state-changing function that performs an external call or token transfer.`

**NFR-RFS8** Security: `The system shall route all position creation through Operator-gated entry points so that no caller can bypass the Operator to mint the first position with attacker-chosen size, eliminating the first-LP inflation manipulation vector at the architectural level.`

## Acceptance

> The feature is complete when all of the following are true:

- All use cases (Deploy Factory, Create Vault for Market, Manage Roles on Factory) pass with full scenario coverage
- Role separation tests verify Operator cannot call Oracle-gated functions and vice versa
- Non-Operator callers cannot create the first position on a vault (verified by invariant test against every position-creation entry point)
- Mints below `minimumFirstLiquidity` revert when `nextPositionId == 0`, and a later mint below the floor succeeds even when `activeLiquidity == 0` (verified by a fuzz test in the UC-T7AG test file)
- EIP-1167 clones use storage for all per-vault config (no `immutable` usage in LPVault)
- Implementation contract cannot be initialized directly
- The vault accepts inbound ERC-1155 transfers of its own two outcome-token IDs from its own ConditionalTokens contract, and rejects receiver-hook calls from every other address and every other token ID
- A vault cannot be created with a zero conditionId, a zero or duplicated outcome-token ID, a condition whose outcome slot count is not 2, or a token pair that differs from the condition's index set 1 and index set 2 position IDs
- A vault cannot be created with a zero or negative tick spacing (FR-DU2Z)
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- Factory role rotation (addOperator, removeOperator, setOracle, transferAdmin/acceptAdmin, addAdmin, removeAdmin, renounceAdminRole) propagates immediately to all existing vaults deployed by that factory
- Vault clones contain no local role state (operators, oracle, admins, pendingAdmin, adminCount) -- all authorization delegated to factory
- The factory holds a default emergency-cancel timelock of 7 days that an Admin sets within (0, 30 days]; each vault copies it at creation and never changes it, so a default change reaches only later vaults
- FEATURES.md status is `implemented`
