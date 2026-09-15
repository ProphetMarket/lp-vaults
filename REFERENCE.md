# Method Reference

Per-method documentation for `LPVault` and `LPVaultFactory`, organized in the same four sections as [FLOWS.md](specs/FLOWS.md). Each entry includes the function signature, actor, parameters, sequence diagram, events emitted, and revert conditions.

**Sections:**

1. [Vault Lifecycle](#1-vault-lifecycle)
2. [Transactional Methods](#2-transactional-methods)
3. [Emergency Procedures](#3-emergency-procedures)
4. [Admin & Governance](#4-admin--governance)

---

## 1. Vault Lifecycle

### `LPVaultFactory.constructor`

```solidity
constructor(
    address implementation_,
    address usdc_,
    address exchange_,
    address conditionalTokens_,
    address admin_,
    address oracle_,
    address operator_,
    address safeFactory_,
    bytes32 safeProxyBytecodeHash_
)
```

**Actor:** Factory Owner (deployment-time only)

Deploys the factory, stores all external contract addresses and the two Safe derivation inputs, initialises the role registry with one admin, one oracle, and one operator, sets `implementationVersion = 1`, and sets `defaultEmergencyCancelTimelock = 7 days`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `implementation_` | `address` | LPVault implementation contract used as the EIP-1167 clone target |
| `usdc_` | `address` | USDC ERC-20 contract address |
| `exchange_` | `address` | ProphetCTFExchange contract address |
| `conditionalTokens_` | `address` | Gnosis ConditionalTokens (ERC-1155) contract address |
| `admin_` | `address` | Initial Admin wallet |
| `oracle_` | `address` | Initial Oracle wallet — must differ from `operator_` |
| `operator_` | `address` | Initial Operator wallet — must differ from `oracle_` |
| `safeFactory_` | `address` | The Poly Safe factory on this chain — the CREATE2 deployer of every user's Safe; immutable |
| `safeProxyBytecodeHash_` | `bytes32` | `keccak256(getContractBytecode())` of that factory, the init code hash of the Safe derivation; immutable. The deploy script reads it from the chain. See [Safe derivation](#safe-derivation) |

```mermaid
sequenceDiagram
    actor Owner
    participant Factory as LPVaultFactory

    Owner->>Factory: deploy(impl, usdc, exchange, ctf, admin, oracle, operator, safeFactory, hash)
    Note right of Factory: Checks: oracle_ != operator_<br/>safeFactory_ != 0, hash != 0
    Note right of Factory: implementation = impl<br/>usdc / exchange / conditionalTokens stored<br/>safeFactory / safeProxyBytecodeHash stored (immutable)<br/>implementationVersion = 1<br/>defaultEmergencyCancelTimelock = 7 days
    Note right of Factory: admins[admin_] = 1, adminCount = 1<br/>oracle = oracle_<br/>operators[operator_] = 1
    Factory-->>Owner: factory address
```

**Events:** none

**Reverts:**
- `RoleSeparation()` — `oracle_` equals `operator_`
- `ZeroAddress()` — `safeFactory_` is zero
- `ZeroBytecodeHash()` — `safeProxyBytecodeHash_` is zero

---

### Safe derivation

Every LP is a Gnosis Safe that Prophet deploys through the Poly Safe factory with `CREATE2`, so the Safe's address is a pure function of its owner key. A Safe has no private key, so `ecrecover` can never return a Safe address. The Safe's owner key signs every LP message, and the vault requires that the Safe derived from the recovered signer equals the Safe the message names:

```text
salt = keccak256(abi.encode(ownerKey))
safe = address(uint160(uint256(keccak256(0xff ++ safeFactory ++ salt ++ safeProxyBytecodeHash))))
```

Both inputs are `immutable` on the factory, and every vault reads them from the factory at call time (`_deriveSafe`), so no Admin can change them. One internal `_verifySafeOwnerSignature(safe, structHash, signature)` runs the check for `depositForIntent`, `reclaimDepositFor`, and the later relayed burn. Every LP-signed type carries a `deadline`, checked inclusively against `block.timestamp`.

Known property: a Safe owner who swaps the owner key leaves the old key able to derive the same Safe, so the old key keeps the relayed paths until the vault holds nothing for that Safe. The exchange has the same property for orders. A valid signature never proves ownership of an `intentId`: the recorded Safe in `pendingDeposits` does, and every path that spends an escrow checks it.

---

### `LPVaultFactory.createVault`

```solidity
function createVault(
    bytes32 marketId_,
    int24   tickSpacing_,
    uint128 minimumFirstLiquidity_,
    bytes32 conditionId_,
    uint256 yesTokenId_,
    uint256 noTokenId_
) external onlyOracle returns (address vault)
```

**Actor:** Oracle

Verifies the market's outcome-token identity against the ConditionalTokens contract, deploys an EIP-1167 minimal-proxy clone of the current implementation, calls `initialize()` on it, and registers it in `vaultForMarket`. A clone can never correct its identity, so a wrong identity reverts before any clone exists.

| Parameter | Type | Description |
|-----------|------|-------------|
| `marketId_` | `bytes32` | Unique identifier for the market — must not already have a vault |
| `tickSpacing_` | `int24` | Minimum tick increment; all position bounds must be multiples of this value. One tick is one basis point (`PRICE_TICK_ONE = 10000`, price = tick / 10000), so `tickSpacing` is the width of a level, and every position range lies inside [0, 10000] |
| `minimumFirstLiquidity_` | `uint128` | Floor on the liquidity value of the first mint (prevents inflation attacks); must be > 0 |
| `conditionId_` | `bytes32` | ConditionalTokens condition ID of the market; must be a prepared 2-outcome condition |
| `yesTokenId_` | `uint256` | YES outcome token ID: the index set 1 position ID of `(usdc, conditionId_)` |
| `noTokenId_` | `uint256` | NO outcome token ID: the index set 2 position ID of `(usdc, conditionId_)` |

```mermaid
sequenceDiagram
    actor Oracle
    participant Factory as LPVaultFactory
    participant CT as ConditionalTokens
    participant Vault as LPVault (new clone)

    Oracle->>Factory: createVault(marketId, tickSpacing, minFirstLiq,<br/>conditionId, yesTokenId, noTokenId)
    Note right of Factory: Checks:<br/>minFirstLiq > 0<br/>vaultForMarket[marketId] == 0<br/>conditionId, yesTokenId, noTokenId non-zero<br/>yesTokenId != noTokenId
    Factory->>CT: getOutcomeSlotCount(conditionId)
    Factory->>CT: getCollectionId and getPositionId<br/>for index sets 1 and 2
    Note right of Factory: Checks:<br/>outcome slot count == 2<br/>yesTokenId == index set 1 ID<br/>noTokenId == index set 2 ID
    Factory->>Vault: EIP-1167 deploy (clone of implementation)
    Factory->>Factory: vaultForMarket[marketId] = vault
    Factory->>Vault: initialize(marketId, usdc, exchange, ctf,<br/>tickSpacing, factory, minFirstLiq, implementationVersion,<br/>conditionId, yesTokenId, noTokenId)
    Vault->>Factory: defaultEmergencyCancelTimelock()
    Vault-->>Factory: initialized
    Note right of Factory: VaultCreated event emitted
    Factory-->>Oracle: vault address
```

**Events:** `VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity)`

**Reverts:**
- `NotOracle()` — caller is not the oracle
- `ZeroFloor()` — `minimumFirstLiquidity_` is 0
- `InvalidTickSpacing()` — `tickSpacing_` is 0 or negative
- `DuplicateMarket()` — a vault already exists for `marketId_`
- `ZeroConditionId()` — `conditionId_` is 0
- `ZeroTokenId()` — `yesTokenId_` or `noTokenId_` is 0
- `DuplicateTokenId()` — `yesTokenId_` equals `noTokenId_`
- `NotBinaryCondition()` — the condition's outcome slot count is not 2; an unprepared condition returns 0
- `TokenIdMismatch()` — `yesTokenId_` is not the index set 1 position ID, or `noTokenId_` is not the index set 2 position ID, of `(usdc, conditionId_)`
- `CloneDeployFailed()` — EIP-1167 `create` returned address(0)

---

### `LPVault.initialize`

```solidity
function initialize(
    bytes32 marketId_,
    address usdc_,
    address exchange_,
    address conditionalTokens_,
    int24   tickSpacing_,
    address factory_,
    uint128 minimumFirstLiquidity_,
    uint256 version_,
    bytes32 conditionId_,
    uint256 yesTokenId_,
    uint256 noTokenId_
) external initializer
```

**Actor:** Factory only (enforced by an inline `msg.sender == factory_` check against the argument, because `factory` is not yet stored when a clone is initialized; there is no `onlyFactory` modifier)

Called once by the factory immediately after cloning. Stores all per-vault configuration, including the outcome-token identity, reads the factory's `defaultEmergencyCancelTimelock()` once into `emergencyCancelTimelock`, sets the vault phase to Active, pre-approves the exchange for USDC and outcome tokens, and snapshots the EIP-712 domain separator. It makes no identity check of its own: only the factory can call it, and `createVault` verifies the identity before it deploys the clone.

| Parameter | Type | Description |
|-----------|------|-------------|
| `marketId_` | `bytes32` | Market identifier for this vault |
| `usdc_` | `address` | USDC ERC-20 address |
| `exchange_` | `address` | ProphetCTFExchange address |
| `conditionalTokens_` | `address` | Gnosis ConditionalTokens (ERC-1155) address |
| `tickSpacing_` | `int24` | Tick increment; all position bounds must align to this |
| `factory_` | `address` | Factory that deployed this clone — must equal `msg.sender` |
| `minimumFirstLiquidity_` | `uint128` | Floor for the first mint, when `nextPositionId == 0` |
| `version_` | `uint256` | Factory's `implementationVersion` at deploy time; stored for off-chain identification |
| `conditionId_` | `bytes32` | ConditionalTokens condition ID of the market; stored as `conditionId` |
| `yesTokenId_` | `uint256` | Index set 1 (YES) position ID; stored as `yesTokenId` |
| `noTokenId_` | `uint256` | Index set 2 (NO) position ID; stored as `noTokenId` |

```mermaid
sequenceDiagram
    participant Factory as LPVaultFactory
    participant Vault as LPVault
    participant USDC
    participant CT as ConditionalTokens

    Factory->>Vault: initialize(...)
    Note right of Vault: Checks:<br/>not already initialized<br/>msg.sender == factory_
    Note right of Vault: Store: marketId, usdc, exchange, ctf,<br/>conditionId, yesTokenId, noTokenId,<br/>tickSpacing, factory, minimumFirstLiquidity,<br/>implementationVersion = version_
    Vault->>Factory: defaultEmergencyCancelTimelock()
    Note right of Vault: emergencyCancelTimelock = the factory's default, read once
    Note right of Vault: phase = 1 (Active)<br/>reentrancyGuard = 1<br/>lastOperatorActivityTimestamp = now
    Note right of Vault: Cache EIP-712 domain separator
    Vault->>USDC: approve(exchange, type(uint256).max)
    Vault->>CT: setApprovalForAll(exchange, true)
```

**Events:** none

**Reverts:**
- `AlreadyInitialized()` — called a second time
- `NotFactory()` — `msg.sender != factory_`

---

### `LPVault.onERC1155Received`, `LPVault.onERC1155BatchReceived`, `LPVault.supportsInterface`

```solidity
function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
    external view onlyConditionalTokens returns (bytes4)

function onERC1155BatchReceived(address, address, uint256[] calldata ids, uint256[] calldata, bytes calldata)
    external view onlyConditionalTokens returns (bytes4)

function supportsInterface(bytes4 interfaceId) external pure returns (bool)
```

**Actor:** The vault's own ConditionalTokens contract, during `safeTransferFrom` or `safeBatchTransferFrom`. `supportsInterface` is a public view for any caller.

The two hooks let the vault receive its outcome tokens: the ERC-1155 standard makes the token contract call them on a contract recipient and revert unless it gets the acknowledgement value back. Both hooks are stateless. They write nothing, merge nothing, and take no reentrancy guard, because a hook runs inside the exchange's settlement transaction and a revert there reverts the match. Each hook returns its acknowledgement value only when the caller is the vault's configured `conditionalTokens` and every token ID is the vault's `yesTokenId` or `noTokenId`, which the factory verified at `createVault`. The unscoped `setApprovalForAll(exchange, true)` that `initialize` grants is acceptable because of this check: no other market's token can enter the vault.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` / `ids` | `uint256` / `uint256[]` | The token ID, or every token ID of the batch; each must be `yesTokenId` or `noTokenId` |
| `interfaceId` | `bytes4` | `0x4e2312e0` (IERC1155Receiver), `0x01ffc9a7` (ERC-165), and `0x1626ba7e` (EIP-1271, the order maker) return `true`; any other value returns `false` |

**Returns:** `0xf23a6e61` from `onERC1155Received`, `0xbc197c81` from `onERC1155BatchReceived`.

**Events:** none

**Reverts:**
- `NotConditionalTokens()` — the caller is not the vault's configured ConditionalTokens contract
- `UnknownTokenId()` — a token ID is neither `yesTokenId` nor `noTokenId`; in a batch, one such element rejects the whole batch

---

### `LPVault.isValidSignature`

```solidity
function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4)
```

**Actor:** The vault's configured exchange, during `_validateOrder` of a fill whose order names the vault as `maker` and `signer` with `signatureType = POLY_1271`.

The vault has no private key, so this is the one way an order can name it as maker: a registered Operator key signs the exchange's `hashOrder(order)`, and the vault vouches for that signature to the exchange (EIP-1271, decision C22). The method returns `0x1626ba7e` when every one of these holds, and `0xffffffff` otherwise: the caller is the vault's `exchange`; the vault is in the Active phase and not paused; the signature is 65 bytes with `s` in the lower half of the curve order and `v` in {27, 28}; `ecrecover` returns a non-zero address; and that address is a registered Operator on the factory at the moment of the call. The registry is read at call time, so one `removeOperator` invalidates every unfilled order that key signed. A paused, wound-down, or frozen vault takes no new fill: a resting order fails its signature check at match time, and the keeper cancels its orders when it sees `TradingPaused`, `VaultWindDownStarted`, or `EmergencyCancelExecuted`. The caller check exists because USDC `FiatTokenV2_2` routes a bytes signature in `permit` and `transferWithAuthorization` to the payer's `isValidSignature` (ERC-7598), so an open vouch would let an Operator key move vault USDC around the exchange.

**OPERATOR TRUST ASSUMPTION:** any registered Operator can author orders that spend vault assets through the exchange. The vault checks who signed, never what was signed: the Operator's order sizes and prices are trusted. The approvals `initialize` granted the exchange become reachable through this method; it adds no transfer path.

| Parameter | Type | Description |
|-----------|------|-------------|
| `hash` | `bytes32` | The digest the signature was produced over: the exchange's `hashOrder(order)` |
| `signature` | `bytes` | 65-byte `r || s || v` ECDSA signature from a registered Operator key |

```mermaid
sequenceDiagram
    participant Exchange as ProphetCTFExchange
    participant Vault as LPVault
    participant Factory as LPVaultFactory

    Exchange->>Vault: staticcall isValidSignature(hashOrder(order), signature)
    Note right of Vault: msg.sender == exchange?<br/>phase == Active and not paused?<br/>signature well formed, signer != 0?
    Vault->>Factory: operators(signer)
    Factory-->>Vault: 1
    Vault-->>Exchange: 0x1626ba7e (or 0xffffffff on any failed check)
```

**Returns:** `0x1626ba7e` when the vault vouches, `0xffffffff` otherwise.

**Events:** none

**Reverts:** none by design. Every refusal is a returned value, because the exchange treats a revert and a wrong return value differently and any address can call this method with any bytes.

**Gas:** 24,503 measured around the call from a cold vault and a cold factory (one external staticcall, three cold storage slots, one `ecrecover`).

---

### `LPVault.startWindDown`

```solidity
function startWindDown() external onlyOracle
```

**Actor:** Oracle

Transitions the vault from Active (phase 1) to WindDown (phase 2). One-way — there is no mechanism to revert to Active. After this call, `depositForIntent`, `mintPositionFor`, and `updateTick` revert; `burnPosition`, `burnPositionFor`, `reclaimDeposit`, `reclaimDepositFor`, `mergeCompleteSets`, `redeemOutcomeTokens`, and `emergencyCancelAll` remain open. The Oracle calls this first, then `redeemOutcomeTokens` once the Conditional Tokens contract holds the result, because the redemption reverts while the vault is Active.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Oracle
    participant Vault as LPVault

    Oracle->>Vault: startWindDown()
    Note right of Vault: Checks: phase == 1 (Active)
    Note right of Vault: phase = 2 (WindDown)
    Note right of Vault: VaultWindDownStarted event emitted
```

**Events:** `VaultWindDownStarted(bytes32 indexed marketId)`

**Reverts:**
- `NotOracle()` — caller is not the oracle
- `VaultNotActive()` — vault is not in Active phase

---

### `LPVault.setMinimumFirstLiquidity`

```solidity
function setMinimumFirstLiquidity(uint128 newMin) external onlyOracle
```

**Actor:** Oracle

Updates the floor applied to the first mint (when `nextPositionId == 0`). Callable at any time. The value matters only before the first mint. After it, the setter still succeeds and no mint reads the value (decision C15 in `audits/audit-fixes-ranged.md`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `newMin` | `uint128` | New minimum liquidity value; must be > 0 |

```mermaid
sequenceDiagram
    actor Oracle
    participant Vault as LPVault

    Oracle->>Vault: setMinimumFirstLiquidity(newMin)
    Note right of Vault: Checks: newMin > 0
    Note right of Vault: minimumFirstLiquidity = newMin
    Note right of Vault: MinimumFirstLiquidityUpdated event emitted
```

**Events:** `MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin)`

**Reverts:**
- `NotOracle()` — caller is not the oracle
- `ZeroFloor()` — `newMin` is 0

---

## 2. Transactional Methods

### `LPVault.depositForIntent`

```solidity
function depositForIntent(
    address  lp,
    int24    tickLower,
    int24    tickUpper,
    uint256  usdcAmount,
    bytes32  intentId,
    uint256  deadline,
    bytes calldata signature
) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat
```

**Actor:** Operator

Escrows an LP's USDC against a signed mint intent. Pulls `usdcAmount` USDC from the LP's Safe (which approved the vault through a relayed Safe transaction), and records the Safe, the amount, and the intent's struct hash under `intentId`. This is the only way USDC enters a position: a plain USDC transfer to the vault is never a deposit.

| Parameter | Type | Description |
|-----------|------|-------------|
| `lp` | `address` | The LP's Safe — the recorded depositor and the USDC source |
| `tickLower` | `int24` | Lower bound of the price range; must be < `tickUpper` and aligned to `tickSpacing` |
| `tickUpper` | `int24` | Upper bound of the price range; must be > `tickLower` and aligned to `tickSpacing` |
| `usdcAmount` | `uint256` | USDC to pull from the Safe; must be > 0 |
| `intentId` | `bytes32` | Unique identifier for replay protection, shared with `mintPositionFor` and both reclaims |
| `deadline` | `uint256` | Last `block.timestamp` at which the deposit is accepted (inclusive) |
| `signature` | `bytes` | 65-byte EIP-712 signature from the Safe's owner key over the `MintIntent` struct |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault
    participant Factory as LPVaultFactory
    participant USDC

    Operator->>Vault: depositForIntent(lp, tL, tU, amount, intentId, deadline, sig)
    Note right of Vault: Checks:<br/>phase == Active, not paused<br/>usdcAmount > 0<br/>block.timestamp <= deadline<br/>tickLower < tickUpper, both aligned<br/>signer recovered from sig
    Vault->>Factory: safeFactory(), safeProxyBytecodeHash()
    Note right of Vault: derived Safe == lp<br/>intentId not used, not escrowed
    Note right of Vault: pendingDeposits[intentId] = (lp, amount, structHash)<br/>totalEscrowed += amount
    Vault->>USDC: transferFrom(lp, vault, usdcAmount)
    Note right of Vault: DepositEscrowed event emitted
```

**Events:** `DepositEscrowed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount)`

**Reverts:**
- `NotOperator()` — caller is not an operator
- `TradingIsPaused()` — vault is paused
- `VaultNotActive()` — vault is not in Active phase
- `ZeroAmount()` — `usdcAmount` is 0
- `IntentExpired()` — `block.timestamp > deadline`
- `InvalidRange()` — `tickLower >= tickUpper`, `tickLower < 0`, or `tickUpper > PRICE_TICK_ONE` (10000)
- `TickNotAligned()` — either tick is not a multiple of `tickSpacing`
- `InvalidSignature()` — signature is malformed, malleable, or from a key whose derived Safe is not `lp`
- `IntentAlreadyUsed()` — `intentId` was consumed by a mint or a reclaim
- `DepositAlreadyEscrowed()` — `intentId` already holds an escrow
- `SafeCastOverflow()` — `usdcAmount` exceeds `uint96`
- `TransferFailed()` — the USDC pull failed (short allowance or balance)

---

### `LPVault.mintPositionFor`

```solidity
function mintPositionFor(
    address  lp,
    int24    tickLower,
    int24    tickUpper,
    uint256  usdcAmount,
    bytes32  intentId,
    uint256  deadline
) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat returns (uint256 positionId)
```

**Actor:** Operator

Creates the concentrated-liquidity position that an escrowed intent authorizes. Verifies no signature and moves no USDC: the escrow (`depositForIntent`) did both. Requires that the escrow names `lp` and that the struct hash recomputed from the six arguments equals the recorded hash, then consumes the escrow, initialises tick state, and records the position owned by the Safe. Reads no clock: `deadline` is an argument only because the hash needs it, so a deposit made near its deadline can still mint.

| Parameter | Type | Description |
|-----------|------|-------------|
| `lp` | `address` | The LP's Safe — must be the escrow's recorded depositor |
| `tickLower` | `int24` | Lower bound of the price range; must be < `tickUpper` and aligned to `tickSpacing` |
| `tickUpper` | `int24` | Upper bound of the price range; must be > `tickLower` and aligned to `tickSpacing` |
| `usdcAmount` | `uint256` | USDC amount of the intent; must be > 0 and equal the escrowed amount |
| `intentId` | `bytes32` | Unique identifier for replay protection; each `intentId` can only be used once |
| `deadline` | `uint256` | The deadline the owner key signed — part of the recorded hash |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: mintPositionFor(lp, tL, tU, amount, intentId, deadline)
    Note right of Vault: Checks:<br/>phase == Active, not paused<br/>usdcAmount > 0<br/>tickLower < tickUpper<br/>both ticks aligned to tickSpacing<br/>intentId not used before<br/>escrow exists, names lp, hash matches<br/>liquidity >= minFirstLiq (if nextPositionId == 0)
    Note right of Vault: Mark intentId as used<br/>delete pendingDeposits[intentId]<br/>totalEscrowed -= amount
    Note right of Vault: Compute liquidity = usdcAmount * PRECISION / rangeWidth
    Note right of Vault: Init ticks if new; update liquidityGross / liquidityNet
    Note right of Vault: Create positions[positionId] with owner = lp,<br/>mintTick = currentTick clamped into [tL, tU]
    Note right of Vault: Increment activeLiquidity if position is in-range
    Note right of Vault: PositionMinted event emitted (no USDC moves)
    Vault-->>Operator: positionId
```

**Events:** `PositionMinted(uint256 indexed positionId, address indexed owner, int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity, uint256 usdcAmount, bytes32 intentId)`. The `positions(uint256)` getter returns `(owner, tickLower, tickUpper, mintTick, liquidity)`, five words. `mintTick` is `currentTick` at the mint, clamped to `tickLower` when the price was below the range and to `tickUpper` when it was at or above it (FR-AFPO).

**Reverts:**
- `NotOperator()` — caller is not an operator
- `TradingIsPaused()` — vault is paused
- `VaultNotActive()` — vault is not in Active phase
- `ZeroAmount()` — `usdcAmount` is 0
- `InvalidRange()` — `tickLower >= tickUpper`, `tickLower < 0`, or `tickUpper > PRICE_TICK_ONE` (10000)
- `TickNotAligned()` — either tick is not a multiple of `tickSpacing`
- `IntentAlreadyUsed()` — `intentId` was already used by a mint or a reclaim
- `DepositNotEscrowed()` — no escrow exists for `intentId`
- `NotIntentOwner()` — the escrow's recorded Safe is not `lp`
- `IntentMismatch()` — the recomputed struct hash differs from the recorded one (range, amount, or deadline changed)
- `BelowMinimumFirstLiquidity()` — first mint liquidity below floor

---

### `LPVault.heartbeat`

```solidity
function heartbeat() external onlyOperator touchesHeartbeat
```

**Actor:** Operator

Refreshes `lastOperatorActivityTimestamp` and changes nothing else. This is the Operator's refresh path while the vault is paused or wound down, where `updateTick` reverts, and for an Operator with no report to send. On an Active market the keeper's `updateTick` with the current tick refreshes the timer itself. Every Operator function carries `touchesHeartbeat`, so every successful Operator call refreshes the timer.

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: heartbeat()
    Note right of Vault: Checks:<br/>phase != Cancelled
    Note right of Vault: lastOperatorActivityTimestamp = now
```

**Events:** none

**Reverts:**
- `NotOperator()` — caller is not an operator
- `VaultCancelled()` — vault is in terminal Cancelled phase

---

### `LPVault.updateTick`

```solidity
function updateTick(int24 newTick) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat
```

**Actor:** Operator

Synchronises the vault's price tick with the off-chain CLOB mid-price. Crosses every initialised tick between `currentTick` and `newTick`, adjusting `activeLiquidity` and `noSideLiquidity`. An interior mint tick is an initialised tick too: it counts its positions' liquidity and holds their NO sub-range's net, so a move crosses it and `ticksCrossed` counts it. For every segment the move traverses, the trailing one included, the vault shifts the three totals of the solvency ledger with the liquidity split as it stood in that segment: moving up, each NO-side level buys NO at `1 − t / 10000` and each YES-side level's YES returns to USDC; moving down, the mirror. The search for the next initialised tick reads only the bitmap words between `currentTick` and `newTick`, so the cost of a call follows the reported move and not where any LP initialised a tick. A call with the current tick refreshes only `lastOperatorActivityTimestamp` and returns: no crossing, no bitmap read, no event. The keeper reports every 60 seconds and after fills, so this is the normal case.

| Parameter | Type | Description |
|-----------|------|-------------|
| `newTick` | `int24` | The new price tick. A value equal to `currentTick` refreshes only the heartbeat |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: updateTick(newTick)
    Note right of Vault: Checks:<br/>not paused<br/>phase == Active
    Note right of Vault: lastOperatorActivityTimestamp = now

    alt newTick == currentTick
        Note right of Vault: return (no crossing, no event)
    else newTick != currentTick
        loop for each initialised tick between currentTick and newTick (a boundary or a mint tick)
            Note right of Vault: accrueSegment(up to the tick) with the current split
            Note right of Vault: crossTick(tick):<br/>activeLiquidity += liquidityNet (or -net)<br/>noSideLiquidity += noLiquidityNet (or -net)
            Note right of Vault: Stops and reverts if crossCount > 256
        end
        Note right of Vault: accrueSegment(the trailing segment to newTick)
        Note right of Vault: write the shift to the three ledger totals

        Note right of Vault: currentTick = newTick
        Note right of Vault: TickUpdated event emitted
    end
```

**Events:** `TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed)` — only when the tick changes

**Reverts:**
- `NotOperator()` — caller is not an operator
- `TradingIsPaused()` — vault is paused
- `VaultNotActive()` — vault is not in Active phase
- `TooManyTicksCrossed()` — more than 256 initialised ticks between old and new tick; call multiple times with intermediate values

---

### `LPVault.burnPosition`

```solidity
function burnPosition(uint256 positionId) external nonReentrant
```

**Actor:** LP's Safe (position owner)

Closes a position the Safe owns and pays what its claim holds under the claim model (decision C26): USDC for every level the price never crossed, one outcome token for the band between the mint tick and the current tick (YES below the mint tick, NO at or above it) plus the USDC that buying that token at each level's price did not spend. The vault settles its tokens first (before the switch it merges its free pairs, the YES and NO pairs above what the ledger owes in both tokens, read before its own claim is debited; after the Oracle's redemption it redeems every token it holds), removes the position's liquidity from both ticks (deleting a tick and clearing its bitmap bit when its `liquidityGross` reaches zero), reduces `activeLiquidity` (and `noSideLiquidity` for a position on the NO side of its mint tick) when the position is in range, removes the position's NO sub-range and its interior mint tick's reference, debits the solvency ledger by the full scaled claim, deletes the record, and pays. Before the switch it pays each asset's owed amount times that asset's ratio (the smaller of 1 and held ÷ owed total), rounded down, USDC in one transfer and the token in kind. After the switch the token leg is worth `tokenOwed × numerator ÷ denominator` USDC at the stored payout, and the burn pays the principal and that USDC as one prorated sum in one USDC transfer, with no ERC-1155 transfer. Never a revert on a shortfall. Works in every phase, while paused, and with every Operator removed. Never refreshes the Operator heartbeat. A burn is valued at the last reported tick, so a burn between a fill and the keeper's report of it takes its share of that fill's spend as a final cut; see `specs/FLOWS.md` 6.1 and ADR-DYNK in FEAT-7G40 (finding CV-08).

| Parameter | Type | Description |
|-----------|------|-------------|
| `positionId` | `uint256` | The position to close; `msg.sender` must be its recorded owner |

**The claim.** With `L = liquidity`, `width = tickUpper − tickLower`, `m = mintTick`, `c = currentTick`, `ONE = 10000`, and `P = 1e18`:

```text
c < m:   a = max(c, tickLower), band = m − a           # the YES band [a, m)
         tokens = L × band / P
         Σt = band × (a + m − 1) / 2
         usdc = L × (width × ONE − Σt) / (ONE × P)
c > m:   b = min(c, tickUpper), band = b − m           # the NO band [m, b)
         tokens = L × band / P
         Σt = band × (m + b − 1) / 2
         usdc = L × ((width − band) × ONE + Σt) / (ONE × P)
c == m, or band == 0:  usdc = L × width / P, no token
```

Worked example: 300 USDC over `[5500, 6500)` minted at 6000 gives `L = 3e23`. With the vault at 5700: `band = 300`, `tokens = 90e6` (90 YES), `Σt = 300 × (5700 + 6000 − 1) / 2 = 1,754,850`, `usdc = 3e23 × (10,000,000 − 1,754,850) / 1e22 = 247,354,500` (247.3545 USDC). The vault spent 52.6455 USDC on the 90 YES, an average price of 0.585, the middle of the band. At 6300 the NO band pays 90 NO and 265,345,500 units.

```mermaid
sequenceDiagram
    actor Safe as LP's Safe
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    Safe->>Vault: burnPosition(positionId)
    Note right of Vault: Checks:<br/>owner != 0 and liquidity > 0<br/>position.owner == msg.sender
    Note right of Vault: the claim from<br/>(liquidity, range, mintTick, currentTick)
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    Note right of Vault: read the stored payout (the switch)
    Vault->>USDC: balanceOf(vault)
    alt switch off
        Note right of Vault: pairs = free pairs, min(YES - min(YES, totalYesOwed), NO - min(NO, totalNoOwed)), read before the debit<br/>usdcPaid = usdcOwed x min(1, (balance + pairs - totalEscrowed) / totalUsdcOwed)<br/>tokenPaid = tokenOwed x min(1, (held - pairs) / tokenTotal)
    else switch on
        Note right of Vault: tokenUsdc = tokenOwed x numerator / denominator<br/>ratio = min(1, (balance + tokens at the payout - totalEscrowed) / (totalUsdcOwed + token totals at the payout))<br/>usdcPaid = usdcOwed x ratio; tokenPaid = (usdcOwed + tokenUsdc) x ratio - usdcPaid
    end
    Note right of Vault: remove the NO sub-range, then the liquidity from both ticks (clear a bit at zero)<br/>activeLiquidity -= liquidity if in range, noSideLiquidity too on the NO side<br/>debit the three ledger totals by the scaled claim<br/>delete positions[positionId]
    alt switch off
        Vault->>CTF: mergePositions(pairs) if pairs > 0
        Vault->>USDC: transfer(safe, usdcPaid)
        Vault->>CTF: safeTransferFrom(vault, safe, tokenId, tokenPaid) — last call
    else switch on
        Vault->>CTF: redeemPositions(usdc, 0, conditionId, [1, 2]) if a token is held
        Vault->>USDC: transfer(safe, usdcPaid + tokenPaid) — last call
    end
    Note right of Vault: PositionBurned event emitted
```

**Events:** `CompleteSetsMerged(address indexed caller, uint256 amount)` when free pairs merged before the switch; `OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount)` when tokens redeemed after it; `PositionBurned(uint256 indexed positionId, address indexed owner, uint256 usdcOwed, uint256 usdcPaid, uint256 tokenId, uint256 tokenOwed, uint256 tokenPaid)` — `paid < owed` marks a ratio below 1; before the switch `tokenPaid` is the tokens transferred, after it the USDC paid for the token leg, and the one USDC transfer carries `usdcPaid + tokenPaid`

**Reverts:**
- `PositionNotFound()` — never minted, already burned, or consumed by `mergePositions`
- `NotPositionOwner()` — caller does not own this position
- `TransferFailed()` — USDC transfer failed

---

### `LPVault.burnPositionFor`

```solidity
function burnPositionFor(
    address  lp,
    uint256  positionId,
    uint256  deadline,
    bytes calldata signature
) external onlyOperator nonReentrant touchesHeartbeat
```

**Actor:** Operator

Relays the owner key's signed `BurnIntent` to close that Safe's position — the same burn as `burnPosition`, with the Operator paying the gas. Every asset goes to `position.owner`, never to the caller. The Operator chooses the block, and so the `currentTick` that values the claim, bounded by the deadline the owner key signed; the Safe's remedy is `burnPosition`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `lp` | `address` | The LP's Safe — must be the position's recorded owner |
| `positionId` | `uint256` | The position to close |
| `deadline` | `uint256` | Last `block.timestamp` at which the relayed burn is accepted (inclusive) |
| `signature` | `bytes` | 65-byte EIP-712 signature from the Safe's owner key over `BurnIntent(address lp,uint256 positionId,uint256 deadline)` |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault
    participant USDC
    participant CTF as ConditionalTokens

    Operator->>Vault: burnPositionFor(lp, positionId, deadline, sig)
    Note right of Vault: Checks:<br/>block.timestamp <= deadline<br/>derived Safe of the signer == lp<br/>struct hash not used<br/>owner != 0, liquidity > 0, owner == lp
    Note right of Vault: usedBurnAuthorizations[structHash] = true
    Note right of Vault: the same body as burnPosition
    Vault->>USDC: transfer(lp, usdcPaid)
    Vault->>CTF: safeTransferFrom(vault, lp, tokenId, tokenPaid)
    Note right of Vault: PositionBurned event emitted
```

**Events:** `CompleteSetsMerged` when pairs merged; `PositionBurned(...)`

**Reverts:**
- `NotOperator()` — caller is not an operator
- `IntentExpired()` — `block.timestamp > deadline`
- `InvalidSignature()` — signature is malformed, malleable, produced over another type, or from a key whose derived Safe is not `lp`
- `IntentAlreadyUsed()` — this `BurnIntent` was already consumed
- `PositionNotFound()` — never minted, already burned, or consumed by `mergePositions`
- `NotPositionOwner()` — `lp` does not own this position
- `TransferFailed()` — USDC transfer failed

---

### `LPVault.mergeCompleteSets`

```solidity
function mergeCompleteSets() external nonReentrant
```

**Actor:** Any wallet

Merges the vault's free pairs, `min(YES − min(YES, totalYesOwed()), NO − min(NO, totalNoOwed()))`, as complete sets of the vault's condition into USDC held by the vault, through the Conditional Tokens contract. A pair below what the ledger owes is a claim's band token and never merges, so the merge changes no claim's token leg and no claim's ratio, and the caller receives nothing (finding CV-01 of `audits/code-validation-round-1.md`, R14). No role, pause, phase, or heartbeat check. A vault with no free pair returns without a call and emits nothing.

```mermaid
sequenceDiagram
    actor Caller as Any wallet
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    Caller->>Vault: mergeCompleteSets()
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    Note right of Vault: amount = min(YES − min(YES, totalYesOwed), NO − min(NO, totalNoOwed)); return if 0
    Vault->>CTF: mergePositions(usdc, 0, conditionId, [1, 2], amount)
    CTF->>USDC: transfer(vault, amount)
    Note right of Vault: CompleteSetsMerged(caller, amount)
```

**Events:** `CompleteSetsMerged(address indexed caller, uint256 amount)`, only when `amount > 0`

**Reverts:**
- `Reentrancy()` — re-entered through a guarded call

---

### `LPVault.redeemOutcomeTokens`

```solidity
function redeemOutcomeTokens() external onlyOracle nonReentrant
function payoutNumerators() external view returns (uint128 numYes, uint128 numNo)
```

**Actor:** Oracle

Redeems the vault's whole YES and NO balances through the Conditional Tokens contract into USDC held by the vault, after the result of the vault's condition is reported (`payoutDenominator(conditionId) != 0`). The first successful call is the switch: it copies the two payout numerators from the Conditional Tokens contract into vault storage, and every later burn values its token leg at that payout in USDC, redeems the vault's tokens first, and pays one USDC transfer at one ratio. The numerators never come from an argument, so the Oracle cannot set a payout. Reverts while the vault is Active: the Oracle calls `startWindDown` first, because `updateTick` and `mintPositionFor` revert in WindDown and Cancelled, so no tick report can move value between claims that are now fixed USDC. Works in WindDown and Cancelled, paused or not, runs again for tokens that arrive later, changes no phase, and refreshes no heartbeat. A call with nothing to redeem makes no call and emits nothing. Before the switch an exit pays the winning token in kind, and the LP redeems it at the Conditional Tokens contract from the Safe for the same USDC, so no LP waits on the Oracle.

```mermaid
sequenceDiagram
    actor Oracle
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    Oracle->>Vault: redeemOutcomeTokens()
    Note right of Vault: Checks: caller is the oracle, phase != 1 (Active)
    Vault->>CTF: payoutDenominator(conditionId) — revert MarketNotResolved if 0
    opt the stored payout is zero
        Vault->>CTF: payoutNumerators(conditionId, 0), payoutNumerators(conditionId, 1)
        Note right of Vault: store both (the switch); SafeCastOverflow above uint128
    end
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    opt either balance above 0
        Vault->>CTF: redeemPositions(usdc, 0, conditionId, [1, 2])
        CTF->>USDC: transfer(vault, balance x numerator / denominator per side)
        Note right of Vault: OutcomeTokensRedeemed(oracle, yes, no, usdc)
    end
```

**Events:** `OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount)`, only when either balance was above zero

**Reverts:**
- `NotOracle()` — caller is not the oracle
- `VaultStillActive()` — the vault is in Active phase
- `MarketNotResolved()` — the Conditional Tokens contract holds no result for the condition
- `SafeCastOverflow()` — a reported numerator exceeds `uint128`; the switch stays off and every exit keeps working
- `Reentrancy()` — re-entered through a guarded call

**Gas:** below 180,000 call gas for the first call with both tokens held, measured cold against the mock USDC and the real Conditional Tokens bytecode (NFR-CYS3 in FEAT-6HBN).

---

### `LPVault.mergePositions`

```solidity
function mergePositions(uint256[] calldata positionIds)
    external onlyOperator whenNotPaused nonReentrant touchesHeartbeat
```

**Actor:** Operator

Combines two or more distinct positions with the same owner, range, and mint tick into the first entry (`positionIds[0]`). Sums liquidity into the survivor and zeroes the liquidity of every consumed record. Tick state is unchanged (net liquidity on the range and on the NO sub-range is the same). The merge writes no total of the solvency ledger: the claim is linear in liquidity, and every merged position shares the range and the mint tick. This joins LP position records. It is not the complete-set merge of YES and NO tokens into USDC, which audit-fix step R9 adds as `mergeCompleteSets()`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `positionIds` | `uint256[]` | Array of distinct position IDs to merge; must have at least 2 elements; all must share the same owner, `tickLower`, `tickUpper`, and `mintTick` |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: mergePositions([posA, posB, posC])
    Note right of Vault: Checks:<br/>not paused<br/>positionIds.length >= 2<br/>no repeated ID (pairwise, before any read)

    Note right of Vault: Load survivor = positions[posA]<br/>Check: survivor.owner != 0 (a burned record never merges)

    loop for each consumed position (posB, posC, ...)
        Note right of Vault: Check: consumed.owner != 0<br/>Check: same owner, same tickLower, same tickUpper<br/>Check: same mintTick
        Note right of Vault: totalLiquidity += consumed.liquidity
        Note right of Vault: consumed.liquidity = 0
    end

    Note right of Vault: survivor.liquidity = totalLiquidity
    Note right of Vault: PositionsMerged event emitted
```

**Events:** `PositionsMerged(uint256[] positionIds, uint256 survivorId)`

**Reverts:**
- `NotOperator()` — caller is not an operator
- `TradingIsPaused()` — vault is paused
- `VaultCancelled()` — vault is in terminal Cancelled phase
- `InsufficientPositions()` — fewer than 2 position IDs provided
- `DuplicatePositionId()` — an ID appears twice in `positionIds`
- `PositionNotFound()` — the survivor or a consumed position was burned, so its owner reads zero
- `RangeMismatch()` — any consumed position has a different owner, `tickLower`, or `tickUpper` than the survivor
- `MintTickMismatch()` — any consumed position has a different `mintTick` than the survivor

---

### `LPVault.reclaimDeposit`

```solidity
function reclaimDeposit(bytes32 intentId) external nonReentrant
```

**Actor:** LP's Safe (through a Safe transaction the owner key signs)

One-call escape hatch: refunds the USDC escrowed against `intentId` to the Safe that paid it. The escrow record proves the deposit, so the call needs no signature, no Operator co-signature, no timelock, no phase check, and no pause check. It works with every Operator removed and in every phase, including Cancelled. Escrow seniority (decision C7) binds burns, which read the balance less `totalEscrowed`, and not fills: the exchange's unlimited USDC allowance can spend escrowed USDC. So the refund merges the vault's free pairs (the pairs above what the ledger owes in both tokens) into USDC before it transfers, and a reclaim never waits for a keeper to merge; the amount paid is the recorded amount, whatever the merge produced. The keeper keeps its quoted size below the vault's USDC balance minus `totalEscrowed`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentId` | `bytes32` | The escrowed intent to refund; `msg.sender` must be its recorded Safe |

```mermaid
sequenceDiagram
    actor Safe as LP's Safe
    participant Vault as LPVault
    participant CT as ConditionalTokens
    participant USDC

    Safe->>Vault: reclaimDeposit(intentId)
    Note right of Vault: Checks:<br/>intentId not already used<br/>escrow exists<br/>recorded Safe == msg.sender
    Vault->>CT: balanceOf(YES), balanceOf(NO)
    Note right of Vault: pairs = free pairs, read before the effects
    Note right of Vault: usedIntents[intentId] = true<br/>delete pendingDeposits[intentId]<br/>totalEscrowed -= amount
    Vault->>CT: mergePositions(pairs), only when pairs > 0
    Vault->>USDC: transfer(recorded Safe, recorded amount)
    Note right of Vault: DepositReclaimed event emitted
```

**Events:** `DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount)` — the recorded Safe and the recorded amount; `CompleteSetsMerged(caller, amount)` first, when the vault held free pairs

**Reverts:**
- `IntentAlreadyUsed()` — `intentId` was already consumed by `mintPositionFor` or a prior reclaim
- `DepositNotEscrowed()` — no escrow exists for `intentId`
- `NotIntentOwner()` — `msg.sender` is not the escrow's recorded Safe
- `TransferFailed()` — USDC transfer failed

---

### `LPVault.reclaimDepositFor`

```solidity
function reclaimDepositFor(
    address  lp,
    bytes32  intentId,
    uint256  deadline,
    bytes calldata signature
) external onlyOperator nonReentrant touchesHeartbeat
```

**Actor:** Operator

Relays the owner key's signed `ReclaimIntent` to refund that Safe's escrow — the same refund as `reclaimDeposit`, with the Operator paying the gas. The USDC goes to the recorded Safe, never to the caller. The `ReclaimIntent` type is distinct from `MintIntent`, so a mint authorization never doubles as a cancellation. No phase check and no pause check. As on the direct path, the shared refund merges the vault's free pairs before it transfers, because escrow seniority binds burns and not fills.

| Parameter | Type | Description |
|-----------|------|-------------|
| `lp` | `address` | The LP's Safe — must be the escrow's recorded depositor |
| `intentId` | `bytes32` | The escrowed intent to refund |
| `deadline` | `uint256` | Last `block.timestamp` at which the relayed reclaim is accepted (inclusive) |
| `signature` | `bytes` | 65-byte EIP-712 signature from the Safe's owner key over `ReclaimIntent(address lp,bytes32 intentId,uint256 deadline)` |

```mermaid
sequenceDiagram
    actor Operator
    participant Vault as LPVault
    participant CT as ConditionalTokens
    participant USDC

    Operator->>Vault: reclaimDepositFor(lp, intentId, deadline, sig)
    Note right of Vault: Checks:<br/>block.timestamp <= deadline<br/>derived Safe of the signer == lp<br/>intentId not already used<br/>escrow exists<br/>recorded Safe == lp
    Vault->>CT: balanceOf(YES), balanceOf(NO)
    Note right of Vault: pairs = free pairs, read before the effects
    Note right of Vault: usedIntents[intentId] = true<br/>delete pendingDeposits[intentId]<br/>totalEscrowed -= amount
    Vault->>CT: mergePositions(pairs), only when pairs > 0
    Vault->>USDC: transfer(lp, recorded amount)
    Note right of Vault: DepositReclaimed event emitted
```

**Events:** `DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount)`; `CompleteSetsMerged(caller, amount)` first, when the vault held free pairs

**Reverts:**
- `NotOperator()` — caller is not an operator
- `IntentExpired()` — `block.timestamp > deadline`
- `InvalidSignature()` — signature is malformed, malleable, produced over a `MintIntent`, or from a key whose derived Safe is not `lp`
- `IntentAlreadyUsed()` — `intentId` was already consumed
- `DepositNotEscrowed()` — no escrow exists for `intentId`
- `NotIntentOwner()` — the escrow's recorded Safe is not `lp`
- `TransferFailed()` — USDC transfer failed

---

### Solvency ledger views

```solidity
function totalUsdcOwedScaled() external view returns (uint256)   // USDC units x 10000 x 1e18
function totalYesOwedScaled()  external view returns (uint256)   // token units x 1e18
function totalNoOwedScaled()   external view returns (uint256)   // token units x 1e18
function totalUsdcOwed() public view returns (uint256)           // the three truncated totals
function totalYesOwed()  public view returns (uint256)
function totalNoOwed()   public view returns (uint256)
function noSideLiquidity() external view returns (uint128)
function ticks(int24) external view returns (uint128 liquidityGross, int128 liquidityNet, int128 noLiquidityNet)
function payoutNumerators() external view returns (uint128 numYes, uint128 numNo)  // (0, 0) until the switch
```

**Actor:** any reader

The running totals of what the vault owes to its live positions, per asset, held in the claim's pre-division unit so that a mint and its burn cancel exactly, and truncated only in the three getters. Every mint, burn, and segment of a tick move writes them in the same call; the merge and the freeze write none. They are the ratio denominators every burn reads before its debit, and the monitoring surface for a shortfall, which no on-chain path reports otherwise. `noSideLiquidity` is the in-range liquidity whose mint tick is at or below `currentTick`, and `ticks()` returns a third value, the net of the NO sub-ranges `[mintTick, tickUpper)` at that tick.

**The ratio.** Per asset, the smaller of 1 and what the vault holds over what it owes:

```text
freePairs = min(YES balance − min(YES balance, totalYesOwed()), NO balance − min(NO balance, totalNoOwed()))
usdcRatio = min(1, (usdc.balanceOf(vault) + freePairs − totalEscrowed) / totalUsdcOwed())
yesRatio  = min(1, (YES balance − freePairs) / totalYesOwed())
noRatio   = min(1, (NO balance − freePairs) / totalNoOwed())
```

The free pairs are the complete sets above what the ledger owes in both tokens, read before the exiting position is debited, so its own band never counts as free. A token balance less the free pairs is never below the smaller of the balance and the total, so a balance that covers the total gives a ratio of 1 whatever the other token's balance is. A burn pays `usdcOwed × usdcRatio` and `tokenOwed × tokenRatio`, each rounded down and never above what is held, and debits the totals by the full owed amount, so every later claimant meets the same ratio. A zero total is a ratio of 1. The reclaim paths apply no ratio: escrowed USDC is senior.

**After the switch.** `payoutNumerators()` is non-zero once the Oracle's first successful `redeemOutcomeTokens` stored the payout. Every asset is then USDC, and one ratio covers every leg, with `at(x, y) = floor(x × numYes ÷ den) + floor(y × numNo ÷ den)` and `den = numYes + numNo`:

```text
usdcRatio = min(1, (usdc.balanceOf(vault) + at(YES balance, NO balance) − totalEscrowed) / (totalUsdcOwed() + at(totalYesOwed(), totalNoOwed())))
```

A burn pays `(usdcOwed + tokenUsdc) × usdcRatio` as one USDC transfer, where `tokenUsdc = at(tokenOwed, 0)` for a YES band and `at(0, tokenOwed)` for a NO band, and reports `tokenPaid` as the part the principal did not take. The three totals stay per asset; only the ratio values them at the payout.

---

## 3. Emergency Procedures

### `LPVault.emergencyCancelAll`

```solidity
function emergencyCancelAll() external
```

**Actor:** Any address (after the vault's operator-silence timelock)

Freezes the vault: sets the phase to Cancelled and changes nothing else. Callable by any address, with or without a position, once the vault's `emergencyCancelTimelock()` (7 days by default) has passed without any successful Operator call (`depositForIntent`, `mintPositionFor`, `reclaimDepositFor`, `burnPositionFor`, `updateTick`, `mergePositions`, or `heartbeat`). `activeLiquidity`, every tick, every position, every escrow, and every balance stay as they are, so each LP exits alone afterwards through `burnPosition`, `burnPositionFor`, `reclaimDeposit`, or `reclaimDepositFor`, which value the claim at the frozen tick and pay it at the ledger's ratio per asset (1 when the vault is whole), and `mergeCompleteSets` keeps working. The call costs the same gas for any number of positions and carries no reentrancy guard, because it makes no external call and moves no token.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Anyone as Any address
    participant Vault as LPVault

    Anyone->>Vault: emergencyCancelAll()
    Note right of Vault: Checks:<br/>phase != Cancelled<br/>now - lastOperatorActivityTimestamp >= emergencyCancelTimelock
    Note right of Vault: phase = 3 (Cancelled)<br/>nothing else written
    Note right of Vault: EmergencyCancelExecuted event emitted
```

**Events:** `EmergencyCancelExecuted(address indexed caller)`

**Reverts:**
- `VaultCancelled()` — vault is already in Cancelled phase
- `TimelockNotElapsed()` — fewer than `emergencyCancelTimelock` seconds since the last operator activity

---

### `LPVault.pauseTrading`

```solidity
function pauseTrading() external onlyAdmin
```

**Actor:** Admin

Sets `paused = true`, immediately blocking `depositForIntent`, `mintPositionFor`, `updateTick`, and `mergePositions`. LP exit paths (`burnPosition`, `burnPositionFor`, `reclaimDeposit`, `reclaimDepositFor`, `mergeCompleteSets`, `emergencyCancelAll`) are unaffected. Does not change the vault's phase.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Admin
    participant Vault as LPVault

    Admin->>Vault: pauseTrading()
    Note right of Vault: Checks: admins[msg.sender] == 1 (via factory)
    Note right of Vault: paused = true
    Note right of Vault: TradingPaused event emitted
```

**Events:** `TradingPaused(address indexed caller)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin

---

### `LPVault.unpauseTrading`

```solidity
function unpauseTrading() external onlyAdmin
```

**Actor:** Admin

Sets `paused = false`, restoring normal operation of all trading entry points.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Admin
    participant Vault as LPVault

    Admin->>Vault: unpauseTrading()
    Note right of Vault: Checks: admins[msg.sender] == 1 (via factory)
    Note right of Vault: paused = false
    Note right of Vault: TradingUnpaused event emitted
```

**Events:** `TradingUnpaused(address indexed caller)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin

---

## 4. Admin & Governance

### `LPVaultFactory.addOperator`

```solidity
function addOperator(address operator_) external onlyAdmin
```

**Actor:** Admin

Registers a new address as an Operator. Takes effect immediately on all vaults deployed by this factory.

| Parameter | Type | Description |
|-----------|------|-------------|
| `operator_` | `address` | Address to register as Operator; must not be the current oracle |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: addOperator(operator_)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>operator_ != oracle
    Note right of Factory: operators[operator_] = 1
    Note right of Factory: NewOperator event emitted
```

**Events:** `NewOperator(address indexed newOperatorAddress, address indexed admin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `RoleSeparation()` — `operator_` is the current oracle

---

### `LPVaultFactory.removeOperator`

```solidity
function removeOperator(address operator_) external onlyAdmin
```

**Actor:** Admin

Deregisters an Operator. Takes effect immediately on all vaults.

| Parameter | Type | Description |
|-----------|------|-------------|
| `operator_` | `address` | Address to remove from the Operator set |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: removeOperator(operator_)
    Note right of Factory: Checks: admins[msg.sender] == 1
    Note right of Factory: operators[operator_] = 0
    Note right of Factory: RemovedOperator event emitted
```

**Events:** `RemovedOperator(address indexed removedOperator, address indexed admin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin

---

### `LPVaultFactory.setOracle`

```solidity
function setOracle(address newOracle) external onlyAdmin
```

**Actor:** Admin

Updates the oracle address. Takes effect immediately on all vaults. The new oracle must not currently be an Operator.

| Parameter | Type | Description |
|-----------|------|-------------|
| `newOracle` | `address` | New oracle wallet address; must not be a registered operator |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: setOracle(newOracle)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>operators[newOracle] != 1
    Note right of Factory: oracle = newOracle
```

**Events:** none

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `RoleSeparation()` — `newOracle` is currently a registered operator

---

### `LPVaultFactory.transferAdmin`

```solidity
function transferAdmin(address newAdmin) external onlyAdmin
```

**Actor:** Admin (current)

Step 1 of a two-step admin transfer. Records `newAdmin` as the pending admin without granting the role. The pending admin must call `acceptAdmin()` to complete the transfer.

| Parameter | Type | Description |
|-----------|------|-------------|
| `newAdmin` | `address` | Proposed new admin wallet; must not be address(0) and must not already be an admin |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: transferAdmin(newAdmin)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>newAdmin != address(0)<br/>admins[newAdmin] != 1
    Note right of Factory: pendingAdmin = newAdmin
    Note right of Factory: AdminTransferProposed event emitted
```

**Events:** `AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `ZeroAddress()` — `newAdmin` is address(0)
- `AlreadyAdmin()` — `newAdmin` is already a registered admin

---

### `LPVaultFactory.acceptAdmin`

```solidity
function acceptAdmin() external
```

**Actor:** Pending admin (set by `transferAdmin`)

Step 2 of a two-step admin transfer. Grants the admin role to `msg.sender`, increments `adminCount`, and clears `pendingAdmin`.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor NewAdmin as Pending Admin
    participant Factory as LPVaultFactory

    NewAdmin->>Factory: acceptAdmin()
    Note right of Factory: Checks:<br/>msg.sender == pendingAdmin<br/>admins[msg.sender] != 1
    Note right of Factory: admins[msg.sender] = 1<br/>adminCount += 1<br/>pendingAdmin = 0
    Note right of Factory: NewAdmin event emitted
```

**Events:** `NewAdmin(address indexed newAdminAddress, address indexed admin)`

**Reverts:**
- `NotPendingAdmin()` — caller is not the current `pendingAdmin`
- `AlreadyAdmin()` — caller already holds the admin role, because `addAdmin` granted it after `transferAdmin` proposed it

A transfer adds the new admin. It does not remove the old admin. To finish a key rotation, the new admin calls `removeAdmin` on the old address.

---

### `LPVaultFactory.addAdmin`

```solidity
function addAdmin(address admin_) external onlyAdmin
```

**Actor:** Admin

Grants the admin role to `admin_` in one step. If `admin_` already holds the role, the call changes no state but still emits `NewAdmin`. For a key that has not yet proven it can sign, use the two-step `transferAdmin` / `acceptAdmin` flow instead.

| Parameter | Type | Description |
|-----------|------|-------------|
| `admin_` | `address` | Wallet to grant the admin role; must not be address(0) |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: addAdmin(admin_)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>admin_ != address(0)
    Note right of Factory: If admins[admin_] != 1:<br/>admins[admin_] = 1<br/>adminCount += 1
    Note right of Factory: NewAdmin event emitted
```

**Events:** `NewAdmin(address indexed newAdminAddress, address indexed admin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `ZeroAddress()` — `admin_` is address(0)

---

### `LPVaultFactory.removeAdmin`

```solidity
function removeAdmin(address admin) external onlyAdmin
```

**Actor:** Admin

Revokes the admin role of `admin`. Vaults read the factory's admin registry at call time, so the address loses admin rights on every vault in the same block. If `admin` is the pending admin, the proposal is withdrawn, so the address cannot complete an earlier `transferAdmin`. If `admin` holds no role, the call changes no role state but still emits `RemovedAdmin`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `admin` | `address` | Wallet whose admin role is revoked |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: removeAdmin(admin)
    Note right of Factory: Checks: admins[msg.sender] == 1
    Note right of Factory: If admins[admin] == 1:<br/>adminCount must be at least 2<br/>admins[admin] = 0<br/>adminCount -= 1
    Note right of Factory: If pendingAdmin == admin:<br/>pendingAdmin = 0
    Note right of Factory: RemovedAdmin event emitted
```

**Events:** `RemovedAdmin(address indexed removedAdmin, address indexed admin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `CannotRemoveLastAdmin()` — `admin` holds the role and is the only remaining admin

---

### `LPVaultFactory.renounceAdminRole`

```solidity
function renounceAdminRole() external onlyAdmin
```

**Actor:** Admin (self)

Revokes the caller's own admin role. If the caller is the pending admin, the proposal is withdrawn. The last remaining admin cannot renounce.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: renounceAdminRole()
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>adminCount must be at least 2
    Note right of Factory: admins[msg.sender] = 0<br/>adminCount -= 1
    Note right of Factory: If pendingAdmin == msg.sender:<br/>pendingAdmin = 0
    Note right of Factory: RemovedAdmin event emitted
```

**Events:** `RemovedAdmin(address indexed removedAdmin, address indexed admin)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `CannotRemoveLastAdmin()` — caller is the only remaining admin

---

### `LPVaultFactory.setDefaultEmergencyCancelTimelock`

```solidity
function setDefaultEmergencyCancelTimelock(uint32 newTimelock) external onlyAdmin
```

**Actor:** Admin

Sets the operator-silence duration that vaults created from now on copy at `createVault`. The default is 7 days at deployment. A change reaches only later vaults: an existing vault keeps the value it copied, readable as `emergencyCancelTimelock()`, and nothing can change it. The bound is `MAX_EMERGENCY_CANCEL_TIMELOCK` (30 days).

| Parameter | Type | Description |
|-----------|------|-------------|
| `newTimelock` | `uint32` | Silence duration in seconds; above 0 and at most 2,592,000 (30 days) |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: setDefaultEmergencyCancelTimelock(newTimelock)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>newTimelock != 0<br/>newTimelock <= 30 days
    Note right of Factory: defaultEmergencyCancelTimelock = newTimelock
    Note right of Factory: DefaultEmergencyCancelTimelockUpdated event emitted
```

**Events:** `DefaultEmergencyCancelTimelockUpdated(uint32 oldTimelock, uint32 newTimelock)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `ZeroTimelock()` — `newTimelock` is 0
- `TimelockTooLong()` — `newTimelock` is above 30 days

---

### `LPVaultFactory.scheduleImplementation`

```solidity
function scheduleImplementation(address newImpl) external onlyAdmin
```

**Actor:** Admin

Step 1 of a two-step timelocked implementation upgrade. Records the pending implementation address and sets `implementationUnlockAt` to 7 days from now. Does not change the active `implementation`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `newImpl` | `address` | New LPVault implementation contract to schedule; must not be address(0) |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: scheduleImplementation(newImpl)
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>newImpl != address(0)<br/>pendingImplementation == address(0)
    Note right of Factory: pendingImplementation = newImpl<br/>implementationUnlockAt = now + 7 days
    Note right of Factory: ImplementationScheduled event emitted
```

**Events:** `ImplementationScheduled(address indexed newImpl, uint256 unlockAt)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `ZeroAddress()` — `newImpl` is address(0)
- `ScheduleAlreadyPending()` — a schedule is already pending; cancel first

---

### `LPVaultFactory.applyImplementation`

```solidity
function applyImplementation() external onlyAdmin
```

**Actor:** Admin

Step 2 of a two-step timelocked implementation upgrade. Updates `implementation` to the pending address, increments `implementationVersion`, and clears the pending state. Can only be called after `implementationUnlockAt` has passed.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: applyImplementation()
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>pendingImplementation != address(0)<br/>now >= implementationUnlockAt
    Note right of Factory: implementation = pendingImplementation<br/>implementationVersion += 1<br/>pendingImplementation = 0<br/>implementationUnlockAt = 0
    Note right of Factory: ImplementationApplied event emitted
```

**Events:** `ImplementationApplied(address indexed newImpl, uint256 version)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `NoPendingSchedule()` — no implementation is scheduled
- `TimelockNotElapsed()` — called before `implementationUnlockAt`

---

### `LPVaultFactory.cancelScheduledImplementation`

```solidity
function cancelScheduledImplementation() external onlyAdmin
```

**Actor:** Admin

Aborts a pending implementation upgrade, clearing `pendingImplementation` and `implementationUnlockAt`. The active `implementation` is unchanged.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | No parameters |

```mermaid
sequenceDiagram
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: cancelScheduledImplementation()
    Note right of Factory: Checks:<br/>admins[msg.sender] == 1<br/>pendingImplementation != address(0)
    Note right of Factory: pendingImplementation = 0<br/>implementationUnlockAt = 0
    Note right of Factory: ImplementationCancelled event emitted
```

**Events:** `ImplementationCancelled(address indexed cancelledImpl)`

**Reverts:**
- `NotAdmin()` — caller is not a registered admin
- `NoPendingSchedule()` — no implementation is currently scheduled
