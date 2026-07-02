---
id: UC-JAIK-001
name: reclaim-deposit
use_case: UC-JAIK
feature: FEAT-JAIJ
objective: implement
status: implemented
files:
  create: []
  modify: [src/LPVault.sol]
depends_on: []
provides: [reclaimDeposit, intentTimestamps, RECLAIM_TIMELOCK, _verifyOperatorSignature]
entry_type: contract-call
covers: [SC-JAIL, SC-JAIM, SC-JAIN, SC-JAIO, SC-JAIP, FR-JAIQ, FR-JAIR, FR-JAIS, FR-JAIT, FR-JAIU, FR-JAIV, NFR-JAIW, NFR-JAIX]
last_update: 2026-07-02
---

# UC-JAIK-001: Reclaim Deposit

## Rationale

Implements the two-phase `reclaimDeposit` function on LPVault, allowing LPs to recover USDC when the Operator fails to fulfill a signed mint intent. Phase 1 records the reclaim submission timestamp; Phase 2 (after RECLAIM_TIMELOCK) executes the refund. Covers all five scenarios: successful reclaim (SC-JAIL), timelock-not-elapsed revert (SC-JAIM), already-fulfilled revert (SC-JAIN), invalid-operator-signature revert (SC-JAIO), and replay revert (SC-JAIP). Also covers all linked FRs and NFRs for timelock constant, signature validation, replay protection, reentrancy guard, and signature malleability bounds.

## Contracts

### Types

```solidity
// No new structs — reclaimDeposit reuses the existing MintIntent struct shape
// (lp, tickLower, tickUpper, usdcAmount, intentId) and the MINT_INTENT_TYPEHASH.

// New storage:
// mapping(bytes32 => uint256) public intentTimestamps;
// — block.timestamp when Phase 1 (reclaim submission) was called.
// — would be immutable in a non-clone contract; storage because EIP-1167.

// New constant:
// uint256 public constant RECLAIM_TIMELOCK = 24 hours;
// — ±15s Polygon block.timestamp tolerance documented at the declaration site.
```

### API Surface

| Name | Signature | Auth | Notes |
|------|-----------|------|-------|
| `reclaimDeposit` | `(address lp, int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId, bytes calldata lpSignature, bytes calldata operatorSignature) external nonReentrant` | `msg.sender == lp` + LP EIP-712 sig + operator EIP-712 sig over MintIntent | Two-phase: Phase 1 records timestamp and emits ReclaimSubmitted; Phase 2 (after RECLAIM_TIMELOCK) marks usedIntents, transfers USDC, emits DepositReclaimed |
| `_verifyOperatorSignature` | `(address lp, int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId, bytes calldata signature) internal view` | n/a | Recovers signer from EIP-712 signature over MintIntent, verifies signer is a registered operator via factory delegation. Enforces s-malleability bounds and v ∈ {27, 28} |

### Behavior

- **Preconditions:**
  - Vault is in Active phase (`phase == 1`)
  - LP has deposited USDC to the vault as part of the deposit-then-credit flow
  - `msg.sender == lp` (LP is the direct caller)
  - LP signature is valid EIP-712 over MintIntent with matching fields
  - Operator signature recovers to a registered operator address
  - `usedIntents[intentId] == false` (not fulfilled by mintPositionFor, not already reclaimed)

- **Postconditions (Phase 1 — submission):**
  - `intentTimestamps[intentId]` set to `block.timestamp`
  - `ReclaimSubmitted` event emitted
  - No USDC transferred
  - `usedIntents[intentId]` remains false

- **Postconditions (Phase 2 — execution):**
  - `usedIntents[intentId]` set to true
  - `usdcAmount` USDC transferred from vault to LP
  - `DepositReclaimed` event emitted

- **Invariants:**
  - `intentTimestamps[id]` is set exactly once and never updated
  - An intentId in `usedIntents` can never be reclaimed or fulfilled again
  - Checks-effects-interactions ordering: state mutations before `_safeTransfer`

- **Error modes:**
  - `IntentAlreadyUsed` — intentId already fulfilled or reclaimed
  - `TimelockNotElapsed` — Phase 2 called before RECLAIM_TIMELOCK elapses
  - `InvalidSignature` — LP signature invalid, operator signature invalid, malleable signature, or bad v value
  - `Reentrancy` — reentrant call detected

## Tests

- **SC-JAIL: Successful reclaim after timelock**
  - Given LP deposited USDC to vault, signed MintIntent, operator co-signed
    - When LP calls reclaimDeposit for the first time (Phase 1)
      - Then intentTimestamps[intentId] equals current block.timestamp
      - And ReclaimSubmitted event is emitted with (intentId, lp, usdcAmount)
      - And no USDC is transferred (LP balance unchanged)
      - And usedIntents[intentId] remains false
    - When LP calls reclaimDeposit again after warping past RECLAIM_TIMELOCK (Phase 2)
      - Then LP USDC balance increases by usdcAmount
      - And vault USDC balance decreases by usdcAmount
      - And usedIntents[intentId] is true
      - And DepositReclaimed event is emitted with (intentId, lp, usdcAmount)
- **SC-JAIM: Revert before timelock elapses**
  - Given Phase 1 submitted and fewer than RECLAIM_TIMELOCK seconds have elapsed
    - When LP calls reclaimDeposit
      - Then reverts with TimelockNotElapsed
- **SC-JAIN: Revert when intent already fulfilled by mintPositionFor**
  - Given operator already called mintPositionFor with this intentId (usedIntents[intentId] == true)
    - When LP calls reclaimDeposit
      - Then reverts with IntentAlreadyUsed
- **SC-JAIO: Revert on invalid operator signature**
  - Given a signature from a non-operator address
    - When LP calls reclaimDeposit
      - Then reverts with InvalidSignature
  - Given operator signature with high-s value (above SECP256K1N_HALF)
    - When LP calls reclaimDeposit
      - Then reverts with InvalidSignature
  - Given operator signature with v not in {27, 28}
    - When LP calls reclaimDeposit
      - Then reverts with InvalidSignature
- **SC-JAIP: Revert on replay (intentId already reclaimed)**
  - Given LP already completed a full reclaim cycle (Phase 1 + Phase 2) for this intentId
    - When LP calls reclaimDeposit with the same intentId
      - Then reverts with IntentAlreadyUsed
- **FR-JAIV: RECLAIM_TIMELOCK constant value**
  - Then RECLAIM_TIMELOCK is at least 86400 (24 hours in seconds)
- **NFR-JAIW: nonReentrant modifier**
  - Given a malicious ERC-20 that calls back into reclaimDeposit during Phase 2 transfer
    - When the reentrant call executes
      - Then reverts with Reentrancy
