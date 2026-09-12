TODO:

DONE:
- 20260912T200447 [implemented] command:change plan:20260912T200119-per-intent-escrow-safe-signatures-r5 — The paused exit paths gain the relayed reclaim and lose the timelock: FR-K1MI names reclaimDeposit by the recorded Safe and reclaimDepositFor by the Operator, and depositForIntent joins the trading entry points that revert TradingIsPaused. SC-K1MP now calls reclaimDeposit(intentId) on an escrow with no wait (decision C1, step R5).
- 20260702T155901 [implemented] command:spec plan:20260702T160256-merge-positions-pause-trading — added UC for Admin-callable pause/unpause trading circuit breaker
