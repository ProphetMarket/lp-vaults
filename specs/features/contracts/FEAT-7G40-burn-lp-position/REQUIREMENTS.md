---
id: FEAT-7G40
name: Burn LP Position
module: contracts
domain: "@positions"
status: implemented
version: 1
refs: [FEAT-T7AF, FEAT-U079, FEAT-TVS0, FEAT-JGE7]
---

# Burn LP Position

> Closes an LP's concentrated-liquidity position and returns what that position actually holds -- USDC, outcome tokens, or a split of both, plus accrued fees -- through an Operator-relayed normal path and a self-service path that never depends on the Operator.

## Non-Goals

- Does not specify the shortfall ratio or haircut applied at payout, nor the vault-wide owed-amount ledger those ratios read -- the dual-asset withdrawal rewrite owns that machinery and will revise this feature when it lands
- Does not auto-convert outcome tokens to USDC, and does not place, match, or settle any order on the CTF Exchange on the LP's behalf
- Does not withdraw fees without closing the position -- see FEAT-U079
- Does not create positions or initialize ticks -- see FEAT-T7AF
- Does not cross ticks or move `currentTick` -- see FEAT-TVS0
- Does not transition the vault between phases -- see FEAT-JGE7 (wind-down) and FEAT-JXQO (emergency cancel)
- Does not refund an unfulfilled mint intent's escrow -- see FEAT-JAIJ
- Does not merge or split positions -- see FEAT-K1M2
- Does not redeem outcome tokens against the resolved market; that is the LP's own 1:1 call to the Conditional Tokens contract, outside this vault

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Calls `burnPosition(positionId)` to close a position they own | Gated by `position.owner == msg.sender`. Permissionless with respect to the Operator: needs no Operator cooperation, signature, or registry state, which is what makes it the escape hatch |
| Operator | Calls `burnPositionFor(positionId, lpSignature)` to relay an LP's signed burn authorization | Gas-sponsored normal path, matching the mint/deposit experience for LPs who authenticate by email and hold no gas. Cannot initiate a burn without the owner's signature, and cannot block the owner's own `burnPosition` |

## Functional Requirements

### Shared Burn Mechanics

**FR-7G4L** `When a burn is executed through either entry point, the system shall route through one shared internal implementation that computes the owed amounts, updates tick and liquidity state, transfers the payout, and clears the position.`
Fit Criterion: Given the same position and the same `currentTick`, a burn through `burnPosition` and a burn through `burnPositionFor` produce identical asset amounts, identical tick state, and identical `activeLiquidity` deltas. The two entry points differ only in their authorization checks and in whether the Operator heartbeat is refreshed; no payout or accounting arithmetic is written twice, so the two paths cannot drift.
Linked to: UC-7G41, UC-7G42

**FR-7G4M** `When a position is burned, the system shall determine the payout composition from currentTick relative to the position's [tickLower, tickUpper] range: entirely USDC when currentTick is below the range, entirely outcome tokens when currentTick is at or above the range, and a split of both when currentTick is inside the range.`
Fit Criterion: Given `currentTick < tickLower`, the LP receives USDC and zero outcome tokens. Given `currentTick >= tickUpper`, the LP receives outcome tokens and zero USDC principal. Given `tickLower <= currentTick < tickUpper`, the LP receives a nonzero amount of each, mirroring Uniswap v3's `burn()` math. The payout is not a fixed USDC promise -- a position's exit composition is a function of where the market sits, not of what was deposited.
Linked to: UC-7G41, UC-7G42

**FR-7G4N** `The system shall not trade, swap, or otherwise convert a position's outcome tokens to USDC during a burn.`
Fit Criterion: Given a burn of an above-range or in-range position, no call is made to the CTF Exchange and no order is placed; the outcome tokens are transferred to the LP as-is. Auto-converting would reintroduce a dependency on a willing counterparty at exactly the moment liquidity is thinnest -- the failure mode the dual-asset model exists to remove. The LP disposes of outcome tokens on their own terms: sell through the exchange subject to market depth, or hold to resolution and redeem 1:1 through the Conditional Tokens contract, which needs no counterparty at all.
Linked to: UC-7G41, UC-7G42

**FR-7G4O** `When a position is burned, the system shall decrement liquidityGross on both tickLower and tickUpper by the position's liquidity, subtract the position's liquidity from liquidityNet on tickLower, and add it back to liquidityNet on tickUpper.`
Fit Criterion: Given a burn of a position with liquidity L, `ticks[tickLower].liquidityGross` decreases by L, `ticks[tickLower].liquidityNet` decreases by L, `ticks[tickUpper].liquidityGross` decreases by L, and `ticks[tickUpper].liquidityNet` increases by L -- the exact inverse of the mint deltas in FEAT-T7AF FR-T7AV.
Linked to: UC-7G41, UC-7G42

**FR-7G4P** `When a boundary tick's liquidityGross reaches zero after a burn, the system shall delete that tick's state and clear its bit in the tick bitmap.`
Fit Criterion: Given the burn of the last position referencing tick T, `ticks[T]` is cleared and the bitmap bit for T reads zero, so subsequent `updateTick` traversals skip T instead of crossing a tick with no liquidity behind it. Given a tick still referenced by another live position, its bit stays set and its state is preserved.
Linked to: UC-7G41

**FR-7G4Q** `When the burned position was in range at burn time, the system shall decrement activeLiquidity by the position's liquidity. If the burned position was out of range, then the system shall leave activeLiquidity unchanged.`
Fit Criterion: Given `tickLower <= currentTick < tickUpper`, `activeLiquidity` decreases by exactly the position's liquidity. Given `currentTick` outside the range, `activeLiquidity` is byte-identical before and after the call.
Linked to: UC-7G41, UC-7G42

**FR-7G4R** `When a position is burned, the system shall compute the position's accrued fees from feeGrowthInside and pay them out in the same call as the principal.`
Fit Criterion: Given a position that has accrued F in fees since its last collect or mint, a single burn call pays out both the principal composition of FR-7G4M and F, and no separate `collect` is required to recover the fees. Given a burn of a position with zero accrued fees, only the principal is paid.
Linked to: UC-7G41, UC-7G42

**FR-7G4S** `When a burn completes, the system shall zero the position record.`
Fit Criterion: Given a burned positionId, its stored `owner`, `tickLower`, `tickUpper`, `liquidity`, `feeGrowthInsideLastX128`, and `tokensOwed` all read as zero, so no residual claim survives the burn.
Linked to: UC-7G41, UC-7G42

**FR-7G4T** `The system shall never assign a burned position's positionId to a new position.`
Fit Criterion: Given a burn of positionId N, a subsequent mint assigns an id drawn from the monotonically increasing `nextPositionId` counter and never N. Reuse would let a stale off-chain reference or a stale signed authorization resolve to a different LP's position.
Linked to: UC-7G41, UC-7G42

**FR-7G4U** `When a burn pays out, the system shall send every asset -- USDC, outcome tokens, and fees -- to the position's recorded owner.`
Fit Criterion: Given a burn through `burnPositionFor` submitted by the Operator, the entire payout lands with `position.owner` and the caller's balances are unchanged apart from gas. The recipient is read from the position record, never from `msg.sender` and never from a caller-supplied address.
Linked to: UC-7G41, UC-7G42

**FR-7G4V** `While the vault is in Active or WindDown phase, the system shall allow burns through both entry points.`
Fit Criterion: Given a vault in WindDown, a burn produces the same payout composition, the same tick updates, and the same `activeLiquidity` delta as the identical burn in Active phase. Exit paths staying open through wind-down is FEAT-JGE7 FR-JGEC; this is the burn half of that guarantee, previously unimplementable because no burn function existed.
Linked to: UC-7G41, UC-7G42

**FR-7G4W** `If a burn is attempted for a positionId that does not correspond to a live position, then the system shall revert.`
Fit Criterion: Given a positionId that was never minted, or one already burned and therefore zeroed by FR-7G4S, the call reverts with a `PositionNotFound` error through either entry point, and no assets leave the vault.
Linked to: UC-7G41

### Self-Service Path

**FR-7G4X** `When the position's owner calls burnPosition(positionId), the system shall execute the shared burn for that position.`
Fit Criterion: Given `position.owner == msg.sender`, the call succeeds with no Operator involvement and produces the outcomes of FR-7G4L through FR-7G4V.
Linked to: UC-7G41

**FR-7G4Y** `If the caller of burnPosition is not the position's recorded owner, then the system shall revert.`
Fit Criterion: Given `position.owner != msg.sender`, the call reverts with a `NotPositionOwner` error, the position remains live, and no assets leave the vault. Restricting the caller is a timing-control protection, not only a theft protection: because payout composition depends on `currentTick` at call time (FR-7G4M), an unrestricted caller could force an LP's exit at an adversarially chosen moment and lock them into a split they never chose, even with the funds landing at the correct owner.
Linked to: UC-7G41

**FR-7G4Z** `The system shall make burnPosition available unconditionally -- not gated behind a declared emergency, an Operator action, an Operator signature, or any Operator registry state.`
Fit Criterion: Given a vault whose entire operator set has been removed by the Admin, and with no emergency or cancellation declared, the owner completes `burnPosition` and receives their payout. This requirement is the actual mechanism behind the protocol's guarantee that LP capital is not trapped when the Operator becomes unresponsive or hostile; any future change that gives this path a dependency on Operator liveness voids that guarantee.
Linked to: UC-7G41

**FR-7G50** `When burnPosition completes, the system shall leave lastOperatorActivityTimestamp unchanged.`
Fit Criterion: Given a successful self-service burn, `lastOperatorActivityTimestamp` reads the same value before and after. `burnPosition` is not an Operator action, and letting LP activity refresh the silence timer would let LPs exiting a stalled vault mask a dead Operator from `emergencyCancelAll` (FEAT-JXQO FR-JXQS) -- the same reasoning that keeps `reclaimDeposit` off the heartbeat (FEAT-JAIJ FR-3ZVR).
Linked to: UC-7G41

### Operator-Relayed Path

**FR-7G51** `When the Operator calls burnPositionFor with the position owner's signed burn authorization, the system shall execute the same shared burn and pay the owner.`
Fit Criterion: Given a valid BurnIntent signed by `position.owner`, the observable outcomes are identical to FR-7G4X -- same payout composition, same tick updates, same `activeLiquidity` delta -- with the Operator paying gas and the assets going to the owner.
Linked to: UC-7G42

**FR-7G52** `When verifying a burn authorization, the system shall use an EIP-712 typehash distinct from the MintIntent and ReclaimIntent typehashes.`
Fit Criterion: A signature produced over a MintIntent or a ReclaimIntent struct is rejected by `burnPositionFor` with `InvalidSignature`, and a BurnIntent signature is rejected by `depositForIntent`, `mintPositionFor`, and `reclaimDepositFor`. Without domain separation, the signature an LP produces to open a position would double as authorization to close it, letting an Operator holding that one signature unilaterally exit the LP at a moment of the Operator's choosing. This follows the reasoning already recorded for `reclaimDepositFor` in FEAT-JAIJ ADR-4029, which names `burnPositionFor` explicitly.
Linked to: UC-7G42

**FR-7G53** `If the burn authorization does not recover to the position's recorded owner, then the system shall revert.`
Fit Criterion: Given a missing signature, a signature over tampered fields, or a signature from any signer other than `position.owner`, the call reverts with `InvalidSignature`, the position remains live, and no assets leave the vault. Operator authority alone never closes a position.
Linked to: UC-7G42

**FR-7G54** `When verifying a burn authorization, the system shall reject signatures with s values above secp256k1n/2 and v values outside {27, 28}.`
Fit Criterion: Given a malleable signature (high-s, or `v` outside `{27, 28}`), the call reverts with `InvalidSignature`. A malleable signature would otherwise yield a second distinct encoding of the same authorization, defeating the replay guard of FR-7G55.
Linked to: UC-7G42

**FR-7G55** `When a burn authorization is executed, the system shall record its unique identifier. If the same authorization is submitted again, then the system shall revert.`
Fit Criterion: Given a burn authorization already consumed by a successful `burnPositionFor`, a second submission of the same authorization reverts with an already-used error rather than being absorbed silently by the zeroed position record. The replay guard is checked and set before any external call, per CLAUDE.md rule 4.
Linked to: UC-7G42

**FR-7G56** `If a caller that is not a registered Operator calls burnPositionFor, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts with `NotOperator` even when the caller holds a genuinely valid owner-signed burn authorization. The owner's own `burnPosition` (FR-7G4X) remains available and is unaffected by this gate.
Linked to: UC-7G42

**FR-7G57** `When burnPositionFor completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given a successful operator-relayed burn, `lastOperatorActivityTimestamp == block.timestamp` after the call; given a revert, it is unchanged. Implemented via the `touchesHeartbeat` modifier (FEAT-JXQO FR-3XTW), which FEAT-JXQO FR-3XTY already names `burnPositionFor` as a future consumer of.
Linked to: UC-7G42

## Non-Functional Requirements

**NFR-7G58** Security: `The system shall apply an inline nonReentrant modifier to both burnPosition and burnPositionFor.`
Rationale: both paths perform external calls -- a USDC ERC-20 transfer and an ERC-1155 `safeTransferFrom` whose `onERC1155Received` hook hands control to the recipient. The ERC-1155 callback makes this a live reentrancy surface, not defense-in-depth.

**NFR-7G59** Security: `The system shall follow checks-effects-interactions ordering in the shared burn implementation: validate authorization and the position first; then update position, tick, bitmap, and activeLiquidity state; then transfer USDC and outcome tokens last.`
Fit Criterion: the position record is zeroed and both boundary ticks are updated before the first token transfer, so a recipient reentering through the ERC-1155 receive hook finds no live position and no residual claim.

**NFR-7G5A** Security: `The system shall use the inline _safeTransfer helper for the USDC payout and the CTF contract's safeTransferFrom for the outcome-token payout, importing no SafeERC20 implementation.`

**NFR-7G5B** Availability: `burnPosition shall depend on no Operator action, no Operator signature, and no Operator registry state at execution time.`
Fit Criterion: an LP completes `burnPosition` in a vault whose entire operator set has been removed by the Admin. This is the property that makes it an escape hatch rather than another Operator-gated path.

**NFR-7G5C** Gas: `When an LP burns a single position, including tick deinitialization and both asset transfers, the total gas cost shall remain below 250,000 gas on Polygon.`

**NFR-7G5D** Security: `burnPositionFor shall carry an OPERATOR TRUST ASSUMPTION NatSpec block including an MEV analysis section, matching the style of ProphetCTFExchange.sol.`
Fit Criterion: the block states what the Operator can do (choose the block in which a held burn authorization executes, and therefore the `currentTick` that sets the payout composition under FR-7G4M) and what the LP must trust, and names `burnPosition` as the LP's unilateral remedy.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-7G41 and UC-7G42 pass with full coverage
- `burnPosition` and `burnPositionFor` share one internal implementation; no payout or accounting arithmetic appears twice
- Payout composition is verified at all three positions of `currentTick` relative to the range, through both entry points
- No burn path calls the CTF Exchange or converts outcome tokens to USDC
- Burning the last position at a tick deletes the tick and clears its bitmap bit
- `activeLiquidity` decreases only for positions that were in range
- Accrued fees are paid in the same call as principal
- A burned positionId is never reassigned
- **`burnPosition` succeeds in a vault with zero registered operators, in a vault with no declared emergency, and in both Active and WindDown phases** (FR-7G4Z, NFR-7G5B) -- pinned by a regression test that removes every operator through the Admin path before burning
- A non-owner cannot burn through either entry point, and a MintIntent or ReclaimIntent signature is rejected by `burnPositionFor`
- A BurnIntent signature is rejected by `depositForIntent`, `mintPositionFor`, and `reclaimDepositFor`
- `burnPositionFor` refreshes `lastOperatorActivityTimestamp`; `burnPosition` does not
- OPERATOR TRUST ASSUMPTION NatSpec block with an MEV analysis present on `burnPositionFor`
- Inline nonReentrant guard on both entry points; checks-effects-interactions ordering verified against the ERC-1155 receive hook
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
