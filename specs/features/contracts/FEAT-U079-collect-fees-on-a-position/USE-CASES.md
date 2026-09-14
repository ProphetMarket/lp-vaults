# Use Cases: Collect Fees on a Position

> Index of all use cases for FEAT-U079.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-U07A | Collect Position Fees | implemented | The LP's Safe withdraws accumulated trading fees from its position without removing it, in every phase, after the vault settles its tokens (the merge before the switch, the redemption after it), at the USDC ratio of the solvency ledger | [UC-U07A-collect-position-fees.md](UC-U07A-collect-position-fees.md) |
| UC-BMF8 | Operator Collect Fees for LP | implemented | The Operator relays the owner key's signed CollectIntent, with a nonce and a deadline, to pay that Safe its fees | [UC-BMF8-operator-collect-fees-for-lp.md](UC-BMF8-operator-collect-fees-for-lp.md) |
