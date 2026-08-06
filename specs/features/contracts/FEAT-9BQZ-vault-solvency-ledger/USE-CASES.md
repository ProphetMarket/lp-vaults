# Use Cases: Vault Solvency Ledger

> Index of all use cases for FEAT-9BQZ.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-9BR0 | Maintain Solvency Totals | implemented | Every operation that creates, discharges, or transforms an obligation moves the matching running total in the same call | [UC-9BR0-maintain-solvency-totals.md](UC-9BR0-maintain-solvency-totals.md) |
| UC-9BR1 | Accumulate Principal Shift | pending | A price move records how much principal it converted between asset sides, for every span traversed rather than only the ticks crossed | [UC-9BR1-accumulate-principal-shift.md](UC-9BR1-accumulate-principal-shift.md) |
| UC-9BR2 | Apply Payout Ratios | pending | An exit path pays a full claim when the vault can cover it and the same proportional share as every other claimant when it cannot | [UC-9BR2-apply-payout-ratios.md](UC-9BR2-apply-payout-ratios.md) |
