TODO:

DONE:
- 20260915T041747 [implemented] command:change plan:20260915T041517-remove-lp-fee-accounting-r17 — The fee accounting left the vault, so the pause gates lose notifyFees and the open exits name burnPosition in place of collect: FR-K1MF lists three gated functions, FR-K1MI names burnPosition (proven by FEAT-7G40 SC-7G49 case C), SC-K1ML drops the notifyFees step, SC-K1MM probes with updateTick, and SC-K1MO (collect while paused) is retired with its test. Source: exploration 20260915T041240-remove-lp-fee-accounting-r17.
- 20260912T200447 [implemented] command:change plan:20260912T200119-per-intent-escrow-safe-signatures-r5 — The paused exit paths gain the relayed reclaim and lose the timelock: FR-K1MI names reclaimDeposit by the recorded Safe and reclaimDepositFor by the Operator, and depositForIntent joins the trading entry points that revert TradingIsPaused. SC-K1MP now calls reclaimDeposit(intentId) on an escrow with no wait (decision C1, step R5).
- 20260702T155901 [implemented] command:spec plan:20260702T160256-merge-positions-pause-trading — added UC for Admin-callable pause/unpause trading circuit breaker
