TODO:

DONE:
- 20260912T200447 [implemented] command:change plan:20260912T200119-per-intent-escrow-safe-signatures-r5 — The factory constructor takes safeFactory and safeProxyBytecodeHash, the two inputs of the Safe derivation, and holds them as immutable values that the vault reads at call time (decision C23, step R5). A zero factory reverts ZeroAddress and a zero hash reverts ZeroBytecodeHash. FR-REQI edited, FR-9OYI and SC-9OY7 added, SC-REQ3 edited.
- 20260617T055202 [implemented] command:spec plan:20260617T055202-deploy-lp-vault-for-market — Deploy factory with Auth role registry and LPVault implementation
