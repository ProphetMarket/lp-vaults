---
id: FEAT-REPZ
name: Deploy LP Vault for a Market
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: []
---

# Deploy LP Vault for a Market

> Provides the factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones, with established role gating (Admin, Operator, Oracle) and a ghost position to prevent first-LP inflation griefing.

## Non-Goals

- Does not handle LP position minting beyond the factory-seeded ghost position -- see feature 2
- Does not handle fee distribution, tick updates, or fee collection -- see features 3-5
- Does not handle position burning or deposit-then-credit orchestration -- see features 6-7
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not manage vault-level role registries beyond initial setup during `initialize()` -- vault-side Admin ops use the same Auth pattern but are exercised by later features

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Factory Owner | Deploys LPVaultFactory with implementation address and initial role assignments | One-time deployment; after deployment, role management passes to Admin |
| Oracle | Calls `createVault(marketId, tickSpacing)` to deploy per-market vaults | Single wallet (`address public oracle`); MUST be separate from Operator |
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

**FR-REQK** `When the Oracle calls createVault with a marketId and tickSpacing, the system shall deploy an EIP-1167 minimal-proxy clone of the implementation contract, call initialize() on the clone, and register the clone address in the marketId-to-vault mapping.`
Fit Criterion: Given a valid unregistered marketId, `vaultForMarket[marketId]` returns the clone address, a `VaultCreated` event is emitted, and the clone's storage matches initialization parameters.
Linked to: UC-REQ1

**FR-REQL** `If the Oracle calls createVault with a marketId that already has a registered vault, then the system shall revert.`
Fit Criterion: Given marketId M already has a vault, `createVault(M, tickSpacing)` reverts.
Linked to: UC-REQ1

**FR-REQM** `If a non-Oracle address calls createVault, then the system shall revert.`
Fit Criterion: Given a non-Oracle address, `createVault(...)` reverts with an access control error.
Linked to: UC-REQ1

### Vault Initialization

**FR-REQN** `When initialize() is called on a new vault clone, the system shall store marketId, USDC address, CTF Exchange address, ConditionalTokens address, oracle address, tickSpacing, and factory address in storage, copy the factory's operator and admin registries, and set the vault phase to Active.`
Fit Criterion: Given a freshly initialized clone, all storage variables match factory-provided values, `phase == Active`, and the vault's role registry mirrors the factory's.
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
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
