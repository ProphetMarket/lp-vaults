# Use Cases: Vault Order Authorization

> Index of all use cases for FEAT-C0DJ.
> Full specifications are in `UC-XXXX-{slug}.md` (siblings of this file).
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-C0DK | Vouch for an Operator-Signed Order | implemented | The vault answers the exchange for a signature produced by a registered Operator, while Active and not paused, so an order naming the vault as maker passes the exchange's signature check | [UC-C0DK-vouch-for-an-operator-signed-order.md](UC-C0DK-vouch-for-an-operator-signed-order.md) |
| UC-C0DL | Settle a Matched Order Into the Vault | implemented | A matched order on the real exchange fills against vault-held capital and delivers outcome-token inventory into the vault without its assets passing through any wallet, and a frozen vault takes no fill | [UC-C0DL-settle-a-matched-order-into-the-vault.md](UC-C0DL-settle-a-matched-order-into-the-vault.md) |
