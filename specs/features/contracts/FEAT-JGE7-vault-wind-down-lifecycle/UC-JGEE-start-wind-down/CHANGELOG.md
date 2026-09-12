TODO:

DONE:
- 20260912T211704 [implemented] command:change plan:20260912T200119-per-intent-escrow-safe-signatures-r5 — Clean the wind-down gating specs after R5: FR-JGEB and SC-JGEI named a mintPosition function that never existed. FR-JGEB now names depositForIntent and mintPositionFor, SC-JGEI is the depositForIntent revert in WindDown, SC-JGEJ names the six-argument mint on an escrowed intent and keeps the escrow reclaimable. The architecture rows follow. The IDs are unchanged.
- 20260912T200447 [implemented] command:change plan:20260912T200119-per-intent-escrow-safe-signatures-r5 — The wind-down exit paths (SC-JGEK) name reclaimDeposit(intentId) and reclaimDepositFor as the reclaims that succeed, and depositForIntent as the deposit that reverts VaultNotActive (decision C1, step R5). No other scenario changes.
- 20260702T082002 [implemented] command:spec plan:20260702T082522-start-wind-down — added UC for Oracle-driven vault wind-down lifecycle transition (Active to WindDown phase gate)
