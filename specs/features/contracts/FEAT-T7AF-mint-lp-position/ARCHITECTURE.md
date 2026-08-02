---
id: FEAT-T7AF
name: Mint LP Position
use_cases: [UC-T7AG]
scenarios: [SC-T7AH, SC-T7AI, SC-T7AJ, SC-T7AK, SC-T7AL, SC-T7AM, SC-T7AN, SC-T7AO, SC-T7AP, SC-T7AQ, SC-T7AR, SC-3Z9J, SC-3Z9K, SC-45IE, SC-3XU5, SC-3XU6]
last_update: 2026-08-01
---

# Architecture: Mint LP Position

## System Context (C4 L1)

> Who uses this feature and what external systems does it touch?

```mermaid
C4Context
    title Mint LP Position -- System Context
    Person(operator, "Operator", "Executes LP mint intents on-chain")
    Person(lp, "LP", "Signs EIP-712 mint intent off-chain")
    System(vault, "LPVault (clone)", "Per-market vault with v3-style positions and tick state")
    System(escrow, "Escrow Deposit (FEAT-3ZRI)", "Holds the intent's USDC before mint")
    Rel(lp, operator, "signs MintIntent", "EIP-712 off-chain")
    Rel(operator, escrow, "depositForIntent()", "funds the intent first")
    Rel(operator, vault, "mintPositionFor()", "contract call")
    Rel(vault, escrow, "consumes pendingDeposits[intentId]", "storage")
```

## Container View (C4 L2)

> Which major components are involved and how do they communicate?

```mermaid
C4Container
    title Mint LP Position -- Container View
    Person(operator, "Operator")
    Person(lp, "LP")
    Container(vault, "LPVault (clone)", "Solidity", "Position minting, tick mgmt, EIP-712 verification")
    Container(auth, "Auth (inlined)", "Solidity mixin", "onlyOperator gate")
    Container(eip712, "EIP-712 (inlined)", "Solidity", "Domain separator, signature recovery, malleability check")
    ContainerDb(positions, "positions mapping", "Storage", "positionId -> Position struct")
    ContainerDb(ticks_db, "ticks mapping", "Storage", "int24 -> TickInfo struct")
    ContainerDb(intents, "usedIntents mapping", "Storage", "bytes32 -> bool")
    ContainerDb(escrow_db, "pendingDeposits mapping", "Storage", "bytes32 -> PendingDeposit{lp, amount} (FEAT-3ZRI)")
    Rel(operator, vault, "mintPositionFor()", "tx")
    Rel(lp, operator, "signs MintIntent", "EIP-712 off-chain")
    Rel(vault, auth, "onlyOperator check")
    Rel(vault, eip712, "verify LP signature")
    Rel(vault, escrow_db, "reads then deletes", "storage")
    Rel(vault, positions, "writes", "storage")
    Rel(vault, ticks_db, "reads/writes", "storage")
    Rel(vault, intents, "writes", "storage")
```

## Data Model

> Entity schemas with field constraints and invariants.

```mermaid
erDiagram
    LPVAULT {
        uint128 activeLiquidity "sum of in-range position liquidity"
        uint256 feeGrowthGlobalX128 "Q128 cumulative fees per unit active L"
        int24 currentTick "last-known market mid-price tick"
        uint256 nextPositionId "auto-increment counter"
        int24 tickSpacing "storage, would be immutable in non-clone"
        uint128 minimumFirstLiquidity "floor for first mint (FEAT-REPZ)"
        uint8 phase "1=Active, 2=WindDown"
        bytes32 DOMAIN_SEPARATOR "cached EIP-712 domain separator"
        uint256 CACHED_CHAIN_ID "chainId at initialize time"
    }
    LPVAULT ||--o{ POSITION : "holds"
    LPVAULT ||--o{ TICK_INFO : "tracks"
    LPVAULT ||--o{ USED_INTENTS : "records"
    POSITION {
        uint256 id PK "auto-increment from nextPositionId"
        address owner "LP address (from signed intent)"
        int24 tickLower "must align to tickSpacing"
        int24 tickUpper "must align to tickSpacing, > tickLower"
        uint128 liquidity "usdcAmount * PRECISION / (tickUpper - tickLower)"
        uint256 feeGrowthInsideLastX128 "snapshot at mint time (Q128)"
        uint256 tokensOwed "0 at mint; accumulates on collect"
    }
    TICK_INFO {
        int24 tick PK "tick index"
        uint128 liquidityGross "total L referencing this tick"
        int128 liquidityNet "L added crossing up, subtracted crossing down"
        uint256 feeGrowthOutsideX128 "fees on the other side of this tick (Q128)"
    }
    USED_INTENTS {
        bytes32 intentId PK "unique per mint intent"
        bool used "always true once recorded"
    }
    MINT_INTENT {
        address lp "LP wallet address"
        int24 tickLower "lower bound of range"
        int24 tickUpper "upper bound of range"
        uint256 usdcAmount "USDC to deposit"
        bytes32 intentId "unique identifier for replay protection"
    }
```

**Invariants:**
- `tickLower < tickUpper` for every position
- `tickLower % tickSpacing == 0` and `tickUpper % tickSpacing == 0`
- `position.feeGrowthInsideLastX128` is set to feeGrowthInside at mint time -- no retroactive claims
- `ticks[t].liquidityGross == sum of |liquidity| of all positions referencing tick t`
- `activeLiquidity == sum of position.liquidity for all positions where tickLower <= currentTick < tickUpper`
- `usedIntents[intentId] == true` after a successful mint -- never reset to false
- A mint only proceeds when `pendingDeposits[intentId].amount == usdcAmount` exactly AND `pendingDeposits[intentId].lp == lp`, and deletes the entry -- position principal is always backed by USDC the vault already collected *from that same LP*
- The owner check is not redundant with signature verification: any party can produce a valid signature over any intentId (FEAT-3ZRI ADR-45IC), so the escrow's recorded depositor is the only thing that stops one LP's deposit funding another LP's position
- `mintPositionFor` makes no external token call: every dollar of position principal entered the vault earlier, via FEAT-3ZRI
- When `activeLiquidity == 0`, the next mint must produce `liquidity >= minimumFirstLiquidity` (FEAT-REPZ invariant)
- Newly initialized tick: `feeGrowthOutsideX128 = (tick <= currentTick) ? feeGrowthGlobalX128 : 0`

## Component Inventory

> Files that participate in this feature.

| File | Role | Key Exports |
|------|------|-------------|
| `src/LPVault.sol` | Per-market vault -- position minting, tick initialization, EIP-712 verification, fee growth computation | `mintPositionFor()`, `_mintPosition()`, `_initializeTick()`, `_computeFeeGrowthInside()`, `_verifyMintIntent()`, reads/deletes `pendingDeposits` |
| `test/features/FEAT-T7AF-mint-lp-position/UC-T7AG-operator-mint-position-for-lp.t.sol` | Integration tests for all 15 scenarios | SC-T7AH through SC-T7AR, SC-3Z9J, SC-3Z9K, SC-3XU5, SC-3XU6 |

## Event Topology

> All events this feature emits or consumes.

| Event | Publisher | Payload | Condition | Consumers |
|-------|-----------|---------|-----------|-----------|
| `PositionMinted(uint256 indexed positionId, address indexed owner, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 usdcAmount, bytes32 intentId)` | LPVault | `positionId, owner, tickLower, tickUpper, liquidity, usdcAmount, intentId` | On successful `mintPositionFor()` | Off-chain Event Listener, Keeper |

**Non-events (explicit):**
- Failed mints (any revert scenario): no events emitted, no state changes
- Tick initialization: no separate event (occurs as part of mint flow)

## API Surface

> Contract functions (entry points) belonging to this feature.

| Method | Path | Handler | Auth | Request Shape | Response Shape | Error Codes |
|--------|------|---------|------|---------------|----------------|-------------|
| call | `LPVault.mintPositionFor(address,int24,int24,uint256,bytes32,bytes)` | `mintPositionFor` | onlyOperator + whenNotPaused + nonReentrant + touchesHeartbeat | `lp, tickLower, tickUpper, usdcAmount, intentId, signature` | `uint256 positionId` | NotOperator, InvalidRange, TickNotAligned, VaultNotActive, ZeroAmount, IntentAlreadyUsed, InvalidSignature, BelowMinimumFirstLiquidity, DepositNotEscrowed, NotIntentOwner |

## Integration Points

> External services, event streams, and infrastructure dependencies.

| System | Protocol | Direction | Purpose |
|--------|----------|-----------|---------|
| FEAT-3ZRI escrow (`pendingDeposits`) | internal storage read + delete | inbound | Supplies the position's principal; mint consumes the entry rather than moving tokens |

## Code Map

> Links spec IDs to implementation files.

| Spec ID | Spec Name | Implementation Files |
|---------|-----------|---------------------|
| UC-T7AG | Operator Mint Position for LP | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_mintPosition()` |
| SC-T7AH | Successful in-range mint with fresh ticks | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_initializeTick()`, `src/LPVault.sol:_computeFeeGrowthInside()` |
| SC-3XU5 | Successful mint refreshes silence timer | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:touchesHeartbeat` |
| SC-3XU6 | Reverted mint leaves silence timer untouched | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:touchesHeartbeat` |
| SC-T7AI | Successful out-of-range mint | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_initializeTick()` |
| SC-T7AJ | Second position on existing tick | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_initializeTick()` |
| SC-T7AK | Inverted range revert | `src/LPVault.sol:mintPositionFor()` |
| SC-T7AL | Misaligned tick revert | `src/LPVault.sol:mintPositionFor()` |
| SC-T7AM | Non-active vault revert | `src/LPVault.sol:mintPositionFor()` |
| SC-T7AN | Non-operator caller revert | `src/LPVault.sol:mintPositionFor()` |
| SC-T7AO | First mint below minimum liquidity | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_mintPosition()` |
| SC-T7AP | Duplicate intentId revert | `src/LPVault.sol:mintPositionFor()` |
| SC-T7AQ | Invalid signature revert | `src/LPVault.sol:mintPositionFor()`, `src/LPVault.sol:_verifyMintIntent()` |
| SC-T7AR | Zero amount revert | `src/LPVault.sol:mintPositionFor()` |
| SC-3Z9J | Revert when no deposit is escrowed | `src/LPVault.sol:mintPositionFor()` (pendingDeposits check) |
| SC-3Z9K | Revert when escrowed amount does not match | `src/LPVault.sol:mintPositionFor()` (pendingDeposits check) |
| SC-45IE | Revert when the escrow belongs to a different LP | `src/LPVault.sol:mintPositionFor()` (escrow owner check) |

## Architecture Decisions

**ADR-T7CD:** Linear tick scheme for prediction market price space
In the context of representing LP price ranges on a prediction market with bounded [0, 1] price space, facing the design choice between Uniswap v3's log-spaced ticks (based on sqrt(1.0001)^i) and linear ticks, we decided to use linear ticks matching the CLOB's price granularity to achieve simpler arithmetic and direct mapping between tick indices and probability values, accepting that this departs from v3's constant-product AMM math (which we don't use -- the CLOB handles matching, not an AMM curve).

**ADR-T7CE:** Liquidity formula: L = usdcAmount * PRECISION / rangeWidth
In the context of computing position liquidity from a USDC deposit, facing the choice between v3's sqrt-price-based formula and a linear USDC-per-tick model, we decided to use `liquidity = usdcAmount * PRECISION / (tickUpper - tickLower)` to achieve a direct, auditable relationship between USDC deposited and liquidity weight, accepting that this is simpler than v3's model because the CLOB handles trade execution -- the vault only needs liquidity for fee-accounting weight, not for swap output computation. See `research/lp-provisioning-engine.md` section "Mapping L (liquidity) to USDC capital" for the derivation.

**ADR-T7CF:** EIP-712 signed intent for operator-gated minting
In the context of LP onboarding under the operator-executes-all model (ADR-RFS9 from FEAT-REPZ), facing the need for the LP to authorize specific mint parameters without directly calling the vault, we decided to use EIP-712 typed structured data (MintIntent struct) signed by the LP and submitted by the Operator, with intentId-based replay protection, to achieve cryptographic authorization verifiable on-chain while keeping the execution path operator-gated, accepting that the LP must pre-approve the vault for USDC (ERC-20 approve) and trust the Operator to submit their intent in a timely manner -- a trust assumption bounded by the reclaimDeposit escape hatch in FEAT-JAIJ.

**ADR-3ZVL:** Mint consumes escrow instead of pulling tokens
In the context of how a mint is funded, facing the original design in which `mintPositionFor` called `transferFrom` on every invocation while `reclaimDeposit` paid out assuming the USDC had been pre-sent, we decided to remove the transfer from mint entirely and require an exact-match escrow entry (`pendingDeposits[intentId] == usdcAmount`, FEAT-3ZRI) that mint deletes as it creates the position, to achieve a single unambiguous funding path shared by mint and reclaim, accepting one extra Operator transaction per LP onboarding. The two symptoms this closes are opposite faces of the same contradiction: a cooperative LP who pre-sent USDC was charged a second time and their first deposit was orphaned with no way to recover it, while an attacker who never deposited and never approved could wait out the 24h timelock and have `reclaimDeposit` pay them out of other LPs' funds. Exact equality is required rather than `>=`, so a mint can neither exceed its collateral nor strand a remainder.

## Testing Decisions

| Service/Pattern | Decision | Reason |
|-----------------|----------|--------|
| USDC (ERC-20) | e2e with mock token | Deploy a minimal ERC-20 mock in test setup; test transferFrom behavior including insufficient balance and missing approval |
| EIP-712 signatures | e2e | Foundry's `vm.sign()` cheatcode generates real ECDSA signatures for test accounts |
| Tick state | e2e | Pure storage -- no external dependency |
