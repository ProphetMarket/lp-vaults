---
id: UC-TOGS-001
name: notify-fees
use_case: UC-TOGS
feature: FEAT-TOGR
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [notifyFees, _mulDiv]
entry_type: contract-call
covers: [SC-TOGT, SC-TOGU, SC-TOGV, SC-TOGW, SC-TOGX, SC-TOGY, FR-TOGZ, FR-TOH0, FR-TOH1, FR-TOH2, FR-TOH3]
last_update: 2026-06-18
---

# UC-TOGS-001: Notify Fees

## Rationale

Implements `notifyFees(uint256 amount)` on LPVault — the Operator-gated entry point that increments the vault's global fee accumulator (`feeGrowthGlobalX128`) using overflow-safe Q128 fixed-point arithmetic. This is the first feature that produces nonzero fee growth and defines the Q128 math conventions (inline `_mulDiv`) that every later fee-related feature relies on. Covers all six scenarios: happy-path fee notification, sequential accumulation, and the three revert guards (zero liquidity, non-operator, zero amount), plus Q128 truncation dust behavior.

## Contracts

### Types

```solidity
// No new types — notifyFees operates on existing LPVault storage:
//   uint256 public feeGrowthGlobalX128;   // Q128 cumulative fees per unit active L
//   uint128 public activeLiquidity;        // sum of in-range position liquidity

// Event added by this slice:
event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

// Error selectors added by this slice:
error NoActiveLiquidity();
error ZeroAmount();  // may already exist from FEAT-T7AF; reuse if so
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `notifyFees` | `(uint256 amount) external onlyOperator` | onlyOperator | Reverts NoActiveLiquidity when activeLiquidity == 0; reverts ZeroAmount when amount == 0. OPERATOR TRUST ASSUMPTION NatSpec required. |
| `_mulDiv` | `(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result)` | internal | Overflow-safe multiply-then-divide; truncates downward. Inlined per pattern policy. |

### Behavior

- **Preconditions:** `activeLiquidity > 0`, `amount > 0`, `operators[msg.sender] == 1`
- **Postconditions:** `feeGrowthGlobalX128' == feeGrowthGlobalX128 + mulDiv(amount, Q128, activeLiquidity)`; `FeesNotified` event emitted with `amount` and the new `feeGrowthGlobalX128`
- **Invariants:** `feeGrowthGlobalX128` is monotonically non-decreasing; `notifyFees` never silently locks fees when `activeLiquidity == 0`; Q128 division truncates downward (dust is economically negligible)
- **Error modes:** `NoActiveLiquidity` (activeLiquidity == 0), `NotOperator` (caller not in operators mapping), `ZeroAmount` (amount == 0)

## Tests

- **SC-TOGT: successful fee notification with active liquidity**
  - Given a vault with one in-range position (activeLiquidity == L) and feeGrowthGlobalX128 == 0
    - When Operator calls notifyFees(amount)
      - Then feeGrowthGlobalX128 == mulDiv(amount, Q128, L)
      - And FeesNotified(amount, feeGrowthGlobalX128) event emitted
      - And vault USDC balance unchanged during the call (no transfers)
      - And no position-level state changes
- **SC-TOGU: sequential notifications accumulate correctly**
  - Given a vault with activeLiquidity == L
    - When Operator calls notifyFees(A) then notifyFees(B)
      - Then feeGrowthGlobalX128 == mulDiv(A, Q128, L) + mulDiv(B, Q128, L)
      - And two FeesNotified events emitted with correct cumulative feeGrowthGlobalX128 values
- **SC-TOGV: revert when no active liquidity**
  - Given a vault with activeLiquidity == 0 (no in-range positions)
    - When Operator calls notifyFees(amount) with amount > 0
      - Then call reverts with NoActiveLiquidity
      - And feeGrowthGlobalX128 unchanged
- **SC-TOGW: revert for non-Operator caller**
  - Given an address that is not a registered Operator (test with LP, Admin, Oracle, and arbitrary address)
    - When non-Operator calls notifyFees(amount)
      - Then call reverts with NotOperator
- **SC-TOGX: revert for zero amount**
  - Given a vault with activeLiquidity > 0
    - When Operator calls notifyFees(0)
      - Then call reverts with ZeroAmount
- **SC-TOGY: Q128 truncation dust behavior**
  - Given a vault with activeLiquidity == L where amount * Q128 % L != 0
    - When Operator calls notifyFees(amount)
      - Then feeGrowthGlobalX128 increment == mulDiv(amount, Q128, L) (floor division, not ceiling)
      - And increment * L / Q128 <= amount (accumulated fees never exceed notified amount)
- **FR-TOH3: mulDiv overflow safety (fuzz)**
  - Given amount large enough that amount * 2^128 would overflow uint256 but the result still fits
    - When Operator calls notifyFees(amount) with activeLiquidity > 0
      - Then call succeeds with the correct truncated result (no overflow revert)
  - Given amount = type(uint256).max where the final result would not fit in uint256
    - When Operator calls notifyFees(amount) with activeLiquidity > 0
      - Then the inline _mulDiv require trips and the call reverts with "mulDiv overflow"
