---
id: UC-REQ1-001
name: create-vault-and-initialize
use_case: UC-REQ1
feature: FEAT-REPZ
objective: implement
files:
  create: []
  modify: [src/LPVaultFactory.sol, src/LPVault.sol]
depends_on: [UC-REQ0-001]
provides: [createVault, initialize, setMinimumFirstLiquidity, vaultForMarket]
entry_type: contract-call
covers: [SC-REQ6, SC-REQ7, SC-REQ8, SC-REQ9, SC-REQA, SC-RG74, SC-RG75, SC-RG76, SC-RG77, FR-FKD0, FR-FKD1, FR-FKD2, FR-FKD3]
last_update: 2026-06-30
status: implemented
---

# UC-REQ1-001: Create Vault and Initialize

## Rationale

Adds the vault creation lifecycle to LPVaultFactory (`createVault`) and the initialization logic to LPVault (`initialize`, `setMinimumFirstLiquidity`). Vaults delegate all role authorization (operator, oracle, admin) to the factory via cross-contract calls — no local role state is stored on the vault. Closes 9 scenarios covering the happy path (clone deployment + initialization + approval setup), duplicate-market revert, access control on createVault and initialize, zero-floor validation, and the Oracle-only setMinimumFirstLiquidity setter. Also closes FR-FKD0/1/2/3 (factory-delegated authorization invariants).

## Contracts

### Types

```solidity
// Minimal interface for factory delegation (inlined in LPVault.sol per pattern policy)
interface ILPVaultFactory {
    function operators(address) external view returns (uint256);
    function oracle() external view returns (address);
    function admins(address) external view returns (uint256);
}

// Vault creation storage on factory
// mapping(bytes32 => address) public vaultForMarket;

// Vault initialization storage (no role state — delegated to factory)
// bytes32 public marketId;               // storage because EIP-1167
// address public usdc;                   // storage because EIP-1167
// address public exchange;               // storage because EIP-1167
// address public conditionalTokens;      // storage because EIP-1167
// address public factory;                // storage because EIP-1167, also used for auth delegation
// int24 public tickSpacing;              // storage because EIP-1167
// uint128 public minimumFirstLiquidity;  // storage, set by Oracle
// uint8 public phase;                    // Active = 1
// bool private _initialized;             // one-shot guard
// uint256 public feeGrowthGlobalX128;    // starts at 0
// uint128 public activeLiquidity;        // starts at 0
// int24 public currentTick;              // starts at 0
// uint256 public nextPositionId;         // starts at 0

// Removed from vault storage (delegated to factory):
// mapping(address => uint256) public admins;
// mapping(address => uint256) public operators;
// uint256 public adminCount;
// address public oracle;
// address public pendingAdmin;

// Events
// event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);
// event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `createVault` | `(bytes32 marketId, int24 tickSpacing, uint128 minimumFirstLiquidity) returns (address)` | onlyOracle | Reverts on duplicate marketId, zero minimumFirstLiquidity |
| `initialize` | `(bytes32 marketId_, address usdc_, address exchange_, address conditionalTokens_, int24 tickSpacing_, address factory_, uint128 minimumFirstLiquidity_)` | onlyFactory | One-shot; stores factory address for auth delegation; approves exchange on USDC and ConditionalTokens |
| `setMinimumFirstLiquidity` | `(uint128 newMin)` | onlyOracle (delegated to factory) | Reverts on zero; updates floor for future zero-liquidity mints |

### Behavior

- **Preconditions:** Factory deployed (UC-REQ0-001 provides); for createVault: `vaultForMarket[marketId] == address(0)` and `minimumFirstLiquidity > 0`; for initialize: `_initialized == false` and `msg.sender == factory`; for setMinimumFirstLiquidity: vault initialized and `newMin > 0`
- **Postconditions:** After createVault: clone deployed, initialized, registered in `vaultForMarket`; vault's `phase == Active`, `activeLiquidity == 0`, `minimumFirstLiquidity` set; vault delegates all auth to factory. After setMinimumFirstLiquidity: `minimumFirstLiquidity == newMin`
- **Invariants:** `vaultForMarket[marketId]` is immutable once set (no overwrite); `minimumFirstLiquidity > 0` always; `_initialized` flips exactly once; vault has no local role state — all auth reads go through `ILPVaultFactory(factory)`
- **Error modes:** `DuplicateMarket` (createVault with existing market); `NotOracle` (non-oracle calls createVault or setMinimumFirstLiquidity); `AlreadyInitialized` (double init); `NotFactory` (non-factory calls initialize); `ZeroFloor` (minimumFirstLiquidity == 0)

## Tests

- **SC-REQ6: Successful vault creation**
  - Given marketId has no existing vault, tickSpacing > 0, minimumFirstLiquidity > 0
    - When Oracle calls `createVault(marketId, tickSpacing, minimumFirstLiquidity)`
      - Then `vaultForMarket[marketId]` returns a non-zero clone address
      - And the clone's `marketId` matches
      - And the clone's `usdc`, `exchange`, `conditionalTokens`, `tickSpacing`, `factory` match factory values
      - And the clone's `minimumFirstLiquidity` matches the passed value
      - And the clone's `phase == Active`
      - And the clone's `activeLiquidity == 0`
      - And `USDC.allowance(vault, exchange) == type(uint256).max`
      - And `ConditionalTokens.isApprovedForAll(vault, exchange) == true`
      - And `VaultCreated(marketId, vaultAddress, minimumFirstLiquidity)` event is emitted
- **SC-REQ7: Duplicate marketId reverts**
  - Given marketId M already has a registered vault
    - When Oracle calls `createVault(M, tickSpacing, minimumFirstLiquidity)`
      - Then the call reverts with DuplicateMarket
- **SC-REQ8: Non-Oracle caller reverts**
  - Given caller is an Operator, Admin, or arbitrary address
    - When caller calls `createVault(marketId, tickSpacing, minimumFirstLiquidity)`
      - Then the call reverts with NotOracle
- **SC-REQ9: Re-initialization of vault clone reverts**
  - Given a vault clone has been created and initialized
    - When any address calls `initialize()` on the vault clone
      - Then the call reverts with AlreadyInitialized
- **SC-REQA: Only factory can call initialize**
  - Given a fresh vault clone exists (deployed but not yet initialized)
    - When a non-factory address calls `initialize()` on the vault clone
      - Then the call reverts with NotFactory
- **SC-RG74: createVault reverts when minimumFirstLiquidity is zero**
  - Given marketId has no existing vault
    - When Oracle calls `createVault(marketId, tickSpacing, 0)`
      - Then the call reverts with ZeroFloor
- **SC-RG75: Oracle updates minimumFirstLiquidity successfully**
  - Given a vault exists with `minimumFirstLiquidity == M` and caller is the Oracle
    - When Oracle calls `setMinimumFirstLiquidity(newMin)` with newMin > 0
      - Then the vault's `minimumFirstLiquidity == newMin`
      - And `MinimumFirstLiquidityUpdated(M, newMin)` event is emitted
- **SC-RG76: Non-Oracle caller cannot update minimumFirstLiquidity**
  - Given a vault exists and caller is an Operator, Admin, LP, or arbitrary address
    - When caller calls `setMinimumFirstLiquidity(newMin)`
      - Then the call reverts with NotOracle
- **SC-RG77: setMinimumFirstLiquidity reverts when newMin is zero**
  - Given a vault exists and caller is the Oracle
    - When Oracle calls `setMinimumFirstLiquidity(0)`
      - Then the call reverts with ZeroFloor
- **FR-FKD0: Vault operator auth delegates to factory**
  - Given a vault deployed by factory F
    - Then the vault's `onlyOperator` modifier queries `F.operators(msg.sender)` and reverts when result != 1
- **FR-FKD1: Vault oracle auth delegates to factory**
  - Given a vault deployed by factory F
    - Then the vault's `onlyOracle` modifier queries `F.oracle()` and reverts when `msg.sender != F.oracle()`
- **FR-FKD2: Vault admin auth delegates to factory**
  - Given a vault deployed by factory F
    - Then the vault's `onlyAdmin` modifier queries `F.admins(msg.sender)` and reverts when result != 1
- **FR-FKD3: Vault has no local role state**
  - Given a freshly initialized vault clone
    - Then the vault has no storage written for `operators`, `oracle`, `admins`, `pendingAdmin`, or `adminCount`
