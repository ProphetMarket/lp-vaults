---
id: UC-JGEE-001
name: start-wind-down
use_case: UC-JGEE
feature: FEAT-JGE7
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [startWindDown]
entry_type: contract-call
covers: [SC-JGEF, SC-JGEG, SC-JGEH, SC-JGEI, SC-JGEJ, SC-JGEK, FR-JGE8, FR-JGE9, FR-JGEA, FR-JGEB, FR-JGEC, NFR-JGED]
last_update: 2026-07-02
---

# UC-JGEE-001: Start Wind Down

## Rationale

Adds the `startWindDown()` function to LPVault, allowing the Oracle to transition the vault's phase from Active (1) to WindDown (2). This is the only net-new code: the phase guard on `mintPositionFor` already exists (`if (phase != 1) revert VaultNotActive()` at line 429), and `collect`/`reclaimDeposit` already have no phase restriction. The slice covers all six scenarios: successful transition (SC-JGEF), phase revert (SC-JGEG), access control revert (SC-JGEH), mint gating via `mintPositionFor` (SC-JGEI subsumed by SC-JGEJ since `mintPosition` does not exist as a function), and exit-path validation (SC-JGEK tests `collect` and `reclaimDeposit`; `burnPosition` is not yet implemented).

## Contracts

### Types

```solidity
// Phase constants (already defined inline in LPVault.sol — phase is uint8 in storage)
// Active = 1 (set in initialize)
// WindDown = 2 (set by startWindDown)

// New event
event VaultWindDownStarted(bytes32 indexed marketId);

// Existing error (reused for phase != Active guard)
error VaultNotActive();
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `startWindDown` | `function startWindDown() external` | onlyOracle | Reverts with `VaultNotActive` if `phase != 1`; reverts with `NotOracle` if caller is not Oracle via factory delegation |

### Behavior

- **Preconditions:** `phase == 1` (Active) and `msg.sender == factory.oracle()`
- **Postconditions:** `phase == 2` (WindDown); `VaultWindDownStarted(marketId)` emitted; all subsequent `mintPositionFor` calls revert with `VaultNotActive`
- **Invariants:** `phase` never transitions from 2 back to 1; no mechanism exists to reverse the wind-down
- **Error modes:** `VaultNotActive` when `phase != 1`; `NotOracle` when caller is not the Oracle

## Tests

- **SC-JGEF: Successful wind-down transition**
  - Given an Active vault (phase == 1) with at least one existing position
    - When Oracle calls `startWindDown()`
      - Then `phase` storage reads `2`
      - And `VaultWindDownStarted(marketId)` event is emitted with the vault's `marketId`
      - And no other state is modified (positions, ticks, fees unchanged)
- **SC-JGEG: Revert when phase is not Active**
  - Given a vault already in WindDown (Oracle called `startWindDown()` previously)
    - When Oracle calls `startWindDown()` again
      - Then transaction reverts with `VaultNotActive()`
- **SC-JGEH: Revert when non-Oracle calls**
  - Given an Active vault
    - When a registered Operator calls `startWindDown()`
      - Then transaction reverts with `NotOracle()`
    - When an LP address calls `startWindDown()`
      - Then transaction reverts with `NotOracle()`
    - When an arbitrary address calls `startWindDown()`
      - Then transaction reverts with `NotOracle()`
- **SC-JGEI + SC-JGEJ: Mint paths revert in WindDown**
  - Given a vault in WindDown (phase == 2) with a valid LP-signed EIP-712 mint intent
    - When Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, signature)`
      - Then transaction reverts with `VaultNotActive()`
      - And no position is created (`nextPositionId` unchanged)
      - And `intentId` is not marked as used in `usedIntents`
- **SC-JGEK: Exit paths succeed in WindDown**
  - Given a vault in WindDown with an existing LP position that has accumulated fees
    - When LP calls `collect(positionId)`
      - Then fees are transferred to LP (USDC balance increases)
      - And `tokensOwed` on the position is zeroed
      - And transaction succeeds (no revert)
  - Given a vault in WindDown with a valid unfulfilled mint intent past `RECLAIM_TIMELOCK`
    - When LP calls `reclaimDeposit(...)` with valid signatures
      - Then USDC is transferred to LP
      - And transaction succeeds (no revert)
- **FR-JGE8: Phase transition + event**
  - Covered by SC-JGEF assertions
- **FR-JGE9: Revert on non-Active phase**
  - Covered by SC-JGEG assertions
- **FR-JGEA: Non-Oracle revert**
  - Covered by SC-JGEH assertions
- **FR-JGEB: Mints revert in WindDown**
  - Covered by SC-JGEI + SC-JGEJ assertions
- **FR-JGEC: Exit paths succeed**
  - Covered by SC-JGEK assertions
- **NFR-JGED: One-way transition**
  - Covered by SC-JGEG (second call reverts) — no reverse path exists in the contract
