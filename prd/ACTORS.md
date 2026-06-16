# Actors

> Roles that interact with this system. Referenced by use cases and requirements.

| Actor | Role | Description | Constraints |
|-------|------|-------------|-------------|
| LP | human | Liquidity provider who deposits USDC into a specific market vault, chooses a price range (tickLower, tickUpper), and earns trading fees while their range is active | Can have multiple positions per vault; can only burn/collect on positions they own; subject to idle-capital constraint on burn |
| Operator | system | Trusted key that credits LP positions via `mintPositionFor` after verifying off-chain deposit intents, calls `notifyFees` to distribute trading fees, and manages vault lifecycle (wind-down) | Single address per vault, set at construction; only account that can call operator-restricted functions |
| Keeper | system | Off-chain service that updates `currentTick` when the CLOB mid-price moves, triggering tick-crossing logic and fee accumulator flips; also calls `mergePositions` to recover USDC from balanced YES/NO pairs | Permissioned to call `updateTick`; does not hold LP funds; one keeper process per vault |
| Factory Owner | human | Deploys the LPVaultFactory and creates new per-market vaults via `createVault(marketId, tickSize)` | Controls the factory contract; sets the operator address and exchange/USDC references |
