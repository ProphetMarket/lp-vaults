# Actors

> Roles that interact with this system. Referenced by use cases and requirements.

| Actor | Role | Description | Constraints |
|-------|------|-------------|-------------|
| LP | human | Liquidity provider who deposits USDC into a specific market vault, chooses a price range (tickLower, tickUpper), and earns trading fees while their range is active | Can have multiple positions per vault; can only burn/collect on positions they own; subject to idle-capital constraint on burn |
| Operator | system | Transactional authority — credits LP positions via `mintPositionFor` after verifying off-chain deposit intents, calls `notifyFees` to distribute trading fees, calls `updateTick` and `mergePositions` | Multiple addresses allowed via `mapping(address => uint256) operators`; managed by Admin via `addOperator` / `removeOperator`; gated by `onlyOperator` modifier |
| Oracle | system | Lifecycle authority — calls `createVault(marketId, tickSpacing)` on the factory to deploy new per-market vaults and sets initialization defaults, calls `startWindDown()` on a vault when its underlying market resolves | Single on-chain wallet (`address public oracle`); set by Admin via `setOracle`; should match the oracle configured on `ProphetCTFExchange` and `Resolution`; MUST be a separate account from Operator |
| Keeper | system | Off-chain service that monitors the CLOB and signs transactions using an Operator key to call `updateTick` and `mergePositions` | Not an on-chain role — has no contract-level authority of its own; trust assumptions are inherited from whichever Operator key it holds |
| Factory Owner | human | Deploys the `LPVaultFactory` contract and bootstraps the role registry (initial Admin) | Sets the implementation contract address, the CTF Exchange address, the USDC address, and the initial Admin / Oracle / Operator wallets at deployment; after deployment, role management is handled by Admin |
