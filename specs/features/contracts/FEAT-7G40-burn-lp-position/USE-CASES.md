# Use Cases: Burn LP Position

> Index of all use cases for FEAT-7G40.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-7G41 | Burn Position | implemented | The LP's Safe closes a position it owns and receives the claim's USDC, its one outcome token (USDC at the payout after the switch), and its fees, with no Operator involvement, in every phase | [UC-7G41-burn-position.md](UC-7G41-burn-position.md) |
| UC-7G42 | Operator Burn Position for LP | implemented | The Operator relays the owner key's signed BurnIntent to close that Safe's position and pay the Safe, with a deadline and its own replay record | [UC-7G42-operator-burn-position-for-lp.md](UC-7G42-operator-burn-position-for-lp.md) |
