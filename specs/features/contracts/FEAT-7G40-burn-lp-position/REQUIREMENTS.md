---
id: FEAT-7G40
name: Burn LP Position
module: contracts
domain: "@positions"
status: implemented
version: 8
refs: [FEAT-T7AF, FEAT-TVS0, FEAT-JGE7, FEAT-6HBN, FEAT-3ZRI, FEAT-9BQZ, FEAT-E943]
---

# Burn LP Position

> LP-initiated closure of a position, in one call by the LP's Safe or one relayed call with the owner key's signature, that credits the measured spread before it values anything, settles the vault's tokens (the merge before the switch, the redemption after it), values the claim from its mint tick under decision C26, removes the position's liquidity from both ticks, and pays the Safe USDC, the position's spread, and one outcome token before the switch, or USDC only after it, each owed amount times its ratio from the solvency ledger (FEAT-9BQZ), with the last live position also taking the residue.

## Non-Goals

- Does not keep the running totals or compute the ratios itself -- see FEAT-9BQZ, whose totals every burn reads and debits
- Does not place an order, and does not convert the outcome leg to USDC before the switch -- after the Oracle's redemption (FEAT-6HBN UC-6HBP) the burn redeems the vault's tokens first and pays the token leg in USDC at the reported payout, see FR-CYS4
- Does not create positions or initialize ticks -- see FEAT-T7AF
- Does not cross ticks or move `currentTick` -- see FEAT-TVS0
- Does not transition the vault between phases -- see FEAT-JGE7 (wind-down) and FEAT-JXQO (emergency cancel)
- Does not refund an unfulfilled mint intent's escrow -- see FEAT-JAIJ
- Does not join positions -- see FEAT-K1M2
- Does not merge the vault's free pairs on its own account -- see FEAT-6HBN, whose internal merge every burn calls first with the number the burn computed
- Does not measure or attribute the spread -- FEAT-E943 owns the measurement, the growth accumulator, and the closing sweep's attribution rule, and the burn is one of its four credit sites

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | The LP's Safe calls `burnPosition(positionId)` to close a position it owns | Gated by `position.owner == msg.sender`. Needs no Operator cooperation, signature, or registry state, in every phase, which is what makes it the escape hatch |
| Operator | Calls `burnPositionFor(lp, positionId, deadline, signature)` to relay the owner key's signed `BurnIntent` | Gas-sponsored normal path. Cannot start a burn without the owner key's signature, cannot redirect the payout, and cannot block the Safe's own `burnPosition` |

## Functional Requirements

### Shared Burn Mechanics

**FR-7G4L** `When a burn is executed through either entry point, the system shall route through one shared internal implementation that reads both token balances and the free pairs, credits the measured surplus to the liquidity in range with the exiting position still counted, values the claim and the position's spread, updates tick and liquidity state, debits the four totals, clears the position, merges the vault's complete sets, and transfers the payout.`
Fit Criterion: Given the same position and the same `currentTick`, a burn through `burnPosition` and a burn through `burnPositionFor` produce identical amounts in `PositionBurned`, `spreadOwed` and `spreadPaid` included, identical tick state, and identical `activeLiquidity` deltas. The credit is written before the claim is read, so a position that exits while spread is uncredited receives its share. The two entry points differ only in their authorization checks and in whether the Operator heartbeat is refreshed; no payout or accounting arithmetic is written twice.
Linked to: UC-7G41, UC-7G42

**FR-7G4M** `When a position is burned, the system shall value its claim from its liquidity, its range, its mint tick, and currentTick: one USDC per token for every level not between the mint tick and currentTick; for the band between them, one YES token per token when currentTick is below the mint tick and one NO token per token when it is above, plus the USDC that buying that token at the level's price (tick / 10000) did not spend; and no token when currentTick equals the mint tick.`
Fit Criterion: Given `L = liquidity`, `width = tickUpper - tickLower`, `m = mintTick`, `c = currentTick`, `ONE = 10000`, and `P = 1e18`: when `c < m`, the YES band is `[a, m)` with `a = max(c, tickLower)`, `band = m - a`, `tokens = L × band / P`, `Σt = band × (a + m - 1) / 2`, and `usdc = L × (width × ONE - Σt) / (ONE × P)`; when `c > m`, the NO band is `[m, b)` with `b = min(c, tickUpper)`, `band = b - m`, `tokens = L × band / P`, `Σt = band × (m + b - 1) / 2`, and `usdc = L × ((width - band) × ONE + Σt) / (ONE × P)`; when `c == m` or `band == 0`, `usdc = L × width / P` and no token. Worked example: 300 USDC over `[5500, 6500)` minted at 6000 with the vault at 5700 gives `L = 3e23`, `band = 300`, 90 YES, `Σt = 1,754,850`, and 247,354,500 USDC units (247.3545 USDC). A fuzz test compares the burn's `usdcOwed` and `tokenOwed` with a per-level loop over the band for random `L`, range, mint tick, and current tick, including a mint tick equal to `tickLower` and to `tickUpper`, within one unit.
Linked to: UC-7G41, UC-7G42

**FR-7G4N** `The system shall not place, match, or settle any order during a burn. The system shall merge the vault's complete sets through the ConditionalTokens contract before it pays, which is not a trade.`
Fit Criterion: Given a burn, no call reaches the CTF Exchange, and the only ConditionalTokens calls are `balanceOf`, then before the switch `mergePositions` when the vault holds a pair and `safeTransferFrom` for the token leg, and after the switch `redeemPositions` when the vault holds a token.
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

**FR-7G4S** `When a burn completes, the system shall delete the position record.`
Fit Criterion: Given a burned positionId, its stored `owner`, `tickLower`, `tickUpper`, `mintTick`, and `liquidity` all read as zero, so no residual claim survives the burn.
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

**FR-COEX** `When a burn pays, the system shall pay each asset's owed amount times that asset's ratio (FEAT-9BQZ FR-9BRM to FR-9BRR), and the position's spread times the USDC ratio, rounded down and never above what the vault holds, debit the four totals by the position's full scaled claim and full scaled spread, and never revert on the comparison.`
Fit Criterion: Given three positions owed 90 YES each and a vault that holds 150 YES, three burns in a row pay 50 YES each and their full USDC (SC-9BSD). Given one position with a claim of 247.3545 USDC plus 90 YES and a vault that holds 200 USDC above escrow and 60 YES, the burn pays 200 USDC and 60 YES, does not revert, emits `PositionBurned` with `usdcOwed = 247,354,500`, `usdcPaid = 200,000,000`, `tokenOwed = 90,000,000`, and `tokenPaid = 60,000,000`, leaves the position deleted, and takes `totalUsdcOwed()` and `totalYesOwed()` to zero. Given a vault whose USDC balance is below `totalEscrowed`, the burn pays zero USDC and does not revert. Given a vault that holds more than the claim, the burn pays the claim exactly. Decisions C6, C7, and O2 (ADR-COEY). Given the round trip of SC-E94P, `PositionBurned` reports `usdcOwed = usdcPaid = 300,000,000` and `spreadOwed = spreadPaid = 1,200,000`, and the vault holds `totalEscrowed` afterwards. The spread is prorated as `_prorate(usdcOwed + spreadOwed) − _prorate(usdcOwed)`, so the two USDC legs sum to one floor and one transfer. After the switch, the three amounts share one USDC ratio and one transfer (FEAT-9BQZ FR-CYS5): the burn prorates `usdcOwed + spreadOwed + tokenUsdc` once, reports `usdcPaid` as the prorated `usdcOwed`, `spreadPaid` as the next part, and `tokenPaid` as the rest, so their sum never exceeds what the vault holds, even after a saturated ledger debit.
Linked to: UC-7G41

**FR-CYS4** `When a burn runs while payoutNumerators() is non-zero, the system shall redeem the vault's whole YES and NO balances through the ConditionalTokens contract before it pays, value the band's token leg at tokenOwed × the side's numerator ÷ the numerators' sum in USDC, rounded down, pay the claim's USDC, the position's spread, and the token leg's USDC at the one USDC ratio of FEAT-9BQZ in one USDC transfer, make no ERC-1155 transfer, and report the token leg's USDC as PositionBurned.tokenPaid.`
Fit Criterion: Given the R9 example (300 USDC over `[5500, 6500)` minted at 6000, the vault at 5700, so the claim is 247,354,500 USDC units plus 90 YES), the vault holding 90 YES, and the Oracle's redemption after `[1, 0]`: the burn pays 337,354,500 USDC units in one transfer and emits `PositionBurned(id, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)`, with no `TransferSingle` from the ConditionalTokens contract. After `[0, 1]`: 247,354,500 USDC units and `tokenPaid = 0`. After `[1, 1]`: 292,354,500 USDC units and `tokenPaid = 45000000`. Given the result reported and the switch off, the burn pays 247,354,500 USDC units and 90 YES in kind, as before the resolution. Given 5 YES and 5 NO that arrived after the Oracle's redemption, the burn redeems them first and emits `OutcomeTokensRedeemed(safe, 5e6, 5e6, 5e6)` before `PositionBurned`. The event carries nine fields, with `spreadOwed` and `spreadPaid` after `usdcPaid`. The USDC is in the vault, and one transfer costs less than one transfer plus an ERC-1155 transfer.
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

**FR-7G52** `When verifying a burn authorization, the system shall use an EIP-712 typehash distinct from the MintIntent and ReclaimIntent typehashes.`
Fit Criterion: A signature produced over a `MintIntent` or a `ReclaimIntent` is rejected by `burnPositionFor` with `InvalidSignature`, and a `BurnIntent` signature is rejected by `depositForIntent` and `reclaimDepositFor`. Without domain separation, the signature an LP produces to open a position would double as authorization to close it (FEAT-JAIJ ADR-4029).
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

**NFR-7G59** Security: `A burn shall read both token balances, the switch, the free pairs, and the USDC balance once, before any effect; then credit the measured surplus; then value the claim, the spread, and the amounts to pay from the values already read; then write the tick, bitmap, activeLiquidity, ledger, and position effects; then run the settlement call and the transfers last: before the switch the merge, the USDC transfer, and the ERC-1155 transfer as the final call; after the switch the redemption and then the USDC transfer as the final call.`
Fit Criterion: a burn calls `balanceOf` once on USDC and twice on the ConditionalTokens contract, and the credit is the only effect before the valuation, which is why the old wording that forbade every effect before the valuation is replaced rather than kept. The position record is deleted and both boundary ticks are updated before the first external call, so a recipient re-entering through the ERC-1155 receive hook finds no live position. The amounts are computable before the merge, because the burn computes the free pairs from view reads before any effect and the ConditionalTokens contract pays exactly that many USDC and burns that many of each token; the merge receives the number the burn computed, never a fresh read, because after the ledger debit the exiting position's own band would count as free (FEAT-6HBN ADR-DFE2). After the switch the amounts are computable before the redemption, because `redeemPositions` pays exactly `balance × numerator ÷ denominator` per side, rounded down, which `_atPayout` reproduces.

**NFR-7G5A** Security: `The system shall use the inline _safeTransfer helper for the USDC payout, the ConditionalTokens safeTransferFrom for an outcome-token payout before the switch, and the ConditionalTokens redeemPositions after it, importing no SafeERC20 implementation.`

**NFR-7G5B** Availability: `burnPosition shall depend on no Operator action, no Operator signature, and no Operator registry state at execution time.`
Fit Criterion: an LP completes `burnPosition` in a vault whose entire operator set the Admin removed.

**NFR-7G5C** Gas: `When an LP burns a single position, including tick deinitialization, the spread credit, a merge of pairs, the closing sweep, and every transfer, the call gas measured cold against the mock USDC and the real ConditionalTokens bytecode shall remain below 320,000.`
Rationale: measured cold on 2026-09-15 on the R18 build, with `optimizer_runs` at 100 (ADR-E94X): 290,703 for a burn before the switch that merges 50 free pairs and pays both legs, and 275,272 for a burn after the switch that redeems 5 YES and 5 NO that arrived late. The R17 build measured 246,913 and 233,488 for the same two burns at `optimizer_runs` 200, so this step adds about 44,000 and about 42,000. Where it goes: three balance reads, the credit's two storage writes and its event, the spread claim's two tick reads, and the sweep's own transfers. Every earlier figure in this requirement was measured at 200 runs and is not comparable to the two above; the ones kept here are the history of the bound, not of this build. Measured cold on the R13 prototype on 2026-09-14: 203,449 for a burn before the switch that pays USDC plus YES in kind, 167,974 after the switch with nothing to redeem, and 233,488 after the switch redeeming late tokens. Re-measured on the R14 build: 246,913 with a merge of 50 free pairs. Measured on the R17 build: 125,295 paying all USDC and 169,320 paying USDC plus YES. The forked-Polygon test in Part 6 measures the real USDC.

**NFR-7G5D** Security: `burnPositionFor shall carry an OPERATOR TRUST ASSUMPTION NatSpec block including an MEV analysis section.`
Fit Criterion: the block states that the Operator can censor, reorder, or delay a relayed exit and chooses which block it lands in, so which `currentTick` values the claim, bounded by the deadline the LP signed; that it cannot start a burn without the owner key's `BurnIntent`, cannot replay a mint or reclaim signature, cannot redirect the payout, and cannot burn a position for another Safe; and that the LP's remedy is `burnPosition`. The MEV analysis states that the burn reads a price but places no order and moves no tick, so no third party can sandwich it.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-7G41 and UC-7G42 pass against the real ConditionalTokens bytecode
- `burnPosition` and `burnPositionFor` share one internal body; no payout or accounting arithmetic appears twice
- The claim is verified at the mint tick, below it, and above it, through both entry points, and the fuzz test matches the per-level loop
- Every burn settles first (the merge before the switch, the redemption after it), and no burn path calls the CTF Exchange
- A burn credits the measured spread before it values the claim, pays each asset's owed amount times its ratio before the switch, and one USDC amount at one ratio after it, debits the full owed amount on all four totals, and never reverts on the comparison
- An exit is final: the record is deleted with its spread snapshot, the vault owes that position nothing, and the last live position's burn pays every USDC above escrow and every remaining token, reporting the excess in `ResidueSwept`
- After the switch a burn pays the winning leg at par, the losing leg nothing, and a cancelled market's leg at half, in one USDC transfer with no ERC-1155 transfer; before the switch it pays the token in kind, resolved or not
- Burning the last position at a tick deletes the tick and clears its bitmap bit
- `activeLiquidity` decreases only for positions that were in range
- A burned positionId is never reassigned
- `burnPosition` succeeds with zero registered operators, with no declared emergency, and in Active and WindDown
- A non-owner cannot burn through either entry point, and a `MintIntent` or `ReclaimIntent` signature is rejected by `burnPositionFor`
- `burnPositionFor` refreshes `lastOperatorActivityTimestamp`; `burnPosition` does not
- OPERATOR TRUST ASSUMPTION NatSpec block with an MEV analysis present on `burnPositionFor`
- Inline nonReentrant guard on both entry points; checks-effects-interactions ordering with the ERC-1155 transfer last before the switch and the USDC transfer last after it
- Forge fmt passes; no console.log in production code
- `forge build --sizes --skip test --skip script` exits 0
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
