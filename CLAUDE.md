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
2. **Access control.** Use modifiers only: `onlyAdmin`, `onlyOperator`, `onlyOracle`, `onlyFactory`. NEVER inline `require(msg.sender == ...)` in a function body — modifiers compose better and are easier to grep. Role registry follows the `ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol` pattern verbatim: `mapping(address => uint256) admins` + `adminCount` + two-step `transferAdmin` / `acceptAdmin`; `mapping(address => uint256) operators`; `address oracle` set via `setOracle`. Two recorded departures: `removeAdmin` and `renounceAdminRole` also clear `pendingAdmin` when it names the removed address (ADR-5UJS), and `isValidSignature` checks `msg.sender == exchange` inline and answers `0xffffffff`, because the method must return a value and never revert (ADR-C0E7 and ADR-CVQ2 in FEAT-C0DJ).
3. **Integer math.** Every Q128 product uses inline `mulDiv` (overflow-safe), with one exception: the fee-growth chain. The subtractions in `_computeFeeGrowthInside` (the two conditional ones and the final `global − below − above`), the flip in `_crossTick`, and every `feeGrowthInsideX128 − feeGrowthInsideLastX128` subtraction run inside `unchecked`, because a late-initialized tick makes the result wrap modulo 2^256 on purpose, and two values that wrapped by the same offset cancel to the true delta only when the subtraction wraps too, as in Uniswap v3. The product `x = liquidity × delta` that consumes that delta stays inside the same `unchecked` block and never goes through `mulDiv`; the truncated fees (`x / Q128`), the ledger debit (`x + tokensOwed × Q128`), and the merge dust (`x mod Q128`) are derived outside the block, so the block holds exactly the one wraparound product at every site. This is a convention that keeps one shape at every fee site, not a safety claim: on a correct delta both forms return the same number, and on a wrong delta both return a wrong number. Every fee-growth `unchecked` block carries a comment that names the intended wraparound. The decision record is ADR-8L1F in `specs/features/contracts/FEAT-T7AF-mint-lp-position/ARCHITECTURE.md`. Every `int24` / `int128` / `uint128` conversion uses inline `SafeCast`. No other `unchecked` block unless overflow is provably impossible AND a comment on the block explains why.
4. **Replay protection.** Every operator-issued or LP-signed action carries a unique `intentId` / `nonce` recorded in a `mapping(bytes32 => bool) used`. Check-then-set inside the same function before any external work.
5. **Signature handling.** EIP-712 with a domain separator cached at `initialize()`; recompute on `block.chainid` mismatch (cf. OpenZeppelin's EIP712 pattern, inlined). ECDSA recovery enforces `s` malleability bounds and rejects `v` values outside `{27, 28}`, in one inline `_recoverSigner`, which returns the zero address on every failure (a wrong length, a high `s`, a bad `v`, a failed `ecrecover`) instead of reverting, so the order maker's `isValidSignature` can share it (ADR-C0YQ in FEAT-C0DJ); every caller rejects the zero address explicitly on its own line. Every LP-signed type carries a `deadline` checked against `block.timestamp` (inclusive). The signer is the Safe's owner key, never the Safe: after recovery, the vault requires that the Safe derived from the signer (CREATE2 through the factory's `safeFactory` and `safeProxyBytecodeHash`, both `immutable`) equals the named Safe, in one internal `_verifySafeOwnerSignature` that every relayed LP path calls (the Safe owner-key decision ADR-9OYP in FEAT-T7AF). A valid signature never proves ownership of an `intentId`; the recorded Safe in `pendingDeposits` does (ADR-45IC in FEAT-3ZRI).
6. **External call hygiene.** Use an inline `_safeTransfer` / `_safeTransferFrom` helper that handles both bool-returning and non-bool-returning ERC-20s (USDT semantics). Never call `.call` / `.delegatecall` on user-supplied addresses. The CTF Exchange address is set at `initialize()` and immutable thereafter. Every payout merges the vault's pairs first and pays each asset's owed amount times the smaller of 1 and held ÷ owed total, from the running totals of the solvency ledger (decisions C26, O2 reversed on 2026-09-14; ADR-COEY in FEAT-7G40 and ADR-COEN in FEAT-9BQZ), debits the full owed amount, and never reverts on that comparison; a ledger debit saturates only in `_burn` and `_collect`, and the Operator paths (`updateTick`, `mergePositions`) use checked arithmetic; the ERC-1155 transfer of a burn is the last external call.
7. **Initialization guards.** Clones use an `initializer` modifier (one-shot, replay-protected). The implementation contract MUST call `_disableInitializers()` in its constructor. The factory is the only address that can call `initialize` on a clone — enforce via an `onlyFactory` modifier checking `msg.sender == factory`.
8. **EIP-1167 specifics.** Clones CANNOT use `immutable` — `immutable` values are baked into the implementation's bytecode and shared across all clones. All per-vault configuration (`marketId`, `usdc`, `exchange`, `conditionalTokens`, `conditionId`, `yesTokenId`, `noTokenId`, `tickSpacing`, `minimumFirstLiquidity`, `emergencyCancelTimelock`) lives in storage and is set inside `initialize()`. At every such storage variable, add a comment: `// would be immutable in a non-clone contract; storage because EIP-1167.`
9. **Fee accumulator safety.** `notifyFees(amount)` MUST revert when `activeLiquidity == 0` — never silently lock fees in the contract. Q128 division truncates downward; the dust accumulates and is recovered on the next call. Document the dust path at the call site.
10. **Tick math bounds.** `updateTick(newTick)` caps the number of ticks crossed per call (256). Revert if exceeded; force the keeper to chunk via multiple calls. Use a `TickBitmap`-style structure (inline) to skip uninitialized ticks rather than walking the full range. The search receives the target tick and stops at the target's bitmap word in both directions, and it checks the extreme `int16` word before it steps, so no LP can make a later `updateTick` scan past the Operator's target and the search never overflows (decision C13, ADR-5IDK in FEAT-TVS0). One tick is one basis point (`PRICE_TICK_ONE = 10000`), and every position range lies inside [0, 10000], checked in `_requireValidRange` at the deposit and the mint; `currentTick` itself is unbounded (ADR-BMF7 in FEAT-T7AF). A burn that takes a tick's `liquidityGross` to zero deletes the tick and clears its bitmap bit through `_removeTickReference`, so a set bit always means liquidity behind it. An interior mint tick is a crossable tick: it counts its positions' liquidity in `liquidityGross` and holds their `noLiquidityNet`, so a set bit still means liquidity behind it, and `updateTick` moves `noSideLiquidity` and the ledger totals for every segment it traverses, the trailing one included (ADR-COEW in FEAT-TVS0).
11. **Approval scope.** `setApprovalForAll(exchange, true)` on the CTF is acceptable BECAUSE the vault holds outcome tokens for exactly one market. The receiver hooks enforce this: they revert on every token ID other than the vault's `yesTokenId` and `noTokenId`, which the factory verifies against `conditionId` at `createVault`. Add a NatSpec comment at the call site documenting this check. The exchange approvals (USDC and CTF) are reachable only through `isValidSignature`, which vouches for a registered Operator's signature to the exchange as caller and only while the vault is Active and not paused (decision C22, FEAT-C0DJ).
12. **Timestamp dependence.** Use `block.number` for ordering when possible. Timelocks (e.g., the per-vault `emergencyCancelTimelock`, copied from the factory default) and signature deadlines may use `block.timestamp` but with a documented ±15s tolerance (Polygon block time). Never use `block.timestamp` for randomness.
13. **Front-running / MEV.** The `feeGrowthInsideLastX128` snapshot at mint time already prevents fee-distribution MEV (new positions can't claim past fees). Any new operator-callable action that touches accounting MUST include an `MEV analysis:` NatSpec block before merge.

## Roles (canonical for this repo)

Mirrors `ctf-exchange/src/ProphetCTFExchange.sol` exactly. Do not invent new roles.

| Role | On-chain? | Authority | Storage |
|------|-----------|-----------|---------|
| Admin | yes | Set/remove operators, set oracle, pause, two-step admin transfer, add/remove/renounce admins, set the factory's default emergency-cancel timelock | `mapping(address => uint256) admins` + `uint256 adminCount` |
| Operator | yes | Transactional: `depositForIntent`, `mintPositionFor`, `reclaimDepositFor`, `burnPositionFor`, `collectFor`, `notifyFees`, `updateTick`, `mergePositions`, `heartbeat`. Multiple addresses allowed. | `mapping(address => uint256) operators` |
| Oracle | yes (single) | Lifecycle: `createVault` (factory), `startWindDown` (vault). Matches the oracle on `ProphetCTFExchange` + `Resolution`. | `address public oracle` |
| LP | yes (a Safe wallet that Prophet deploys) | Direct, as a Safe transaction: `reclaimDeposit`, `collect`, `burnPosition` on escrows and positions the Safe owns, in every phase. Relayed: the owner key signs `MintIntent`, `ReclaimIntent`, `BurnIntent`, and `CollectIntent`, each with a deadline | n/a — checked via `position.owner == msg.sender`, `pendingDeposits[intentId].lp == msg.sender`, or the Safe derived from the owner key |
| Keeper | **NO (off-chain)** | Off-chain bot that holds an Operator key and calls `updateTick` + `mergePositions`, and merges the vault's pairs through `mergeCompleteSets`. It signs vault orders with the Operator key (`signer = maker = vault`, `signatureType = POLY_1271`) and cancels its resting orders on `EmergencyCancelExecuted`, `VaultWindDownStarted`, and `TradingPaused`, because the vault refuses their signatures at match time (C22). Not a contract concept. | n/a |
| Any Wallet | yes (no role) | `mergeCompleteSets()`, and `emergencyCancelAll()` after the vault's operator-silence timelock: functions whose effect cannot favor their caller | n/a — no modifier |

### Function → role authority matrix

| Function | Role | Contract |
|---|---|---|
| `createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId)` | Oracle | `LPVaultFactory` |
| `setOracle`, `addOperator`, `removeOperator`, `pauseTrading` | Admin | both |
| `transferAdmin`, `acceptAdmin` | Admin | `LPVaultFactory` |
| `addAdmin`, `removeAdmin`, `renounceAdminRole` | Admin | `LPVaultFactory` |
| `initialize(...)` | factory-only (`onlyFactory`) | `LPVault` |
| `depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, signature)` | Operator (owner-key signature, checked against the derived Safe) | `LPVault` |
| `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, deadline)` | Operator (escrow required, no signature, no USDC) | `LPVault` |
| `reclaimDeposit(intentId)` | LP's Safe (the recorded depositor, direct call, no timelock, every phase) | `LPVault` |
| `reclaimDepositFor(lp, intentId, deadline, signature)` | Operator (owner-key signature) | `LPVault` |
| `collect(positionId)`, `burnPosition(positionId)` | LP's Safe (`position.owner`, every phase, paused or not) | `LPVault` |
| `burnPositionFor(lp, positionId, deadline, signature)` | Operator (owner-key `BurnIntent`, checked against the derived Safe and `position.owner`) | `LPVault` |
| `collectFor(lp, positionId, nonce, deadline, signature)` | Operator (owner-key `CollectIntent`, checked the same way) | `LPVault` |
| `mergeCompleteSets()` | Any address, every phase | `LPVault` |
| `isValidSignature(hash, signature)` | The exchange (a view: returns `0x1626ba7e` when the recovered signer is a registered Operator and the vault is Active and not paused, `0xffffffff` otherwise, never reverts) | `LPVault` |
| `notifyFees(amount)`, `updateTick(newTick)`, `mergePositions(...)` | Operator | `LPVault` |
| `heartbeat()` | Operator | `LPVault` |
| `startWindDown()` | Oracle | `LPVault` |
| `emergencyCancelAll()` | any address, after the vault's operator-silence timelock; the freeze moves no funds | `LPVault` |
| `setDefaultEmergencyCancelTimelock(newTimelock)` | Admin; the default that later vaults copy, within (0, 30 days] | `LPVaultFactory` |

### Hard rules

- **Operator and Oracle are SEPARATE accounts.** Compromise of one must not unlock the other's powers. Tests must verify this.
- **Admin is registry-only.** Admin cannot directly call user-facing functions (no `mintPositionFor`, no `notifyFees`). Admin only manages who else holds what role.
- **No upgradability.** Vaults are immutable EIP-1167 clones. The implementation contract address is fixed at factory deploy time. If a fix is needed, deploy a new factory; vaults already in-flight keep their old implementation.
- **OPERATOR TRUST ASSUMPTION NatSpec on every operator-gated function.** Match `ProphetCTFExchange.sol`'s style — explicitly state what the operator can do and what users must trust.
- **Every Operator function, present and future, carries `touchesHeartbeat` beside `onlyOperator`** (the liveness decision ADR-3XU3 in FEAT-JXQO, and the silence-timer requirement FR-JXQS). This includes `depositForIntent`, `reclaimDepositFor`, `burnPositionFor`, and `collectFor`. The self-service exits (`burnPosition`, `collect`, `reclaimDeposit`) and `mergeCompleteSets` never refresh it. `isValidSignature` is a view the exchange calls, not an Operator function, so it carries neither `onlyOperator` nor `touchesHeartbeat`.

## Foundry conventions

- Compiler: `pragma solidity 0.8.20;` (exact, not `^0.8.20`). The optimizer is on with `optimizer_runs = 200` in `foundry.toml`, chosen for contract size (the compiler optimizer decision, ADR-9FOM in `specs/features/contracts/FEAT-J92H-deploy-contracts/ARCHITECTURE.md`). Do not change either value without a new decision record.
- Size check, in the completion check of every step: run `forge build --sizes --skip test --skip script`. It must exit 0. The report states the runtime size and the room of `LPVault` and `LPVaultFactory`. The check skips test and script files because `forge test` does not enforce the 24,576-byte limit, so a test harness may exceed it. A harness over the limit never blocks a step. `forge test` alone never proves that a contract deploys.
- `forge fmt` on every commit. Set up a pre-commit hook.
- Tests:
  - `test/features/{FEAT-dir}/{UC-dir}.t.sol` — integration tests, **one file per use case**. The path is derived from `specs/MODULES.md` (`Tests` column) and the spec tree; it is never chosen ad hoc. Every task and fix that touches a UC appends to that UC's single file — never a new numbered file.
  - `test/invariants/` — invariant tests (Foundry's `forge-std/StdInvariant.sol`)
  - `test/integration/` — forked-Polygon scenarios against deployed `ProphetCTFExchange`
  - `test/fixtures/` — shared test fixtures: the real Conditional Tokens deployer, the real exchange deployer, the one ERC-20 mock, and the vault storage helpers. Test files import them. `src/` never does.
  - `test/artifacts/` — vendored build artifacts of contracts this repository cannot compile: today `ProphetCTFExchange.json`, pinned to its source commit in the fixture that deploys it.
- Fuzz tests on all arithmetic-heavy code (Q128 math, liquidity formula, tick crossing).
- Invariants on every state-machine property. Required invariants:
  - `Σ position.liquidity over in-range positions == activeLiquidity`, and `noSideLiquidity == Σ liquidity over in-range positions with mintTick <= currentTick`, in every phase, including Cancelled, because the freeze keeps both (FEAT-JXQO FR-JXQP); the check is `invariant_activeLiquidityEqualsInRangeLiquidity` in `test/invariants/TickState.t.sol`, whose handler freezes the vault in about six runs of ten
  - `ticks[t].liquidityGross == Σ liquidity of positions referencing t as tickLower, tickUpper, or an interior mint tick`, and `ticks[t].noLiquidityNet == the NO sub-ranges' net at t`
  - `Σ ticks[t].liquidityGross over the distinct referenced ticks == Σ position.liquidity × (2 + [interior mint tick])` — a merge conserves liquidity, and a burn removes it from the record and from every tick it references at once. This is the summed form of the `liquidityGross` invariant, kept as its own named check (`invariant_mergeConservesLiquidity`) because audit issue 6.14 asked for it.
  - The four scaled ledger totals equal the sum over every live position of its scaled claim at `currentTick` and its scaled fee claim, exactly, across mints, burns, collects, fee reports, merges, freezes, and tick moves that cross nothing or end between ticks (`invariant_ledgerEqualsSumOfClaims` in `test/invariants/SolvencyLedger.t.sol`); and no burn or collect pays more of an asset than the vault holds, with every burn paying `floor(owed × min(1, held ÷ total))` per asset (`invariant_payoutsNeverExceedHeld`).
  - `Σ claimable fees over all positions + Σ fees paid out by collect ≤ Σ amounts passed to notifyFees`, with no slack, because every rounding on this path rounds down. When every position has been in range since its mint and nothing was collected, this bound matches `feeGrowthGlobalX128 × activeLiquidity / 2^128` up to rounding dust. The per-instant form alone does not hold once a position leaves range with unclaimed fees, so the invariant test proves the conservation form.
  - A tick's bitmap bit is set if and only if `ticks[t].liquidityGross > 0`, over every tick a mint ever referenced, so a burn that clears the bit keeps the search honest (FEAT-7G40 FR-7G4P). The check is `invariant_zeroLiquidityTickHasNoBit` in `test/invariants/TickState.t.sol`, and its handler burns through both entry points.
  - `usdc.balanceOf(vault) ≥ totalEscrowed + Σ minted principal + Σ claimable fees over all positions`, with no exchange fill: every fee credit is backed by USDC the vault holds beyond escrow and principal, because `notifyFees` takes the USDC it credits (R8, decision C19). The qualifier matters: `initialize()` grants the exchange a max USDC approval, and every fill turns vault USDC into outcome tokens, so on chain the balance falls below escrow plus principal as soon as trading starts (the accepted drift, decision C8). The invariant harness deploys no exchange, so there it holds exactly. The per-call form holds on chain without the qualifier: each `FeesNotified` is preceded by a `Transfer` of `amount` into the vault in the same transaction. The check is `invariant_feeCreditsAreBacked` in `test/invariants/FeeGrowthAccounting.t.sol`.
- No `console.log` in production code. Foundry's linter catches this.

## When in doubt

- **Touches Q128, tick state, or signatures** → write the fuzz / invariant first, then the implementation. Ask for a second human review before merge.
- **Tempted to import a library implementation** → ask "could this be 50 lines inline?" If yes, inline it. If no, ask before adding the dependency.
- **Authority ambiguity in a feature spec** → default to the narrower role and surface the ambiguity in the PR description. Better to be wrong on the safe side.
- **Anything new the Operator can do** → add an OPERATOR TRUST ASSUMPTION NatSpec block before merging.

## See also

- `../contracts/src/ProphetCTFExchange.sol` — role conventions to mirror, and the exchange the vault answers as order maker
- `../ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol` — role registry pattern (copy this verbatim, inlined)
- `../research/lp-provisioning-engine.md` — research, architecture, Phase 1 contract sketch
- `../research/lp-vaults-build-plan.md` — 8-feature build order with `/m:spec` prompts
- `specs/` — project context (PROJECT, MODULES, DOMAINS, ACTORS, FEATURES, TECH-STACK, GLOSSARY)

<!-- molcajete:principles:start -->
## Engineering Principles (Molcajete)

Trust comes from tests, not code shape. Code can change; behavior is the contract.

- Integration tests are the trust contract. Unit tests only for heavy algorithmic logic.
- Hexagonal architecture: drive tests through driver ports with the real internal stack; mock only the outer-edge driven ports.
- Dependency injection makes the outer edge swappable at test time.
- 80% coverage floor on touched files (configurable via `.molcajete/settings.json testing.threshold`).
- Small functions, clear module boundaries, no god files. Refactor to reuse; never duplicate.
- Principles are technology-agnostic. The stack is recorded in `specs/TECH-STACK.md`.

See `.claude/rules/principles.md` for full text and rationale. Re-read it before any architecture decision, test-scope decision, or refactor.
<!-- molcajete:principles:end -->
