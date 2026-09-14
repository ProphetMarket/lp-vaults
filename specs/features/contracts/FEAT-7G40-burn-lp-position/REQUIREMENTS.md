---
id: FEAT-7G40
name: Burn LP Position
module: contracts
domain: "@positions"
status: implemented
version: 4
refs: [FEAT-T7AF, FEAT-U079, FEAT-TVS0, FEAT-JGE7, FEAT-6HBN, FEAT-3ZRI, FEAT-9BQZ]
---

# Burn LP Position

> LP-initiated closure of a position, in one call by the LP's Safe or one relayed call with the owner key's signature, that merges the vault's pairs into USDC, values the claim from its mint tick under decision C26, removes the position's liquidity from both ticks, and pays the Safe USDC plus one outcome token, each asset's owed amount times its ratio, from the solvency ledger (FEAT-9BQZ).

## Non-Goals

- Does not keep the running totals or compute the ratios itself -- see FEAT-9BQZ, whose totals every burn reads and debits
- Does not convert the outcome leg to USDC, place an order, or redeem a resolved token -- Part 6 of the audit plan adds the resolved branch at the single token-payment site
- Does not withdraw fees without closing the position -- see FEAT-U079
- Does not create positions or initialize ticks -- see FEAT-T7AF
- Does not cross ticks or move `currentTick` -- see FEAT-TVS0
- Does not transition the vault between phases -- see FEAT-JGE7 (wind-down) and FEAT-JXQO (emergency cancel)
- Does not refund an unfulfilled mint intent's escrow -- see FEAT-JAIJ
- Does not join positions -- see FEAT-K1M2
- Does not merge the vault's pairs on its own account -- see FEAT-6HBN, whose internal merge every burn calls first

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | The LP's Safe calls `burnPosition(positionId)` to close a position it owns | Gated by `position.owner == msg.sender`. Needs no Operator cooperation, signature, or registry state, in every phase, which is what makes it the escape hatch |
| Operator | Calls `burnPositionFor(lp, positionId, deadline, signature)` to relay the owner key's signed `BurnIntent` | Gas-sponsored normal path. Cannot start a burn without the owner key's signature, cannot redirect the payout, and cannot block the Safe's own `burnPosition` |

## Functional Requirements

### Shared Burn Mechanics

**FR-7G4L** `When a burn is executed through either entry point, the system shall route through one shared internal implementation that values the claim, updates tick and liquidity state, clears the position, merges the vault's complete sets, and transfers the payout.`
Fit Criterion: Given the same position and the same `currentTick`, a burn through `burnPosition` and a burn through `burnPositionFor` produce identical amounts in `PositionBurned`, identical tick state, and identical `activeLiquidity` deltas. The two entry points differ only in their authorization checks and in whether the Operator heartbeat is refreshed; no payout or accounting arithmetic is written twice.
Linked to: UC-7G41, UC-7G42

**FR-7G4M** `When a position is burned, the system shall value its claim from its liquidity, its range, its mint tick, and currentTick: one USDC per token for every level not between the mint tick and currentTick; for the band between them, one YES token per token when currentTick is below the mint tick and one NO token per token when it is above, plus the USDC that buying that token at the level's price (tick / 10000) did not spend; and no token when currentTick equals the mint tick.`
Fit Criterion: Given `L = liquidity`, `width = tickUpper - tickLower`, `m = mintTick`, `c = currentTick`, `ONE = 10000`, and `P = 1e18`: when `c < m`, the YES band is `[a, m)` with `a = max(c, tickLower)`, `band = m - a`, `tokens = L × band / P`, `Σt = band × (a + m - 1) / 2`, and `usdc = L × (width × ONE - Σt) / (ONE × P)`; when `c > m`, the NO band is `[m, b)` with `b = min(c, tickUpper)`, `band = b - m`, `tokens = L × band / P`, `Σt = band × (m + b - 1) / 2`, and `usdc = L × ((width - band) × ONE + Σt) / (ONE × P)`; when `c == m` or `band == 0`, `usdc = L × width / P` and no token. Worked example: 300 USDC over `[5500, 6500)` minted at 6000 with the vault at 5700 gives `L = 3e23`, `band = 300`, 90 YES, `Σt = 1,754,850`, and 247,354,500 USDC units (247.3545 USDC). A fuzz test compares the burn's `usdcOwed` and `tokenOwed` with a per-level loop over the band for random `L`, range, mint tick, and current tick, including a mint tick equal to `tickLower` and to `tickUpper`, within one unit.
Linked to: UC-7G41, UC-7G42

**FR-7G4N** `The system shall not place, match, or settle any order during a burn. The system shall merge the vault's complete sets through the ConditionalTokens contract before it pays, which is not a trade.`
Fit Criterion: Given a burn, no call reaches the CTF Exchange, and the only ConditionalTokens calls are `balanceOf`, `mergePositions` when the vault holds a pair, and `safeTransferFrom` for the token leg.
Linked to: UC-7G41, UC-7G42

**FR-7G4O** `When a position is burned, the system shall decrement liquidityGross on both tickLower and tickUpper by the position's liquidity, subtract the position's liquidity from liquidityNet on tickLower, add it back to liquidityNet on tickUpper, remove the position's NO sub-range from noLiquidityNet at mintTick and at tickUpper, and, when mintTick lies strictly inside the range, decrement liquidityGross on mintTick by the position's liquidity.`
Fit Criterion: Given a burn of a position with liquidity L, `ticks[tickLower].liquidityGross` decreases by L, `ticks[tickLower].liquidityNet` decreases by L, `ticks[tickUpper].liquidityGross` decreases by L, `ticks[tickUpper].liquidityNet` increases by L, `ticks[mintTick].noLiquidityNet` decreases by L and `ticks[tickUpper].noLiquidityNet` increases by L when `mintTick < tickUpper`, and `ticks[mintTick].liquidityGross` decreases by L when `tickLower < mintTick < tickUpper`, the exact inverse of the mint deltas in FEAT-T7AF FR-T7AV. The NO sub-range leaves before the boundary ticks, so a boundary tick that deinitializes already holds a zero `noLiquidityNet` (FEAT-9BQZ).
Linked to: UC-7G41, UC-7G42

**FR-7G4P** `When a boundary tick's liquidityGross reaches zero after a burn, the system shall delete that tick's state and clear its bit in the tick bitmap.`
Fit Criterion: Given the burn of the last position referencing tick T, `ticks[T]` reads zero and the bitmap bit for T reads zero, so a later `updateTick` across T crosses nothing. Given a tick still referenced by another live position, its bit stays set and its state is preserved. The bit is cleared through `_clearTickBitmapBit` (audit issue 6.15, decision C17).
Linked to: UC-7G41

**FR-7G4Q** `When the burned position was in range at burn time, the system shall decrement activeLiquidity by the position's liquidity. If the burned position was out of range, then the system shall leave activeLiquidity unchanged.`
Fit Criterion: Given `tickLower <= currentTick < tickUpper`, `activeLiquidity` decreases by exactly the position's liquidity. Given `currentTick` outside the range, `activeLiquidity` is identical before and after the call.
Linked to: UC-7G41, UC-7G42

**FR-7G4R** `When a position is burned, the system shall compute the position's accrued fees from feeGrowthInside and pay them with the USDC leg in the same call.`
Fit Criterion: Given a position that has accrued F in fees since its last collect or mint, one burn call pays the claim's USDC plus F in one USDC transfer, `PositionBurned.feesOwed == F`, and no separate `collect` is required. The product is the sixth `unchecked` fee site (ADR-8L1F in FEAT-T7AF). Given zero accrued fees, only the claim is paid.
Linked to: UC-7G41, UC-7G42

**FR-7G4S** `When a burn completes, the system shall delete the position record.`
Fit Criterion: Given a burned positionId, its stored `owner`, `tickLower`, `tickUpper`, `mintTick`, `liquidity`, `feeGrowthInsideLastX128`, and `tokensOwed` all read as zero, so no residual claim survives the burn.
Linked to: UC-7G41, UC-7G42

**FR-7G4T** `The system shall never assign a burned position's positionId to a new position.`
Fit Criterion: Given a burn of positionId N, a later mint receives an id from the monotonic `nextPositionId` counter and never N.
Linked to: UC-7G41, UC-7G42

**FR-7G4U** `When a burn pays out, the system shall send every asset, USDC and the outcome token, to the position's recorded owner.`
Fit Criterion: Given a burn through `burnPositionFor` submitted by the Operator, the entire payout lands with `position.owner` and the caller's balances are unchanged apart from gas. The recipient is read from the position record, never from `msg.sender` and never from a caller-supplied address.
Linked to: UC-7G41, UC-7G42

**FR-7G4V** `While the vault is in any phase (Active, WindDown, or Cancelled), and whether or not trading is paused, the system shall allow burns through both entry points.`
Fit Criterion: Given a vault in WindDown or in Cancelled, a burn produces the same `PositionBurned` amounts, the same tick updates, and the same `activeLiquidity` delta as the identical burn in Active phase at the same `currentTick`. The freeze keeps every record (FEAT-JXQO FR-JXQP), so an in-range burn after it subtracts its liquidity from `activeLiquidity` without underflow. Decisions C5 and C9.
Linked to: UC-7G41, UC-7G42

**FR-7G4W** `If a burn is attempted for a positionId with no owner or with zero liquidity, then the system shall revert PositionNotFound.`
Fit Criterion: Given a never-minted id, an already-burned id, or a position that `mergePositions` consumed, the call reverts `PositionNotFound` through either entry point, and no asset leaves the vault. A consumed position's liquidity already moved to a survivor; burning it would touch the ticks by zero and could clear a bit a survivor needs.
Linked to: UC-7G41

**FR-COEX** `When a burn pays, the system shall pay each asset's owed amount times that asset's ratio (FEAT-9BQZ FR-9BRM to FR-9BRR), rounded down and never above what the vault holds, debit the four totals by the position's full scaled claim and scaled fees, and never revert on the comparison.`
Fit Criterion: Given three positions owed 90 YES each and a vault that holds 150 YES, three burns in a row pay 50 YES each and their full USDC (SC-9BSD). Given one position with a claim of 247.3545 USDC plus 90 YES and a vault that holds 200 USDC above escrow and 60 YES, the burn pays 200 USDC and 60 YES, does not revert, emits `PositionBurned` with `usdcOwed = 247,354,500`, `usdcPaid = 200,000,000`, `tokenOwed = 90,000,000`, and `tokenPaid = 60,000,000`, leaves the position deleted, and takes `totalUsdcOwed()` and `totalYesOwed()` to zero. Given a vault whose USDC balance is below `totalEscrowed`, the burn pays zero USDC and does not revert. Given a vault that holds more than the claim, the burn pays the claim exactly. Decisions C6, C7, and O2 (ADR-COEY).
Linked to: UC-7G41

### Self-Service Path

**FR-7G4X** `When the position's owner calls burnPosition(positionId), the system shall execute the shared burn for that position.`
Fit Criterion: Given `position.owner == msg.sender`, the call succeeds with no Operator involvement and produces the outcomes of FR-7G4L through FR-7G4W and FR-COEX.
Linked to: UC-7G41

**FR-7G4Y** `If the caller of burnPosition is not the position's recorded owner, then the system shall revert.`
Fit Criterion: Given `position.owner != msg.sender`, the call reverts `NotPositionOwner`, the position stays live, and no asset leaves the vault. Restricting the caller is a timing-control protection: the claim depends on `currentTick` at call time (FR-7G4M), so an unrestricted caller could force an LP's exit at a moment the LP did not choose, even with the funds landing at the correct owner.
Linked to: UC-7G41

**FR-7G4Z** `The system shall make burnPosition available with no Operator action, signature, or registry read, no timelock, and no declared emergency.`
Fit Criterion: Given a vault whose entire operator set the Admin removed, and with no emergency or cancellation declared, the owner completes `burnPosition` and receives the payout. Any future change that gives this path a dependency on Operator liveness voids the guarantee that LP capital is never trapped.
Linked to: UC-7G41

**FR-7G50** `When burnPosition completes, the system shall leave lastOperatorActivityTimestamp unchanged.`
Fit Criterion: Given a successful self-service burn, `lastOperatorActivityTimestamp` reads the same value before and after. Letting LP activity refresh the silence timer would let LPs exiting a stalled vault mask a dead Operator from `emergencyCancelAll` (FEAT-JXQO FR-JXQS).
Linked to: UC-7G41

### Operator-Relayed Path

**FR-7G51** `When the Operator calls burnPositionFor(lp, positionId, deadline, signature) with the owner key's signature over BurnIntent(address lp,uint256 positionId,uint256 deadline), the system shall execute the shared burn and pay lp.`
Fit Criterion: Given a valid `BurnIntent` signed by the owner key of `lp`, the observable outcomes are identical to FR-7G4X, with the Operator paying gas and the assets going to `position.owner`.
Linked to: UC-7G42

**FR-7G52** `When verifying a burn authorization, the system shall use an EIP-712 typehash distinct from the MintIntent, ReclaimIntent, and CollectIntent typehashes.`
Fit Criterion: A signature produced over a `MintIntent`, a `ReclaimIntent`, or a `CollectIntent` is rejected by `burnPositionFor` with `InvalidSignature`, and a `BurnIntent` signature is rejected by `depositForIntent`, `reclaimDepositFor`, and `collectFor`. Without domain separation, the signature an LP produces to open a position would double as authorization to close it (FEAT-JAIJ ADR-4029).
Linked to: UC-7G42

**FR-7G53** `The system shall verify the signature with _verifySafeOwnerSignature(lp, structHash, signature) and shall revert NotPositionOwner when position.owner != lp.`
Fit Criterion: Given a missing signature, a signature over tampered fields, or a signature from a key whose derived Safe is not `lp`, the call reverts `InvalidSignature`. Given a valid signature for a Safe that does not own the position, the call reverts `NotPositionOwner`. The position stays live and no asset leaves the vault. A valid signature never proves ownership of a position; the recorded owner does (ADR-45IC).
Linked to: UC-7G42

**FR-7G54** `When verifying a burn authorization, the system shall reject signatures with s values above secp256k1n/2 and v values outside {27, 28}.`
Fit Criterion: Given a malleable signature (high-s, or `v` outside `{27, 28}`), the call reverts `InvalidSignature`, through the inline `_recoverSigner`.
Linked to: UC-7G42

**FR-7G55** `When a burn authorization is executed, the system shall record its struct hash in usedBurnAuthorizations before any external call; if the same struct hash is submitted again, the system shall revert IntentAlreadyUsed.`
Fit Criterion: Given a `BurnIntent` already consumed by a successful `burnPositionFor`, a second submission reverts `IntentAlreadyUsed` before the position check, so a replay is distinguishable from a burn of a position that never existed. The record is a separate mapping keyed by the struct hash (ADR-85DM).
Linked to: UC-7G42

**FR-7G56** `If a caller that is not a registered Operator calls burnPositionFor, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts `NotOperator` even when the caller holds a valid `BurnIntent`. The owner's own `burnPosition` stays available.
Linked to: UC-7G42

**FR-7G57** `When burnPositionFor completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given a successful relayed burn, `lastOperatorActivityTimestamp == block.timestamp` after the call; given a revert, it is unchanged. Implemented through the `touchesHeartbeat` modifier (FEAT-JXQO FR-3XTW).
Linked to: UC-7G42

**FR-BMF0** `If block.timestamp > deadline, then burnPositionFor shall revert IntentExpired.`
Fit Criterion: Given a `BurnIntent` whose `deadline` is one second in the past, the call reverts `IntentExpired`, and the same signature succeeds one second earlier. The deadline is inclusive, with Polygon's ±15 s tolerance (CLAUDE.md checklist item 12, decision C23).
Linked to: UC-7G42

## Non-Functional Requirements

**NFR-7G58** Security: `The system shall apply an inline nonReentrant modifier to both burnPosition and burnPositionFor.`
Rationale: both paths make external calls, the merge, a USDC transfer, and an ERC-1155 `safeTransferFrom` whose receiver hook hands control to the recipient. A Safe owner can replace the Safe's fallback handler, so the ERC-1155 callback is a live reentrancy surface.

**NFR-7G59** Security: `The shared burn shall run its checks and reads first (the claim, the fees, both token balances, the USDC balance, and the two amounts to pay), then the tick, bitmap, activeLiquidity, and position effects, then the merge and the transfers last, with the ERC-1155 transfer as the final call.`
Fit Criterion: the position record is deleted and both boundary ticks are updated before the first external call, so a recipient re-entering through the ERC-1155 receive hook finds no live position. The amounts are computable before the merge, because the ConditionalTokens contract pays exactly `min(yes, no)` USDC for a merge and burns that many of each token.

**NFR-7G5A** Security: `The system shall use the inline _safeTransfer helper for the USDC payout and the ConditionalTokens safeTransferFrom for the outcome-token payout, importing no SafeERC20 implementation.`

**NFR-7G5B** Availability: `burnPosition shall depend on no Operator action, no Operator signature, and no Operator registry state at execution time.`
Fit Criterion: an LP completes `burnPosition` in a vault whose entire operator set the Admin removed.

**NFR-7G5C** Gas: `When an LP burns a single position, including tick deinitialization, a merge of pairs, and both transfers, the total gas shall remain below 250,000 gas against the mock USDC.`
Rationale: measured cold on the prototype at 103,318 to 162,900 call gas, plus the 21,000 base. The forked-Polygon test in Part 6 measures the real USDC.

**NFR-7G5D** Security: `burnPositionFor shall carry an OPERATOR TRUST ASSUMPTION NatSpec block including an MEV analysis section.`
Fit Criterion: the block states that the Operator can censor, reorder, or delay a relayed exit and chooses which block it lands in, so which `currentTick` values the claim, bounded by the deadline the LP signed; that it cannot start a burn without the owner key's `BurnIntent`, cannot replay a mint, reclaim, or collect signature, cannot redirect the payout, and cannot burn a position for another Safe; and that the LP's remedy is `burnPosition`. The MEV analysis states that the burn reads a price but places no order and moves no tick, so no third party can sandwich it.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-7G41 and UC-7G42 pass against the real ConditionalTokens bytecode
- `burnPosition` and `burnPositionFor` share one internal body; no payout or accounting arithmetic appears twice
- The claim is verified at the mint tick, below it, and above it, through both entry points, and the fuzz test matches the per-level loop
- Every burn merges the vault's pairs first, and no burn path calls the CTF Exchange
- A burn pays each asset's owed amount times its ratio, debits the full owed amount, and never reverts on the comparison
- Burning the last position at a tick deletes the tick and clears its bitmap bit
- `activeLiquidity` decreases only for positions that were in range
- Accrued fees ride the USDC leg in the same call
- A burned positionId is never reassigned
- `burnPosition` succeeds with zero registered operators, with no declared emergency, and in Active and WindDown
- A non-owner cannot burn through either entry point, and a `MintIntent`, `ReclaimIntent`, or `CollectIntent` signature is rejected by `burnPositionFor`
- `burnPositionFor` refreshes `lastOperatorActivityTimestamp`; `burnPosition` does not
- OPERATOR TRUST ASSUMPTION NatSpec block with an MEV analysis present on `burnPositionFor`
- Inline nonReentrant guard on both entry points; checks-effects-interactions ordering with the ERC-1155 transfer last
- Forge fmt passes; no console.log in production code
- `forge build --sizes --skip test --skip script` exits 0
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
