---
id: FEAT-6HBN
name: Complete-Set Merge and Resolution Redemption
module: contracts
domain: "@vault"
status: implemented
version: 4
refs: [FEAT-REPZ, FEAT-JXQO, FEAT-JGE7, FEAT-7G40, FEAT-U079, FEAT-9BQZ]
---

# Complete-Set Merge and Resolution Redemption

> Lets any wallet turn the vault's matched YES and NO outcome tokens into USDC held by the vault, in every phase, gives every payout path one internal merge to call before it pays, and lets the Oracle redeem the vault's tokens after the market resolves, which switches every later payout to USDC at the reported payout.

## Non-Goals

- Does not redeem while the vault is Active -- the Oracle calls `startWindDown` first, so no tick report can move value after the switch (ADR-6HCK)
- Does not read the payout from an argument -- the numerators come from the ConditionalTokens contract inside the call
- Does not merge inside the ERC-1155 receiver hooks -- a hook runs inside the exchange's settlement transaction, so a revert there reverts the match (ADR-3WLP)
- Does not split USDC into complete sets -- the exchange splits at fill time
- Does not value, price, or pay a claim -- see FEAT-7G40 (burn) and FEAT-U079 (collect), which call the internal merge first and, after the switch, the internal redemption
- Does not change the vault phase

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Any Wallet | Calls `mergeCompleteSets()` on a vault | Any address, with or without a role. The keeper usually calls it after fills. The caller receives nothing. |
| Oracle | Calls `redeemOutcomeTokens()` on a vault in WindDown or Cancelled | The lifecycle role. Its first successful call stores the payout the ConditionalTokens contract reported and switches every later payout to USDC. The caller receives nothing. |

## Functional Requirements

### Complete-Set Merge

**FR-6HBZ** `When any wallet calls mergeCompleteSets, the system shall merge the free pairs, min(YES balance − min(YES balance, totalYesOwed()), NO balance − min(NO balance, totalNoOwed())), as complete sets of the vault's condition through the ConditionalTokens contract into USDC held by the vault, and emit CompleteSetsMerged(caller, amount).`
Fit Criterion: Given the vault holds 100 YES and 60 NO and the ledger owes no token, after `mergeCompleteSets()` the vault holds 40 YES, 0 NO, and 60 more USDC, and `CompleteSetsMerged(caller, 60)` is emitted. Given the vault holds 150 YES and 120 NO and the ledger owes 90 YES and 60 NO, the merge takes `min(150 − 90, 120 − 60) = 60` pairs and leaves 90 YES, 60 NO, and 60 more USDC. The caller receives nothing. A pair below what the ledger owes is a claim's band token, and merging it would pay that claim a cut token leg and strand the USDC (finding CV-01 of `audits/code-validation-round-1.md`).
Linked to: UC-6HBO

**FR-6HC0** `If the vault holds no free pair when mergeCompleteSets or an internal merge runs, then the system shall return without calling mergePositions and without emitting an event.`
Fit Criterion: Given 50 YES and 0 NO, or 0 YES and 0 NO, or 90 YES and 50 NO with 90 YES owed, the call does not revert, balances do not change, and no `CompleteSetsMerged` event is emitted. Every payout calls the internal merge, and a payout must never revert on it. When either balance is zero the merge returns before it reads the ledger, because no pair can be free then.
Linked to: UC-6HBO

**FR-6HC1** `While the vault is in any phase (Active, WindDown, or Cancelled), the system shall accept mergeCompleteSets from any wallet, whether or not trading is paused.`
Fit Criterion: The Operator, an LP's Safe, the Oracle, and an address with no role each merge successfully in every phase and while `paused == true`. The call can only turn the vault's own pairs into the vault's own USDC.
Linked to: UC-6HBO

**FR-6HC2** `When mergeCompleteSets succeeds, the system shall leave lastOperatorActivityTimestamp unchanged.`
Fit Criterion: When the Operator calls `mergeCompleteSets()`, `lastOperatorActivityTimestamp` keeps its earlier value. A refresh from any wallet would let anyone postpone `emergencyCancelAll`.
Linked to: UC-6HBO

### Resolution Redemption

**FR-6HC4** `When the Oracle calls redeemOutcomeTokens while the vault phase is WindDown or Cancelled and payoutDenominator(conditionId) on the ConditionalTokens contract is non-zero, the system shall, on the first such call, copy payoutNumerators(conditionId, 0) and payoutNumerators(conditionId, 1) from the ConditionalTokens contract into vault storage, and on every such call redeem the vault's whole YES and NO balances through redeemPositions(usdc, bytes32(0), conditionId, [1, 2]) into USDC held by the vault and, when either balance was above zero, emit OutcomeTokensRedeemed(caller, yesAmount, noAmount, usdcAmount).`
Fit Criterion: Given payouts `[1, 0]`, a vault in WindDown holding 100 YES and 60 NO, after `redeemOutcomeTokens()` the vault holds 0 YES, 0 NO, and 100 more USDC, `payoutNumerators()` returns `(1, 0)`, and `OutcomeTokensRedeemed(oracle, 100e6, 60e6, 100e6)` is emitted. Given `[1, 1]`, the vault gains 80 USDC and `payoutNumerators()` returns `(1, 1)`. The numerators come from the ConditionalTokens contract inside the call and never from an argument, so the Oracle cannot set a payout.
Linked to: UC-6HBP

**FR-6HC5** `If redeemOutcomeTokens is called while payoutDenominator(conditionId) on the ConditionalTokens contract is 0, then the system shall revert MarketNotResolved.`
Fit Criterion: Given no reported result, the call reverts with `MarketNotResolved`, balances do not change, and `payoutNumerators()` stays `(0, 0)`. The vault error names the cause; the ConditionalTokens contract would otherwise revert with its own string, "result for condition not received yet".
Linked to: UC-6HBP

**FR-6HC6** `If any caller other than the Oracle calls redeemOutcomeTokens, then the system shall revert NotOracle.`
Fit Criterion: Given the result reported and the phase WindDown, the Operator, an Admin, an LP's Safe, and an address with no role each revert with `NotOracle`, and nothing changes. Lifecycle actions belong to the Oracle, and the switch changes the ratio shape for every LP, so only the lifecycle role may throw it.
Linked to: UC-6HBP

**FR-6HC7** `If redeemOutcomeTokens is called while the vault phase is Active, then the system shall revert VaultStillActive. While the vault phase is WindDown or Cancelled, the system shall accept redeemOutcomeTokens from the Oracle whether or not trading is paused, and shall accept it again after an earlier redemption, making no redeemPositions call and emitting no event when both balances are zero.`
Fit Criterion: Given the result reported and the phase Active, the call reverts `VaultStillActive` and nothing changes. After `startWindDown()` the same call succeeds. After `emergencyCancelAll()` the same call succeeds and the phase stays Cancelled. A second call with 0 YES and 0 NO succeeds, makes no `redeemPositions` call, and emits nothing. Tokens that arrive after a redemption are redeemed by the next call. `updateTick` and `mintPositionFor` revert in WindDown and Cancelled, so once the switch is on no tick report can move value between claims that are now fixed USDC, and no mint can open a claim against a resolved market.
Linked to: UC-6HBP

**FR-CYS2** `If a payout numerator read from the ConditionalTokens contract exceeds type(uint128).max, then redeemOutcomeTokens shall revert SafeCastOverflow and leave the switch off.`
Fit Criterion: Given a condition whose oracle reported `[2^128, 0]`, the call reverts `SafeCastOverflow`, `payoutNumerators()` stays `(0, 0)`, and a burn pays the token in kind. Prophet's `Resolution.sol` reports only `[1, 0]`, `[0, 1]`, and `[1, 1]`, so the path is unreachable in production; the vault stays in a safe state if it is ever reached, because every exit keeps working without the switch.
Linked to: UC-6HBP

## Non-Functional Requirements

**NFR-6HC3** Security: `mergeCompleteSets shall carry the inline nonReentrant modifier, and its NatSpec shall carry an MEV analysis block.`

**NFR-6HC8** Security: `redeemOutcomeTokens shall carry the inline nonReentrant modifier, shall read the payout numerators only from the ConditionalTokens contract and never from an argument, and shall carry an ORACLE TRUST ASSUMPTION NatSpec block with an MEV analysis section.`
Fit Criterion: the block states that the Oracle can delay the switch and cannot set the payout, cannot direct the USDC anywhere except the vault (the ConditionalTokens contract pays its caller, and the caller is the vault), and that before the switch an exit pays the winning token in kind, which the LP redeems at the ConditionalTokens contract from the Safe for the same USDC, so no LP waits on the Oracle. The MEV analysis states that the call moves value between nobody, that the switch changes the ratio shape from three ratios to one, and that the LP chooses the burn moment on both sides of it.

**NFR-CYS3** Gas: `The Oracle's first redeemOutcomeTokens call, with both tokens held and the payout to store, shall cost below 180,000 call gas against the mock USDC and the real ConditionalTokens bytecode, measured with every slot cold.`
Rationale: measured on the prototype on 2026-09-14 at 140,623 call gas with YES winning and 90 YES held (the phase read, the factory's oracle read, the result read, two numerator reads, one storage write of 22,100, two balance reads, `redeemPositions`, and the event), and 124,987 with NO winning, where the redemption pays nothing. A later call skips the storage write. Every Oracle call gets a measured bound, as `notifyFees` and `collect` have.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-6HBO and UC-6HBP pass against the real ConditionalTokens bytecode
- A merge turns complete sets into the same number of USDC, never a token a claim is owed, and the caller receives nothing
- A call with no free pair succeeds with no merge call and no event
- Any wallet merges in Active, WindDown, and Cancelled, and while paused, and no merge refreshes the Operator heartbeat
- The internal merge runs first in every burn and every paying collect before the switch, and the internal redemption after it
- The first redemption stores the payout read from the ConditionalTokens contract, and a redemption never accepts a payout argument
- A redemption reverts while Active, before the result, and for every non-Oracle caller
- A redemption with nothing to redeem makes no call and emits nothing
- Forge fmt passes; no console.log in production code
- `forge build --sizes --skip test --skip script` exits 0
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
