# Use Cases: Deploy LP Vault for a Market

> Index of all use cases for FEAT-REPZ.
> Full specifications are in `UC-XXXX-{slug}.md`.
> Updated whenever a use case is added or changes status.

| ID | Name | Status | Description | File |
|----|------|--------|-------------|------|
| UC-REQ0 | Deploy Factory | implemented | Factory Owner deploys the LPVaultFactory with implementation, external addresses, and initial role assignments | [UC-REQ0-deploy-factory.md](UC-REQ0-deploy-factory.md) |
| UC-REQ1 | Create Vault for Market | implemented | Oracle deploys a per-market LP vault via the factory with factory-delegated role authorization | [UC-REQ1-create-vault-for-market.md](UC-REQ1-create-vault-for-market.md) |
| UC-REQ2 | Manage Roles on Factory | implemented | Admin manages the role registry: add/remove operators, set oracle, two-step admin transfer; changes propagate to all vaults | [UC-REQ2-manage-roles-on-factory.md](UC-REQ2-manage-roles-on-factory.md) |
