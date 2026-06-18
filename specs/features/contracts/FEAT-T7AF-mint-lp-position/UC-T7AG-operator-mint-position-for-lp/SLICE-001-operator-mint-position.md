---
id: UC-T7AG-001
name: operator-mint-position
use_case: UC-T7AG
feature: FEAT-T7AF
objective: implement
status: pending
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: [UC-REQ1-001]
provides: [mintPositionFor, positions, ticks, TickInfo, Position, usedIntents, MINT_INTENT_TYPEHASH]
entry_type: contract-call
covers: [SC-T7AH, SC-T7AI, SC-T7AJ, SC-T7AK, SC-T7AL, SC-T7AM, SC-T7AN, SC-T7AO, SC-T7AP, SC-T7AQ, SC-T7AR, FR-T7AS, FR-T7AT, FR-T7AU, FR-T7AV, FR-T7AW, FR-T7AX, FR-T7AY, FR-T7AZ, FR-T7B0, FR-T7B1, FR-T7B2, FR-T7B3, FR-T7B4, FR-T7B5]
last_update: 2026-06-17
---

# UC-T7AG-001: Operator Mint Position

## Rationale

Adds operator-gated LP position minting to LPVault. Implements `mintPositionFor` (external, onlyOperator + nonReentrant) backed by internal helpers for EIP-712 signature verification, tick initialization, feeGrowthInside computation, and the core position-record creation. All 11 scenarios share `src/LPVault.sol` as their single target file, so they form one slice per the file-ownership constraint. The v3-style tick math (feeGrowthOutsideX128 initialization, feeGrowthInside computation) is the highest-risk code and gets the most test coverage — driven through the public `mintPositionFor` entry point as integration tests per Principle 1.

## Contracts

### Types

```solidity
struct Position {
    address owner;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInsideLastX128;
    uint256 tokensOwed;
}

struct TickInfo {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutsideX128;
}

// Storage declarations added to LPVault
// mapping(uint256 => Position) public positions;
// mapping(int24 => TickInfo) public ticks;
// mapping(bytes32 => bool) public usedIntents;
// bytes32 public DOMAIN_SEPARATOR;
// uint256 private _cachedChainId;

// EIP-712 typed data
// bytes32 constant MINT_INTENT_TYPEHASH = keccak256(
//     "MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)"
// );

// Liquidity scaling factor — converts USDC (6 decimals) to liquidity weight
// uint256 constant LIQUIDITY_PRECISION = 1e18;

// Events
// event PositionMinted(
//     uint256 indexed positionId,
//     address indexed owner,
//     int24 tickLower,
//     int24 tickUpper,
//     uint128 liquidity,
//     uint256 usdcAmount,
//     bytes32 intentId
// );

// Errors (added to existing error block)
// error InvalidRange();
// error TickNotAligned();
// error VaultNotActive();
// error ZeroAmount();
// error IntentAlreadyUsed();
// error InvalidSignature();
// error BelowMinimumFirstLiquidity();
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `mintPositionFor` | `(address lp, int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId, bytes calldata signature) external returns (uint256 positionId)` | onlyOperator, nonReentrant | Verifies EIP-712 sig from lp, creates position, pulls USDC from lp's wallet |

### Behavior

- **Preconditions:** vault initialized and Active (phase == 1); caller is registered Operator; LP has approved vault for >= usdcAmount USDC; LP signed valid MintIntent with domain separator matching this vault and chain
- **Postconditions:** position record at nextPositionId with owner=lp, correct tickLower/tickUpper/liquidity/feeGrowthInsideLastX128/tokensOwed=0; ticks[tickLower] and ticks[tickUpper] initialized (if first use) and liquidityGross/liquidityNet updated; activeLiquidity increased if position is in-range; USDC transferred from lp to vault; PositionMinted event emitted; usedIntents[intentId]=true; nextPositionId incremented
- **Invariants:** feeGrowthInsideLastX128 snapshot prevents retroactive fee claims; ticks[t].feeGrowthOutsideX128 initialized to feeGrowthGlobalX128 if t<=currentTick else 0 (only on first use, liquidityGross==0); usedIntents mapping is write-once (never reset); signature verification enforces s<=secp256k1n/2 and v in {27,28}; DOMAIN_SEPARATOR recomputed when block.chainid != _cachedChainId; checks-effects-interactions: state before transferFrom
- **Error modes:** `InvalidRange` (tickLower >= tickUpper); `TickNotAligned` (tick % tickSpacing != 0); `VaultNotActive` (phase != 1); `ZeroAmount` (usdcAmount == 0); `IntentAlreadyUsed` (replay); `InvalidSignature` (bad sig, wrong signer, malleability); `NotOperator` (non-operator caller); `BelowMinimumFirstLiquidity` (activeLiquidity==0 and computed liquidity < minimumFirstLiquidity)

## Tests

- **SC-T7AH: successful in-range mint with fresh ticks**
  - Given vault with currentTick=50, tickSpacing=10, feeGrowthGlobalX128=1000, ticks 20/80 unused, LP approved 600 USDC, valid signature + unique intentId
    - When Operator calls mintPositionFor(lp, 20, 80, 600, intentId, sig)
      - Then position at nextPositionId has owner=lp, tickLower=20, tickUpper=80
      - And position.liquidity == 600 * LIQUIDITY_PRECISION / 60
      - And position.feeGrowthInsideLastX128 == feeGrowthInside([20, 80]) at mint time
      - And position.tokensOwed == 0
      - And ticks[20].feeGrowthOutsideX128 == 1000 (initialized to global, since 20 <= 50)
      - And ticks[80].feeGrowthOutsideX128 == 0 (above currentTick)
      - And ticks[20].liquidityGross == liquidity
      - And ticks[20].liquidityNet == int128(liquidity)
      - And ticks[80].liquidityGross == liquidity
      - And ticks[80].liquidityNet == -int128(liquidity)
      - And activeLiquidity increased by liquidity (position in-range: 20 <= 50 < 80)
      - And LP USDC balance decreased by 600
      - And vault USDC balance increased by 600
      - And PositionMinted(positionId, lp, 20, 80, liquidity, 600, intentId) event emitted
      - And usedIntents[intentId] == true
      - And nextPositionId incremented by 1
- **SC-T7AI: successful out-of-range mint (above current tick)**
  - Given vault with currentTick=50, tickSpacing=10, feeGrowthGlobalX128=2000, ticks 60/90 unused, LP approved 300 USDC, valid sig + unique intentId
    - When Operator calls mintPositionFor(lp, 60, 90, 300, intentId, sig)
      - Then position created with tickLower=60, tickUpper=90, liquidity=300*PRECISION/30
      - And ticks[60].feeGrowthOutsideX128 == 0 (60 > currentTick 50)
      - And ticks[90].feeGrowthOutsideX128 == 0 (90 > currentTick 50)
      - And activeLiquidity unchanged (position out-of-range)
      - And LP USDC balance decreased by 300
      - And PositionMinted event emitted
- **SC-T7AJ: second position on existing tick**
  - Given tick 20 already initialized with liquidityGross=prevL, feeGrowthOutsideX128=500; tick 60 unused
    - When Operator calls mintPositionFor(lp, 20, 60, 400, intentId, sig)
      - Then ticks[20].liquidityGross == prevL + newLiquidity (accumulated)
      - And ticks[20].feeGrowthOutsideX128 == 500 (preserved, NOT re-initialized)
      - And ticks[60] initialized freshly
      - And new position has correct feeGrowthInsideLastX128 using existing tick state
- **SC-T7AK: inverted range revert**
  - Given LP signed intent with tickLower=80, tickUpper=20
    - When Operator calls mintPositionFor
      - Then reverts with InvalidRange
      - And no state changes, no USDC transferred, no events
- **SC-T7AL: misaligned tick revert**
  - Given vault with tickSpacing=10, LP signed intent with tickLower=15, tickUpper=80
    - When Operator calls mintPositionFor
      - Then reverts with TickNotAligned
      - And no state changes
- **SC-T7AM: non-active vault revert**
  - Given vault in WindDown phase (phase != 1)
    - When Operator calls mintPositionFor with valid intent
      - Then reverts with VaultNotActive
      - And no state changes
- **SC-T7AN: non-operator caller revert**
  - Given caller is LP, Admin, Oracle, or arbitrary address (not a registered Operator)
    - When caller calls mintPositionFor with valid intent
      - Then reverts with NotOperator
      - And no state changes
- **SC-T7AO: first mint below minimum liquidity**
  - Given vault with activeLiquidity==0, minimumFirstLiquidity=1000*PRECISION, LP signed intent that produces liquidity < 1000*PRECISION
    - When Operator calls mintPositionFor
      - Then reverts with BelowMinimumFirstLiquidity
      - And no state changes, no USDC transferred
- **SC-T7AP: duplicate intentId revert**
  - Given intentId 0xabc already used in a prior successful mint
    - When Operator calls mintPositionFor with same intentId
      - Then reverts with IntentAlreadyUsed
      - And no state changes
- **SC-T7AQ: invalid signature revert**
  - Given LP signed intent but Operator submits with different lp address than signer
    - When Operator calls mintPositionFor
      - Then reverts with InvalidSignature
      - And no state changes
  - Given signature with high-s value (above secp256k1n/2)
    - When Operator calls mintPositionFor
      - Then reverts with InvalidSignature
  - Given signature with v != 27 and v != 28
    - When Operator calls mintPositionFor
      - Then reverts with InvalidSignature
- **SC-T7AR: zero amount revert**
  - Given LP signed intent with usdcAmount=0
    - When Operator calls mintPositionFor
      - Then reverts with ZeroAmount
      - And no state changes
