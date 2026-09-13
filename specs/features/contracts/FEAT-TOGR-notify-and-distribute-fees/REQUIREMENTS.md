---
id: FEAT-TOGR
name: Notify and Distribute Fees
module: contracts
domain: "@fees"
status: implemented
version: 2
refs: [FEAT-T7AF]
---

# Notify and Distribute Fees

> Enables the Operator to distribute newly arrived fee revenue across all in-range LP positions by incrementing the vault's global Q128 fee accumulator proportionally to active liquidity, while the vault takes that revenue from the Operator wallet in the same call.

## Non-Goals

- Does not handle tick crossing or `feeGrowthOutsideX128` updates -- see feature 4 (@ticks)
- Does not handle per-position fee computation (`feeGrowthInside`) or collection (`tokensOwed`) -- see feature 5 (@positions, @fees)
- Does not handle the off-chain USDC sweep from CTF Exchange to the Operator wallet -- Operator responsibility before calling `notifyFees`, which then takes the swept USDC from that wallet
- Does not handle vault lifecycle transitions -- see feature 8 (@vault)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Calls `notifyFees(amount)`, which takes `amount` USDC from the Operator wallet in the same call | Gated by `onlyOperator` modifier; multiple operator wallets allowed; each wallet holds the swept USDC and a standing USDC approval to each vault it reports to |

## Functional Requirements

### Fee Accumulator Update

**FR-TOGZ** `When the Operator calls notifyFees(amount), the system shall increment feeGrowthGlobalX128 by mulDiv(amount, 2^128, activeLiquidity) and emit a FeesNotified event with amount and the new feeGrowthGlobalX128.`
Fit Criterion: Given activeLiquidity > 0 and amount > 0, feeGrowthGlobalX128 increases by exactly mulDiv(amount, Q128, activeLiquidity), and a FeesNotified(amount, feeGrowthGlobalX128) event is emitted.
Linked to: UC-TOGS

### Fee Funding

**FR-ASNL** `When the Operator calls notifyFees(amount), the system shall transfer amount USDC from the caller to the vault with transferFrom, after it increments feeGrowthGlobalX128 and before it emits FeesNotified.`
Fit Criterion: Given a funded and approved Operator wallet, one `notifyFees(amount)` call raises the vault's USDC balance by `amount`, lowers the caller's balance by `amount`, and increments `feeGrowthGlobalX128` by `mulDiv(amount, Q128, activeLiquidity)`, all in one transaction. The USDC contract's `Transfer(caller, vault, amount)` log precedes the `FeesNotified` log.
Linked to: UC-TOGS

**FR-ASNM** `If the USDC transferFrom from the caller fails when notifyFees is called, then the system shall revert with TransferFailed and leave feeGrowthGlobalX128 unchanged.`
Fit Criterion: Given a caller with no USDC balance, or with a balance but no approval, `notifyFees(amount)` reverts with `TransferFailed`, and `feeGrowthGlobalX128`, `lastOperatorActivityTimestamp`, and both USDC balances are unchanged after the call.
Linked to: UC-TOGS

### Safety Guards

**FR-TOH0** `If activeLiquidity == 0 when notifyFees is called, then the system shall revert to prevent silently locking fees in the contract.`
Fit Criterion: Given activeLiquidity == 0, notifyFees(amount) reverts with a NoActiveLiquidity error regardless of amount.
Linked to: UC-TOGS

**FR-TOH1** `If a non-Operator address calls notifyFees, then the system shall revert.`
Fit Criterion: Given any address not in the operators mapping, notifyFees(amount) reverts with a NotOperator error.
Linked to: UC-TOGS

**FR-TOH2** `If amount == 0 when notifyFees is called, then the system shall revert.`
Fit Criterion: Given amount == 0, notifyFees(0) reverts with a ZeroAmount error.
Linked to: UC-TOGS

### Overflow Protection

**FR-TOH3** `While computing the feeGrowthGlobalX128 increment, the system shall use an inline mulDiv to perform overflow-safe Q128 multiplication and division, truncating downward.`
Fit Criterion: Given amount * 2^128 would overflow uint256 in a naive multiply, the mulDiv produces the correct truncated result without overflow. The Q128 arithmetic produces the same value as (amount * 2^128) / activeLiquidity computed with unbounded precision, truncated toward zero.
Linked to: UC-TOGS

## Non-Functional Requirements

**NFR-TOH4** Gas: `When the Operator calls notifyFees, the total gas cost shall remain below 50,000 gas on Polygon.`
Superseded by NFR-ASNP: the 50,000 bound predates the USDC pull that `notifyFees` performs since decision C19.

**NFR-TOH5** Security: `The system shall use inline mulDiv (overflow-safe multiply-then-divide) for the Q128 fee accumulator increment to prevent uint256 overflow on the intermediate amount * 2^128 product.`

**NFR-TOH6** Security: `OPERATOR TRUST ASSUMPTION -- The Operator is trusted to have deposited at least amount USDC into the vault before calling notifyFees. The contract does not verify the vault's USDC balance. An Operator who calls notifyFees without funding it creates an accounting mismatch. This matches the CTF Exchange trust model.`
Superseded by NFR-ASNO: the vault now takes the USDC inside `notifyFees`; it still performs no balance check (decision C6).

**NFR-ASNN** Security: `The system shall run notifyFees under the inline reentrancy guard and shall follow checks-effects-interactions: validate phase, amount, and activeLiquidity first, increment feeGrowthGlobalX128 second, transfer USDC last.` The guard is new here, because `notifyFees` made no external call before decision C19. `CLAUDE.md` checklist item 1 requires it on every external state-changing function that performs a token transfer, and the collect feature states the same rule for `collect` (NFR-U07R).

**NFR-ASNO** Security: `OPERATOR TRUST ASSUMPTION -- The Operator funds every fee report in the same call: notifyFees takes amount USDC from the Operator wallet, so the Operator cannot credit income it did not pay. The Operator can still under-report: the vault cannot know what the exchange earned off-chain, so a report smaller than the true income, or no report at all, stays inside the trust model. The Operator's trading authority over the vault's balance through the exchange approval is a separate trust assumption (CLAUDE.md checklist item 11).` Supersedes NFR-TOH6 (decision C19, 2026-09-11).

**NFR-ASNP** Gas: `When the Operator calls notifyFees against the ERC-20 mock in the test suite, the call gas shall stay below 80,000.` The bound is measured against the mock (`test/fixtures/MockERC20.sol`), whose `transferFrom` is three storage writes. The real USDC contract on Polygon costs more per `transferFrom` than the mock, and the forked-Polygon test in Part 6 of the audit plan measures it. Supersedes NFR-TOH4, whose 50,000 bound predates the USDC pull; the prototype measured a median of 65,750 gas on 2026-09-13. The user chose 80,000 on 2026-09-13.

**NFR-ASNQ** Operations: `Each Operator wallet shall hold a standing USDC approval to each vault it reports fees to, granted when the vault is onboarded to the keeper.`
Fit Criterion: a vault whose Operator wallet gave no approval reverts on the first `notifyFees` with `TransferFailed`, which is the expected failure mode. The recommended grant is a max approval to the vault, as `initialize()` grants to the exchange, because the vault pulls only inside `notifyFees`, which the Operator itself calls with the amount it chose. `DEPLOYMENT.md` names the step, and Part 6 of the audit plan lists it as work outside this repository.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-TOGS pass with full coverage
- Non-operator callers cannot notify fees (SC-TOGW)
- Notification with activeLiquidity == 0 reverts (security checklist item 9, SC-TOGV)
- Q128 overflow protection verified via fuzz test with large amounts
- Q128 truncation dust behavior documented and tested (SC-TOGY)
- An unfunded call (no balance, or no approval) reverts with `TransferFailed` and leaves `feeGrowthGlobalX128` unchanged (SC-ASNK)
- A funded call moves `amount` USDC from the Operator wallet to the vault in the same transaction (SC-TOGT)
- The backing invariant `invariant_feeCreditsAreBacked` in `test/invariants/FeeGrowthAccounting.t.sol` passes
- Inline mulDiv used (no library import)
- OPERATOR TRUST ASSUMPTION NatSpec present on notifyFees, in the narrowed form (NFR-ASNO)
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
