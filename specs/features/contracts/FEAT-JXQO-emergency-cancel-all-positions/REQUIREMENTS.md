---
id: FEAT-JXQO
name: Emergency Cancel All Positions
module: contracts
domain: "@vault"
status: implemented
version: 9
refs: [FEAT-REPZ, FEAT-JGE7, FEAT-TVS0, FEAT-7G40, FEAT-JAIJ, FEAT-6HBN]
---

# Emergency Cancel All Positions

> Safety net that lets any address freeze the vault after the Operator has been silent beyond the vault's emergency-cancel timelock. The freeze sets the phase to Cancelled, a terminal state, and changes nothing else: every position, every tick, and every total stay as they are, and every LP exit and the complete-set merge keep working, so each LP leaves in their own transaction.

## Non-Goals

- Does not pay any position or any escrow: the freeze moves no funds. Each LP exits through the burn (FEAT-7G40) or the reclaim (FEAT-JAIJ), in every phase
- Does not handle Operator key recovery -- the assumption is the Operator is permanently absent
- Does not provide a mechanism to un-cancel -- the Cancelled state is terminal
- Does not prevent an Operator that is alive but uncooperative from calling `heartbeat()` indefinitely to hold off `emergencyCancelAll` -- see ADR-3XU3
- Does not stop a fill by itself: the vault approves an order only while it is Active and not paused (decision C22, the order-maker decision ADR-BZBZ recorded in this feature and built in Part 6 of `audits/audit-fixes-ranged.md`), so a frozen vault takes no new fill while its claims are paid at the frozen tick

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Any address | Calls `emergencyCancelAll()` after operator silence | No role and no position required: the timelock is the whole condition, because the freeze moves no funds (ADR-BZBY) |

## Functional Requirements

### Emergency Cancel

**FR-JXQP** `When any address calls emergencyCancelAll() after the vault's emergency-cancel timelock has elapsed since the last Operator action, the system shall set the vault phase to Cancelled (3), change no other state, transfer no asset, and emit an EmergencyCancelExecuted event.`
Fit Criterion: Given `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock`, for any caller, with or without a position: `phase == 3`, `EmergencyCancelExecuted(caller)` is emitted, and `activeLiquidity`, `noSideLiquidity`, `currentTick`, `nextPositionId`, `totalEscrowed`, the three ledger totals of FEAT-9BQZ, every position record, every tick record, and every bitmap word are unchanged. The vault's USDC and outcome-token balances are unchanged. The call costs the same gas for any number of positions (NFR-BZBV). Decision C9.
Linked to: UC-JXQW

**FR-JXQQ** `If emergencyCancelAll() is called before the vault's emergency-cancel timelock has elapsed since the last Operator action, then the system shall revert.`
Fit Criterion: Given `block.timestamp - lastOperatorActivityTimestamp < emergencyCancelTimelock`, the call reverts `TimelockNotElapsed` and no state changes. `emergencyCancelTimelock` is the value the vault copied from the factory at `createVault` (FEAT-REPZ, FR-REQK and FR-BZC0).
Linked to: UC-JXQW

### Operator Silence Timer

**FR-JXQS** `When any Operator-gated vault function completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given the Operator successfully calls any of `depositForIntent`, `mintPositionFor`, `reclaimDepositFor`, `burnPositionFor`, `updateTick`, `mergePositions`, or `heartbeat`, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given the call reverts for any reason, `lastOperatorActivityTimestamp` is unchanged.
Linked to: UC-JXQW

**FR-3XTW** `When the Operator calls heartbeat(), the system shall reset lastOperatorActivityTimestamp to block.timestamp and change no other vault state.`
Fit Criterion: Given the Operator calls `heartbeat()`, `lastOperatorActivityTimestamp == block.timestamp` and `activeLiquidity`, `currentTick`, `nextPositionId`, `phase`, and every position and tick record are unchanged. `heartbeat()` succeeds while the vault is paused and while the vault is in WindDown, because a pause is an Admin decision about trading and a wind-down is an Oracle decision about the market, and neither says whether the Operator is alive.
Linked to: UC-JXQW

**FR-3XTX** `If any caller other than a registered Operator calls heartbeat(), then the system shall revert.`
Fit Criterion: Given an LP, Admin, Oracle, or arbitrary address calls `heartbeat()`, the call reverts with an access control error and `lastOperatorActivityTimestamp` is unchanged.
Linked to: UC-JXQW

**FR-3XTY** `If heartbeat() is called while the vault phase is Cancelled (3), then the system shall revert.`
Fit Criterion: Given `phase == 3`, `heartbeat()` reverts `VaultCancelled`. The freeze is terminal, so the silence timer has no further reader and a refresh serves no purpose.
Linked to: UC-JXQW

### Cancelled Phase Gating

**FR-JXQT** `While the vault phase is Cancelled (3), when any address calls a trading entry point, the system shall revert; every LP exit and the complete-set merge shall succeed and pay what they pay in the Active phase.`
Fit Criterion: Given `phase == 3`, calls to `mintPositionFor`, `depositForIntent`, `updateTick`, `mergePositions`, `heartbeat`, `startWindDown`, and `emergencyCancelAll` all revert (`VaultNotActive` or `VaultCancelled`). `reclaimDeposit` and `reclaimDepositFor` refund the recorded escrow (FEAT-JAIJ FR-9OYO). `burnPosition` and `burnPositionFor` pay the claim valued at the frozen `currentTick`, remove the liquidity from both ticks, and reduce `activeLiquidity` when the position is in range (FEAT-7G40 FR-7G4V). `mergeCompleteSets` merges the pairs (FEAT-6HBN FR-6HC1), and the Oracle's `redeemOutcomeTokens` redeems the tokens and sets the switch (FEAT-6HBN FR-6HC7). The freeze leaves every record in place, so a frozen vault pays exactly what a wound-down vault pays at the same tick. Decision C9.
Linked to: UC-JXQW

## Non-Functional Requirements

**NFR-JXQU** Security: `The Cancelled phase shall be a one-way terminal state with no mechanism to revert to Active or WindDown.`

**NFR-BZBV** Gas: `The execution gas of emergencyCancelAll shall not depend on the number of positions, escrows, or ticks in the vault, and shall stay below 30,000 gas on a cold vault.` The R10 build measured 9,403 call gas on a cold vault on 2026-09-14, the same figure with one position and with five (`FreezeGasTest` in the UC-JXQW test file, with `vm.cool` and `gasleft()`); the prototype with the timelock stored as `uint256` had measured 16,483. A Polygon transaction adds 21,000 base gas. Audit issue 6.11.

## Acceptance

> The feature is complete when all of the following are true:

- All UC scenarios pass with full coverage
- Any address, with or without a position, freezes the vault after the vault's emergency-cancel timelock
- Early callers (before the timelock) are rejected
- The freeze changes only the phase: `activeLiquidity`, every position, every tick, and every total are unchanged, and no asset moves
- An in-range position burns after the freeze and pays in full
- The freeze costs the same gas for any number of positions
- The vault enters the terminal Cancelled state (phase 3), every trading entry point reverts after it, and every exit and the merge succeed
- Every successful Operator-gated call (depositForIntent, mintPositionFor, reclaimDepositFor, burnPositionFor, updateTick, mergePositions, heartbeat) resets the silence timer
- A reverted Operator call leaves the silence timer untouched
- `heartbeat()` is Operator-only, changes no other state, works while paused and in WindDown, and reverts once the vault is Cancelled
- The tick invariant `invariant_activeLiquidityEqualsInRangeLiquidity` holds in phase 3
- `forge build --sizes --skip test --skip script` exits 0 and the report states both contract sizes
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
