# Modules

> Physical application layers that make up the system.
> Each module maps to a deployable application, service, or package.
> `Tests` is the per-module root for integration/component test files; see the slicing skill's Test File Convention.
> `Driving Ports` is the comma-separated list of inbound entry-point kinds the module exposes (e.g., `http, event, cron`). Each slice's `entry_type` must be one of these values. See the setup skill's "Driving Ports Column" rule.

| ID | Module | Description | Directory | Tests | Driving Ports |
|----|--------|-------------|-----------|-------|---------------|
| contracts | LP Vault Contracts | Solidity smart contracts: LPVaultFactory (EIP-1167 clone deployer + registry), LPVault (per-market vault with v3-style positions and fee accumulators), and supporting libraries (Tick, Position, TickBitmap) | `.` | `test/` | contract-call |
