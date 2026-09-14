---
id: FEAT-T7AF
name: Mint LP Position
module: contracts
domain: "@positions"
status: implemented
version: 6
refs: [FEAT-REPZ, FEAT-3ZRI, FEAT-JAIJ]
---

# Mint LP Position

> Enables operator-gated creation of concentrated-liquidity LP positions that consume a per-intent escrow, with v3-style tick initialization and fee-snapshot anchoring to prevent retroactive fee claims.

## Non-Goals

- Does not handle fee collection -- see feature 5
- Does not handle position burning -- see feature 6
- Does not take USDC or verify a signature -- the escrow does both, see FEAT-3ZRI
- Does not refund an escrow -- see FEAT-JAIJ
- Does not handle tick crossing / updateTick -- see feature 4
- Does not handle fee notification / notifyFees -- see feature 3
- Does not handle vault wind-down or emergency cancel -- see feature 8
- Does not manage vault-level role registries -- see FEAT-REPZ

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Mints the position that an escrowed intent authorizes | Gated by `onlyOperator` modifier; moves no USDC and verifies no signature; the escrow (FEAT-3ZRI) did both |
| LP | Owner of the Safe that the escrow names | The Safe is the position owner; the owner key signed the MintIntent at the deposit |

## Functional Requirements

### Position Creation

**FR-T7AS** `When the Operator submits a mint intent whose escrow the vault holds for the named Safe, the system shall consume that escrow, subtract its amount from totalEscrowed, compute liquidity as usdcAmount * PRECISION / (tickUpper - tickLower), create a position record owned by the Safe with a feeGrowthInsideLastX128 snapshot and the clamped mintTick, and emit a PositionMinted event that carries the mintTick.`
Fit Criterion: Given an escrowed intent, the vault's USDC balance does not change, `pendingDeposits[intentId]` is deleted, `totalEscrowed` falls by the escrowed amount, a position record exists at the assigned positionId with owner = the Safe and correct tickLower, tickUpper, mintTick, liquidity, and feeGrowthInsideLastX128, and a PositionMinted event is emitted with the correct fields, mintTick included.
Linked to: UC-T7AG

**FR-3Z9W** `If the Operator submits a mint intent whose recomputed struct hash (lp, tickLower, tickUpper, usdcAmount, intentId, deadline) does not equal the hash recorded in the intent's escrow, then the system shall revert.`
Fit Criterion: Any changed range, amount, or deadline reverts with `IntentMismatch`. The mint verifies no signature and reads no clock: the deadline is an argument only because the hash needs it, so a deposit made near its deadline can still mint.
Linked to: UC-T7AG

**FR-45ID** `If the Operator submits a mint intent for a Safe that is not the escrow entry's recorded depositor, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp == A`, a mint naming Safe B reverts with `NotIntentOwner` before the hash compare, so a foreign claim reports ownership and not a mismatch. A valid signature does not prove who owns an intentId, and the mint checks no signature at all, so the recorded Safe is the only ownership proof.
Linked to: UC-T7AG

**FR-3ZVK** `When a mint consumes an intent's escrow, the system shall set usedIntents[intentId], delete pendingDeposits[intentId], and reduce totalEscrowed before it performs any external call.`
Fit Criterion: The mint performs no external call at all. The escrow is deleted in the same call that reads it, so a reclaim of the same intentId after the mint reverts (ADR-JAIY).
Linked to: UC-T7AG

**FR-T7AT** `When a position is minted, the system shall set feeGrowthInsideLastX128 to the current feeGrowthInside computed for the position's [tickLower, tickUpper] range, preventing the position from claiming pre-existing fees.`
Fit Criterion: Given a position minted at time T with accumulated feeGrowthGlobalX128 = G, the position's tokensOwed is 0 immediately after minting, and fees distributed before T produce zero claimable tokens for this position.
Linked to: UC-T7AG

**FR-AFPO** `When a position is minted, the system shall record mintTick as currentTick clamped into the position's range: tickLower when currentTick < tickLower, tickUpper when currentTick > tickUpper, and currentTick otherwise.`
Fit Criterion: Given currentTick = 50, a mint over [20, 80) stores mintTick = 50, a mint over [60, 90) stores mintTick = 60, and a mint over [0, 30) stores mintTick = 30. The stored value never changes after the mint. The `PositionMinted` event carries the stored value. The mint tick anchors which levels of the range hold USDC and which hold outcome tokens under the claim model (decision C26 in `audits/audit-fixes-ranged.md`), and `mergePositions` requires it equal across merged positions (FEAT-K1M2, FR-AFPT). The clamp is the user's choice of 2026-09-12 (ADR-AFPP).
Linked to: UC-T7AG

### Tick State

**FR-T7AU** `When a position references a tick with liquidityGross == 0, the system shall initialize the tick's feeGrowthOutsideX128 to feeGrowthGlobalX128 if tick <= currentTick, else to 0.`
Fit Criterion: Given a freshly initialized tick at or below currentTick, feeGrowthOutsideX128 == feeGrowthGlobalX128. Given a tick above currentTick, feeGrowthOutsideX128 == 0.
Linked to: UC-T7AG

**FR-T7AV** `When a position is minted, the system shall increment liquidityGross on both tickLower and tickUpper by the position's liquidity, add the position's liquidity to liquidityNet on tickLower, subtract it from liquidityNet on tickUpper, book the position's NO sub-range [mintTick, tickUpper) by adding its liquidity to noLiquidityNet on mintTick and subtracting it on tickUpper, and, when mintTick lies strictly inside the range, initialize mintTick and increment its liquidityGross by the position's liquidity.`
Fit Criterion: Given a mint with liquidity L, ticks[tickLower].liquidityGross increases by L, ticks[tickLower].liquidityNet increases by L, ticks[tickUpper].liquidityGross increases by L, ticks[tickUpper].liquidityNet decreases by L; when mintTick < tickUpper, ticks[mintTick].noLiquidityNet increases by L and ticks[tickUpper].noLiquidityNet decreases by L; when tickLower < mintTick < tickUpper, ticks[mintTick].liquidityGross increases by L and its bitmap bit is set, so `updateTick` crosses it (FEAT-TVS0 ADR-COEW). A mint at its upper bound books no NO sub-range, because that side is empty.
Linked to: UC-T7AG

### Active Liquidity

**FR-T7AW** `When a position is minted with tickLower <= currentTick < tickUpper, the system shall add the position's liquidity to activeLiquidity.`
Fit Criterion: Given currentTick within the position's range, activeLiquidity increases by the position's liquidity value.
Linked to: UC-T7AG

**FR-T7AX** `When a position is minted with currentTick < tickLower or currentTick >= tickUpper, the system shall not modify activeLiquidity.`
Fit Criterion: Given currentTick outside the position's range, activeLiquidity remains unchanged after the mint.
Linked to: UC-T7AG

### EIP-712 Intent Verification

**FR-T7AY** `When the Operator escrows a mint intent, the system shall verify an EIP-712 signature over a MintIntent typed struct containing lp, tickLower, tickUpper, usdcAmount, intentId, and deadline, using the domain separator cached at initialize() and recomputed on chainId mismatch, and shall accept the signature only when the Safe address derived from the recovered signer equals lp.`
Fit Criterion: Given a signature from the owner key of the Safe named as `lp`, over the correct MintIntent struct and domain separator, the deposit proceeds. Given a signer whose derived Safe is not `lp`, given `lp` equal to the signer's own address, or given tampered fields, the call reverts with `InvalidSignature`. The mint itself verifies no signature (FR-3Z9W).
Linked to: UC-T7AG, UC-3Z92

**FR-9OYJ** `When the vault verifies any LP-signed EIP-712 message (MintIntent, ReclaimIntent, and every later LP type), the system shall reject the message when block.timestamp is greater than the message's deadline.`
Fit Criterion: A message with `deadline == block.timestamp` is accepted, and one with `deadline == block.timestamp - 1` reverts with `IntentExpired`. The check tolerates Polygon's ±15 second block timestamp variance, which the NatSpec at each check documents.
Linked to: UC-3Z92, UC-3Z93

**FR-T7AZ** `When verifying a signature, the system shall reject signatures with s values above secp256k1n/2 and v values outside {27, 28}.`
Fit Criterion: Given a malleable signature (high-s or v != 27/28), the call reverts with an InvalidSignature error. One internal `_recoverSigner` applies the rule to every LP signature.
Linked to: UC-3Z92, UC-3Z93

**FR-T7B0** `When initialize() is called on a vault clone, the system shall compute and cache the EIP-712 domain separator and the chain ID. While block.chainid differs from the cached chain ID, the system shall recompute the domain separator dynamically.`
Fit Criterion: Given a chain fork that changes chainId, signatures produced with the original chainId are rejected and signatures produced with the forked chainId are accepted.
Linked to: UC-3Z92

### Replay Protection

**FR-T7B1** `When a mint intent is executed, the system shall record the intentId in a used-intents mapping. If the same intentId has been used before, then the system shall revert.`
Fit Criterion: Given an intentId that has already been used in a successful mint or reclaim, a second call with the same intentId reverts with an IntentAlreadyUsed error, before the escrow is read.
Linked to: UC-T7AG

### Validation

**FR-T7B2** `If tickLower >= tickUpper, or tickLower < 0, or tickUpper > PRICE_TICK_ONE (10000) in a mint intent, then the system shall revert.`
Fit Criterion: Given tickLower = 80 and tickUpper = 20, or tickLower = −10 and tickUpper = 20, or tickLower = 9990 and tickUpper = 10010, the call reverts with an `InvalidRange` error. Every level of an accepted range has a price `tick / 10000`, so the claim formula of FEAT-7G40 can value it (ADR-BMF7).
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

**NFR-T7B6** Gas: `When an Operator mints a position (including tick initialization), the total gas cost shall remain below 300,000 gas on Polygon.`

**NFR-T7B7** Security: `The system shall apply an inline nonReentrant modifier to the mint function as defense in depth: the mint makes no external call, and the guard keeps position, tick, and activeLiquidity state closed to any guarded path that re-enters, so a later revision that adds an external call cannot inherit an unguarded function.`

**NFR-T7B8** Security: `The system shall follow checks-effects-interactions ordering in the mint function: validate inputs and confirm that the escrow names this Safe and this intent hash first; then set usedIntents, delete the escrow, reduce totalEscrowed, and update position, tick, and activeLiquidity state. The mint performs no external call.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-T7AG pass with full coverage
- Non-operator callers cannot mint (FR-RFS6 from FEAT-REPZ verified in scenario SC-T7AN)
- First mint below minimumFirstLiquidity reverts when nextPositionId == 0, and a later small mint succeeds after activeLiquidity returns to zero (FR-RFS7 from FEAT-REPZ verified in scenarios SC-T7AO and SC-AFPM)
- Every position records its clamped mintTick and the PositionMinted event carries it (FR-AFPO verified in scenario SC-AFPN)
- Positions minted at time T cannot claim fees from before T (fuzz test on feeGrowthInsideLastX128 snapshot)
- Tick initialization is correct for both below-current and above-current ticks (fuzz test)
- The mint consumes exactly the recorded escrow and reverts `DepositNotEscrowed`, `NotIntentOwner`, and `IntentMismatch` in that order of precedence
- The owner-key signature check at the deposit rejects malleability and a key that derives a different Safe
- Replay protection prevents double-use of intentId
- activeLiquidity updates only for in-range positions
- Inline nonReentrant guard on mint function
- Checks-effects-interactions ordering verified
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
