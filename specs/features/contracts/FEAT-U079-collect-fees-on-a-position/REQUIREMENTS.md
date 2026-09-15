---
id: FEAT-U079
name: Collect Fees on a Position
module: contracts
domain: "@positions"
status: implemented
version: 6
refs: [FEAT-TVS0, FEAT-6HBN, FEAT-3ZRI, FEAT-JAIJ, FEAT-9BQZ]
---

# Collect Fees on a Position

> Enables an LP to withdraw accumulated trading fees from their position without removing it, in one call by the LP's Safe or one relayed call with the owner key's signature, using the v3 feeGrowthInside accumulator to compute what is owed, merging the vault's free pairs first and paying its share of what the vault holds above escrow under the solvency ledger (FEAT-9BQZ).

## Non-Goals

- Does not remove the position or return the LP's principal -- see FEAT-7G40
- Does not handle fee notification or global accumulator updates -- see FEAT-TOGR
- Does not handle tick crossing or feeGrowthOutside flipping -- see FEAT-TVS0
- Does not handle vault lifecycle transitions -- see FEAT-JGE7 (wind-down) and FEAT-JXQO (emergency cancel)
- Does not merge the vault's free pairs or redeem its tokens on its own account -- see FEAT-6HBN, whose internal settlement every paying collect calls first (the merge before the switch, the redemption after it)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | The LP's Safe calls `collect(positionId)` to withdraw earned fees | Only the position's owner can collect; verified via `position.owner == msg.sender` |
| Operator | Calls `collectFor(lp, positionId, nonce, deadline, signature)` to relay the owner key's signed `CollectIntent` | Gas-sponsored normal path. Cannot start a collect without the owner key's signature and cannot redirect the payout |

## Functional Requirements

### Fee Computation

**FR-U07H** `When the LP calls collect(positionId), the system shall compute feeGrowthInsideX128 for the position's [tickLower, tickUpper] range using feeGrowthGlobalX128 and each boundary tick's feeGrowthOutsideX128.`
Fit Criterion: Given feeGrowthGlobalX128 = G, ticks[tickLower].feeGrowthOutsideX128 and ticks[tickUpper].feeGrowthOutsideX128 reflecting accumulated fees below and above the range, feeGrowthInsideX128 = G - feeGrowthBelow - feeGrowthAbove per the v3 formula.
Linked to: UC-U07A

**FR-U07I** `When collect computes feeGrowthInsideX128, the system shall calculate owed fees as liquidity * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128, truncating toward zero.`
Fit Criterion: Given a position with liquidity L whose feeGrowthInsideX128 grew by delta since the last collect (or mint), the owed amount = L * delta / 2^128 (truncated), matching the v3 fee accounting.
Linked to: UC-U07A

### Snapshot

**FR-U07J** `When collect completes, the system shall set the position's feeGrowthInsideLastX128 to the current feeGrowthInsideX128 value.`
Fit Criterion: Given a collect at time T, a subsequent collect at time T+1 with no new fee growth produces zero owed fees.
Linked to: UC-U07A

### Payout

**FR-U07K** `When collect computes a nonzero owed amount, the system shall settle first (merge the vault's complete sets before the switch, redeem every token after it), transfer the owed amount times the USDC ratio of FEAT-9BQZ (FR-9BRM before the switch, FR-CYS5 after it; rounded down, never above what is held) to the position's owner, set the position's tokensOwed to zero, debit totalFeesOwedX128 by the position's full scaled fee claim, and emit FeesCollected with positionId, owner, the amount owed, and the amount paid.`
Fit Criterion: Given owed > 0 and a covered vault, the LP's USDC balance increases by exactly the owed amount, `tokensOwed` is zero, and `FeesCollected(positionId, owner, owed, owed)` is emitted. Given owed = 10 USDC and a USDC ratio of 0.4, the call pays 4, does not revert, leaves `tokensOwed = 0`, emits `FeesCollected(positionId, owner, 10e6, 4e6)`, and a later collect owes only the fees that grew since. Given a vault whose USDC balance is below `totalEscrowed`, the call pays zero, does not revert, and emits `FeesCollected(positionId, owner, owed, 0)`. Given owed = 9,999,999 units after the Oracle's redemption, with the vault's USDC drained so that held is 173,677,249 against a pooled owed total of 347,354,499 (the principal, the fees, and the 90 YES owed at the payout), the call pays 4,999,999 and makes no `mergePositions` call. Decisions C6, C7, and O2 (ADR-COEN in FEAT-9BQZ).
Linked to: UC-U07A, UC-BMF8

**FR-U07L** `When collect computes zero owed fees, the system shall succeed without performing a USDC transfer.`
Fit Criterion: Given no fee growth since the last collect, no USDC transfer occurs and the transaction succeeds.
Linked to: UC-U07A

### Access Control

**FR-U07M** `If the caller is not the position's owner, then the system shall revert.`
Fit Criterion: Given position.owner != msg.sender, collect(positionId) reverts with a NotPositionOwner error.
Linked to: UC-U07A

**FR-U07N** `If positionId does not correspond to an existing position, then the system shall revert.`
Fit Criterion: Given a nonexistent positionId, collect(positionId) reverts with a PositionNotFound error.
Linked to: UC-U07A

### Phase Independence

**FR-U07O** `While the vault is in any phase (Active, WindDown, or Cancelled), and whether or not trading is paused, the system shall allow collect and collectFor to proceed.`
Fit Criterion: Given a vault in WindDown or in Cancelled, collect and collectFor succeed for valid positions with accrued fees and pay the same amount as in the Active phase, because the freeze keeps every record (FEAT-JXQO FR-JXQP). Decision C9.
Linked to: UC-U07A, UC-BMF8

### Operator-Relayed Path

**FR-BMF9** `When the Operator calls collectFor(lp, positionId, nonce, deadline, signature) with the owner key's signature over CollectIntent(address lp,uint256 positionId,uint256 nonce,uint256 deadline), the system shall run the same collect as the self-service path and pay lp.`
Fit Criterion: Given a valid `CollectIntent` signed by the owner key of `lp`, the LP's USDC balance increases by the amount `collect` would pay, `FeesCollected(positionId, lp, owed, paid)` is emitted, and the Operator's balances are unchanged apart from gas. Decision C3.
Linked to: UC-BMF8

**FR-BMFA** `The system shall verify the collect signature with _verifySafeOwnerSignature, revert IntentExpired when block.timestamp > deadline, revert IntentAlreadyUsed when usedCollectAuthorizations[structHash] is set, record the struct hash before any external call, and revert NotPositionOwner when position.owner != lp.`
Fit Criterion: Given a `CollectIntent` whose `deadline` passed, the call reverts `IntentExpired`. Given a struct hash already consumed, it reverts `IntentAlreadyUsed`. Given a key whose derived Safe is not `lp`, or a `MintIntent`, `ReclaimIntent`, or `BurnIntent` signature, it reverts `InvalidSignature`. Given a valid signature for a Safe that does not own the position, it reverts `NotPositionOwner`. The type carries a `nonce` because a collect repeats over a position's life, so each authorization is unique (ADR-85DM in FEAT-7G40).
Linked to: UC-BMF8

**FR-BMFB** `The system shall refresh lastOperatorActivityTimestamp when collectFor succeeds, and shall leave it unchanged when collect succeeds.`
Fit Criterion: Given a successful `collectFor`, `lastOperatorActivityTimestamp == block.timestamp`. Given a successful `collect`, the value before and after is the same. Implemented through the `touchesHeartbeat` modifier on `collectFor` only.
Linked to: UC-BMF8, UC-U07A

## Non-Functional Requirements

**NFR-U07P** Gas: `When the LP collects fees on a single position, the call gas shall remain below 120,000 when the vault holds no pair, and below 180,000 when the collect merges the vault's free pairs, against the mock USDC and the real ConditionalTokens bytecode, measured with every slot cold.`
Rationale: measured cold on the build of 2026-09-13 at 99,646 call gas with nothing to merge and 153,283 with 20 pairs merged, plus the 21,000 base each. The merge through the real ConditionalTokens contract costs about 54,000 gas cold, which the user accepted on 2026-09-13 (decision C26) over a collect that could pay from USDC a fill already spent; a keeper that merges on sight keeps the per-collect cost at the lower figure. Re-measured on the R14 build (2026-09-14): 117,976 with no pair, up from 117,998 on the R13 build, because the free-pairs rule returns before its two ledger reads when either balance is zero, and 168,792 with 20 pairs merged, up from 164,152 for those two reads. The bounds stay.

**NFR-U07Q** Security: `The system shall apply an inline nonReentrant modifier on collect to prevent reentrancy via the USDC transfer callback.`

**NFR-U07R** Security: `The system shall follow checks-effects-interactions ordering in collect: validate ownership and read the balances, the switch, and the ledger totals first (both token balances, the USDC balance, the stored payout, the ratio's two sides, and the amount to pay), update position state and the ledger second (the feeGrowthInsideLastX128 snapshot, tokensOwed to zero, and the fee total's debit), then settle (the merge before the switch, the redemption after it) and transfer USDC last.`
Rationale: the merge pays exactly the free pairs the collect computed from view reads (the two balances and the two owed totals, read before the fee debit) and the redemption pays exactly `balance × numerator ÷ denominator` per side, so the amount to pay is known before any effect, and CLAUDE.md checklist item 1 holds without exception. The settlement receives the number the collect computed, never a fresh read (FEAT-6HBN ADR-DFE2).

**NFR-BMFC** Security: `collectFor shall carry an OPERATOR TRUST ASSUMPTION NatSpec block with an MEV analysis section.`
Fit Criterion: the block states that the Operator can delay a collect and chooses its block, which changes nothing about the fees owed, because the accumulator only grows; that it cannot start one without the signature, replay a spent nonce, or redirect the payout; and that the LP's remedy is `collect`.

**NFR-U07S** Security: `The system shall use an inline _safeTransfer helper for the USDC payout to handle both bool-returning and non-bool-returning ERC-20s (USDT semantics).`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-U07A pass with full coverage
- Non-owner callers cannot collect (FR-U07M verified in SC-U07D)
- Sequential collects with no fee growth produce zero payout (no double-counting, SC-U07G)
- Collect works in Active, WindDown, and Cancelled phases (SC-U07F, SC-BMFD)
- Every paying collect merges the vault's free pairs first, pays the owed amount times the USDC ratio, and settles the claim (SC-BMFE, SC-COEZ)
- All scenarios in UC-BMF8 pass, and a `MintIntent`, `ReclaimIntent`, or `BurnIntent` signature is rejected by `collectFor`
- `collectFor` refreshes `lastOperatorActivityTimestamp`; `collect` does not
- OPERATOR TRUST ASSUMPTION NatSpec block with an MEV analysis present on `collectFor`
- feeGrowthInsideX128 matches v3 formula: global - below(lower) - above(upper)
- Q128 truncation dust verified via fuzz test
- Inline nonReentrant guard on collect
- Checks-effects-interactions ordering verified
- Inline _safeTransfer used (no SafeERC20 import)
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
