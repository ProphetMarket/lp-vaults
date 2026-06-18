---
id: FEAT-T7AF
name: Mint LP Position
module: contracts
domain: "@positions"
status: implemented
version: 1
refs: [FEAT-REPZ]
---

# Mint LP Position

> Enables operator-gated creation of concentrated-liquidity LP positions via EIP-712 signed intents, with v3-style tick initialization and fee-snapshot anchoring to prevent retroactive fee claims.

## Non-Goals

- Does not handle fee collection -- see feature 5
- Does not handle position burning -- see feature 6
- Does not handle deposit-then-credit flow (USDC pre-sent to vault) or reclaimDeposit escape hatch -- see feature 7
- Does not handle tick crossing / updateTick -- see feature 4
- Does not handle fee notification / notifyFees -- see feature 3
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not manage vault-level role registries -- see FEAT-REPZ

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Executes the LP's signed mint intent on-chain | Gated by `onlyOperator` modifier; pulls USDC from LP's wallet via transferFrom |
| LP | Signs EIP-712 mint intent off-chain | Their wallet is the USDC source; position ownership recorded as LP address |

## Functional Requirements

### Position Creation

**FR-T7AS** `When the Operator submits a valid EIP-712 mint intent signed by an LP, the system shall pull usdcAmount USDC from the LP's wallet via transferFrom, compute liquidity as usdcAmount * PRECISION / (tickUpper - tickLower), create a position record with feeGrowthInsideLastX128 snapshot, and emit a PositionMinted event.`
Fit Criterion: Given a valid intent with matching signature, the LP's USDC balance decreases by usdcAmount, a position record exists at the assigned positionId with correct tickLower, tickUpper, liquidity, and feeGrowthInsideLastX128, and a PositionMinted event is emitted with the correct fields.
Linked to: UC-T7AG

**FR-T7AT** `When a position is minted, the system shall set feeGrowthInsideLastX128 to the current feeGrowthInside computed for the position's [tickLower, tickUpper] range, preventing the position from claiming pre-existing fees.`
Fit Criterion: Given a position minted at time T with accumulated feeGrowthGlobalX128 = G, the position's tokensOwed is 0 immediately after minting, and fees distributed before T produce zero claimable tokens for this position.
Linked to: UC-T7AG

### Tick State

**FR-T7AU** `When a position references a tick with liquidityGross == 0, the system shall initialize the tick's feeGrowthOutsideX128 to feeGrowthGlobalX128 if tick <= currentTick, else to 0.`
Fit Criterion: Given a freshly initialized tick at or below currentTick, feeGrowthOutsideX128 == feeGrowthGlobalX128. Given a tick above currentTick, feeGrowthOutsideX128 == 0.
Linked to: UC-T7AG

**FR-T7AV** `When a position is minted, the system shall increment liquidityGross on both tickLower and tickUpper by the position's liquidity, add the position's liquidity to liquidityNet on tickLower, and subtract it from liquidityNet on tickUpper.`
Fit Criterion: Given a mint with liquidity L, ticks[tickLower].liquidityGross increases by L, ticks[tickLower].liquidityNet increases by L, ticks[tickUpper].liquidityGross increases by L, ticks[tickUpper].liquidityNet decreases by L.
Linked to: UC-T7AG

### Active Liquidity

**FR-T7AW** `When a position is minted with tickLower <= currentTick < tickUpper, the system shall add the position's liquidity to activeLiquidity.`
Fit Criterion: Given currentTick within the position's range, activeLiquidity increases by the position's liquidity value.
Linked to: UC-T7AG

**FR-T7AX** `When a position is minted with currentTick < tickLower or currentTick >= tickUpper, the system shall not modify activeLiquidity.`
Fit Criterion: Given currentTick outside the position's range, activeLiquidity remains unchanged after the mint.
Linked to: UC-T7AG

### EIP-712 Intent Verification

**FR-T7AY** `When the Operator submits a mint intent, the system shall verify the LP's EIP-712 signature over a MintIntent typed struct containing lp, tickLower, tickUpper, usdcAmount, and intentId, using the domain separator cached at initialize() and recomputed on chainId mismatch.`
Fit Criterion: Given a valid signature from the LP's private key over the correct MintIntent struct and domain separator, the mint proceeds. Given any other signer or tampered fields, the call reverts.
Linked to: UC-T7AG

**FR-T7AZ** `When verifying a signature, the system shall reject signatures with s values above secp256k1n/2 and v values outside {27, 28}.`
Fit Criterion: Given a malleable signature (high-s or v != 27/28), the call reverts with an InvalidSignature error.
Linked to: UC-T7AG

**FR-T7B0** `When initialize() is called on a vault clone, the system shall compute and cache the EIP-712 domain separator and the chain ID. While block.chainid differs from the cached chain ID, the system shall recompute the domain separator dynamically.`
Fit Criterion: Given a chain fork that changes chainId, signatures produced with the original chainId are rejected and signatures produced with the forked chainId are accepted.
Linked to: UC-T7AG

### Replay Protection

**FR-T7B1** `When a mint intent is executed, the system shall record the intentId in a used-intents mapping. If the same intentId has been used before, then the system shall revert.`
Fit Criterion: Given an intentId that has already been used in a successful mint, a second call with the same intentId reverts with an IntentAlreadyUsed error.
Linked to: UC-T7AG

### Validation

**FR-T7B2** `If tickLower >= tickUpper in a mint intent, then the system shall revert.`
Fit Criterion: Given tickLower = 80 and tickUpper = 20, the call reverts with an InvalidRange error.
Linked to: UC-T7AG

**FR-T7B3** `If tickLower or tickUpper is not evenly divisible by the vault's tickSpacing, then the system shall revert.`
Fit Criterion: Given tickSpacing = 10 and tickLower = 15, the call reverts with a TickNotAligned error.
Linked to: UC-T7AG

**FR-T7B4** `If the vault's phase is not Active when a mint is attempted, then the system shall revert.`
Fit Criterion: Given a vault in WindDown phase, any mint call reverts with a VaultNotActive error.
Linked to: UC-T7AG

**FR-T7B5** `If usdcAmount in a mint intent is 0, then the system shall revert.`
Fit Criterion: Given usdcAmount == 0, the call reverts with a ZeroAmount error.
Linked to: UC-T7AG

## Non-Functional Requirements

**NFR-T7B6** Gas: `When an Operator mints a position (including tick initialization and USDC transfer), the total gas cost shall remain below 300,000 gas on Polygon.`

**NFR-T7B7** Security: `The system shall apply an inline nonReentrant modifier to the mint function to prevent reentrancy via the USDC transferFrom callback.`

**NFR-T7B8** Security: `The system shall follow checks-effects-interactions ordering in the mint function: validate inputs and verify signature first, update position and tick state second, perform the external USDC transferFrom last.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-T7AG pass with full coverage
- Non-operator callers cannot mint (FR-RFS6 from FEAT-REPZ verified in scenario SC-T7AN)
- First mint below minimumFirstLiquidity reverts when activeLiquidity == 0 (FR-RFS7 from FEAT-REPZ verified in scenario SC-T7AO)
- Positions minted at time T cannot claim fees from before T (fuzz test on feeGrowthInsideLastX128 snapshot)
- Tick initialization is correct for both below-current and above-current ticks (fuzz test)
- EIP-712 signature verification rejects malleability and wrong signers
- Replay protection prevents double-use of intentId
- activeLiquidity updates only for in-range positions
- Inline nonReentrant guard on mint function
- Checks-effects-interactions ordering verified
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
