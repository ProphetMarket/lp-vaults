# LP Vaults — Repository Rules

This file is auto-loaded by Claude Code on every conversation in this repo. Rules below are not suggestions — they are PR-blocking. Read top to bottom before editing any Solidity in this repo.

## Priorities (strict order)

1. **Security.** Every change must be safe by default. No optimization, no convenience helper, no library shortcut is worth a vulnerability.
2. **Gas efficiency.** Among secure options, choose the cheapest. Pack storage where it doesn't compromise readability. Cache storage reads inside loops.
3. **Readability / auditability.** Code is read more than written. Auditors are the primary readers. Prefer the clear version of equivalent code.

If two of these conflict, the higher-priority one wins. Do not silently trade security for gas.

## Pattern policy

**Inline well-known patterns. Do not import library implementations.**

| Allowed imports | Forbidden imports (inline instead) |
|-----------------|-----------------------------------|
| `openzeppelin-contracts/token/ERC20/IERC20.sol` (interface only) | `SafeERC20` |
| `openzeppelin-contracts/token/ERC1155/IERC1155.sol` (interface only) | `ReentrancyGuard` |
| `openzeppelin-contracts/token/ERC1155/IERC1155Receiver.sol` (interface only) | `SafeCast` |
| `ctf-exchange/.../IConditionalTokens.sol` (interface only) | `Clones` / `ClonesUpgradeable` |
| `forge-std/*` (TEST-ONLY — never imported by `src/`) | `EIP712`, `ECDSA`, `Initializable`, `Address`, `Math.mulDiv` |

Rationale: smaller audit surface, no transitive dependency risk, no version-pinning surprises. The patterns are familiar enough that inlining costs nothing in review time and removes an entire class of supply-chain risk. Reference implementations (OpenZeppelin, Solady, Uniswap v3) are fine to copy verbatim — just keep them in this repo.

## Security checklist (every PR)

Auditors examine these categories first. Every PR must satisfy every applicable item.

1. **Reentrancy.** Apply an inline `nonReentrant` modifier to every external state-changing function that performs an external call or token transfer. Follow checks-effects-interactions strictly — state mutations before external calls, always.
2. **Access control.** Use modifiers only: `onlyAdmin`, `onlyOperator`, `onlyOracle`, `onlyFactory`. NEVER inline `require(msg.sender == ...)` in a function body — modifiers compose better and are easier to grep. Role registry follows the `ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol` pattern verbatim: `mapping(address => uint256) admins` + `adminCount` + two-step `transferAdmin` / `acceptAdmin`; `mapping(address => uint256) operators`; `address oracle` set via `setOracle`.
3. **Integer math.** Every Q128 product uses inline `mulDiv` (overflow-safe). Every `int24` / `int128` / `uint128` conversion uses inline `SafeCast`. No `unchecked` blocks unless overflow is provably impossible AND a comment on the block explains why.
4. **Replay protection.** Every operator-issued or LP-signed action carries a unique `intentId` / `nonce` recorded in a `mapping(bytes32 => bool) used`. Check-then-set inside the same function before any external work.
5. **Signature handling.** EIP-712 with a domain separator cached at `initialize()`; recompute on `block.chainid` mismatch (cf. OpenZeppelin's EIP712 pattern, inlined). ECDSA recovery enforces `s` malleability bounds and rejects `v` values outside `{27, 28}`.
6. **External call hygiene.** Use an inline `_safeTransfer` / `_safeTransferFrom` helper that handles both bool-returning and non-bool-returning ERC-20s (USDT semantics). Never call `.call` / `.delegatecall` on user-supplied addresses. The CTF Exchange address is set at `initialize()` and immutable thereafter.
7. **Initialization guards.** Clones use an `initializer` modifier (one-shot, replay-protected). The implementation contract MUST call `_disableInitializers()` in its constructor. The factory is the only address that can call `initialize` on a clone — enforce via an `onlyFactory` modifier checking `msg.sender == factory`.
8. **EIP-1167 specifics.** Clones CANNOT use `immutable` — `immutable` values are baked into the implementation's bytecode and shared across all clones. All per-vault configuration (`marketId`, `usdc`, `exchange`, `oracle`, `tickSpacing`) lives in storage and is set inside `initialize()`. At every such storage variable, add a comment: `// would be immutable in a non-clone contract; storage because EIP-1167.`
9. **Fee accumulator safety.** `notifyFees(amount)` MUST revert when `activeLiquidity == 0` — never silently lock fees in the contract. Q128 division truncates downward; the dust accumulates and is recovered on the next call. Document the dust path at the call site.
10. **Tick math bounds.** `updateTick(newTick)` caps the number of ticks crossed per call (256). Revert if exceeded; force the keeper to chunk via multiple calls. Use a `TickBitmap`-style structure (inline) to skip uninitialized ticks rather than walking the full range.
11. **Approval scope.** `setApprovalForAll(exchange, true)` on the CTF is acceptable BECAUSE the vault holds outcome tokens for exactly one market — token IDs for other markets cannot enter the vault (no entry point exists). Add a NatSpec comment at the call site documenting this assumption.
12. **Timestamp dependence.** Use `block.number` for ordering when possible. Timelocks (e.g., `RECLAIM_TIMELOCK`) may use `block.timestamp` but with a documented ±15s tolerance (Polygon block time). Never use `block.timestamp` for randomness.
13. **Front-running / MEV.** The `feeGrowthInsideLastX128` snapshot at mint time already prevents fee-distribution MEV (new positions can't claim past fees). Any new operator-callable action that touches accounting MUST include an `MEV analysis:` NatSpec block before merge.

## Roles (canonical for this repo)

Mirrors `ctf-exchange/src/ProphetCTFExchange.sol` exactly. Do not invent new roles.

| Role | On-chain? | Authority | Storage |
|------|-----------|-----------|---------|
| Admin | yes | Set/remove operators, set oracle, pause, two-step admin transfer | `mapping(address => uint256) admins` + `uint256 adminCount` |
| Operator | yes | Transactional: `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`. Multiple addresses allowed. | `mapping(address => uint256) operators` |
| Oracle | yes (single) | Lifecycle: `createVault` (factory), `startWindDown` (vault). Matches the oracle on `ProphetCTFExchange` + `Resolution`. | `address public oracle` |
| LP | yes (any wallet) | `mintPosition`, `collect`, `burnPosition`, `reclaimDeposit` (on positions they own) | n/a — checked via `position.owner == msg.sender` |
| Keeper | **NO (off-chain)** | Off-chain bot that holds an Operator key and calls `updateTick` + `mergePositions`. Not a contract concept. | n/a |

### Function → role authority matrix

| Function | Role | Contract |
|---|---|---|
| `createVault(marketId, tickSpacing)` | Oracle | `LPVaultFactory` |
| `setOracle`, `addOperator`, `removeOperator`, `pauseTrading` | Admin | both |
| `transferAdmin`, `acceptAdmin` | Admin | both |
| `initialize(...)` | factory-only (`onlyFactory`) | `LPVault` |
| `mintPosition(tickLower, tickUpper, usdcAmount)` | any wallet | `LPVault` |
| `mintPositionFor(lp, ..., intentId)` | Operator | `LPVault` |
| `reclaimDeposit(intent, operatorSig)` | LP (signed intent + timelock) | `LPVault` |
| `collect(positionId)`, `burnPosition(positionId)` | LP (`position.owner`) | `LPVault` |
| `notifyFees(amount)`, `updateTick(newTick)`, `mergePositions(...)` | Operator | `LPVault` |
| `startWindDown()` | Oracle | `LPVault` |
| `emergencyCancelAll()` | any position holder, after operator-silence timelock | `LPVault` |

### Hard rules

- **Operator and Oracle are SEPARATE accounts.** Compromise of one must not unlock the other's powers. Tests must verify this.
- **Admin is registry-only.** Admin cannot directly call user-facing functions (no `mintPositionFor`, no `notifyFees`). Admin only manages who else holds what role.
- **No upgradability.** Vaults are immutable EIP-1167 clones. The implementation contract address is fixed at factory deploy time. If a fix is needed, deploy a new factory; vaults already in-flight keep their old implementation.
- **OPERATOR TRUST ASSUMPTION NatSpec on every operator-gated function.** Match `ProphetCTFExchange.sol`'s style — explicitly state what the operator can do and what users must trust.

## Foundry conventions

- Compiler: `pragma solidity 0.8.20;` (exact, not `^0.8.20`).
- `forge fmt` on every commit. Set up a pre-commit hook.
- Tests:
  - `test/{Contract}.t.sol` — unit tests
  - `test/invariants/` — invariant tests (Foundry's `forge-std/StdInvariant.sol`)
  - `test/integration/` — forked-Polygon scenarios against deployed `ProphetCTFExchange`
- Fuzz tests on all arithmetic-heavy code (Q128 math, liquidity formula, tick crossing).
- Invariants on every state-machine property. Required invariants:
  - `Σ position.liquidity over in-range positions == activeLiquidity`
  - `ticks[t].liquidityGross == Σ |liquidityNet| of positions referencing t`
  - `sum of all positions' claimable fees ≤ feeGrowthGlobalX128 × activeLiquidity / 2^128` (bounded by Q128 dust)
- No `console.log` in production code. Foundry's linter catches this.

## When in doubt

- **Touches Q128, tick state, or signatures** → write the fuzz / invariant first, then the implementation. Ask for a second human review before merge.
- **Tempted to import a library implementation** → ask "could this be 50 lines inline?" If yes, inline it. If no, ask before adding the dependency.
- **Authority ambiguity in a feature spec** → default to the narrower role and surface the ambiguity in the PR description. Better to be wrong on the safe side.
- **Anything new the Operator can do** → add an OPERATOR TRUST ASSUMPTION NatSpec block before merging.

## See also

- `../ctf-exchange/src/ProphetCTFExchange.sol` — role conventions to mirror
- `../ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol` — role registry pattern (copy this verbatim, inlined)
- `../research/lp-provisioning-engine.md` — research, architecture, Phase 1 contract sketch
- `../research/lp-vaults-build-plan.md` — 8-feature build order with `/m:spec` prompts
- `prd/` — project context (PROJECT, MODULES, DOMAINS, ACTORS, FEATURES, TECH-STACK, GLOSSARY)
