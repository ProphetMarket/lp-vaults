---
id: FEAT-JAIJ
name: LP Escape Hatch
module: contracts
domain: "@positions"
status: dirty
version: 3
refs: [FEAT-T7AF, FEAT-3ZRI]
---

# LP Escape Hatch

> Refunds an LP's escrowed USDC when a signed mint intent goes unfulfilled, through a permissionless self-service path that works even when the Operator does not, plus an Operator-relayed twin for the ordinary voluntary-cancellation case.

## Non-Goals

- Does not handle direct (non-operator) LP minting -- that's a separate feature
- Does not create the escrow it refunds -- see FEAT-3ZRI
- Does not handle position burning or fee withdrawal -- see FEAT-U079
- Does not handle vault wind-down or emergency cancel -- separate features
- Does not refund gas costs or compensate for opportunity cost during the timelock wait

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Calls `reclaimDeposit` to recover their own escrowed USDC | Permissionless: needs no Operator cooperation, which is the entire point of the escape hatch. Gated by `msg.sender == lp` |
| Operator | Calls `reclaimDepositFor` to relay an LP's signed reclaim authorization | Gas-sponsored convenience path for a voluntary cancellation; cannot initiate a reclaim without the LP's signature, and cannot block the LP's own `reclaimDeposit` |

## Functional Requirements

### Reclaim Logic

**FR-JAIQ** `When the escrow entry's recorded depositor calls reclaimDeposit for an intentId that has escrowed USDC, has not been fulfilled by mintPositionFor, and whose RECLAIM_TIMELOCK has elapsed since submission, the system shall transfer the escrowed amount back to that LP, delete the escrow entry, and mark the intentId as used.`
Fit Criterion: Given a funded, unfulfilled intent past timelock reclaimed by its recorded depositor, that LP's USDC balance increases by exactly `pendingDeposits[intentId].amount`, then the escrow entry is cleared and `usedIntents[intentId] == true`. The refund amount and the recipient are both read from on-chain escrow, never from the caller-supplied `usdcAmount` or `lp`.
Linked to: UC-JAIK

**FR-3ZVM** `If a reclaim is attempted for an intentId with no escrowed USDC, then the system shall revert.`
Fit Criterion: Given no escrow entry for the intentId, both reclaim paths revert with `NothingToReclaim` and no USDC leaves the vault. This is what stops a caller who deposited nothing from draining the vault's general balance after waiting out the timelock: with no escrow entry there is nothing to pay out, regardless of what amount their signed intent claims.
Linked to: UC-JAIK, UC-3Z93

**FR-45IF** `If a reclaim is attempted for an LP who is not the escrow entry's recorded depositor, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp == A`, a `reclaimDeposit` called by B with a signature validly produced by B over the same intentId reverts with `NotIntentOwner`; the same holds for `reclaimDepositFor` submitted on B's behalf. A's escrow is untouched, A is not locked out, and no USDC leaves the vault.

This is the single most security-critical check in the feature. `reclaimDeposit` is permissionless by design, so without it the sequence is: read a pending `intentId` from the public `DepositEscrowed` log, sign your own intent over it (`_verifyMintIntent` compares the recovered signer to a caller-supplied `lp`, so any party can sign over any intentId — FEAT-3ZRI FR-45I9, ADR-45IC), wait out `RECLAIM_TIMELOCK`, and collect the victim's deposit while `usedIntents` locks them out permanently. That is an unprivileged drain of any pending deposit, and it reintroduces the exact vulnerability the escrow model was built to close.
Linked to: UC-JAIK, UC-3Z93

**FR-JAIR** `If an LP calls reclaimDeposit before RECLAIM_TIMELOCK has elapsed, then the system shall revert.`
Fit Criterion: Given an unfulfilled intent submitted T seconds ago where T < RECLAIM_TIMELOCK, the call reverts with `TimelockNotElapsed`.
Linked to: UC-JAIK

**FR-JAIS** `If an LP calls reclaimDeposit with an intentId that was already fulfilled by mintPositionFor, then the system shall revert.`
Fit Criterion: Given `usedIntents[intentId] == true`, reclaimDeposit reverts with `IntentAlreadyUsed`. A minted intent's escrow was already deleted by the mint (FEAT-T7AF FR-3ZVK), so the two paths cannot both consume it.
Linked to: UC-JAIK

### Signature Validation

**FR-3ZVN** `When an LP calls reclaimDeposit, the system shall verify the LP's EIP-712 signature over the MintIntent struct and shall not require or verify any Operator signature.`
Fit Criterion: Given a valid LP self-signed intent, the call proceeds regardless of whether any Operator has signed it, and regardless of whether the Operator who originally escrowed the deposit is still registered. Given a signature that does not recover to the named LP, the call reverts with `InvalidSignature`.
Linked to: UC-JAIK

### Operator-Relayed Reclaim

**FR-3ZVO** `When the Operator calls reclaimDepositFor with the recorded depositor's signed reclaim authorization, the system shall apply the same escrow-sourced refund, ownership check, and two-phase timelock mechanics as reclaimDeposit.`
Fit Criterion: Given a valid ReclaimIntent signed by the escrow's recorded depositor, Phase 1 records `intentTimestamps[intentId]` and Phase 2 after RECLAIM_TIMELOCK refunds `pendingDeposits[intentId].amount` to that LP, deletes the escrow entry, and marks the intentId used -- identical observable outcomes to FR-JAIQ, with the Operator paying gas and the USDC going to the recorded depositor, never to the caller and never to a different named LP.
Linked to: UC-3Z93

**FR-3ZVP** `When verifying a reclaim authorization, the system shall use an EIP-712 typehash distinct from the MintIntent typehash.`
Fit Criterion: An LP signature produced over a MintIntent struct is rejected by `reclaimDepositFor` with `InvalidSignature`, and a ReclaimIntent signature is rejected by `depositForIntent` and `mintPositionFor`. Without domain separation an Operator holding an LP's mint authorization could unilaterally cancel that LP's pending deposit, so a mint authorization must never be replayable as a reclaim authorization.
Linked to: UC-3Z93

**FR-3ZVQ** `If a caller that is not a registered Operator calls reclaimDepositFor, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts with `NotOperator`. The LP's own permissionless path (`reclaimDeposit`) remains available and is unaffected.
Linked to: UC-3Z93

**FR-3ZVR** `When reclaimDepositFor completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given a successful operator-relayed reclaim, `lastOperatorActivityTimestamp == block.timestamp` after the call; given a revert, it is unchanged. Implemented via the `touchesHeartbeat` modifier (FEAT-JXQO FR-3XTW). `reclaimDeposit` does NOT touch the heartbeat -- it is not an Operator action, and letting it refresh the silence timer would let LP activity mask a dead Operator.
Linked to: UC-3Z93

### Replay Protection

**FR-JAIU** `If a reclaim is attempted for an intentId that was already reclaimed, then the system shall revert.`
Fit Criterion: Given a previously reclaimed intentId, both `reclaimDeposit` and `reclaimDepositFor` revert (same guard as FR-JAIS -- `usedIntents` is shared), and the deleted escrow entry means there is nothing to pay out regardless.
Linked to: UC-JAIK, UC-3Z93

### Timelock Constant

**FR-JAIV** `The system shall define RECLAIM_TIMELOCK as a constant with a value documented to tolerate Polygon's block.timestamp variance (+/-15s).`
Fit Criterion: RECLAIM_TIMELOCK is a constant >= 24 hours.
Linked to: UC-JAIK, UC-3Z93

## Non-Functional Requirements

**NFR-JAIW** Security: `reclaimDeposit and reclaimDepositFor shall each use the inline nonReentrant modifier per CLAUDE.md rule 1.`

**NFR-JAIX** Security: `Signature verification on both reclaim paths shall enforce s-malleability bounds and reject v values outside {27, 28} per CLAUDE.md rule 5.`

**NFR-3Z9X** Availability: `reclaimDeposit shall depend on no Operator action, no Operator signature, and no Operator registry state at execution time.`
Fit Criterion: An LP can complete both phases of `reclaimDeposit` in a vault whose entire operator set has been removed by the Admin. This is the property that makes it an escape hatch rather than another Operator-gated path, and it also removes the failure mode where removing an operator invalidated a previously-collected co-signature.

## Acceptance

> The feature is complete when all of the following are true:

- `reclaimDeposit` returns escrowed USDC to the LP after the timelock elapses, sourcing the amount from `pendingDeposits[intentId]`
- `reclaimDeposit` takes no `operatorSignature` parameter and performs no operator-signature verification
- An intentId with no escrow cannot be reclaimed, so a caller who deposited nothing receives nothing
- **An LP cannot reclaim an escrow recorded against a different depositor, through either entry point, even holding a signature they validly produced over that intentId** (FR-45IF) -- pinned by a regression test that walks the full attack: read the intentId from the log, self-sign, wait out the timelock, and be rejected
- A reclaim deletes the escrow entry and marks the intentId used, making mint and reclaim mutually exclusive
- `reclaimDeposit` succeeds in a vault with zero registered operators
- `reclaimDepositFor` mirrors the two-phase timelock mechanics and pays the LP, not the caller
- A MintIntent signature is rejected by `reclaimDepositFor`, and a ReclaimIntent signature is rejected by the mint and deposit paths
- `reclaimDepositFor` refreshes `lastOperatorActivityTimestamp`; `reclaimDeposit` does not
- OPERATOR TRUST ASSUMPTION NatSpec block present on `reclaimDepositFor`, including an MEV-analysis note; `reclaimDeposit`'s NatSpec no longer describes an operator co-signature
- nonReentrant applied to both entry points; forge fmt passes
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
