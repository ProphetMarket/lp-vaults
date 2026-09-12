# Use Cases: LP Escape Hatch

> Index of all use cases for FEAT-JAIJ.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-JAIK | Reclaim Deposit | implemented | The LP's Safe recovers the USDC that the Operator escrowed against a mint intent and did not mint, in one call, in every phase | [UC-JAIK-reclaim-deposit.md](UC-JAIK-reclaim-deposit.md) |
| UC-3Z93 | Operator Reclaim Deposit for LP | implemented | Operator relays the owner key's signed ReclaimIntent to refund that Safe's escrowed USDC, paying the recorded Safe and never the caller | [UC-3Z93-operator-reclaim-deposit-for-lp.md](UC-3Z93-operator-reclaim-deposit-for-lp.md) |
