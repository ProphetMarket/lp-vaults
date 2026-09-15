---
id: FEAT-JAIJ
name: LP Escape Hatch
module: contracts
domain: "@positions"
status: implemented
version: 4
refs: [FEAT-T7AF, FEAT-3ZRI, FEAT-REPZ, FEAT-6HBN]
---

# LP Escape Hatch

> LP-initiated recovery of the USDC escrowed against a mint intent that the Operator did not mint, in one call by the LP's Safe or one relayed call with the owner key's signature, in every vault phase.

## Non-Goals

- Does not escrow USDC -- see FEAT-3ZRI
- Does not handle position burning -- see FEAT-7G40
- Does not handle vault wind-down or emergency cancel -- separate features
- Does not wait: no timelock exists on either reclaim path (ADR-9OYQ)
- Does not refund gas costs

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | The Safe calls `reclaimDeposit` to recover its own escrowed USDC, through a Safe transaction the owner key signs | Permissionless: needs no Operator cooperation. Gated by `msg.sender == pendingDeposits[intentId].lp` |
| Operator | Calls `reclaimDepositFor` to relay the owner key's signed ReclaimIntent | Gas-sponsored path for a voluntary cancellation; cannot start a reclaim without the owner key's ReclaimIntent, and cannot block the Safe's own `reclaimDeposit` |

## Functional Requirements

### Reclaim Logic

**FR-JAIQ** `When the escrow entry's recorded Safe calls reclaimDeposit for an intentId that has escrowed USDC and has not been consumed, the system shall mark the intentId as used, delete the escrow entry, subtract its amount from totalEscrowed, and transfer that amount to the recorded Safe.`
Fit Criterion: Given an escrowed intent, the Safe's USDC balance increases by the escrowed amount, `pendingDeposits[intentId].lp == address(0)`, `totalEscrowed` falls by the amount, and `usedIntents[intentId] == true`, in one call with no wait. The refund amount and the recipient both come from the escrow record, never from a caller-supplied value.
Linked to: UC-JAIK

**FR-3ZVM** `If a reclaim is attempted for an intentId with no escrowed USDC, then the system shall revert.`
Fit Criterion: Given no escrow entry for the intentId, both reclaim paths revert with `DepositNotEscrowed` and no USDC leaves the vault. A caller who deposited nothing receives nothing, whatever it signed (audit issue 6.1).
Linked to: UC-JAIK, UC-3Z93

**FR-45IF** `If a reclaim is attempted by a caller, or for a named Safe, that is not the escrow entry's recorded Safe, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp == A`, a `reclaimDeposit` called by Safe B, by A's owner key, or by any other address reverts with `NotIntentOwner`; a `reclaimDepositFor` naming B, even with B's valid ReclaimIntent signature, reverts with `NotIntentOwner`. A's escrow is untouched and no USDC leaves the vault.

This is the most security-critical check in the feature. A valid signature does not prove who owns an intentId (FEAT-3ZRI FR-45I9, ADR-45IC), and intentIds are public in the `DepositEscrowed` log. The recorded Safe is the only ownership proof.
Linked to: UC-JAIK, UC-3Z93

**FR-JAIS** `If a reclaim is attempted for an intentId that was already consumed by mintPositionFor, then the system shall revert.`
Fit Criterion: Given `usedIntents[intentId] == true`, both reclaim paths revert with `IntentAlreadyUsed` before they read the escrow. A minted intent's escrow was already deleted by the mint (FEAT-T7AF FR-3ZVK), so the two paths cannot both consume it.
Linked to: UC-JAIK, UC-3Z93

**FR-9OYO** `While the vault is in any phase, including Cancelled, and whether or not it is paused, when a reclaim is attempted, the system shall apply no phase check and no pause check.`
Fit Criterion: Given an escrow, `reclaimDeposit` and `reclaimDepositFor` succeed when the vault is paused, after `startWindDown`, and after `emergencyCancelAll` has set phase 3. A pending deposit is never locked by a phase (audit issue 6.7).
Linked to: UC-JAIK, UC-3Z93

**FR-DU2U** `When a reclaim refunds an escrow, the system shall merge the vault's free pairs (FEAT-6HBN FR-6HBZ) into USDC before the USDC transfer, and shall pay the recorded amount unchanged.`
Fit Criterion: Given a 600 USDC escrow, a vault balance of 200 after the exchange's allowance spent 400 on a fill, and 500 free pairs, the reclaim merges 500 pairs and pays 600 in one call; with no free pair the reclaim makes no merge call and emits no `CompleteSetsMerged`. Escrow seniority (decision C7) binds burns, which read the balance less `totalEscrowed`, and not fills: the exchange holds an unlimited USDC allowance from `initialize` (FEAT-REPZ FR-REQO), so a fill can spend escrowed USDC, and the keeper must keep its quoted size below the vault's USDC balance minus `totalEscrowed`. The merge is what lets a reclaim recover without a keeper (finding CV-06 of `audits/code-validation-round-1.md`, ADR-DU2V).
Linked to: UC-JAIK, UC-3Z93

### Signature Validation

**FR-3ZVN** `When the Safe calls reclaimDeposit, the system shall verify no signature and shall authorize the refund from msg.sender alone.`
Fit Criterion: `reclaimDeposit(intentId)` takes one argument. The call proceeds when `msg.sender == pendingDeposits[intentId].lp`, regardless of any Operator state and regardless of whether the Operator that escrowed the deposit is still registered.
Linked to: UC-JAIK

### Operator-Relayed Reclaim

**FR-3ZVO** `When the Operator calls reclaimDepositFor with the owner key's signed ReclaimIntent for the recorded Safe, the system shall apply the same escrow-sourced refund and ownership check as reclaimDeposit, and shall pay the recorded Safe.`
Fit Criterion: Given a valid ReclaimIntent signed by the owner key of the escrow's recorded Safe, the refund of `pendingDeposits[intentId].amount` goes to that Safe, the escrow is deleted, `totalEscrowed` falls, and the intentId is marked used -- identical observable outcomes to FR-JAIQ, with the Operator paying gas and the USDC going to the recorded Safe, never to the caller.
Linked to: UC-3Z93

**FR-3ZVP** `When verifying a reclaim authorization, the system shall use the ReclaimIntent typehash (lp, intentId, deadline), distinct from the MintIntent typehash.`
Fit Criterion: An owner-key signature produced over a MintIntent struct is rejected by `reclaimDepositFor` with `InvalidSignature`, and a ReclaimIntent signature is rejected by `depositForIntent`. A mint authorization must never double as a cancellation (ADR-4029).
Linked to: UC-3Z93

**FR-3ZVQ** `If a caller that is not a registered Operator calls reclaimDepositFor, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts with `NotOperator`. The Safe's own `reclaimDeposit` remains available and is unaffected.
Linked to: UC-3Z93

**FR-3ZVR** `When reclaimDepositFor completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given a successful relayed reclaim, `lastOperatorActivityTimestamp == block.timestamp` after the call; given a revert, it is unchanged. Implemented via `touchesHeartbeat` (FEAT-JXQO FR-3XTW). `reclaimDeposit` does NOT touch the heartbeat: it is not an Operator action, and letting it refresh the silence timer would let LP activity mask a dead Operator.
Linked to: UC-3Z93

### Replay Protection

**FR-JAIU** `If a reclaim is attempted for an intentId that was already reclaimed, then the system shall revert.`
Fit Criterion: Given a previously reclaimed intentId, both reclaim paths revert with `IntentAlreadyUsed` (same guard as FR-JAIS -- `usedIntents` is shared, ADR-JAIY).
Linked to: UC-JAIK, UC-3Z93

## Non-Functional Requirements

**NFR-JAIW** Security: `reclaimDeposit and reclaimDepositFor shall each use the inline nonReentrant modifier per CLAUDE.md rule 1, and each shall set usedIntents, delete the escrow, and reduce totalEscrowed before the merge of the free pairs and the USDC transfer, which are the only external calls, in that order.`
Fit Criterion: the two token balances and the free pairs are read before any effect; the merge is the first interaction and the USDC transfer the last; a token that re-enters during the transfer meets the guard (the NFR-JAIW reentrancy test).

**NFR-JAIX** Security: `The owner-key signature verification on reclaimDepositFor shall enforce s-malleability bounds and reject v values outside {27, 28} per CLAUDE.md rule 5, through the shared _recoverSigner.`

**NFR-3Z9X** Availability: `reclaimDeposit shall depend on no Operator action, no Operator signature, and no Operator registry state at execution time.`
Fit Criterion: A Safe completes `reclaimDeposit` in a vault whose entire operator set the Admin removed. This is what makes it an escape hatch (audit issue 6.13).

## Acceptance

> The feature is complete when all of the following are true:

- `reclaimDeposit(intentId)` returns the escrowed USDC to the recorded Safe in one call, with no wait, sourcing the amount and the recipient from `pendingDeposits[intentId]`
- `reclaimDeposit` takes no signature and performs no signature verification
- An intentId with no escrow cannot be reclaimed, so a caller who deposited nothing receives nothing
- A Safe cannot reclaim an escrow recorded against a different Safe, through either entry point, even holding a valid signature over that intentId (FR-45IF)
- A reclaim deletes the escrow entry and marks the intentId used, so mint and reclaim are mutually exclusive
- `reclaimDeposit` succeeds in a vault with zero registered operators
- Both reclaim paths succeed while paused, in WindDown, and in Cancelled
- A reclaim merges the vault's free pairs before it pays, so a vault whose balance a fill took below its escrow still pays the full amount in one call when the free pairs cover the gap (FR-DU2U)
- `reclaimDepositFor` pays the recorded Safe, not the caller, and rejects a MintIntent signature, an expired deadline, and an owner key that derives a different Safe
- `reclaimDepositFor` refreshes `lastOperatorActivityTimestamp`; `reclaimDeposit` does not
- OPERATOR TRUST ASSUMPTION NatSpec block present on `reclaimDepositFor`, including an MEV analysis
- nonReentrant applied to both entry points; a reentrant call during the refund reverts; forge fmt passes
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
