---
id: UC-U07A-001
name: collect-fees
use_case: UC-U07A
feature: FEAT-U079
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [collect, _safeTransfer]
entry_type: contract-call
covers: [SC-U07B, SC-U07C, SC-U07D, SC-U07E, SC-U07F, SC-U07G, FR-U07H, FR-U07I, FR-U07J, FR-U07K, FR-U07L, FR-U07M, FR-U07N, FR-U07O]
last_update: 2026-06-18
---

# UC-U07A-001: Collect Fees

## Rationale

Implements the `collect(uint256 positionId)` function on LPVault — the read-side of the v3 fee math. This slice closes all 6 scenarios of UC-U07A: the happy-path collect with accrued fees, the zero-fee no-op, access-control reverts (non-owner and invalid position), phase-independent collection during wind-down, and the anti-double-counting proof via sequential collects. The entire feature converges to one external function and one new internal helper (`_safeTransfer`), both in `src/LPVault.sol`.

## Contracts

### Types

```solidity
// Event emitted on successful collect with nonzero owed amount
event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

// Custom errors
error NotPositionOwner();
error PositionNotFound();
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `collect` | `(uint256 positionId) external nonReentrant` | `position.owner == msg.sender` | Computes owed fees via `_computeFeeGrowthInside`, updates snapshot, transfers USDC. No phase restriction. |
| `_safeTransfer` | `(address token, address to, uint256 amount) internal` | n/a | Push-direction ERC-20 transfer handling bool/non-bool returns (USDT semantics). Mirrors `_safeTransferFrom` pattern. |

### Behavior

- **Preconditions:** Position with `positionId` must exist (owner != address(0)). Caller must be `position.owner`.
- **Postconditions:** `position.feeGrowthInsideLastX128 == _computeFeeGrowthInside(tickLower, tickUpper)`. If owed > 0, vault USDC balance decreased by owed and LP USDC balance increased by owed. If owed == 0, no USDC transfer.
- **Invariants:** `collect` never modifies `position.liquidity`, `position.tickLower`, `position.tickUpper`, any tick state, `activeLiquidity`, or `feeGrowthGlobalX128`. It is purely read-side on fee accumulators + write on the position snapshot + USDC payout.
- **Error modes:** `NotPositionOwner` — caller is not the position owner. `PositionNotFound` — positionId maps to a zero-initialized position struct.

## Tests

- **SC-U07B: first collect with accrued fees**
  - Given a vault with an in-range position (tickLower <= currentTick < tickUpper) and notifyFees called with a known amount
    - When the position owner calls collect(positionId)
      - Then the LP receives the correct owed USDC (liquidity * feeGrowthDelta / Q128)
      - And position.feeGrowthInsideLastX128 equals current _computeFeeGrowthInside(tickLower, tickUpper)
      - And a FeesCollected event is emitted with the correct positionId, owner, and amount
      - And the vault's USDC balance decreases by the owed amount
      - And position.liquidity, tickLower, tickUpper remain unchanged
- **SC-U07C: zero fees owed**
  - Given a vault with a position and no notifyFees calls since mint
    - When the position owner calls collect(positionId)
      - Then no USDC is transferred (vault and LP balances unchanged)
      - And no FeesCollected event is emitted
      - And the transaction succeeds (no revert)
- **SC-U07D: non-owner caller rejected**
  - Given a valid position owned by address A
    - When address B (B != A) calls collect(positionId)
      - Then the transaction reverts with NotPositionOwner
- **SC-U07E: position not found**
  - Given a positionId that does not correspond to any minted position
    - When any caller calls collect(positionId)
      - Then the transaction reverts with PositionNotFound
- **SC-U07F: collect during wind-down**
  - Given a vault in WindDown phase with a position that has accumulated fees
    - When the position owner calls collect(positionId)
      - Then the LP receives the owed USDC (same computation as Active phase)
      - And a FeesCollected event is emitted
      - And the vault phase remains WindDown
- **SC-U07G: second collect only pays new fees**
  - Given a position that was collected once, then additional fees distributed via notifyFees
    - When the position owner calls collect(positionId) a second time
      - Then the LP receives only the fees accrued since the first collect (delta, not total)
      - And position.feeGrowthInsideLastX128 is updated to the new current value
      - And a FeesCollected event is emitted with the delta amount only
- **FR-U07H: feeGrowthInside computation correctness**
  - Given varying tick positions (current tick below range, inside range, above range)
    - Then _computeFeeGrowthInside returns the correct value per the v3 formula: global - below(lower) - above(upper)
- **FR-U07I: Q128 fee calculation**
  - Given known liquidity and feeGrowthInside delta
    - Then owed = liquidity * delta / Q128, truncated toward zero
- **FR-U07R: checks-effects-interactions ordering**
  - Given a collect call that transfers USDC
    - Then the position snapshot is updated before the external USDC transfer (verifiable via reentrancy test or ordering assertion)
