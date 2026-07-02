---
id: FEAT-JAIJ
name: LP Escape Hatch
module: contracts
domain: "@positions"
status: implemented
version: 1
refs: [FEAT-T7AF]
---

# LP Escape Hatch

> LP-initiated USDC recovery when the Operator fails to fulfill a signed mint intent within the RECLAIM_TIMELOCK period.

## Non-Goals

- Does not handle direct (non-operator) LP minting -- that's a separate feature
- Does not handle position burning or fee withdrawal -- see FEAT-U079
- Does not handle vault wind-down or emergency cancel -- separate features
- Does not refund gas costs or compensate for opportunity cost during the timelock wait

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| LP | Calls reclaimDeposit to recover USDC | Must present the same signed intent used in the deposit-then-credit flow |
| Operator | Implicitly involved: failure to call mintPositionFor triggers the reclaim path | The operator signature on the intent proves the operator acknowledged the deposit |

## Functional Requirements

### Reclaim Logic

**FR-JAIQ** `When an LP calls reclaimDeposit with a valid signed intent whose intentId has not been fulfilled by mintPositionFor and the RECLAIM_TIMELOCK has elapsed since the intent was submitted, the system shall transfer the intent's usdcAmount back to the LP and mark the intentId as used.`
Fit Criterion: Given a valid unfulfilled intent past timelock, the LP's USDC balance increases by usdcAmount and `usedIntents[intentId] == true`.
Linked to: UC-JAIK

**FR-JAIR** `If an LP calls reclaimDeposit before RECLAIM_TIMELOCK has elapsed, then the system shall revert.`
Fit Criterion: Given an unfulfilled intent submitted T seconds ago where T < RECLAIM_TIMELOCK, the call reverts.
Linked to: UC-JAIK

**FR-JAIS** `If an LP calls reclaimDeposit with an intentId that was already fulfilled by mintPositionFor, then the system shall revert.`
Fit Criterion: Given `usedIntents[intentId] == true`, reclaimDeposit reverts.
Linked to: UC-JAIK

### Signature Validation

**FR-JAIT** `If an LP calls reclaimDeposit with an invalid operator signature, then the system shall revert.`
Fit Criterion: Given a signature that does not recover to a registered operator address, the call reverts.
Linked to: UC-JAIK

### Replay Protection

**FR-JAIU** `If an LP calls reclaimDeposit with an intentId that was already reclaimed, then the system shall revert.`
Fit Criterion: Given a previously reclaimed intentId, the call reverts (same guard as FR-JAIS -- usedIntents is shared).
Linked to: UC-JAIK

### Timelock Constant

**FR-JAIV** `The system shall define RECLAIM_TIMELOCK as a constant with a value documented to tolerate Polygon's block.timestamp variance (+/-15s).`
Fit Criterion: RECLAIM_TIMELOCK is a constant >= 24 hours.
Linked to: UC-JAIK

## Non-Functional Requirements

**NFR-JAIW** Security: `reclaimDeposit shall use the inline nonReentrant modifier per CLAUDE.md rule 1.`

**NFR-JAIX** Security: `The operator signature verification shall enforce s-malleability bounds and reject v values outside {27, 28} per CLAUDE.md rule 5.`

## Acceptance

> The feature is complete when all of the following are true:

- reclaimDeposit successfully returns USDC to LP after timelock elapses
- All 5 revert scenarios are tested (early call, already fulfilled, invalid sig, replay)
- Replay protection shares the existing usedIntents mapping
- EIP-712 signature validation matches the existing _verifyMintIntent pattern
- nonReentrant applied; forge fmt passes
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
