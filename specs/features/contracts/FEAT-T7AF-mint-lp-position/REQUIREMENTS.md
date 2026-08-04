---
id: FEAT-T7AF
name: Mint LP Position
module: contracts
domain: "@positions"
status: implemented
version: 4
refs: [FEAT-REPZ, FEAT-3ZRI]
---

# Mint LP Position

> Enables operator-gated creation of concentrated-liquidity LP positions via EIP-712 signed intents, with v3-style tick initialization and fee-snapshot anchoring to prevent retroactive fee claims.

## Non-Goals

- Does not handle fee collection -- see feature 5
- Does not handle position burning -- see FEAT-7G40
- Does not pull USDC from the LP's wallet; the intent must already be funded as per-intent escrow -- see FEAT-3ZRI
- Does not refund an unfulfilled intent's escrow -- see FEAT-JAIJ
- Does not handle tick crossing / updateTick -- see feature 4
- Does not handle fee notification / notifyFees -- see feature 3
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not manage vault-level role registries -- see FEAT-REPZ

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Executes the LP's signed mint intent on-chain | Gated by `onlyOperator` modifier; consumes the intent's escrow (FEAT-3ZRI) rather than moving any tokens itself |
| LP | Signs EIP-712 mint intent off-chain | One signature authorizes both the escrow (FEAT-3ZRI) and this mint; position ownership recorded as LP address |

## Functional Requirements

### Position Creation

**FR-T7AS** `When the Operator submits a valid EIP-712 mint intent signed by an LP whose escrow already covers the intent, the system shall consume that escrow, compute liquidity as usdcAmount * PRECISION / (tickUpper - tickLower), create a position record with feeGrowthInsideLastX128 snapshot, and emit a PositionMinted event.`
Fit Criterion: Given a valid intent with matching signature and `pendingDeposits[intentId] == usdcAmount`, a position record exists at the assigned positionId with correct tickLower, tickUpper, liquidity, and feeGrowthInsideLastX128, `pendingDeposits[intentId] == 0` afterwards, and a PositionMinted event is emitted with the correct fields. The LP's USDC balance is unchanged by this call -- it was debited earlier, at escrow time (FEAT-3ZRI FR-3Z9M).
Linked to: UC-T7AG

**FR-3Z9W** `If the Operator submits a mint intent whose escrowed amount does not exactly equal the intent's usdcAmount, then the system shall revert.`
Fit Criterion: Given no escrow entry for the intentId (never funded, or already consumed), the call reverts with `DepositNotEscrowed`. Given `pendingDeposits[intentId].amount != usdcAmount` (funded against a different amount), the call reverts with the same error. Exact equality is required rather than a sufficiency check, so a position can never be minted larger than the USDC actually collected for it, nor silently leave a remainder stranded in escrow.
Linked to: UC-T7AG

**FR-45ID** `If the Operator submits a mint intent for an LP who is not the escrow entry's recorded depositor, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp == A` and a mint submitted for LP B with a signature validly produced by B over the same intentId, the call reverts with `NotIntentOwner` and no position is created. A valid signature over an intentId is necessary but not sufficient to spend that intentId's escrow, because any party can sign over any intentId (FEAT-3ZRI FR-45I9, ADR-45IC). Without this check a compromised or colluding Operator could mint B a position funded entirely by A's deposit.
Linked to: UC-T7AG

**FR-3ZVK** `When a mint consumes an intent's escrow, the system shall delete pendingDeposits[intentId] before performing any external call.`
Fit Criterion: Given a successful mint, `pendingDeposits[intentId] == 0` and `usedIntents[intentId] == true`, so neither a second mint nor a reclaim can draw on the same escrow. The deletion sits in the Effects section, preserving checks-effects-interactions.
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

### Operator Liveness

**FR-3XU4** `When mintPositionFor completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given the Operator successfully mints a position for an LP, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given the mint reverts for any reason, `lastOperatorActivityTimestamp` is unchanged. The silence timer this feeds is consumed by `emergencyCancelAll` (FEAT-JXQO, FR-JXQS).
Linked to: UC-T7AG

## Non-Functional Requirements

**NFR-T7B6** Gas: `When an Operator mints a position (including tick initialization and USDC transfer), the total gas cost shall remain below 300,000 gas on Polygon.`

**NFR-T7B7** Security: `The system shall apply an inline nonReentrant modifier to the mint function.`
Rationale: mint performs no token transfer once funding moves to escrow (FEAT-3ZRI), so there is no callback to reenter through today. The guard is retained as defense-in-depth because mint mutates position, tick, and activeLiquidity state that other guarded paths read, and because a future revision that reintroduces an external call must not silently inherit an unguarded function.

**NFR-T7B8** Security: `The system shall follow checks-effects-interactions ordering in the mint function: validate inputs, verify the signature, and confirm the escrow covers the intent first; then consume the escrow and update position, tick, and activeLiquidity state.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-T7AG pass with full coverage
- `mintPositionFor` contains no `transferFrom` call and no token transfer of any kind
- Minting an intent with no escrow, or with an escrow that does not exactly match the intent's amount, reverts with `DepositNotEscrowed`
- A minted intent's escrow entry is deleted, so it can be neither re-minted nor reclaimed
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
