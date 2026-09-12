TODO:

DONE:
- 20260912T164159 [implemented] command:change plan:20260912T164110-compiler-optimizer-size-check-r0b — Turn the Solidity optimizer on at 200 runs for contract size (ADR-9FOM) and add the foundry.toml row to the Component Inventory. No scenario changes. The vault goes from 24,188 to 14,521 bytes, and the deployed bytecode differs from the audited build.
- 20260702T120000 [implemented] command:change plan:20260702T120100-remove-private-key-env-var — Remove PRIVATE_KEY env var from deploy script; require cast wallet (--account) or hardware wallet (--ledger/--trezor) for transaction signing. Added SC-K49S scenario, updated FR-J92O and NFR-J92U.
- 20260701T000000 [implemented] command:spec plan:20260701T000100-deploy-contracts — created UC for deploying LPVault implementation and LPVaultFactory via env-var-driven Foundry script
