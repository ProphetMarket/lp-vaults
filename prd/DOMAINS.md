# Domains

> Logical business concerns that cross module boundaries.
> Use domain tags on features and use cases to filter by business area
> (e.g., list every feature under @vault across all modules).

| ID | Domain | Description |
|----|--------|-------------|
| @vault | Vault Lifecycle | Factory pattern (EIP-1167 clones), per-market vault creation and registry, lifecycle state machine (Active -> WindDown), exchange and CTF approvals, emergency cancel |
| @positions | Position Management | LP position minting (direct `mintPosition` + operator-driven `mintPositionFor`), two-phase burning, fee collection, deposit reclaim escape hatch, intent fulfillment guards |
| @fees | Fee Accounting | Uniswap v3-style fee accumulators: `feeGrowthGlobalX128`, per-tick `feeGrowthOutsideX128`, `feeGrowthInside` computation, `notifyFees` distribution, Q128 fixed-point math |
| @ticks | Tick Management | Per-tick state (liquidityGross, liquidityNet, feeGrowthOutside), tick crossing logic in `updateTick`, active liquidity tracking, TickBitmap for efficient traversal |
