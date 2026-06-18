---
id: FEAT-TOGR
name: Notify and Distribute Fees
module: contracts
domain: "@fees"
status: implemented
version: 1
refs: [FEAT-T7AF]
---

# Notify and Distribute Fees

> Enables the Operator to distribute newly arrived fee revenue across all in-range LP positions by incrementing the vault's global Q128 fee accumulator proportionally to active liquidity.

## Non-Goals

- Does not handle tick crossing or `feeGrowthOutsideX128` updates -- see feature 4 (@ticks)
- Does not handle per-position fee computation (`feeGrowthInside`) or collection (`tokensOwed`) -- see feature 5 (@positions, @fees)
- Does not handle the off-chain USDC sweep from CTF Exchange to vault -- Operator responsibility before calling `notifyFees`
- Does not handle vault lifecycle transitions -- see feature 8 (@vault)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Calls `notifyFees(amount)` after depositing fee revenue as USDC into the vault | Gated by `onlyOperator` modifier; multiple operator wallets allowed; responsible for ensuring USDC is in the vault before calling |

## Functional Requirements

### Fee Accumulator Update

**FR-TOGZ** `When the Operator calls notifyFees(amount), the system shall increment feeGrowthGlobalX128 by mulDiv(amount, 2^128, activeLiquidity) and emit a FeesNotified event with amount and the new feeGrowthGlobalX128.`
Fit Criterion: Given activeLiquidity > 0 and amount > 0, feeGrowthGlobalX128 increases by exactly mulDiv(amount, Q128, activeLiquidity), and a FeesNotified(amount, feeGrowthGlobalX128) event is emitted.
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

**NFR-TOH5** Security: `The system shall use inline mulDiv (overflow-safe multiply-then-divide) for the Q128 fee accumulator increment to prevent uint256 overflow on the intermediate amount * 2^128 product.`

**NFR-TOH6** Security: `OPERATOR TRUST ASSUMPTION -- The Operator is trusted to have deposited at least amount USDC into the vault before calling notifyFees. The contract does not verify the vault's USDC balance. An Operator who calls notifyFees without funding it creates an accounting mismatch. This matches the CTF Exchange trust model.`

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-TOGS pass with full coverage
- Non-operator callers cannot notify fees (SC-TOGW)
- Notification with activeLiquidity == 0 reverts (security checklist item 9, SC-TOGV)
- Q128 overflow protection verified via fuzz test with large amounts
- Q128 truncation dust behavior documented and tested (SC-TOGY)
- Inline mulDiv used (no library import)
- OPERATOR TRUST ASSUMPTION NatSpec present on notifyFees
- Forge fmt passes; no console.log in production code
- Coverage gate met against `.molcajete/settings.json` `testing.threshold`
- FEATURES.md status is `implemented`
