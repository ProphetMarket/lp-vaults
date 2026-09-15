# Domains

> Logical business concerns that cross module boundaries.
> Use domain tags on features and use cases to filter by business area
> (e.g., list every feature under @vault across all modules).

| ID | Domain | Description |
|----|--------|-------------|
| @vault | Vault Lifecycle | Factory pattern (EIP-1167 clones), per-market vault creation and registry, outcome-token identity, lifecycle state machine (Active -> WindDown), exchange and CTF approvals, emergency cancel, the solvency ledger of what the vault owes per asset |
| @positions | Position Management | LP position minting (escrow then operator-driven `mintPositionFor`), the claim model and the burn (self-service and relayed), deposit reclaim escape hatch, intent fulfillment guards |
| @fees | Fee Accounting | Deprecated on 2026-09-14 (R17): the fee accounting left the vault; FEAT-TOGR is retained for the audit trail |
| @ticks | Tick Management | Per-tick state (liquidityGross, liquidityNet, noLiquidityNet), tick crossing logic in `updateTick`, active liquidity tracking, TickBitmap for efficient traversal |
