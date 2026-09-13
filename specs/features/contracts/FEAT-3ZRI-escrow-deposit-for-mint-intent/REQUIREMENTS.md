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

> Operator-gated escrow of an LP's USDC from the LP's Safe against a signed mint intent, recorded per intentId with the Safe, the amount, and the intent hash, so the mint and the reclaim spend exactly what was recorded.

## Non-Goals

- Does not offer a self-service deposit for the LP -- see FR-3Z9V and ADR-3Z9Z
- Does not create positions or touch tick state -- see FEAT-T7AF
- Does not refund escrowed USDC -- see FEAT-JAIJ for both reclaim entry points
- Does not accept a plain USDC transfer as a deposit -- see FR-9OYN
- Does not handle fee collection, position burning, wind-down, or emergency cancel -- separate features

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Executes the funding step of an LP's signed mint intent on-chain | Gated by `onlyOperator`; pulls USDC from the LP's Safe via `transferFrom` and records it under the intentId |
| LP | Signs the EIP-712 MintIntent with the Safe's owner key, and approves the vault from the Safe through a relayed Safe transaction | Never calls the vault on this path; the Safe is the USDC source and the recorded depositor |

## Functional Requirements

### Escrow Creation

**FR-3Z9M** `When the Operator submits a valid mint intent signed by the owner key of the LP's Safe, the system shall pull usdcAmount USDC from that Safe via transferFrom, record an escrow entry under intentId holding the Safe, usdcAmount, and the intent's struct hash, add usdcAmount to totalEscrowed, and emit a DepositEscrowed event.`
Fit Criterion: Given a valid intent with a matching owner-key signature and sufficient allowance from the Safe, the Safe's USDC balance decreases by usdcAmount, the vault's USDC balance increases by usdcAmount, `pendingDeposits[intentId].lp == lp`, `pendingDeposits[intentId].amount == usdcAmount`, `pendingDeposits[intentId].structHash` equals the MintIntent struct hash, `totalEscrowed` increases by usdcAmount, and a `DepositEscrowed(intentId, lp, usdcAmount)` event is emitted.
Linked to: UC-3Z92

**FR-45I9** `The system shall record the depositing Safe in the escrow entry, and shall permit only that Safe to consume the escrow.`
Fit Criterion: After a deposit for Safe A under intentId X, `pendingDeposits[X].lp == A`. Every path that consumes an escrow (`mintPositionFor`, `reclaimDeposit`, `reclaimDepositFor`) reverts with `NotIntentOwner` when the Safe it acts for is not `pendingDeposits[X].lp`.

This requirement is load-bearing. A valid signature does not prove who owns an `intentId`: any owner key can sign a MintIntent over any `intentId` that names its own Safe. The recorded Safe is the only thing that separates A's deposit from a forged claim on it, and intentIds are public in the `DepositEscrowed` log.
Linked to: UC-3Z92

**FR-3Z9N** `If depositForIntent is called with an intentId that already holds an escrow entry, or whose intentId is already recorded in usedIntents, then the system shall revert.`
Fit Criterion: Given `pendingDeposits[intentId].lp != address(0)`, a second call reverts with `DepositAlreadyEscrowed`, also when the second call names a different Safe. Given `usedIntents[intentId] == true`, the call reverts with `IntentAlreadyUsed`. In both cases no USDC moves.
Linked to: UC-3Z92

**FR-3Z9O** `If usdcAmount in a deposit intent is 0, then the system shall revert.`
Fit Criterion: Given `usdcAmount == 0`, the call reverts with `ZeroAmount`. A zero escrow could never mint, because the mint rejects a zero usdcAmount (FEAT-T7AF FR-T7B5). The "nothing escrowed" sentinel is the entry's zero `lp` address, not its amount.
Linked to: UC-3Z92

**FR-45IA** `If usdcAmount in a deposit intent exceeds the range representable by the escrow entry's amount field, then the system shall revert.`
Fit Criterion: The escrow amount is stored as `uint96` so the Safe and the amount pack into one storage slot. `uint96` holds about 7.9e28 base units, far above the USDC supply, so the bound is unreachable in practice. An inline SafeCast still reverts with `SafeCastOverflow` instead of truncating.
Linked to: UC-3Z92

**FR-3Z9P** `If the vault's phase is not Active when a deposit is attempted, then the system shall revert.`
Fit Criterion: Given a vault in WindDown or Cancelled phase, `depositForIntent` reverts with `VaultNotActive`. Given a paused vault, it reverts with `TradingIsPaused`. No USDC moves. An escrow only funds a mint, and mints are Active-only (FR-T7B4).
Linked to: UC-3Z92

**FR-9OYK** `If block.timestamp is greater than the intent's deadline when a deposit is attempted, then the system shall revert.`
Fit Criterion: Given `deadline = T`, a call at `block.timestamp = T + 1` reverts with `IntentExpired`, and a call at `block.timestamp = T` succeeds. The deadline applies once, at the deposit; the mint reads no clock (FEAT-T7AF FR-3Z9W). The check tolerates Polygon's ±15 second block timestamp variance, which the NatSpec documents.
Linked to: UC-3Z92

**FR-9OYL** `If tickLower >= tickUpper, or either tick is not a multiple of tickSpacing, or tickLower < 0, or tickUpper > PRICE_TICK_ONE, then depositForIntent shall revert.`
Fit Criterion: Given an inverted range or a range outside [0, 10000], the call reverts with `InvalidRange`. Given a misaligned tick, the call reverts with `TickNotAligned`. No USDC moves. The vault never takes USDC for an intent that the mint always rejects (ADR-BMF7 in FEAT-T7AF).
Linked to: UC-3Z92

### Escrow Accounting

**FR-9OYM** `The system shall keep totalEscrowed equal to the sum of every escrow entry's amount.`
Fit Criterion: After any sequence of deposits, mints, and reclaims, `totalEscrowed == Σ pendingDeposits[id].amount` over every intentId that was ever escrowed, and `USDC.balanceOf(vault) >= totalEscrowed`.
Linked to: UC-3Z92

**FR-9OYN** `The system shall never credit a USDC transfer that did not pass through depositForIntent to any intent.`
Fit Criterion: Given a Safe that transferred USDC to the vault directly, `mintPositionFor` for that Safe's intent reverts with `DepositNotEscrowed`, `reclaimDeposit` reverts with `DepositNotEscrowed`, and `totalEscrowed` is unchanged. A plain transfer carries no record of who paid, which is the cause of audit issues 6.1 and 6.2.
Linked to: UC-3Z92

### EIP-712 Intent Verification

**FR-3Z9Q** `When the Operator submits a deposit intent, the system shall verify the owner key's EIP-712 signature over the MintIntent typed struct (lp, tickLower, tickUpper, usdcAmount, intentId, deadline) and shall require that the Safe derived from the recovered signer equals lp.`
Fit Criterion: Given a signature from the owner key of the Safe named as `lp`, over the correct MintIntent struct and domain separator, the escrow proceeds. Given a signer whose derived Safe is not `lp`, given `lp` equal to the signer's own address, given a high-s signature, a v outside {27, 28}, a wrong length, or tampered fields, the call reverts with `InvalidSignature` and no USDC moves. The derivation is the Poly Safe factory's CREATE2 formula with the factory's `safeFactory()` and `safeProxyBytecodeHash()` (FEAT-REPZ FR-9OYI).
Linked to: UC-3Z92

### Access Control

**FR-3Z9R** `If a caller that is not a registered Operator calls depositForIntent, then the system shall revert.`
Fit Criterion: Given `operators[msg.sender] != 1`, the call reverts with `NotOperator`, even when the signature is valid. This keeps the chokepoint that stops an attacker from seeding a position ahead of a real LP's deposit (ADR-3Z9Z).
Linked to: UC-3Z92

### Operator Liveness

**FR-3Z9S** `When depositForIntent completes successfully, the system shall reset lastOperatorActivityTimestamp to block.timestamp.`
Fit Criterion: Given a successful escrow, `lastOperatorActivityTimestamp == block.timestamp` after the call. Given a revert for any reason, it is unchanged. Implemented by `touchesHeartbeat` beside `onlyOperator`, per FEAT-JXQO FR-3XTW.
Linked to: UC-3Z92

**FR-3Z9V** `The system shall not provide a permissionless direct-LP deposit entry point for escrow.`
Fit Criterion: No function lets an LP escrow its own USDC without an Operator. Nothing is pulled until `depositForIntent` runs, so an uncooperative Operator leaves the LP's USDC in the Safe. Every exit path (reclaim, and later burn and collect) has a direct-call twin, because those funds are already inside the vault.
Linked to: UC-3Z92

## Non-Functional Requirements

**NFR-3Z9T** Security: `The system shall apply an inline nonReentrant modifier to depositForIntent to prevent reentrancy via the USDC transferFrom callback.`

**NFR-3Z9U** Security: `The system shall follow checks-effects-interactions ordering in depositForIntent: verify the deadline, the signature, and the guards first, write the escrow entry and totalEscrowed second, perform the external USDC transferFrom last.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-3Z92 pass with full coverage
- A successful escrow is observable as `pendingDeposits[intentId] == (lp, usdcAmount, structHash)`, `totalEscrowed` increased, and a matching vault balance increase
- The escrow entry names its Safe, and every consuming path rejects a caller acting for any other Safe (FR-45I9)
- Escrowing the same intentId twice reverts, also when the second attempt names a different Safe; escrowing a used intentId reverts
- A zero amount, an expired deadline, an inverted range, and a misaligned tick each revert with their named error
- The two real Safe vectors (Polygon and Amoy) accept the Safe and reject the owner's own address
- A plain USDC transfer is never credited to an intent
- Non-operator callers cannot escrow, even holding a valid signature
- A successful deposit refreshes `lastOperatorActivityTimestamp`; a reverted one does not
- Inline `nonReentrant` guard applied; checks-effects-interactions ordering verified
- OPERATOR TRUST ASSUMPTION NatSpec block present on `depositForIntent`, including an MEV analysis
- The escrow invariant test (`test/invariants/EscrowAccounting.t.sol`) holds
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
