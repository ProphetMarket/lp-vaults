# Use Cases: Vault Solvency Ledger

> Index of all use cases for FEAT-9BQZ.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-9BR0 | Maintain Solvency Totals | implemented | Every mint, burn, merge, and freeze moves the matching scaled total in the same call, so the ledger answers what the vault owes per asset without iterating a position | [UC-9BR0-maintain-solvency-totals.md](UC-9BR0-maintain-solvency-totals.md) |
| UC-9BR1 | Accumulate Principal Shift | implemented | A tick move moves the totals for every segment the price traversed, with the liquidity split as it stood in that segment, the trailing segment included | [UC-9BR1-accumulate-principal-shift.md](UC-9BR1-accumulate-principal-shift.md) |
| UC-9BR2 | Apply Payout Ratios | implemented | A burn pays the whole claim when the vault covers it and the same share as every other claimant when it does not, per asset before the switch and as one USDC sum after it, debits the full owed amount, and never reverts | [UC-9BR2-apply-payout-ratios.md](UC-9BR2-apply-payout-ratios.md) |
