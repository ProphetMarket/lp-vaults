---
id: FEAT-6HBN
name: Complete-Set Merge and Resolution Redemption
module: contracts
domain: "@vault"
status: implemented
version: 2
refs: [FEAT-REPZ, FEAT-JXQO, FEAT-7G40, FEAT-U079]
---

# Complete-Set Merge and Resolution Redemption

> Lets any wallet turn the vault's matched YES and NO outcome tokens into USDC held by the vault, in every phase, and gives every payout path one internal merge to call before it pays.

## Non-Goals

- Does not redeem the vault's tokens after the market resolves -- Part 6 of the audit plan builds the Oracle's `redeemOutcomeTokens` under this feature with its reserved IDs (UC-6HBP, FR-6HC4 to FR-6HC7, NFR-6HC8, ADR-6HCK), and its phase rule follows the merge's
- Does not merge inside the ERC-1155 receiver hooks -- a hook runs inside the exchange's settlement transaction, so a revert there reverts the match (ADR-3WLP)
- Does not split USDC into complete sets -- the exchange splits at fill time
- Does not value, price, or pay a claim -- see FEAT-7G40 (burn) and FEAT-U079 (collect), which call the internal merge first
- Does not change the vault phase

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Any Wallet | Calls `mergeCompleteSets()` on a vault | Any address, with or without a role. The keeper usually calls it after fills. The caller receives nothing. |

## Functional Requirements

### Complete-Set Merge

**FR-6HBZ** `When any wallet calls mergeCompleteSets, the system shall merge min(YES balance, NO balance) complete sets of the vault's condition through the ConditionalTokens contract into USDC held by the vault, and emit CompleteSetsMerged(caller, amount).`
Fit Criterion: Given the vault holds 100 YES and 60 NO, after `mergeCompleteSets()` the vault holds 40 YES, 0 NO, and 60 more USDC, and `CompleteSetsMerged(caller, 60)` is emitted. The caller receives nothing.
Linked to: UC-6HBO

**FR-6HC0** `If the vault holds no complete set when mergeCompleteSets or an internal merge runs, then the system shall return without calling mergePositions and without emitting an event.`
Fit Criterion: Given 50 YES and 0 NO, or 0 YES and 0 NO, the call does not revert, balances do not change, and no `CompleteSetsMerged` event is emitted. Every payout calls the internal merge, and a payout must never revert on it.
Linked to: UC-6HBO

**FR-6HC1** `While the vault is in any phase (Active, WindDown, or Cancelled), the system shall accept mergeCompleteSets from any wallet, whether or not trading is paused.`
Fit Criterion: The Operator, an LP's Safe, the Oracle, and an address with no role each merge successfully in every phase and while `paused == true`. The call can only turn the vault's own pairs into the vault's own USDC.
Linked to: UC-6HBO

**FR-6HC2** `When mergeCompleteSets succeeds, the system shall leave lastOperatorActivityTimestamp unchanged.`
Fit Criterion: When the Operator calls `mergeCompleteSets()`, `lastOperatorActivityTimestamp` keeps its earlier value. A refresh from any wallet would let anyone postpone `emergencyCancelAll`.
Linked to: UC-6HBO

## Non-Functional Requirements

**NFR-6HC3** Security: `mergeCompleteSets shall carry the inline nonReentrant modifier, and its NatSpec shall carry an MEV analysis block.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-6HBO pass against the real ConditionalTokens bytecode
- A merge turns complete sets into the same number of USDC, and the caller receives nothing
- A call with no complete set succeeds with no merge call and no event
- Any wallet merges in Active, WindDown, and Cancelled, and while paused, and no merge refreshes the Operator heartbeat
- The internal merge runs first in every burn and every paying collect
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
