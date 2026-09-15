# Contract Flows

This document shows every flow of the two contracts, `LPVaultFactory` and `LPVault`, as sequence diagrams. I derived every diagram from the code in `src/`, not from the feature specs, so a reader can review the code against the specs with this document beside them.

Reviewed on 2026-09-15 against branch `fix/audit-ranged` at the R18 documentation commit (1c59cd4), with a clean working tree.

Each section names the function, its modifiers in the order the compiler runs them, the checks in the order the body runs them, the state the function writes, the external calls in order, and the event. A check that fails reverts with the named error. Every line reference points into `src/LPVault.sol` unless it names `LPVaultFactory.sol`.

## Terms

- **Safe**: the LP's wallet, a Gnosis Safe proxy that the Poly Safe factory (the Safe factory the exchange uses) deploys with CREATE2 (an opcode that computes a contract address from the deployer, a salt, and the code hash, so the address is known before deployment). The Safe has no private key. Its owner key signs.
- **Owner key**: the externally owned account that owns the Safe. It signs every relayed LP message. The vault derives the Safe address from the recovered signer and requires that it equals the named Safe.
- **EIP-712**: a typed-data signing standard. A message is a struct hash under a domain separator (a hash of the contract name, version, chain id, and address), so a signature for one vault cannot replay on another.
- **EIP-1167**: the minimal-proxy standard. The factory deploys a 45-byte contract that forwards every call to the implementation with `delegatecall`, so each vault has its own storage and shares one code.
- **ERC-1271**: a standard that lets a contract answer "is this signature mine?" with a magic value. The exchange asks the vault this for every order that names the vault as maker.
- **Tick**: one basis point of price. Tick 6000 is price 0.60. A position covers the half-open range `[tickLower, tickUpper)` inside `[0, 10000]`.
- **Claim model (decision C26)**: every level of a position's range starts as 1 USDC per unit of liquidity. When the price falls through a level below the mint tick, that level bought YES at the level's price. When the price rises through a level at or above the mint tick, that level bought NO at one minus the level's price. A burn pays what the levels hold now.
- **Solvency ledger**: four running totals of what the vault owes all live positions: USDC principal, YES tokens, NO tokens, and since R18 the credited spread (`totalSpreadOwedX128`). Each payout multiplies what it is owed by the smaller of 1 and held ÷ owed total, per asset, so a short vault cuts every claimant alike. The USDC ratio's denominator is the principal plus the credited spread.
- **The switch**: the Oracle's first successful `redeemOutcomeTokens`. It copies the market's payout from the Conditional Tokens contract into the vault. Before it, a burn pays its token leg in kind. After it, every payout is USDC at that payout.

## Actors and contracts

| Symbol | What it is | Authority in the code |
|---|---|---|
| Admin | An address with `admins[addr] == 1` on the factory | Role registry, pause, upgrade schedule, the default timelock |
| Oracle | The one address in `factory.oracle` | `createVault`, `setMinimumFirstLiquidity`, `startWindDown`, `redeemOutcomeTokens` |
| Operator | An address with `operators[addr] == 1` on the factory | Every `*For` relay, `updateTick`, `mergePositions`, `heartbeat`, and signing vault orders |
| Safe | The LP's Safe, recorded as `position.owner` or `pendingDeposits[intentId].lp` | `burnPosition`, `reclaimDeposit` |
| Owner key | The Safe's owner | Signs `MintIntent`, `ReclaimIntent`, `BurnIntent` |
| Anyone | Any address, no role | `mergeCompleteSets`, `emergencyCancelAll` |
| Factory | `LPVaultFactory` | Deploys clones, holds roles and the Safe derivation inputs |
| Vault | One `LPVault` clone per market | Everything else |
| Exchange | `ProphetCTFExchange` | Calls `isValidSignature`, spends the approvals `initialize` granted |
| CTF | Gnosis `ConditionalTokens` (ERC-1155) | Holds the outcome tokens, merges, redeems, calls the receiver hooks |
| USDC | The collateral ERC-20 | Moves on every payout and escrow |

## Phase state machine

`phase` is a `uint8`: 1 = Active, 2 = WindDown, 3 = Cancelled. `paused` is a separate `bool` that any phase can carry.

```mermaid
stateDiagram-v2
    [*] --> Active : initialize() sets phase = 1
    Active --> WindDown : startWindDown() by the Oracle
    Active --> Cancelled : emergencyCancelAll() by anyone after the silence timelock
    WindDown --> Cancelled : emergencyCancelAll() by anyone after the silence timelock
    Cancelled --> [*]
```

What each phase allows, from the checks in the code:

| Function | Active | WindDown | Cancelled | Paused |
|---|---|---|---|---|
| `depositForIntent`, `mintPositionFor`, `updateTick` | yes | no (`VaultNotActive`) | no (`VaultNotActive`) | no (`TradingIsPaused`) |
| `mergePositions` | yes | yes | no (`VaultCancelled`) | no (`TradingIsPaused`) |
| `heartbeat` | yes | yes | no (`VaultCancelled`) | yes |
| `startWindDown` | yes | no (`VaultNotActive`) | no (`VaultNotActive`) | yes |
| `redeemOutcomeTokens` | no (`VaultStillActive`) | yes | yes | yes |
| `emergencyCancelAll` | yes, after the timelock | yes, after the timelock | no (`VaultCancelled`) | yes |
| `burnPosition`, `burnPositionFor`, `reclaimDeposit`, `reclaimDepositFor`, `mergeCompleteSets` | yes | yes | yes | yes |
| `isValidSignature` vouches | yes | no (`0xffffffff`) | no (`0xffffffff`) | no (`0xffffffff`) |
| `pauseTrading`, `unpauseTrading`, `setMinimumFirstLiquidity` | yes | yes | yes | yes |

## 1. Deployment

### 1.1 Deploy the factory (`LPVaultFactory` constructor)

`LPVaultFactory.sol:186-224`. The `LPVault` implementation is deployed first. Its constructor calls `_disableInitializers()` (`LPVault.sol:646-648`), which sets `_initialized = true` on the implementation, so nobody can call `initialize` on it.

```mermaid
sequenceDiagram
    autonumber
    actor Deployer
    participant Impl as LPVault implementation
    participant Factory as LPVaultFactory

    Deployer->>Impl: deploy
    Note right of Impl: constructor sets _initialized = true
    Deployer->>Factory: deploy(impl, usdc, exchange, ctf, admin, oracle, operator, safeFactory, safeProxyBytecodeHash)
    Note right of Factory: oracle == operator → revert RoleSeparation<br/>safeFactory == 0 → revert ZeroAddress<br/>safeProxyBytecodeHash == 0 → revert ZeroBytecodeHash
    Note right of Factory: implementation = impl<br/>usdc, exchange, conditionalTokens, safeFactory, safeProxyBytecodeHash are immutable<br/>implementationVersion = 1<br/>defaultEmergencyCancelTimelock = 7 days<br/>admins[admin] = 1, adminCount = 1<br/>oracle = oracle, operators[operator] = 1
```

The constructor checks no other argument for zero. A zero `admin_` leaves the factory with no usable admin.

### 1.2 Create a vault for a market (`createVault` and `initialize`)

`LPVaultFactory.sol:242-287`, `LPVaultFactory.sol:313-328`, `LPVault.sol:680-733`.

```mermaid
sequenceDiagram
    autonumber
    actor Oracle
    participant Factory as LPVaultFactory
    participant CTF as ConditionalTokens
    participant Vault as LPVault clone
    participant USDC

    Oracle->>Factory: createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)
    Note right of Factory: onlyOracle → NotOracle<br/>minimumFirstLiquidity == 0 → ZeroFloor<br/>tickSpacing <= 0 → InvalidTickSpacing<br/>vaultForMarket[marketId] != 0 → DuplicateMarket
    Note right of Factory: _validateOutcomeIdentity:<br/>conditionId == 0 → ZeroConditionId<br/>either token id == 0 → ZeroTokenId<br/>yesTokenId == noTokenId → DuplicateTokenId
    Factory->>CTF: getOutcomeSlotCount(conditionId)
    Note right of Factory: != 2 → NotBinaryCondition
    Factory->>CTF: getCollectionId(0, conditionId, 1) and getPositionId(usdc, that)
    Factory->>CTF: getCollectionId(0, conditionId, 2) and getPositionId(usdc, that)
    Note right of Factory: either id differs → TokenIdMismatch
    Factory->>Vault: create (EIP-1167 bytecode with impl)
    Note right of Factory: clone == 0 → CloneDeployFailed<br/>vaultForMarket[marketId] = vault (before the external call)
    Factory->>Vault: initialize(marketId, usdc, exchange, ctf, tickSpacing, factory, minimumFirstLiquidity, implementationVersion, conditionId, yesTokenId, noTokenId)
    Note right of Vault: initializer: _initialized → AlreadyInitialized, then _initialized = true<br/>msg.sender != factory_ → NotFactory
    Note right of Vault: writes factory, marketId, usdc, exchange, conditionalTokens,<br/>conditionId, yesTokenId, noTokenId, tickSpacing, minimumFirstLiquidity
    Vault->>Factory: defaultEmergencyCancelTimelock()
    Note right of Vault: emergencyCancelTimelock = that value (copied once)<br/>implementationVersion = version<br/>phase = 1<br/>lastOperatorActivityTimestamp = block.timestamp<br/>_reentrancyGuard = 1<br/>_cachedChainId = block.chainid, DOMAIN_SEPARATOR computed
    Vault->>USDC: approve(exchange, type(uint256).max)
    Vault->>CTF: setApprovalForAll(exchange, true)
    Factory-->>Oracle: VaultCreated(marketId, vault, minimumFirstLiquidity)
```

The vault stores no roles. Every role check reads the factory at call time (`LPVault.sol:576-586`).

`createVault` rejects a zero or negative `tickSpacing` with `InvalidTickSpacing` before the duplicate check (finding CV-12 of `audits/code-validation-round-1.md`), so `_requireValidRange` (`LPVault.sol:2483-2493`) never divides by zero. The vault itself stores the value without a second check.

## 2. Factory governance

### 2.1 Role management

All on `LPVaultFactory.sol:414-511`. Each vault reads `admins`, `operators`, and `oracle` from the factory on every call, so a change reaches every vault in the same block.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Pending as Pending admin
    participant Factory as LPVaultFactory

    Admin->>Factory: addOperator(op)
    Note right of Factory: onlyAdmin<br/>op == oracle → RoleSeparation<br/>operators[op] = 1<br/>NewOperator(op, admin)

    Admin->>Factory: removeOperator(op)
    Note right of Factory: onlyAdmin<br/>operators[op] = 0 (no check that it was 1)<br/>RemovedOperator(op, admin)

    Admin->>Factory: setOracle(newOracle)
    Note right of Factory: onlyAdmin<br/>operators[newOracle] == 1 → RoleSeparation<br/>oracle = newOracle<br/>no event

    Admin->>Factory: transferAdmin(newAdmin)
    Note right of Factory: onlyAdmin<br/>newAdmin == 0 → ZeroAddress<br/>admins[newAdmin] == 1 → AlreadyAdmin<br/>pendingAdmin = newAdmin<br/>AdminTransferProposed(admin, newAdmin)

    Pending->>Factory: acceptAdmin()
    Note right of Factory: msg.sender != pendingAdmin → NotPendingAdmin<br/>admins[msg.sender] == 1 → AlreadyAdmin<br/>admins[msg.sender] = 1, adminCount += 1, pendingAdmin = 0<br/>NewAdmin(msg.sender, msg.sender)

    Admin->>Factory: addAdmin(a)
    Note right of Factory: onlyAdmin<br/>a == 0 → ZeroAddress<br/>if admins[a] != 1: admins[a] = 1, adminCount++<br/>NewAdmin(a, admin) always

    Admin->>Factory: removeAdmin(a)
    Note right of Factory: onlyAdmin<br/>if admins[a] == 1: adminCount <= 1 → CannotRemoveLastAdmin, else admins[a] = 0, adminCount--<br/>if pendingAdmin == a: pendingAdmin = 0<br/>RemovedAdmin(a, admin) always

    Admin->>Factory: renounceAdminRole()
    Note right of Factory: onlyAdmin<br/>adminCount <= 1 → CannotRemoveLastAdmin<br/>admins[msg.sender] = 0, adminCount--<br/>if pendingAdmin == msg.sender: pendingAdmin = 0<br/>RemovedAdmin(msg.sender, msg.sender)
```

`setOracle` emits no event. `setOracle(address(0))` is accepted.

### 2.2 Implementation upgrade

`LPVaultFactory.sol:356-401`. Only vaults created after `applyImplementation` use the new code. An existing clone keeps the implementation address inside its own bytecode.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: scheduleImplementation(newImpl)
    Note right of Factory: onlyAdmin<br/>newImpl == 0 → ZeroAddress<br/>pendingImplementation != 0 → ScheduleAlreadyPending<br/>pendingImplementation = newImpl<br/>implementationUnlockAt = now + 7 days<br/>ImplementationScheduled(newImpl, unlockAt)

    alt Admin cancels
        Admin->>Factory: cancelScheduledImplementation()
        Note right of Factory: onlyAdmin<br/>pendingImplementation == 0 → NoPendingSchedule<br/>pending state cleared<br/>ImplementationCancelled(cancelled)
    else 7 days pass, Admin applies
        Admin->>Factory: applyImplementation()
        Note right of Factory: onlyAdmin<br/>pendingImplementation == 0 → NoPendingSchedule<br/>now < implementationUnlockAt → TimelockNotElapsed<br/>implementation = newImpl<br/>implementationVersion += 1<br/>pending state cleared<br/>ImplementationApplied(newImpl, version)
    end
```

`scheduleImplementation` does not check that `newImpl` holds code.

### 2.3 Default emergency-cancel timelock

`LPVaultFactory.sol:297-304`. The value reaches only vaults created after the change, because `initialize` copies it once.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Factory as LPVaultFactory

    Admin->>Factory: setDefaultEmergencyCancelTimelock(newTimelock)
    Note right of Factory: onlyAdmin<br/>newTimelock == 0 → ZeroTimelock<br/>newTimelock > 30 days → TimelockTooLong<br/>defaultEmergencyCancelTimelock = newTimelock<br/>DefaultEmergencyCancelTimelockUpdated(old, new)
```

## 3. Signature verification (shared by every relayed LP path)

`LPVault.sol:2510-2519`, with `_recoverSigner` (`2530-2551`) and `_deriveSafe` (`2557-2564`). `depositForIntent`, `reclaimDepositFor`, and `burnPositionFor` all call `_verifySafeOwnerSignature(lp, structHash, signature)`.

```mermaid
sequenceDiagram
    autonumber
    participant Vault as LPVault
    participant Factory as LPVaultFactory

    Note right of Vault: digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)<br/>domainSeparator is the cached one, recomputed if block.chainid changed
    Note right of Vault: _recoverSigner(digest, signature) returns address(0) when:<br/>signature.length != 65<br/>s > secp256k1n / 2<br/>v not in {27, 28}<br/>ecrecover fails
    Note right of Vault: signer == 0 → InvalidSignature
    Vault->>Factory: safeFactory(), safeProxyBytecodeHash()
    Note right of Vault: derived = CREATE2 address(safeFactory, keccak256(abi.encode(signer)), safeProxyBytecodeHash)<br/>derived != lp → InvalidSignature
```

The three type strings (`LPVault.sol:343-357`):

| Type | Fields | Replay record |
|---|---|---|
| `MintIntent` | `lp, tickLower, tickUpper, usdcAmount, intentId, deadline` | `usedIntents[intentId]` and `pendingDeposits[intentId]` |
| `ReclaimIntent` | `lp, intentId, deadline` | `usedIntents[intentId]` |
| `BurnIntent` | `lp, positionId, deadline` | `usedBurnAuthorizations[structHash]` |

The domain is `name = "LPVault"`, `version = "1"`, `chainId`, and the vault's address (`LPVault.sol:2910-2914`).

## 4. Escrow and mint

### 4.1 Escrow a deposit (`depositForIntent`)

`LPVault.sol:998-1041`. Modifiers: `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat`.

```mermaid
sequenceDiagram
    autonumber
    actor OwnerKey as Owner key
    participant Safe as LP Safe
    actor Operator
    participant Vault as LPVault
    participant USDC

    OwnerKey->>Safe: Safe transaction: USDC.approve(vault, amount)
    OwnerKey->>Operator: EIP-712 signature over MintIntent(lp = Safe, tickLower, tickUpper, usdcAmount, intentId, deadline)
    Operator->>Vault: depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, signature)
    Note right of Vault: modifiers: NotOperator, TradingIsPaused, Reentrancy, then lastOperatorActivityTimestamp = now
    Note right of Vault: checks in order:<br/>phase != 1 → VaultNotActive<br/>usdcAmount == 0 → ZeroAmount<br/>now > deadline → IntentExpired<br/>_requireValidRange: lower >= upper → InvalidRange, lower < 0 or upper > 10000 → InvalidRange, misaligned → TickNotAligned<br/>_verifySafeOwnerSignature → InvalidSignature<br/>usedIntents[intentId] → IntentAlreadyUsed<br/>pendingDeposits[intentId].lp != 0 → DepositAlreadyEscrowed
    Note right of Vault: effects:<br/>pendingDeposits[intentId] = (lp, uint96(usdcAmount) or SafeCastOverflow, structHash)<br/>totalEscrowed += usdcAmount
    Vault->>USDC: transferFrom(lp, vault, usdcAmount)
    Note right of Vault: call fails or returns false → TransferFailed
    Vault-->>Operator: DepositEscrowed(intentId, lp, usdcAmount)
```

### 4.2 Mint the position (`mintPositionFor`)

`LPVault.sol:1087-1201`, with `_addTickReference` (`2575-2588`) and `_addNoSubRange` (`2609-2615`). Modifiers: `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat`. No signature, no USDC movement, no clock read. Since R18 the mint has one external call, the merge of the vault's free pairs, which runs after every effect.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Vault as LPVault
    participant CTF as ConditionalTokens

    Operator->>Vault: mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, deadline)
    Note right of Vault: modifiers: NotOperator, TradingIsPaused, Reentrancy, heartbeat
    Note right of Vault: checks in order:<br/>phase != 1 → VaultNotActive<br/>usdcAmount == 0 → ZeroAmount<br/>_requireValidRange → InvalidRange or TickNotAligned<br/>usedIntents[intentId] → IntentAlreadyUsed<br/>escrow.lp == 0 → DepositNotEscrowed<br/>escrow.lp != lp → NotIntentOwner<br/>escrow.structHash != hash(lp, range, usdcAmount, intentId, deadline) → IntentMismatch
    Note right of Vault: reads: both token balances, the switch, the free pairs, the USDC balance (FEAT-E943)
    Note right of Vault: credit: the measured surplus to activeLiquidity as it stands,<br/>before the new position joins it → SpreadCredited
    Note right of Vault: effects:<br/>usedIntents[intentId] = true<br/>delete pendingDeposits[intentId]<br/>totalEscrowed -= escrow.amount
    Note right of Vault: liquidity = uint128(usdcAmount × 1e18 ÷ (tickUpper − tickLower)) or SafeCastOverflow<br/>nextPositionId == 0 and liquidity < minimumFirstLiquidity → BelowMinimumFirstLiquidity
    Note right of Vault: ticks[tickLower]: initialize if liquidityGross == 0 (set the bitmap bit, and if tick <= currentTick set spreadGrowthOutsideX128 = spreadGrowthGlobalX128), liquidityGross += L, liquidityNet += L<br/>ticks[tickUpper]: same initialize, liquidityGross += L, liquidityNet -= L
    Note right of Vault: mintTick = currentTick clamped into [tickLower, tickUpper]
    Note right of Vault: positionId = nextPositionId++<br/>positions[positionId] = (lp, tickLower, tickUpper, mintTick, L, 0)
    Note right of Vault: if tickLower <= currentTick < tickUpper: activeLiquidity += L, noSideLiquidity += L
    Note right of Vault: totalUsdcOwedScaled += L × width × 10000<br/>_addNoSubRange: if mintTick != tickUpper: ticks[mintTick].noLiquidityNet += L, ticks[tickUpper].noLiquidityNet -= L, and if mintTick != tickLower: initialize mintTick and liquidityGross += L
    Note right of Vault: positions[positionId].spreadGrowthInsideLastX128 = growth inside [tickLower, tickUpper)<br/>taken after both bounds hold their outside snapshots, so the new claim is zero
    Vault->>CTF: mergePositions(free pairs), when above zero → CompleteSetsMerged
    Vault-->>Operator: PositionMinted(positionId, lp, tickLower, tickUpper, mintTick, L, usdcAmount, intentId)
```

The mint's claim on the ledger is USDC only, and its spread claim is exactly zero: the credit runs before the position joins the in-range set, so a position minted after a trade never claims that trade's value (FEAT-E943 FR-E94B). An interior mint tick becomes a crossable tick with `liquidityNet == 0` and a non-zero `noLiquidityNet`, and it carries a spread growth snapshot that is written and flipped but never read.

### 4.3 Reclaim an escrow (`reclaimDeposit`, `reclaimDepositFor`)

`LPVault.sol:1677-1767`. `reclaimDeposit` has only `nonReentrant`. `reclaimDepositFor` has `onlyOperator`, `nonReentrant`, `touchesHeartbeat`. Neither checks the phase or the pause. Both run `_refundEscrow`, which merges the vault's free pairs before it pays, because a fill can spend escrowed USDC through the exchange's allowance (finding CV-06 of `audits/code-validation-round-1.md`, ADR-DU2V).

```mermaid
sequenceDiagram
    autonumber
    actor OwnerKey as Owner key
    participant Safe as LP Safe
    actor Operator
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    alt Self-service
        Safe->>Vault: reclaimDeposit(intentId)
        Note right of Vault: usedIntents[intentId] → IntentAlreadyUsed<br/>escrow.lp == 0 → DepositNotEscrowed<br/>escrow.lp != msg.sender → NotIntentOwner
    else Relayed
        OwnerKey->>Operator: signature over ReclaimIntent(lp = Safe, intentId, deadline)
        Operator->>Vault: reclaimDepositFor(lp, intentId, deadline, signature)
        Note right of Vault: now > deadline → IntentExpired<br/>_verifySafeOwnerSignature → InvalidSignature<br/>usedIntents[intentId] → IntentAlreadyUsed<br/>escrow.lp == 0 → DepositNotEscrowed<br/>escrow.lp != lp → NotIntentOwner
    end
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    Note right of Vault: _refundEscrow:<br/>pairs = free pairs from those balances (section 7.1), read before any effect<br/>usedIntents[intentId] = true<br/>delete pendingDeposits[intentId]<br/>totalEscrowed -= escrow.amount
    opt pairs > 0
        Vault->>CTF: mergePositions(usdc, 0, conditionId, [1, 2], pairs)
        Note right of Vault: CompleteSetsMerged(msg.sender, pairs)
    end
    Vault->>USDC: transfer(escrow.lp, escrow.amount)
    Vault-->>Safe: DepositReclaimed(intentId, escrow.lp, escrow.amount)
```

A mint and a reclaim of one `intentId` share `usedIntents`, so exactly one of them succeeds. The refund credits no spread: it reads no USDC balance and pays the recorded amount whatever the merge produced.

## 5. Operator trading work

### 5.1 Move the price (`updateTick`)

`LPVault.sol:1837-1906`, with `_nextInitializedTick` (`2793-2851`), `_recordSegment` (`1929-1959`), `_accrueSegment` (`2672-2702`), `_crossTick` (`2634-2653`), `_applyShift` (`2707-2711`), and `_settleReport` (`1968-1994`). Modifiers: `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat`. Active only.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Vault as LPVault
    participant CTF as ConditionalTokens

    Operator->>Vault: updateTick(newTick)
    Note right of Vault: modifiers: NotOperator, TradingIsPaused, Reentrancy, heartbeat
    Note right of Vault: phase != 1 → VaultNotActive
    alt newTick == currentTick
        Note right of Vault: return: no crossing, no write, no event (the heartbeat is already refreshed)
    else moving up (newTick > currentTick)
        loop each initialized tick t in (currentTick, newTick], at most 256
            Note right of Vault: _nextInitializedTick reads bitmap words only up to the word that holds newTick<br/>crossCount > 256 → TooManyTicksCrossed
            Note right of Vault: _accrueSegment(segmentEdge, t, up): with N = noSideLiquidity, Y = activeLiquidity − N, k = levels<br/>shift.no += N × k, shift.yes −= Y × k, shift.usdc += Y × Σt − N × (k × 10000 − Σt)<br/>skipped when activeLiquidity == 0
            Note right of Vault: _recordSegment(segmentEdge, t, up): the segment's activeLiquidity and model spend, packed for _settleReport
            Note right of Vault: _crossTick(t, up): activeLiquidity += liquidityNet<br/>noSideLiquidity += noLiquidityNet<br/>spreadGrowthOutsideX128 = spreadGrowthGlobalX128 − spreadGrowthOutsideX128 (the flip)
        end
        Note right of Vault: _accrueSegment(lastCrossed, newTick, up): the trailing segment
    else moving down (newTick < currentTick)
        loop each initialized tick t in (newTick, currentTick], at most 256
            Note right of Vault: _accrueSegment(t, segmentEdge, down): the same three deltas, negated
            Note right of Vault: _recordSegment(t, segmentEdge, down): the same record
            Note right of Vault: _crossTick(t, down): activeLiquidity −= liquidityNet, noSideLiquidity −= noLiquidityNet, the same flip
        end
        Note right of Vault: _accrueSegment(newTick, lastCrossed, down): the trailing segment
    end
    Note right of Vault: _applyShift: each non-zero delta written once to totalUsdcOwedScaled, totalYesOwedScaled, totalNoOwedScaled (checked, both directions)<br/>currentTick = newTick
    Note right of Vault: _settleReport: read both token balances, the switch, the free pairs, the USDC balance<br/>creditable = held − principal owed − spread owed, zero while a token balance is short
    Note right of Vault: when creditable > 0 and some segment had liquidity: split creditable by active × model spend per segment<br/>each segment's growth goes to spreadGrowthGlobalX128 and totalSpreadOwedX128 → SpreadCredited per segment
    Note right of Vault: each crossed tick's spreadGrowthOutsideX128 gains the growth credited before it (unchecked, modular)
    Vault->>CTF: mergePositions(free pairs), when above zero → CompleteSetsMerged
    Vault-->>Operator: TickUpdated(oldTick, newTick, crossCount)
```

A move that needs more than 256 crossings, or that jumps many empty bitmap words, is chunked by the Operator into several calls. The totals land on the same values either way, and chunking at every initialized tick also makes the spread credit exact per segment (FEAT-E943 NFR-E94D).

The unchanged-tick path reads no balance and credits nothing, so a round trip that ends where it began is credited by `mergeCompleteSets()` instead (section 7.1, ADR-E94V).

### 5.2 Merge position records (`mergePositions`)

`LPVault.sol:2028-2120`. Modifiers: `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat`. Works in Active and WindDown. This joins LP records. It is not the complete-set merge of section 7.1.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: mergePositions([survivor, consumed1, consumed2, ...])
    Note right of Vault: modifiers: NotOperator, TradingIsPaused, Reentrancy, heartbeat
    Note right of Vault: phase == 3 → VaultCancelled<br/>length < 2 → InsufficientPositions<br/>any repeated id (pairwise over calldata) → DuplicatePositionId
    Note right of Vault: survivor = positions[ids[0]]: owner == 0 → PositionNotFound<br/>owner, tickLower, tickUpper, mintTick read
    Note right of Vault: totalLiquidity = survivor.liquidity<br/>inside = growth inside [tickLower, tickUpper)<br/>spreadSum = survivor.liquidity × (inside − survivor.spreadGrowthInsideLastX128)
    loop each consumed id
        Note right of Vault: owner == 0 → PositionNotFound<br/>owner, tickLower, or tickUpper differ → RangeMismatch<br/>mintTick differs → MintTickMismatch
        Note right of Vault: spreadSum += consumed.liquidity × (inside − consumed.spreadGrowthInsideLastX128)<br/>totalLiquidity += consumed.liquidity<br/>consumed.liquidity = 0, consumed.spreadGrowthInsideLastX128 = 0 (owner stays)
    end
    Note right of Vault: if totalLiquidity > 0: survivor.spreadGrowthInsideLastX128 = inside − floor(spreadSum ÷ totalLiquidity)<br/>totalSpreadOwedX128 −= the dust the floor dropped (checked)
    Note right of Vault: survivor.liquidity = totalLiquidity<br/>ticks untouched, principal totals untouched
    Vault-->>Operator: PositionsMerged(ids, ids[0])
```

A consumed record keeps its owner with zero liquidity. `burnPosition` rejects it with `PositionNotFound` (`LPVault.sol:1249`).

Every id must name a record with a live owner: the survivor and each consumed record revert `PositionNotFound` when `owner == address(0)` (finding CV-03 of `audits/code-validation-round-1.md`, FR-DU2X), so a burned or never-minted id never merges. A set of records a previous merge already consumed still merges: they hold no liquidity and no spread claim, so the survivor's snapshot is left as it is.

### 5.3 Signal liveness (`heartbeat`)

`LPVault.sol:1790-1794`. Modifiers: `onlyOperator`, `touchesHeartbeat`. No pause check.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Vault as LPVault

    Operator->>Vault: heartbeat()
    Note right of Vault: NotOperator, then lastOperatorActivityTimestamp = now<br/>phase == 3 → VaultCancelled (rolls the write back)
```

Every Operator function carries `touchesHeartbeat`, so any successful Operator call refreshes the timer. The self-service exits and `mergeCompleteSets` never do.

## 6. LP exits

### 6.1 Burn a position (`burnPosition`, `burnPositionFor`)

`LPVault.sol:1243-1319` (the two entry points), `_burn` (`1350-1439`), `_sweepResidue` (`1453-1482`), `_burnAmounts` (`1498-1533`), `_claim` (`1554-1598`), and `_holdings` (`2367-2384`). `burnPosition` has only `nonReentrant`. `burnPositionFor` has `onlyOperator`, `nonReentrant`, `touchesHeartbeat`. Neither checks the phase or the pause.

```mermaid
sequenceDiagram
    autonumber
    actor OwnerKey as Owner key
    participant Safe as LP Safe
    actor Operator
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    alt Self-service
        Safe->>Vault: burnPosition(positionId)
        Note right of Vault: owner == 0 or liquidity == 0 → PositionNotFound<br/>owner != msg.sender → NotPositionOwner
    else Relayed
        OwnerKey->>Operator: signature over BurnIntent(lp = Safe, positionId, deadline)
        Operator->>Vault: burnPositionFor(lp, positionId, deadline, signature)
        Note right of Vault: now > deadline → IntentExpired<br/>_verifySafeOwnerSignature → InvalidSignature<br/>usedBurnAuthorizations[structHash] → IntentAlreadyUsed<br/>owner == 0 or liquidity == 0 → PositionNotFound<br/>owner != lp → NotPositionOwner<br/>usedBurnAuthorizations[structHash] = true
    end
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    Vault->>USDC: balanceOf(vault)
    Note right of Vault: _holdings: the free pairs, the switch, held, total, and the creditable surplus<br/>creditable is zero while a token balance is below its owed total (FEAT-E943)
    Note right of Vault: the one effect before the valuation: credit the surplus to activeLiquidity,<br/>which still counts this position → SpreadCredited, then re-read total
    Note right of Vault: _burnAmounts, from the values already read:<br/>_claim(range, mintTick, L) at currentTick → usdcScaled, tokenId, tokenScaled<br/>usdcOwed = usdcScaled ÷ (10000 × 1e18), tokenOwed = tokenScaled ÷ 1e18<br/>spreadScaled = L × (spreadGrowthInside − the position's snapshot), spreadOwed = spreadScaled ÷ 2^128
    alt switch off (stored payout is zero)
        Note right of Vault: held = max(0, balance + pairs − totalEscrowed), total = totalUsdcOwed + totalSpreadOwed<br/>usdcPaid = usdcOwed × min(1, held ÷ total)<br/>spreadPaid = (usdcOwed + spreadOwed) × min(1, held ÷ total) − usdcPaid<br/>tokenPaid = tokenOwed × min(1, (tokenBalance − pairs) ÷ tokenTotalOwed)
    else switch on
        Note right of Vault: tokenUsdc = tokenOwed × numerator ÷ (numYes + numNo)<br/>held = max(0, balance + atPayout(YES, NO) − totalEscrowed)<br/>total = totalUsdcOwed + totalSpreadOwed + atPayout(totalYesOwed, totalNoOwed)<br/>usdcPaid and spreadPaid as above<br/>tokenPaid = (usdcOwed + spreadOwed + tokenUsdc) × min(1, held ÷ total) − usdcPaid − spreadPaid
    end
    Note right of Vault: effects:<br/>_removeNoSubRange (noLiquidityNet at mintTick and tickUpper, drop the interior reference)<br/>ticks[tickLower].liquidityNet −= L, ticks[tickUpper].liquidityNet += L, liquidityGross −= L on both<br/>a tick at liquidityGross == 0 is deleted, its bitmap bit cleared, and its growth snapshot deleted with it<br/>if in range: activeLiquidity −= L, and if mintTick <= currentTick: noSideLiquidity −= L<br/>ledger: totalUsdcOwedScaled −= usdcScaled, totalSpreadOwedX128 −= spreadScaled, the band's token total −= tokenScaled, all saturating<br/>lastPosition = totalUsdcOwedScaled == 0 after the debit<br/>delete positions[positionId], the spread snapshot with it
    alt switch off
        opt pairs > 0
            Vault->>CTF: mergePositions(usdc, 0, conditionId, [1, 2], pairs)
            Note right of Vault: CompleteSetsMerged(msg.sender, pairs)
        end
        opt usdcPaid + spreadPaid > 0
            Vault->>USDC: transfer(owner, usdcPaid + spreadPaid)
        end
        opt tokenPaid > 0
            Vault->>CTF: safeTransferFrom(vault, owner, tokenId, tokenPaid, "") — the last call
        end
    else switch on
        opt YES or NO balance > 0
            Vault->>CTF: redeemPositions(usdc, 0, conditionId, [1, 2])
            Note right of Vault: OutcomeTokensRedeemed(msg.sender, YES, NO, atPayout(YES, NO))
        end
        opt usdcPaid + spreadPaid + tokenPaid > 0
            Vault->>USDC: transfer(owner, usdcPaid + spreadPaid + tokenPaid) — the last call
        end
    end
    opt lastPosition
        Note right of Vault: the closing sweep replaces both transfer blocks above:<br/>pay every USDC above totalEscrowed, and before the switch every remaining YES and NO<br/>ResidueSwept(positionId, owner, the amounts beyond this position's own claim)
    end
    Vault-->>Safe: PositionBurned(positionId, owner, usdcOwed, usdcPaid, spreadOwed, spreadPaid, tokenId, tokenOwed, tokenPaid)
```

The claim (`_claim`), with `m` the mint tick, `c` the current tick, `L` the liquidity, and `width = tickUpper − tickLower`:

| Case | Token | Band | Tokens (scaled) | USDC (scaled) |
|---|---|---|---|---|
| `c < m` | YES | `[max(c, tickLower), m)` | `L × band` | `L × (width × 10000 − Σ ticks of the band)` |
| `c > m` | NO | `[m, min(c, tickUpper))` | `L × band` | `L × ((width − band) × 10000 + Σ ticks of the band)` |
| `c == m`, or the band is empty | none (`tokenId = 0`) | — | 0 | `L × width × 10000` |

`Σ ticks of the band` is the arithmetic series `band × (first + last) ÷ 2` over the band's tick indices, exact because `band × (a + m − 1)` is always even.

A burn is valued at the last reported tick (decision C8). A fill the keeper has not reported yet has already spent the vault's USDC. The ledger's ratio spreads that spend over every claim in proportion to its USDC owed, and a burn inside that window takes its share as a final cut, and credits nothing, because the unreported spend puts the vault below what the ledger owes. The tokens the fill bought belong to no claim after the report. Since R18 they reach the positions that stayed: through the spread credit once the switch values them, or through the closing sweep on the last live position's burn (FEAT-E943 FR-E94C). Before a self-service burn, compare `totalYesOwed()` and `totalNoOwed()` with the vault's two token balances: a balance above the owed total and above the free pairs can be an unreported fill. The Operator reports the tick before it relays `burnPositionFor`, which closes this window on the relayed path (finding CV-08 of `audits/code-validation-round-1.md`, and ADR-DYNK in FEAT-7G40).

### 6.2 Exit after a freeze

After `emergencyCancelAll` the burn and the reclaim run unchanged at the frozen `currentTick`. No code path differs from sections 4.3 and 6.1. Each LP exits in their own transaction.

## 7. Outcome tokens

### 7.1 Merge free pairs (`mergeCompleteSets`)

`LPVault.sol:2152-2161`, with `_holdings` (`2367-2384`), `_freePairs` (`2173-2180`), `_creditSpread` (`2394-2406`), and `_mergeCompleteSets` (`2211-2216`). Modifier: `nonReentrant` only. No role, phase, pause, or heartbeat.

```mermaid
sequenceDiagram
    autonumber
    actor Anyone
    participant Vault as LPVault
    participant CTF as ConditionalTokens
    participant USDC

    Anyone->>Vault: mergeCompleteSets()
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    Vault->>USDC: balanceOf(vault)
    Note right of Vault: switch on → pairs = 0 (no pair is counted after the switch)<br/>either balance == 0 → pairs = 0<br/>else pairs = min(YES − min(YES, totalYesOwed), NO − min(NO, totalNoOwed))
    Note right of Vault: creditable = held − principal owed − spread owed, counting the pairs as USDC before the switch<br/>and the token balances at the stored payout after it<br/>zero before the switch while a token balance is below its owed total
    opt creditable > 0 and activeLiquidity > 0
        Note right of Vault: credit the surplus to the liquidity in range<br/>Vault-->>Anyone: SpreadCredited(amount, spreadGrowthGlobalX128)
    end
    alt pairs == 0
        Note right of Vault: return with no merge call and no CompleteSetsMerged event
    else pairs > 0
        Vault->>CTF: mergePositions(usdc, 0, conditionId, [1, 2], pairs)
        Note right of Vault: the CTF pays the vault pairs USDC
        Vault-->>Anyone: CompleteSetsMerged(msg.sender, pairs)
    end
```

A pair below the owed totals is a claim's band token. It never merges, so one claim's YES is never netted against another claim's NO. After the switch the call counts no pair and merges nothing, because `_holdings` computes the free pairs only while the switch is off (ADR-DFE2). It still credits: the token balances enter the measurement at the stored payout. The tokens themselves leave through the redemption inside the next burn or the Oracle's next `redeemOutcomeTokens`.

Since R18 the call also credits the measured spread before it merges (FEAT-E943 FR-6HBZ). This is where a round trip that ends where it began is attributed, because the unchanged-tick report reads no balance (section 5.1, ADR-E94V). The caller still receives nothing. The one residual the MEV analysis records: a caller who is an LP in range can time the call ahead of a report or a mint, bounded by the surplus pending at that moment.

### 7.2 Fill a vault order (`isValidSignature` and the receiver hooks)

`LPVault.sol:847-867` and `752-781`. The vault is the maker of its own orders. The keeper signs with the Operator key and names the vault as `maker` and `signer` with `signatureType = POLY_1271`.

```mermaid
sequenceDiagram
    autonumber
    actor Keeper as Keeper (Operator key)
    participant Exchange as ProphetCTFExchange
    participant Vault as LPVault
    participant Factory as LPVaultFactory
    participant USDC
    participant CTF as ConditionalTokens

    Keeper->>Exchange: matchOrders with a vault order
    Exchange->>Vault: isValidSignature(hashOrder(order), signature)
    Note right of Vault: msg.sender != exchange → 0xffffffff<br/>phase != 1 or paused → 0xffffffff<br/>_recoverSigner == 0 → 0xffffffff
    Vault->>Factory: operators(signer)
    Note right of Vault: != 1 → 0xffffffff, else 0x1626ba7e<br/>never reverts, records nothing
    Vault-->>Exchange: 0x1626ba7e
    Exchange->>USDC: transferFrom(vault, ..., amount) under the approval from initialize
    Exchange->>CTF: safeTransferFrom(..., vault, tokenId, amount)
    CTF->>Vault: onERC1155Received(operator, from, id, value, data)
    Note right of Vault: msg.sender != conditionalTokens → NotConditionalTokens<br/>id not in {yesTokenId, noTokenId} → UnknownTokenId<br/>returns 0xf23a6e61, writes nothing
```

`onERC1155BatchReceived` checks every id the same way and returns `0xbc197c81`. `supportsInterface` returns true for `0x4e2312e0` (ERC-1155 receiver), `0x01ffc9a7` (ERC-165), and `0x1626ba7e` (ERC-1271).

The vault checks who signed, never what was signed. There is no size cap, price band, side restriction, nonce, or order record in the vault. One `removeOperator` on the factory invalidates every unfilled order that key signed.

### 7.3 Redeem after resolution (`redeemOutcomeTokens`)

`LPVault.sol:2256-2279`, with `_redeemOutcomeTokens` (`2293-2298`) and `_atPayout` (`2311-2316`). Modifiers: `onlyOracle`, `nonReentrant`. No heartbeat, no pause check, no phase change.

```mermaid
sequenceDiagram
    autonumber
    actor Oracle
    participant Vault as LPVault
    participant CTF as ConditionalTokens

    Oracle->>Vault: redeemOutcomeTokens()
    Note right of Vault: NotOracle, Reentrancy<br/>phase == 1 → VaultStillActive
    Vault->>CTF: payoutDenominator(conditionId)
    Note right of Vault: == 0 → MarketNotResolved
    opt stored payout is (0, 0)
        Vault->>CTF: payoutNumerators(conditionId, 0), payoutNumerators(conditionId, 1)
        Note right of Vault: payoutNumeratorYes, payoutNumeratorNo = uint128(each) or SafeCastOverflow<br/>this is the switch, written once
    end
    Vault->>CTF: balanceOf(vault, YES), balanceOf(vault, NO)
    opt either balance > 0
        Vault->>CTF: redeemPositions(usdc, 0, conditionId, [1, 2])
        Note right of Vault: the CTF pays the vault YES × numYes ÷ den + NO × numNo ÷ den
        Vault-->>Oracle: OutcomeTokensRedeemed(oracle, YES, NO, atPayout(YES, NO))
    end
```

The Oracle can delay the switch. It cannot set the payout: the vault reads it from the Conditional Tokens contract inside the call. A market whose two numerators are both zero cannot resolve at the Conditional Tokens contract, so the stored pair is non-zero whenever the switch is on.

## 8. Lifecycle and emergency

### 8.1 Wind down (`startWindDown`)

`LPVault.sol:902-906`. Modifier: `onlyOracle`. No reentrancy guard, because there is no external call.

```mermaid
sequenceDiagram
    autonumber
    actor Oracle
    participant Vault as LPVault

    Oracle->>Vault: startWindDown()
    Note right of Vault: NotOracle<br/>phase != 1 → VaultNotActive<br/>phase = 2
    Vault-->>Oracle: VaultWindDownStarted(marketId)
```

After it, `depositForIntent`, `mintPositionFor`, and `updateTick` revert `VaultNotActive`. `mergePositions` and `heartbeat` still work. Every exit still works. `isValidSignature` refuses, so a resting vault order fails at match time.

### 8.2 Freeze after Operator silence (`emergencyCancelAll`)

`LPVault.sol:949-963`. No modifier at all.

```mermaid
sequenceDiagram
    autonumber
    actor Anyone
    participant Vault as LPVault

    Anyone->>Vault: emergencyCancelAll()
    Note right of Vault: phase == 3 → VaultCancelled<br/>now − lastOperatorActivityTimestamp < emergencyCancelTimelock → TimelockNotElapsed<br/>phase = 3 and nothing else
    Vault-->>Anyone: EmergencyCancelExecuted(msg.sender)
```

The freeze keeps every position, tick, escrow, balance, and ledger total. `mergePositions` and `heartbeat` revert `VaultCancelled` from then on. The three Active-only functions revert `VaultNotActive`. The phase is terminal.

### 8.3 Pause and unpause (`pauseTrading`, `unpauseTrading`)

`LPVault.sol:916-926`. Modifier: `onlyAdmin`. Neither checks the current value, so a repeated call succeeds and emits again.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Operator
    participant Safe as LP Safe
    participant Vault as LPVault

    Admin->>Vault: pauseTrading()
    Note right of Vault: NotAdmin<br/>paused = true<br/>TradingPaused(admin)
    Operator--xVault: depositForIntent, mintPositionFor, updateTick, mergePositions → TradingIsPaused
    Operator->>Vault: heartbeat, reclaimDepositFor, burnPositionFor still work
    Safe->>Vault: burnPosition, reclaimDeposit, mergeCompleteSets still work
    Admin->>Vault: unpauseTrading()
    Note right of Vault: NotAdmin<br/>paused = false<br/>TradingUnpaused(admin)
```

### 8.4 Set the first-mint floor (`setMinimumFirstLiquidity`)

`LPVault.sol:881-888`. Modifier: `onlyOracle`.

```mermaid
sequenceDiagram
    autonumber
    actor Oracle
    participant Vault as LPVault

    Oracle->>Vault: setMinimumFirstLiquidity(newMin)
    Note right of Vault: NotOracle<br/>newMin == 0 → ZeroFloor<br/>minimumFirstLiquidity = newMin
    Vault-->>Oracle: MinimumFirstLiquidityUpdated(oldMin, newMin)
```

The floor applies only while `nextPositionId == 0`. After the first mint the setter still succeeds and changes a value no mint reads.

## 9. Full lifecycle example

One market from deployment to the last exit, with every call in the order the code allows it.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    actor Oracle
    actor Operator
    participant Safe as LP Safe
    participant Factory as LPVaultFactory
    participant Vault as LPVault
    participant CTF as ConditionalTokens

    Admin->>Factory: deploy
    Oracle->>Factory: createVault(...)
    Factory->>Vault: clone + initialize (phase = 1, approvals to the exchange)
    Operator->>Vault: depositForIntent(...) with the owner key's MintIntent
    Vault->>Safe: transferFrom USDC
    Operator->>Vault: mintPositionFor(...) → positionId 0, mintTick = clamped currentTick
    Operator->>Vault: updateTick(newTick) as the CLOB moves, ledger shifts per segment
    Oracle->>Vault: startWindDown() → phase = 2
    Oracle->>Vault: redeemOutcomeTokens() → the switch, every token redeemed
    Safe->>Vault: burnPosition(0) → one USDC transfer for principal + the token leg at the payout
```

If the Operator goes silent for the vault's timelock at any point after creation, anyone calls `emergencyCancelAll` and the same exits run at the frozen tick.

## 10. Who can call what

| Function | Caller | Modifiers in order | Phase gate |
|---|---|---|---|
| `createVault` | Oracle | `onlyOracle` | — |
| `setDefaultEmergencyCancelTimelock` | Admin | `onlyAdmin` | — |
| `addOperator`, `removeOperator`, `setOracle`, `transferAdmin`, `addAdmin`, `removeAdmin`, `renounceAdminRole` | Admin | `onlyAdmin` | — |
| `acceptAdmin` | the pending admin | none (inline check) | — |
| `scheduleImplementation`, `applyImplementation`, `cancelScheduledImplementation` | Admin | `onlyAdmin` | — |
| `initialize` | the factory | `initializer`, then inline `msg.sender == factory_` | — |
| `setMinimumFirstLiquidity` | Oracle | `onlyOracle` | none |
| `startWindDown` | Oracle | `onlyOracle` | Active |
| `redeemOutcomeTokens` | Oracle | `onlyOracle`, `nonReentrant` | WindDown or Cancelled |
| `pauseTrading`, `unpauseTrading` | Admin | `onlyAdmin` | none |
| `depositForIntent` | Operator | `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat` | Active |
| `mintPositionFor` | Operator | `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat` | Active |
| `updateTick` | Operator | `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat` | Active |
| `mergePositions` | Operator | `onlyOperator`, `whenNotPaused`, `nonReentrant`, `touchesHeartbeat` | not Cancelled |
| `heartbeat` | Operator | `onlyOperator`, `touchesHeartbeat` | not Cancelled |
| `reclaimDepositFor`, `burnPositionFor` | Operator | `onlyOperator`, `nonReentrant`, `touchesHeartbeat` | none |
| `reclaimDeposit`, `burnPosition` | the recorded Safe | `nonReentrant` | none |
| `mergeCompleteSets` | anyone | `nonReentrant` | none |
| `emergencyCancelAll` | anyone | none | not Cancelled, after the timelock |
| `isValidSignature` | the exchange (a view) | none (inline checks, never reverts) | Active and not paused |
| `onERC1155Received`, `onERC1155BatchReceived` | the Conditional Tokens contract (views) | `onlyConditionalTokens` | none |
| `supportsInterface`, `payoutNumerators`, `totalUsdcOwed`, `totalYesOwed`, `totalNoOwed`, `totalSpreadOwed`, `operators`, `oracle`, `admins` | anyone (views) | none | none |
