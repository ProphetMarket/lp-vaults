# Modules

> Physical application layers that make up the system.
> Each module maps to a deployable application, service, or package.
> `Tests` is the per-module root for integration/component test files; see the slicing skill's Test File Convention.

| ID | Module | Description | Directory | Tests |
|----|--------|-------------|-----------|-------|
| contracts | LP Vault Contracts | Solidity smart contracts: LPVaultFactory (EIP-1167 clone deployer + registry), LPVault (per-market vault with v3-style positions and fee accumulators), and supporting libraries (Tick, Position, TickBitmap) | `.` | `test/` |
