---
id: FEAT-3ZRI
name: Escrow Deposit for Mint Intent
module: contracts
domain: "@positions"
status: implemented
version: 2
refs: [FEAT-REPZ, FEAT-T7AF, FEAT-JAIJ]
---

# Escrow Deposit for Mint Intent

> Operator-executed per-intent USDC escrow that pulls an LP's deposit into the vault against a specific signed mint intent, so that minting and reclaiming both draw on verified on-chain state instead of re-pulling or paying out unattributed funds.

## Non-Goals

- Does not create positions or touch tick state -- see FEAT-T7AF
- Does not refund escrowed USDC -- see FEAT-JAIJ for both reclaim entry points
- Does not offer a permissionless (direct-LP-wallet) deposit path -- see FR-3Z9V and ADR-3Z9Z
- Does not validate tick alignment or range width; those are enforced when the intent is minted -- see FEAT-T7AF
- Does not handle fee collection, position burning, wind-down, or emergency cancel -- separate features

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Executes the LP's signed mint intent's funding step on-chain | Gated by `onlyOperator`; pulls USDC from the LP's wallet via `transferFrom` and records it under the intentId |
| LP | Signs the EIP-712 MintIntent off-chain and approves the vault for USDC | Never calls the vault directly on this path; their wallet is the USDC source |

## Functional Requirements

### Escrow Creation

**FR-3Z9M** `When the Operator submits a valid EIP-712 mint intent signed by an LP, the system shall pull usdcAmount USDC from the LP's wallet via transferFrom, record an escrow entry under intentId holding both the depositing LP's address and usdcAmount, and emit a DepositEscrowed event.`
Fit Criterion: Given a valid intent with a matching LP signature and sufficient allowance, the LP's USDC balance decreases by usdcAmount, the vault's USDC balance increases by usdcAmount, `pendingDeposits[intentId].lp == lp`, `pendingDeposits[intentId].amount == usdcAmount`, and a `DepositEscrowed(intentId, lp, usdcAmount)` event is emitted.
Linked to: UC-3Z92

**FR-45I9** `The system shall record the depositing LP's address in the escrow entry, and shall permit only that address to consume the escrow.`
Fit Criterion: After a deposit by LP A under intentId X, `pendingDeposits[X].lp == A`. Every path that consumes an escrow (`mintPositionFor`, `reclaimDeposit`, `reclaimDepositFor`) reverts with `NotIntentOwner` when the LP it is acting for is not `pendingDeposits[X].lp`.

This requirement is load-bearing and is the reason the escrow entry is a struct rather than a bare amount. An `intentId` is **not** bound to an LP by the signature scheme: `_verifyMintIntent` recovers a signer and compares it to a caller-supplied `lp` parameter, so any party can produce a signature that verifies over any `intentId` simply by signing with their own key and naming their own address. Without the recorded owner, an attacker who reads an `intentId` out of the public `DepositEscrowed` log can sign their own intent over it and claim another LP's escrow — via `reclaimDeposit`, which is permissionless by design, that is an unprivileged drain of any pending deposit.
Linked to: UC-3Z92

**FR-3Z9N** `If depositForIntent is called with an intentId that already holds an escrow entry, or whose intentId is already recorded in usedIntents, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp != address(0)`, a second call reverts with `DepositAlreadyEscrowed` — including when the second caller names a different LP, so an intentId cannot be straddled by two depositors. Given `usedIntents[intentId] == true` (already minted or already reclaimed), the call reverts with `IntentAlreadyUsed`. In both cases no USDC moves.
Linked to: UC-3Z92

**FR-3Z9O** `If usdcAmount in a deposit intent is 0, then the system shall revert.`
Fit Criterion: Given `usdcAmount == 0`, the call reverts with `ZeroAmount`. A zero-value escrow could never be minted, because minting rejects a zero usdcAmount (FEAT-T7AF FR-T7B5), so it could only ever be unwound through the reclaim timelock. Rejecting it up front keeps every escrow entry in the mapping spendable. Note that the "nothing escrowed" sentinel is the entry's zero `lp` address, not its amount.
Linked to: UC-3Z92

**FR-45IA** `If usdcAmount in a deposit intent exceeds the range representable by the escrow entry's amount field, then the system shall revert.`
Fit Criterion: The escrow amount is stored as `uint96` so the entry packs into a single storage slot alongside the 20-byte LP address. `uint96` holds ~7.9e28 base units, or ~7.9e22 USDC at 6 decimals — many orders of magnitude above the token's total supply — so the bound is unreachable in practice. It is still enforced with an inline SafeCast that reverts with `SafeCastOverflow` rather than truncating, because a silent truncation would record an escrow smaller than the USDC actually collected.
Linked to: UC-3Z92

**FR-3Z9P** `If the vault's phase is not Active when a deposit is attempted, then the system shall revert.`
Fit Criterion: Given a vault in WindDown or Cancelled phase, `depositForIntent` reverts with `VaultNotActive` and no USDC moves. Escrow only funds mints, and mints are Active-only (FR-T7B4), so escrowing into a non-Active vault could only ever strand funds until reclaim.
Linked to: UC-3Z92

### EIP-712 Intent Verification

**FR-3Z9Q** `When the Operator submits a deposit intent, the system shall verify the LP's EIP-712 signature over the same MintIntent typed struct used by mintPositionFor, containing lp, tickLower, tickUpper, usdcAmount, and intentId.`
Fit Criterion: Given a valid signature from the LP's private key over the correct MintIntent struct and domain separator, the escrow proceeds. Given any other signer, tampered fields, a high-s signature, or a v outside {27, 28}, the call reverts with `InvalidSignature` and no USDC moves. The same signature therefore authorizes both the escrow and the later mint -- the LP signs once.
Linked to: UC-3Z92

### Access Control

**FR-3Z9R** `If a caller that is not a registered Operator calls depositForIntent, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts with `NotOperator`, even when the LP signature is valid. This preserves the project-wide chokepoint that keeps an attacker from seeding a position ahead of a real LP's deposit (ADR-3Z9Z).
Linked to: UC-3Z92

### Operator Liveness

**FR-3Z9S** `When depositForIntent completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given the Operator successfully escrows a deposit, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given the call reverts for any reason, `lastOperatorActivityTimestamp` is unchanged. Implemented by stacking the `touchesHeartbeat` modifier alongside `onlyOperator`, per FEAT-JXQO's FR-3XTW.
Linked to: UC-3Z92

## Non-Functional Requirements

**NFR-3Z9T** Security: `The system shall apply an inline nonReentrant modifier to depositForIntent to prevent reentrancy via the USDC transferFrom callback.`

**NFR-3Z9U** Security: `The system shall follow checks-effects-interactions ordering in depositForIntent: verify the signature and the escrow/used-intent guards first, write pendingDeposits[intentId] second, perform the external USDC transferFrom last.`

**FR-3Z9V** Availability: `The system shall not provide a permissionless direct-LP deposit entry point for escrow.`
Fit Criterion: No function exists that lets an LP escrow their own USDC without an Operator. This is deliberate and is the one place the codebase's "every value path needs a permissionless escape hatch" rule does not apply: nothing is pulled until `depositForIntent` runs, so an uncooperative Operator leaves the LP's funds untouched in their own wallet. There is nothing to rescue. Every *exit* path (burn, collect, reclaim) still gets a direct-call twin because those funds are already inside the vault.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-3Z92 pass with full coverage
- A successful escrow is observable as `pendingDeposits[intentId].lp == lp`, `.amount == usdcAmount`, and a matching vault balance increase
- The escrow entry names its depositor, and every consuming path rejects a caller acting for any other LP (FR-45I9)
- Escrowing the same intentId twice reverts, including when the second attempt names a different LP; escrowing an already-minted or already-reclaimed intentId reverts
- Zero-amount escrow reverts, so `pendingDeposits`'s zero sentinel stays unambiguous
- Non-operator callers cannot escrow, even holding a valid LP signature
- The LP signature verified here is byte-identical to the one `mintPositionFor` verifies -- one LP signature covers both steps
- A successful deposit refreshes `lastOperatorActivityTimestamp`; a reverted one does not
- Inline `nonReentrant` guard applied; checks-effects-interactions ordering verified
- OPERATOR TRUST ASSUMPTION NatSpec block present on `depositForIntent`, including an MEV-analysis note
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
