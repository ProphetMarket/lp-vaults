// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market
// UC-REQ0-001: deploy-factory-with-role-registry
// UC-REQ1-001: create-vault-and-initialize
// FEAT-T7AF: Mint LP Position
// UC-T7AG: Operator Mint Position for LP
// UC-T7AG-001: operator-mint-position
// FEAT-TOGR: Notify and Distribute Fees
// UC-TOGS: Operator Notify Fee Revenue
// UC-TOGS-001: notify-fees
// FEAT-TVS0: Update Tick and Cross Ticks
// UC-TVS1: Update Current Tick
// UC-TVS1-001: update-tick-with-crossing
// FEAT-U079: Collect Fees on a Position
// UC-U07A: Collect Position Fees
// UC-U07A-001: collect-fees
// FEAT-JGE7: Vault Wind-Down Lifecycle
// UC-JGEE: Start Wind Down
// UC-JGEE-001: start-wind-down
// FEAT-JXQO: Emergency Cancel All Positions
// UC-JXQW: Emergency Cancel All
// UC-JXQW-001: emergency-cancel-all
// FEAT-K1M2: Merge Positions
// UC-K1M8: Merge Same-Range Positions
// UC-K1M8-001: merge-same-range-positions
// FEAT-K1MD: Pause Trading
// UC-K1MK: Pause and Unpause Vault
// UC-K1MK-001: pause-and-unpause-vault
// FEAT-7G40: Burn LP Position
// UC-7G41: Burn Position, UC-7G42: Operator Burn Position for LP
// UC-7G41-001: burn-position
// UC-7G42-001: operator-burn-position-for-lp

/// @dev Minimal ERC-20 interface — only approve needed for exchange setup.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC-1155 interface — setApprovalForAll for exchange setup, and
///      safeTransferFrom for paying a burned position's outcome-token leg (FEAT-7G40).
///      No bool handling: ERC-1155 mandates a revert on failure, unlike ERC-20.
interface IERC1155 {
    function setApprovalForAll(address operator, bool approved) external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/// @dev Minimal Gnosis ConditionalTokens interface — only the two position-id views
///      initialize() needs to verify the market's outcome-token identity (FR-5XY2).
interface IConditionalTokens {
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external view returns (uint256);
}

/// @dev Minimal factory interface for auth delegation (FR-FKD0, FR-FKD1, FR-FKD2).
///      Vault modifiers read role state from the factory at call time.
interface ILPVaultFactory {
    function operators(address) external view returns (uint256);
    function oracle() external view returns (address);
    function admins(address) external view returns (uint256);
}

/// @title LPVault
/// @notice Per-market vault holding USDC and ERC-1155 outcome tokens. Deployed as EIP-1167
///         minimal-proxy clone by LPVaultFactory. Manages v3-style concentrated-liquidity
///         positions and fee accumulators.
/// @dev Auth pattern inlined from ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol
///      with the addition of `oracle` role, `factory` guard, and role-separation checks.
///      All per-vault configuration lives in storage (not immutable) because EIP-1167 clones
///      share the implementation's bytecode.
contract LPVault {
    // ──────────────────────────────────────────────
    // Auth delegation (FR-FKD0, FR-FKD1, FR-FKD2, FR-FKD3)
    // Vault reads all role state from factory at call time.
    // No local admins/operators/oracle/pendingAdmin/adminCount storage.
    // ──────────────────────────────────────────────

    function operators(address addr) public view returns (uint256) {
        return ILPVaultFactory(factory).operators(addr);
    }

    function oracle() public view returns (address) {
        return ILPVaultFactory(factory).oracle();
    }

    function admins(address addr) public view returns (uint256) {
        return ILPVaultFactory(factory).admins(addr);
    }

    // ──────────────────────────────────────────────
    // Per-vault configuration (storage because EIP-1167)
    // ──────────────────────────────────────────────

    // would be immutable in a non-clone contract; storage because EIP-1167.
    address public factory;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    bytes32 public marketId;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    address public usdc;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    address public exchange;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    address public conditionalTokens;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    int24 public tickSpacing;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint128 public minimumFirstLiquidity;

    // ──────────────────────────────────────────────
    // Initialization guard
    // ──────────────────────────────────────────────

    /// @dev Flips to true exactly once — in the implementation's constructor
    ///      (via _disableInitializers) and again in each clone's initialize().
    bool private _initialized;

    // ──────────────────────────────────────────────
    // Vault state
    // ──────────────────────────────────────────────

    /// @dev Phase lifecycle: 1 = Active, 2 = WindDown, 3 = Cancelled (terminal)
    uint8 public phase;

    /// @dev Circuit breaker flag. When true, trading entry points
    ///      (depositForIntent, mintPositionFor, notifyFees, updateTick, mergePositions) revert.
    ///      Exit paths (collect, reclaimDeposit, reclaimDepositFor, burnPosition,
    ///      burnPositionFor) and emergencyCancelAll are unaffected — a pause must never
    ///      trap an LP's capital. Independent of the phase state machine.
    bool public paused;

    /// @dev Running total of liquidity in range
    uint128 public activeLiquidity;

    /// @dev Global fee accumulator (Q128 fixed-point)
    uint256 public feeGrowthGlobalX128;

    /// @dev Current tick for the vault's market price
    int24 public currentTick;

    /// @dev Counter for minting new positions
    uint256 public nextPositionId;

    /// @dev Tracks the most recent block.timestamp at which an Operator called
    ///      notifyFees or updateTick. Used by emergencyCancelAll to detect
    ///      prolonged Operator silence.
    uint256 public lastOperatorActivityTimestamp;

    /// @dev Identifies which LPVault implementation this clone was deployed from.
    ///      Set once in initialize() from the factory's implementationVersion counter.
    ///      Off-chain systems use this to determine which code version a vault runs.
    uint256 public implementationVersion;

    // ──────────────────────────────────────────────
    // Position and tick state (FEAT-T7AF)
    // ──────────────────────────────────────────────

    struct Position {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInsideLastX128;
        uint256 tokensOwed;
    }

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutsideX128;
    }

    /// @dev positionId => Position record
    mapping(uint256 => Position) public positions;

    /// @dev tick index => per-tick fee and liquidity state
    mapping(int24 => TickInfo) public ticks;

    /// @dev intentId => true if already used (replay protection)
    mapping(bytes32 => bool) public usedIntents;

    // ──────────────────────────────────────────────
    // Reclaim state (FEAT-JAIJ)
    // ──────────────────────────────────────────────

    /// @dev intentId => block.timestamp when Phase 1 (reclaim submission) was called.
    ///      Set exactly once per intentId; never updated. Used by reclaimDeposit Phase 2
    ///      to enforce RECLAIM_TIMELOCK. Would be immutable in a non-clone contract;
    ///      storage because EIP-1167.
    mapping(bytes32 => uint256) public intentTimestamps;

    // ──────────────────────────────────────────────
    // Escrow state (FEAT-3ZRI)
    // ──────────────────────────────────────────────

    /// @dev A deposit escrowed against one intentId: who put it in, and how much.
    ///      Packs into a single slot (20-byte address + 12-byte amount).
    struct PendingDeposit {
        address lp;
        uint96 amount;
    }

    /// @dev intentId => the escrow held for that intent by depositForIntent.
    ///      The single source of truth for "WHOSE USDC, and how much, is attributable
    ///      to this intentId". mintPositionFor consumes the entry to fund a position;
    ///      the reclaim paths refund it. Exactly one of those can ever happen.
    ///
    ///      The `lp` field is load-bearing, not bookkeeping. An intentId is NOT bound
    ///      to an LP by the signature scheme: _verifyMintIntent recovers a signer and
    ///      compares it to a caller-supplied `lp` argument, so anyone can produce a
    ///      signature that verifies over any intentId by signing with their own key and
    ///      naming their own address. Every path that spends an escrow must therefore
    ///      check `lp` against this recorded depositor — a valid signature over an
    ///      intentId is necessary but never sufficient. Without that check, an attacker
    ///      could read a pending intentId out of the DepositEscrowed log, self-sign over
    ///      it, and drain the deposit via the permissionless reclaimDeposit path.
    ///
    ///      `lp == address(0)` is the reserved "nothing escrowed" sentinel. A zero
    ///      usdcAmount is still rejected (FR-3Z9O) because such an escrow could never be
    ///      minted (mint rejects a zero amount) and could only be unwound through the
    ///      24-hour reclaim timelock.
    ///
    ///      Declared after intentTimestamps rather than at the end of storage so
    ///      escrow state sits beside the reclaim state that reads it. Safe because
    ///      EIP-1167 clones are never upgraded in place: a layout change reaches
    ///      only vaults deployed from a newly-published implementation.
    mapping(bytes32 => PendingDeposit) public pendingDeposits;

    // ──────────────────────────────────────────────
    // TickBitmap (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev One uint256 word per 256 consecutive ticks. Bit N is set when the
    ///      tick at (wordPosition * 256 + N) is initialized. Enables O(1) per-word
    ///      lookup of the next initialized tick during updateTick.
    mapping(int16 => uint256) public tickBitmap;

    // ──────────────────────────────────────────────
    // Outcome-token identity (FR-5XY1, FR-5XY2)
    // ──────────────────────────────────────────────

    /// @dev Declared here rather than beside the other per-vault config above, which is
    ///      where they logically belong. Inserting three slots into that block shifts
    ///      every slot beneath it, including the position, tick, and bitmap mappings whose
    ///      numbering several test fixtures compute by hand. Declaring them below those
    ///      leaves that numbering intact. Safe for the same reason given at
    ///      `pendingDeposits` above: EIP-1167 clones are never upgraded in place, so a
    ///      layout change reaches only vaults deployed from a newly-published
    ///      implementation. Note this is still an insertion, not a true append — the
    ///      EIP-712 and reentrancy-guard slots declared further down do move.

    /// @dev The prepared condition this vault's market resolves against — the input
    ///      splitPosition requires to mint a complete set from USDC.
    // would be immutable in a non-clone contract; storage because EIP-1167.
    bytes32 public conditionId;

    /// @dev The two ERC-1155 position ids this vault is allowed to hold. Verified at
    ///      initialize() to be the pair deriving from (usdc, conditionId); which one is
    ///      labelled YES is the order the Oracle passed them in.
    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint256 public yesTokenId;

    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint256 public noTokenId;

    // ──────────────────────────────────────────────
    // EIP-712 (inlined per pattern policy in CLAUDE.md)
    // ──────────────────────────────────────────────

    bytes32 public DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");

    /// @dev Authorizes CANCELLING a pending deposit, as opposed to funding and
    ///      minting one. Carries the same five fields as MintIntent, so the two
    ///      differ only by typehash — which is the entire point (ADR-4029). Reusing
    ///      MintIntent here would mean the one signature an LP produces to fund a
    ///      position doubles as authorization to cancel it, letting an Operator who
    ///      holds that signature unilaterally reverse the LP's intent. The same
    ///      reasoning applies to any future burnPositionFor / collectFor authorization.
    bytes32 private constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");

    /// @dev Authorizes CLOSING a position, as opposed to funding or cancelling one
    ///      (ADR-7G5H). A third disjoint namespace: a MintIntent or ReclaimIntent
    ///      signature cannot be replayed here, and a BurnIntent signature is rejected by
    ///      depositForIntent, mintPositionFor, and reclaimDepositFor. Without that
    ///      separation the one signature an LP produces to OPEN a position would double
    ///      as authorization to CLOSE it, letting an Operator holding it exit the LP
    ///      unilaterally at a currentTick of the Operator's choosing.
    ///
    ///      Carries positionId ALONE, deliberately. The owner is not a field: the digest
    ///      has to stay computable after a burn has zeroed the position record, because
    ///      burnPositionFor checks the replay guard BEFORE the position-liveness check so
    ///      a replayed authorization reports IntentAlreadyUsed rather than
    ///      PositionNotFound (FR-7G55). Owner binding happens instead by comparing the
    ///      recovered signer against position.owner, which is strictly stronger than
    ///      trusting a signed field would be.
    bytes32 private constant BURN_INTENT_TYPEHASH = keccak256("BurnIntent(uint256 positionId)");

    uint256 private constant SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @dev Scaling factor for liquidity computation: L = usdcAmount * PRECISION / rangeWidth
    uint256 public constant LIQUIDITY_PRECISION = 1e18;

    /// @dev Q128 = 2^128. Scaling factor for fee accumulator fixed-point math.
    uint256 internal constant Q128 = 1 << 128;

    /// @dev Maximum number of initialized ticks that can be crossed in a single
    ///      updateTick call. Prevents gas griefing on large price moves.
    uint256 internal constant MAX_TICK_CROSSINGS = 256;

    /// @dev Minimum wait between Phase 1 (reclaim submission) and Phase 2 (execution).
    ///      24 hours = 86400 seconds. Polygon block.timestamp tolerance is ±15s, which
    ///      is negligible at this scale.
    uint256 public constant RECLAIM_TIMELOCK = 24 hours;

    /// @dev Minimum silence duration before any position holder can trigger
    ///      emergencyCancelAll. 7 days is long enough to distinguish operator
    ///      outage from normal low-activity periods. Polygon block.timestamp
    ///      tolerance is ±15s, negligible at this scale.
    uint256 public constant EMERGENCY_CANCEL_TIMELOCK = 7 days;

    // ──────────────────────────────────────────────
    // Reentrancy guard (inlined per pattern policy in CLAUDE.md)
    // ──────────────────────────────────────────────

    /// @dev 1 = not entered, 2 = entered. Set to 1 in initialize().
    uint256 private _reentrancyGuard;

    // ──────────────────────────────────────────────
    // Burn authorization state (FEAT-7G40)
    // ──────────────────────────────────────────────

    /// @dev BurnIntent digest => true once burnPositionFor has consumed it (FR-7G55).
    ///
    ///      Deliberately NOT the shared `usedIntents` mapping. A BurnIntent digest is a
    ///      pure function of (domainSeparator, positionId), so anyone can precompute the
    ///      digest for anyone else's position. Sharing the slot would let an attacker
    ///      escrow and mint a throwaway intent whose LP-chosen `intentId` IS the burn
    ///      digest of a victim's position, permanently marking it used and denying that
    ///      position the gas-sponsored exit forever. A separate mapping removes the
    ///      collision rather than relying on nobody noticing it.
    ///
    ///      Appended at the end of storage; safe for the reason given at pendingDeposits
    ///      above — EIP-1167 clones are never upgraded in place, so a layout change
    ///      reaches only vaults deployed from a newly-published implementation.
    mapping(bytes32 => bool) public usedBurnAuthorizations;

    // ──────────────────────────────────────────────
    // Solvency ledger (FEAT-9BQZ, UC-9BR0)
    // ──────────────────────────────────────────────

    /// @dev What the vault owes, per asset, as running totals maintained incrementally
    ///      by every operation that creates, discharges, or transforms an obligation
    ///      (FR-9BR3). Never reconstructed by iterating positions: iteration would make
    ///      the cost grow with position count and put the exit paths at the mercy of a
    ///      gas limit — the failure this ledger exists to prevent.
    ///
    ///      Every total is a COUNT OF TOKENS, never a dollar value, and no read or write
    ///      here consults a price (FR-9BR4). Dollar-denominating would recreate the bug
    ///      this ledger exists to fix: record "owed $60" against 100 YES at $0.60, watch
    ///      the price halve, and the vault owes $60 backed by $30. Owe 100 YES, hold
    ///      100 YES, and the vault is square at any price.
    ///
    ///      `public` is load-bearing, not convenience: the generated getters are the
    ///      entire monitoring surface (FR-9BR6). Because no path reverts on a shortfall
    ///      (FR-9BRS), reading these off-chain is the only way one becomes visible.
    ///
    ///      Appended at the end of storage; safe for the reason given at
    ///      usedBurnAuthorizations above.

    /// @dev Principal owed, per asset. Raised on mint by a position's starting split and
    ///      lowered on burn by its split at burn time (T-002). NOT touched by fee
    ///      collection: a collect changes neither liquidity nor the tick range, so the
    ///      position's principal claim is unchanged (FR-9BR7).
    ///
    ///      YES and NO are separate, non-negative, and NEVER collapsed into one signed
    ///      net (FR-9BR5). Under a signed net, a position tilted toward YES and one
    ///      tilted toward NO cancel — so a vault holding neither token would report
    ///      itself solvent while unable to pay either side. The vault holds two distinct
    ///      ERC-1155 balances; this mirrors that.
    uint256 public totalUsdcOwed;
    uint256 public totalYesOwed;
    uint256 public totalNoOwed;

    /// @dev Fee entitlement owed, per asset. Raised by notifyFees and lowered by collect
    ///      and burn, each by what it actually paid out (T-003). Three totals rather than
    ///      one because which asset a fee arrives in is a property of the fill the
    ///      exchange executed, not a choice the vault makes.
    uint256 public totalFeesUsdcOwed;
    uint256 public totalFeesYesOwed;
    uint256 public totalFeesNoOwed;

    /// @dev USDC held against intents that have been funded but not yet minted.
    ///
    ///      Belongs in the usdcRatio denominator (FR-9BRM) because depositForIntent pulls
    ///      real USDC that already sits in that ratio's numerator. Omitting it would
    ///      overstate solvency by exactly the pending-escrow balance and let a burner be
    ///      paid in full out of money owed to a depositor who never got their position.
    uint256 public totalEscrowed;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error AlreadyInitialized();
    error NotFactory();
    error NotAdmin();
    error NotOperator();
    error NotOracle();
    error ZeroFloor();
    error InvalidRange();
    error TickNotAligned();
    error VaultNotActive();
    error ZeroAmount();
    error IntentAlreadyUsed();
    error InvalidSignature();
    error BelowMinimumFirstLiquidity();
    error NoActiveLiquidity();
    error SafeCastOverflow();
    error TransferFailed();
    error Reentrancy();
    error SameTick();
    error TooManyTicksCrossed();
    error NotPositionOwner();
    error PositionNotFound();
    error TimelockNotElapsed();
    error NotIntentOwner();
    error NoPositionHeld();
    error VaultCancelled();
    error RangeMismatch();
    error InsufficientPositions();
    error TradingIsPaused();
    error NotConditionalTokens();
    error ZeroConditionId();
    error ZeroTokenId();
    error DuplicateTokenId();
    error TokenIdMismatch();
    error UnknownTokenId();
    error DepositAlreadyEscrowed();
    error DepositNotEscrowed();
    error NothingToReclaim();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    // SC-JGEF: emitted when Oracle transitions vault from Active to WindDown
    event VaultWindDownStarted(bytes32 indexed marketId);

    // SC-JXQX: emitted when a position holder triggers emergency cancel
    event EmergencyCancelExecuted(address indexed caller);

    // SC-TOGT, SC-TOGU: emitted when Operator distributes fee revenue
    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

    // SC-TVS2 through SC-TVS4: emitted on every successful tick update
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    // SC-U07B, SC-U07F, SC-U07G: emitted when LP collects nonzero fees
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

    // SC-JAIL: emitted on Phase 1 of reclaimDeposit (records submission timestamp)
    event ReclaimSubmitted(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // SC-JAIL: emitted on Phase 2 of reclaimDeposit (USDC transferred to LP)
    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // SC-K1M9: emitted when Operator merges same-range positions
    event PositionsMerged(uint256[] positionIds, uint256 survivorId);

    // SC-K1ML: emitted when Admin pauses trading
    event TradingPaused(address indexed caller);

    // SC-K1MM: emitted when Admin unpauses trading
    event TradingUnpaused(address indexed caller);

    // SC-3Z94: emitted when the Operator escrows an LP's deposit against an intent
    event DepositEscrowed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // SC-7G43 through SC-7G4E, SC-7G49, SC-7G4A, SC-7G4K: emitted on every successful burn,
    // through either entry point. outcomeTokenAmount is the size of the complete set paid:
    // that many yesTokenId AND that many noTokenId (ADR-7G5F).
    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcAmount,
        uint256 outcomeTokenAmount,
        uint256 feesAmount
    );

    // SC-T7AH, SC-T7AI, SC-T7AJ: emitted on every successful position mint
    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 usdcAmount,
        bytes32 intentId
    );

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    /// @dev One-shot guard. Reverts if _initialized is already true.
    modifier initializer() {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyAdmin() {
        if (ILPVaultFactory(factory).admins(msg.sender) != 1) revert NotAdmin();
        _;
    }

    modifier onlyOperator() {
        if (ILPVaultFactory(factory).operators(msg.sender) != 1) revert NotOperator();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != ILPVaultFactory(factory).oracle()) revert NotOracle();
        _;
    }

    /// @dev Gates the ERC-1155 receiver hooks. Inside a receiver hook msg.sender is the
    ///      token contract itself, so comparing it to `conditionalTokens` pins the vault
    ///      to its own market's ERC-1155 and rejects every other token contract.
    modifier onlyConditionalTokens() {
        if (msg.sender != conditionalTokens) revert NotConditionalTokens();
        _;
    }

    /// @dev Gates trading entry points while the vault is paused.
    ///      LP exit paths (collect, reclaimDeposit) are NOT gated.
    modifier whenNotPaused() {
        if (paused) revert TradingIsPaused();
        _;
    }

    /// @dev Records Operator liveness (FEAT-JXQO, FR-JXQS). Stacked alongside onlyOperator
    ///      on every Operator-gated function so any successful Operator call refreshes the
    ///      emergency-cancel silence timer. Kept separate from onlyOperator so that modifier
    ///      does access control only, and so the requirement stays visible in each function's
    ///      signature — a new Operator-gated function missing it is obvious at a glance.
    ///      Writing before the body is equivalent to writing after: a revert rolls back the
    ///      whole transaction, so the timer advances if and only if the call succeeds.
    modifier touchesHeartbeat() {
        lastOperatorActivityTimestamp = block.timestamp;
        _;
    }

    /// @dev Inlined reentrancy guard. _reentrancyGuard is set to 1 in initialize().
    modifier nonReentrant() {
        if (_reentrancyGuard != 1) revert Reentrancy();
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    // ──────────────────────────────────────────────
    // Constructor (implementation only)
    // ──────────────────────────────────────────────

    // SC-REQ5: _disableInitializers prevents anyone from calling initialize()
    //          on the implementation contract directly.
    constructor() {
        _disableInitializers();
    }

    /// @dev Sets _initialized = true so the initializer modifier always reverts.
    ///      Called once in the implementation's constructor. Clones skip the
    ///      constructor, so their _initialized starts at false (default).
    function _disableInitializers() internal {
        _initialized = true;
    }

    // ──────────────────────────────────────────────
    // Initialization (clone only)
    // ──────────────────────────────────────────────

    // SC-REQ6, SC-REQA: initializes vault clone with config, approvals, and factory guard
    /// @notice Initializes a freshly-deployed vault clone with per-market configuration.
    /// @dev Called exactly once by LPVaultFactory.createVault(). The factory_ param
    ///      must match msg.sender — defense-in-depth beyond the one-shot initializer.
    ///      Role state (operators, oracle, admins) is NOT copied from the factory.
    ///      The vault reads role state from the factory at call time via ILPVaultFactory.
    ///      Approval scope: setApprovalForAll(exchange, true) on the ConditionalTokens
    ///      is acceptable BECAUSE the vault holds outcome tokens for exactly one market.
    ///      That is enforced, not assumed: the receiver hooks reject every token id
    ///      outside {yesTokenId, noTokenId}, so no foreign id can enter the vault even
    ///      though the approval itself is unscoped.
    /// @param marketId_ Unique market identifier from the CTF Exchange
    /// @param usdc_ USDC ERC-20 address
    /// @param exchange_ ProphetCTFExchange address
    /// @param conditionalTokens_ Gnosis ConditionalTokens (ERC-1155) address
    /// @param tickSpacing_ Minimum tick increment for positions
    /// @param factory_ Factory contract address — must equal msg.sender
    /// @param minimumFirstLiquidity_ Floor for the first mint when activeLiquidity == 0
    /// @param version_ Implementation version from the factory's counter
    /// @param conditionId_ Prepared condition this market resolves against
    /// @param yesTokenId_ ERC-1155 position id the vault treats as YES
    /// @param noTokenId_ ERC-1155 position id the vault treats as NO
    function initialize(
        bytes32 marketId_,
        address usdc_,
        address exchange_,
        address conditionalTokens_,
        int24 tickSpacing_,
        address factory_,
        uint128 minimumFirstLiquidity_,
        uint256 version_,
        bytes32 conditionId_,
        uint256 yesTokenId_,
        uint256 noTokenId_
    ) external initializer {
        // Factory guard: caller must be the factory that deployed this clone
        if (msg.sender != factory_) revert NotFactory();

        // Reject a malformed or mismatched outcome-token identity before anything is
        // written. A clone cannot be re-initialized and has no setter for these values,
        // so a wrong identity here is permanent.
        _validateOutcomeIdentity(usdc_, conditionalTokens_, conditionId_, yesTokenId_, noTokenId_);

        // Store factory address for auth delegation and onlyFactory checks
        factory = factory_;

        // Store per-vault configuration
        marketId = marketId_;
        usdc = usdc_;
        exchange = exchange_;
        conditionalTokens = conditionalTokens_;
        conditionId = conditionId_;
        yesTokenId = yesTokenId_;
        noTokenId = noTokenId_;
        tickSpacing = tickSpacing_;
        minimumFirstLiquidity = minimumFirstLiquidity_;
        implementationVersion = version_;

        // Set vault lifecycle to Active
        phase = 1;

        // Start the operator-silence timer from vault creation so the
        // emergency cancel timelock doesn't trigger prematurely
        lastOperatorActivityTimestamp = block.timestamp;

        // Enable reentrancy guard for nonReentrant functions
        _reentrancyGuard = 1;

        // Cache EIP-712 domain separator for signature verification
        _cachedChainId = block.chainid;
        DOMAIN_SEPARATOR = _computeDomainSeparator();

        // Pre-approve the exchange to spend USDC and outcome tokens on behalf of this vault
        IERC20(usdc_).approve(exchange_, type(uint256).max);
        IERC1155(conditionalTokens_).setApprovalForAll(exchange_, true);
    }

    // SC-5XY4, SC-5XY5: reject a malformed or mismatched outcome-token identity
    /// @notice Verifies that the supplied outcome-token identity is well-formed and
    ///         actually belongs to the supplied condition.
    /// @dev Kept out of initialize()'s own frame — with eleven parameters there, inlining
    ///      the four derivation locals pushes the function past the EVM's reachable stack.
    ///
    ///      The set comparison is deliberate: the derivation cannot know which index set
    ///      the market calls YES, so either order is accepted and the caller's order is
    ///      what names it. Both ids are still proven to belong to this condition.
    ///
    ///      Assumes a binary market with parentCollectionId == 0 and USDC as collateral,
    ///      which is the only market shape this repo supports.
    function _validateOutcomeIdentity(
        address usdc_,
        address conditionalTokens_,
        bytes32 conditionId_,
        uint256 yesTokenId_,
        uint256 noTokenId_
    ) internal view {
        if (conditionId_ == bytes32(0)) revert ZeroConditionId();
        if (yesTokenId_ == 0 || noTokenId_ == 0) revert ZeroTokenId();
        if (yesTokenId_ == noTokenId_) revert DuplicateTokenId();

        IConditionalTokens ct = IConditionalTokens(conditionalTokens_);
        uint256 first = ct.getPositionId(usdc_, ct.getCollectionId(bytes32(0), conditionId_, 1));
        uint256 second = ct.getPositionId(usdc_, ct.getCollectionId(bytes32(0), conditionId_, 2));

        bool matchesInOrder = yesTokenId_ == first && noTokenId_ == second;
        bool matchesSwapped = yesTokenId_ == second && noTokenId_ == first;
        if (!matchesInOrder && !matchesSwapped) revert TokenIdMismatch();
    }

    // ──────────────────────────────────────────────
    // ERC-1155 reception (FR-3WLI, FR-3WLJ, FR-3WLK, FR-5XY3)
    // ──────────────────────────────────────────────

    // SC-5XY6: reject any token id that does not belong to this vault's market
    /// @notice Reverts unless `id` is one of this vault's two outcome tokens.
    /// @dev The caller guard alone is not enough: one ConditionalTokens contract carries
    ///      the tokens of every market on the platform, so a correct caller can still be
    ///      delivering a token this vault has no business holding.
    /// @param id The ERC-1155 token id being transferred in
    function _requireOwnTokenId(uint256 id) internal view {
        if (id != yesTokenId && id != noTokenId) revert UnknownTokenId();
    }

    // SC-3WLL, SC-3WLN, SC-5XY6: acknowledge single outcome-token transfers from this vault's CTF
    /// @notice Accepts a single ERC-1155 outcome token transfer into the vault.
    /// @dev Stateless by design. The vault's position, tick, and fee accounting is driven
    ///      by mintPositionFor, burnPosition, collect, and notifyFees — never by observing
    ///      an inbound transfer — so this hook deliberately records nothing. Reconciling
    ///      raw token balances against position accounting is the Operator's off-chain job.
    ///      No nonReentrant guard: the hook mutates nothing and makes no external call, and
    ///      guarding it would revert legitimate transfers that occur inside an already-
    ///      guarded vault call.
    /// @param id The token id being transferred — must be yesTokenId or noTokenId
    /// @return The ERC-1155 single-transfer acknowledgement value.
    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        view
        onlyConditionalTokens
        returns (bytes4)
    {
        _requireOwnTokenId(id);
        return 0xf23a6e61;
    }

    // SC-3WLM, SC-3WLN, SC-5XY6: acknowledge batch outcome-token transfers from this vault's CTF
    /// @notice Accepts a batch ERC-1155 outcome token transfer into the vault.
    /// @dev Stateless for the same reasons as onERC1155Received above. Every element is
    ///      checked, so one foreign id rejects the whole batch — there is no partial
    ///      acceptance to reason about, and no ordering of the batch changes the outcome.
    ///      The loop needs no cap: its length is set by the ConditionalTokens contract and
    ///      paid for by whoever initiated the transfer, and a batch too large to check is
    ///      equally too large to transfer.
    /// @param ids The token ids being transferred — every one must be yesTokenId or noTokenId
    /// @return The ERC-1155 batch-transfer acknowledgement value.
    function onERC1155BatchReceived(address, address, uint256[] calldata ids, uint256[] calldata, bytes calldata)
        external
        view
        onlyConditionalTokens
        returns (bytes4)
    {
        uint256 length = ids.length;
        for (uint256 i = 0; i < length; ++i) {
            _requireOwnTokenId(ids[i]);
        }
        return 0xbc197c81;
    }

    // SC-3WLO: ERC-165 reporting so callers that probe before transferring proceed
    /// @notice Reports whether the vault implements a given interface.
    /// @param interfaceId The ERC-165 interface identifier to query.
    /// @return True for IERC1155Receiver (0x4e2312e0) and ERC-165 itself (0x01ffc9a7).
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x4e2312e0 || interfaceId == 0x01ffc9a7;
    }

    // ──────────────────────────────────────────────
    // Oracle governance
    // ──────────────────────────────────────────────

    // SC-RG75, SC-RG76, SC-RG77: oracle-only setter for minimum first liquidity floor
    /// @notice Updates the minimum liquidity required for the first mint in this vault.
    /// @dev Only callable by the oracle. Zero is rejected to maintain the invariant
    ///      that minimumFirstLiquidity > 0 at all times.
    /// @param newMin New floor value — must be greater than zero
    function setMinimumFirstLiquidity(uint128 newMin) external onlyOracle {
        if (newMin == 0) revert ZeroFloor();

        uint128 oldMin = minimumFirstLiquidity;
        minimumFirstLiquidity = newMin;

        emit MinimumFirstLiquidityUpdated(oldMin, newMin);
    }

    // SC-JGEF through SC-JGEK: Oracle-driven vault lifecycle transition
    /// @notice Transitions the vault from Active to WindDown phase.
    /// @dev One-way transition — there is no mechanism to revert from WindDown
    ///      back to Active. Once in WindDown, mintPositionFor reverts (existing
    ///      phase guard at the top of that function), while collect and
    ///      reclaimDeposit remain callable so LPs can exit.
    ///      ORACLE TRUST ASSUMPTION: The Oracle can freeze minting on any vault
    ///      by calling startWindDown(). LPs must trust that the Oracle only
    ///      triggers wind-down when the underlying market has resolved.
    function startWindDown() external onlyOracle {
        if (phase != 1) revert VaultNotActive();
        phase = 2;
        emit VaultWindDownStarted(marketId);
    }

    // ──────────────────────────────────────────────
    // Pause trading (FEAT-K1MD, UC-K1MK)
    // ──────────────────────────────────────────────

    // SC-K1ML, SC-K1MM, SC-K1MN: admin-only circuit breaker
    /// @notice Halts all trading entry points (mintPositionFor, notifyFees,
    ///         updateTick, mergePositions) while keeping LP exit paths live.
    /// @dev Does not change the vault's phase — pause and phase are orthogonal.
    function pauseTrading() external onlyAdmin {
        paused = true;
        emit TradingPaused(msg.sender);
    }

    /// @notice Resumes normal trading after a pause.
    /// @dev Does not change the vault's phase.
    function unpauseTrading() external onlyAdmin {
        paused = false;
        emit TradingUnpaused(msg.sender);
    }

    // ──────────────────────────────────────────────
    // Emergency cancel (FEAT-JXQO, UC-JXQW)
    // ──────────────────────────────────────────────

    // SC-JXQX through SC-JXR2: position-holder-triggered emergency force-close
    /// @notice Force-closes all open positions and distributes principal + accrued
    ///         fees to each position owner. Transitions vault to terminal Cancelled state.
    /// @dev Callable by any address that owns at least one position, after the
    ///      operator-silence timelock has elapsed. Iterates all positions (bounded
    ///      by nextPositionId), computes each position's payout, zeroes state, then
    ///      transfers USDC. Follows checks-effects-interactions: all state mutations
    ///      happen before any external transfer call.
    ///      The Cancelled phase (3) is terminal — no vault function succeeds after this.
    function emergencyCancelAll() external nonReentrant {
        // --- Checks ---

        // Already cancelled — terminal state, nothing to do
        if (phase == 3) revert VaultCancelled();

        // Operator-silence timelock must have elapsed (±15s Polygon tolerance is negligible at 7-day scale)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - lastOperatorActivityTimestamp < EMERGENCY_CANCEL_TIMELOCK) {
            revert TimelockNotElapsed();
        }

        // Caller must own at least one active position in this vault
        uint256 count = nextPositionId;
        bool callerHasPosition = false;
        for (uint256 i = 0; i < count; i++) {
            if (positions[i].owner == msg.sender && positions[i].liquidity > 0) {
                callerHasPosition = true;
                break;
            }
        }
        if (!callerHasPosition) revert NoPositionHeld();

        // --- Effects ---

        // Build payout arrays from position data before zeroing state
        address[] memory owners = new address[](count);
        uint256[] memory payouts = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            Position storage p = positions[i];
            if (p.liquidity == 0) continue;

            // Compute uncollected fees using the same accumulator formula as collect
            uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(p.tickLower, p.tickUpper);
            uint256 fees = _accruedFees(p.liquidity, feeGrowthInsideX128, p.feeGrowthInsideLastX128);
            fees += p.tokensOwed;

            // Reconstruct original principal from liquidity and tick range width
            uint256 rangeWidth = uint256(int256(p.tickUpper - p.tickLower));
            uint256 principal = uint256(p.liquidity) * rangeWidth / LIQUIDITY_PRECISION;

            owners[i] = p.owner;
            payouts[i] = principal + fees;

            // Zero position state
            p.liquidity = 0;
            p.tokensOwed = 0;
            p.feeGrowthInsideLastX128 = 0;
        }

        // Transition to terminal state
        activeLiquidity = 0;
        phase = 3;

        // Every live position was just paid out and zeroed, so no principal or fee
        // obligation survives (FR-9BRG). Cleared outright rather than debited per position
        // because the loop above discharges ALL of them: leaving a residue would report a
        // fully-drained vault as still owing, and every ratio would then read as a total
        // shortfall against an empty balance.
        //
        // Clearing is also the only reading that survives this path's payout composition.
        // The loop reconstructs principal across the FULL range width and pays it entirely
        // in USDC, regardless of currentTick — unlike _owedAmounts, which splits by where
        // the price sits. Debiting leg by leg would therefore strand the YES and NO totals
        // at whatever an in-range position was carrying, permanently, against a vault
        // holding nothing. (That composition mismatch is FEAT-JXQO's to resolve; the ledger
        // only has to avoid being corrupted by it.)
        //
        // totalEscrowed is deliberately NOT cleared. This function never touches
        // pendingDeposits, so it pays no escrow refund — and reclaimDeposit reverts once
        // phase == 3, leaving an unminted deposit with no path out. That obligation is
        // genuinely still outstanding, and the ledger's job is to keep reporting it rather
        // than forgive what the vault cannot settle.
        totalUsdcOwed = 0;
        totalYesOwed = 0;
        totalNoOwed = 0;
        totalFeesUsdcOwed = 0;
        totalFeesYesOwed = 0;
        totalFeesNoOwed = 0;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        for (uint256 i = 0; i < count; i++) {
            if (payouts[i] > 0) {
                _safeTransfer(usdc, owners[i], payouts[i]);
            }
        }

        emit EmergencyCancelExecuted(msg.sender);
    }

    // ──────────────────────────────────────────────
    // Escrow deposit (FEAT-3ZRI, UC-3Z92)
    // ──────────────────────────────────────────────

    // SC-3Z94 through SC-3Z9B: operator-gated per-intent USDC escrow
    /// @notice Pulls an LP's USDC into the vault and records it against a specific
    ///         signed mint intent, funding that intent so `mintPositionFor` can later
    ///         convert it into a position.
    /// @dev Verifies the SAME `MintIntent` struct that `mintPositionFor` verifies, so
    ///      the LP signs once and that one signature authorizes both the escrow and
    ///      the mint. Range and tick-alignment rules are deliberately NOT checked here;
    ///      they are enforced at mint, which keeps the validation rules in one place.
    ///      The cost is that an LP can escrow against a malformed intent that mint will
    ///      always reject, leaving them to recover it through the reclaim path.
    ///
    ///      OPERATOR TRUST ASSUMPTION: The Operator chooses whether and when to escrow
    ///      an LP's signed intent. They cannot fabricate a deposit — every escrow needs
    ///      that LP's own EIP-712 signature over these exact fields, so a compromised
    ///      Operator key can censor, reorder, or delay an onboarding, but cannot pull
    ///      funds from an LP who never signed. An Operator who simply refuses to call
    ///      this leaves the LP's USDC untouched in the LP's own wallet: nothing is
    ///      pulled until this function runs, so unlike the exit paths there is nothing
    ///      to rescue and deliberately no permissionless twin (FR-3Z9V).
    ///
    ///      MEV analysis: this function moves value but creates no position, touches no
    ///      tick, and reads no price, so its ordering relative to other transactions
    ///      changes nothing an observer could profit from. The front-running risk the
    ///      Operator chokepoint exists to prevent — an attacker seeding a tiny position
    ///      ahead of a real LP's deposit to skew tick-initialization and fee-growth
    ///      state — lives in `mintPositionFor`, which is separately Operator-gated. The
    ///      one ordering effect here is that escrowing an intentId blocks a competing
    ///      escrow of the same intentId, and intentIds are LP-chosen and signature-bound,
    ///      so no third party can race for one.
    /// @param lp LP wallet address — must match the signer of the EIP-712 intent
    /// @param tickLower Lower tick bound from the MintIntent — part of the signed digest
    /// @param tickUpper Upper tick bound from the MintIntent — part of the signed digest
    /// @param usdcAmount USDC to pull from the LP's wallet — must be > 0
    /// @param intentId Unique identifier this escrow is recorded against
    /// @param lpSignature EIP-712 signature from the LP over the MintIntent struct
    function depositForIntent(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata lpSignature
    ) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat {
        // --- Checks ---

        // Escrow only ever funds a mint, and mints are Active-only. Accepting a
        // deposit into a wound-down or cancelled vault would strand the LP's USDC
        // until the reclaim timelock elapsed.
        if (phase != 1) revert VaultNotActive();

        // A zero-value escrow could never be minted -- mint rejects a zero usdcAmount
        // (FR-T7B5) -- so it could only ever be unwound through the 24-hour reclaim
        // timelock. Rejecting it here keeps every entry in the mapping spendable.
        // (The "nothing escrowed" sentinel is the entry's zero lp address, not its
        // amount; see the pendingDeposits declaration.)
        if (usdcAmount == 0) revert ZeroAmount();

        // Verify the LP authorized this exact deposit
        _verifyMintIntent(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature);

        // Never escrow twice against one intent — that is the double-charge this
        // whole mechanism exists to prevent. Keying the guard on the recorded
        // depositor rather than the amount also stops a second, different LP from
        // straddling an intentId another LP has already funded.
        if (pendingDeposits[intentId].lp != address(0)) revert DepositAlreadyEscrowed();

        // Never re-fund an intent already consumed by a mint or a completed reclaim.
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // --- Effects ---

        // Record WHO deposited alongside how much. Every consuming path checks the
        // `lp` field, because a valid signature over an intentId does not prove
        // ownership of it — see the mapping's declaration.
        pendingDeposits[intentId] = PendingDeposit({lp: lp, amount: _toUint96(usdcAmount)});

        // The obligation enters the ledger in the same call that pulls the USDC backing
        // it (FR-9BRD), so the two never disagree — and before the transfer, per the
        // effects-then-interactions ordering NFR-9BRY requires of every ledger write.
        totalEscrowed += usdcAmount;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        _safeTransferFrom(usdc, lp, address(this), usdcAmount);

        emit DepositEscrowed(intentId, lp, usdcAmount);
    }

    // ──────────────────────────────────────────────
    // Position minting (FEAT-T7AF, UC-T7AG)
    // ──────────────────────────────────────────────

    // SC-T7AH through SC-T7AR: operator-gated LP position mint via EIP-712 signed intent
    // SC-3Z9J, SC-3Z9K, SC-45IE: the mint's escrow requirement and ownership check
    /// @notice Executes an LP's signed EIP-712 mint intent to create a concentrated-liquidity position.
    /// @dev Funding comes entirely from the intent's escrow (FEAT-3ZRI): this function
    ///      makes no external token call at all. The escrow must have been recorded
    ///      against this exact LP, for this exact amount, by a prior depositForIntent.
    ///
    ///      OPERATOR TRUST ASSUMPTION: The Operator can submit any LP's signed intent
    ///      at any time. LPs must trust that the Operator submits their intent promptly.
    ///      This trust is bounded by the reclaimDeposit escape hatch (FEAT-JAIJ), which
    ///      lets the LP recover an escrow the Operator never mints without needing the
    ///      Operator's cooperation. What the Operator cannot do is redirect one LP's
    ///      deposit to another: the escrow records its depositor, and this function
    ///      rejects any mint whose named LP is not that address.
    /// @param lp LP wallet address — must match both the signer of the EIP-712 intent
    ///        and the depositor recorded on the intent's escrow
    /// @param tickLower Lower tick bound — must be < tickUpper and aligned to tickSpacing
    /// @param tickUpper Upper tick bound — must be > tickLower and aligned to tickSpacing
    /// @param usdcAmount Position principal — must be > 0 and must exactly equal the
    ///        amount escrowed against intentId. Not pulled from the LP's wallet here;
    ///        it was debited earlier, at escrow time.
    /// @param intentId Unique identifier for replay protection, and the key of the
    ///        escrow this mint consumes
    /// @param signature EIP-712 signature from the LP over the MintIntent struct
    /// @return positionId The ID of the newly created position
    function mintPositionFor(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata signature
    ) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat returns (uint256 positionId) {
        // --- Checks ---

        // Vault must be active (not wound down)
        if (phase != 1) revert VaultNotActive();

        // USDC amount must be non-zero
        if (usdcAmount == 0) revert ZeroAmount();

        // Range must be valid: lower < upper
        if (tickLower >= tickUpper) revert InvalidRange();

        // Both ticks must align to the vault's tickSpacing
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) revert TickNotAligned();

        // Verify EIP-712 signature from the LP
        _verifyMintIntent(lp, tickLower, tickUpper, usdcAmount, intentId, signature);

        // Replay protection: each intentId can only be used once. Checked ahead of the
        // escrow so that a mint replayed after a successful one reports
        // IntentAlreadyUsed — the first mint deleted the escrow on its way out, so an
        // escrow-first order would misreport the replay as DepositNotEscrowed.
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // The intent must already be funded — by this LP, for exactly this amount.
        PendingDeposit memory deposit = pendingDeposits[intentId];

        // Nothing escrowed at all. Minting here would create liquidity against USDC
        // the vault never collected (FR-3Z9W). The sentinel is the zero lp address.
        if (deposit.lp == address(0)) revert DepositNotEscrowed();

        // Escrowed, but by someone else. A valid signature over an intentId proves
        // only that someone signed it, never that they funded it: _verifyMintIntent
        // compares the recovered signer against this caller-supplied `lp`, so any
        // party can sign over any intentId by naming their own address. The recorded
        // depositor is what settles ownership (FR-45ID). Without this check a
        // colluding or compromised Operator could mint one LP a position funded
        // entirely by another's deposit. Checked before the amount so a foreign claim
        // reports NotIntentOwner rather than being masked by an amount mismatch.
        if (deposit.lp != lp) revert NotIntentOwner();

        // Exact equality, not sufficiency (FR-3Z9W): a position must never be minted
        // larger than the USDC actually collected for it, and a smaller one would
        // silently strand the remainder in an escrow this mint is about to delete.
        if (deposit.amount != usdcAmount) revert DepositNotEscrowed();

        // --- Effects ---

        usedIntents[intentId] = true;

        // Consume the escrow. Deleting it here is what makes mint and reclaim mutually
        // exclusive on the same deposit (FR-3ZVK): neither a second mint nor a reclaim
        // can draw on an escrow that no longer exists.
        delete pendingDeposits[intentId];

        // The pending-refund obligation is discharged, but nothing is forgiven: it
        // changes form into a live position claim, which T-002 records on the principal
        // totals in this same call (FR-9BRE). Safe against underflow (NFR-9BRT) because
        // depositForIntent added exactly this amount and the equality check above proves
        // `usdcAmount` is that amount.
        totalEscrowed -= usdcAmount;
        // ...and re-enters it as a position claim below, once the position record exists
        // and its starting split can be computed (FR-9BR8). Both legs land in this one
        // call, so the obligation is never double-counted across its two forms nor
        // dropped between them.

        // Compute liquidity weight from USDC and range width
        // casting to uint256 is safe because tickUpper > tickLower is validated above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 rangeWidth = uint256(int256(tickUpper - tickLower));
        uint128 liquidity = _toUint128(usdcAmount * LIQUIDITY_PRECISION / rangeWidth);

        // First-mint floor check (FR-RFS7 from FEAT-REPZ)
        if (activeLiquidity == 0 && liquidity < minimumFirstLiquidity) {
            revert BelowMinimumFirstLiquidity();
        }

        // Initialize ticks if they haven't been used before (liquidityGross == 0)
        _initializeTick(tickLower);
        _initializeTick(tickUpper);

        // Update tick state: liquidityGross tracks total references, liquidityNet
        // tracks the directional delta applied when the tick is crossed
        ticks[tickLower].liquidityGross += liquidity;
        ticks[tickLower].liquidityNet += _toInt128(liquidity);
        ticks[tickUpper].liquidityGross += liquidity;
        ticks[tickUpper].liquidityNet -= _toInt128(liquidity);

        // Snapshot feeGrowthInside at mint time to prevent retroactive fee claims
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(tickLower, tickUpper);

        // Create the position record
        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: lp,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInsideLastX128: feeGrowthInsideX128,
            tokensOwed: 0
        });

        // Update active liquidity if the position is in-range
        if (tickLower <= currentTick && currentTick < tickUpper) {
            activeLiquidity += liquidity;
        }

        // Record the new obligation using the SAME split model the burn discharges it
        // with (FR-9BR8), so credit and debit cannot disagree. Reading _owedAmounts here
        // rather than crediting the raw `usdcAmount` is load-bearing on two counts:
        //
        //   1. A position minted while currentTick already sits inside its range is
        //      split from its very first block — it owes outcome tokens immediately,
        //      with no price movement at all. Crediting all-USDC would understate the
        //      YES and NO obligations permanently, because updateTick only accumulates
        //      shifts for segments it TRAVERSES and never revisits a range that was
        //      already straddled at mint. That is a gap no later task closes.
        //
        //   2. `liquidity` above truncates, so the reconstructed principal can be
        //      marginally below `usdcAmount`. Crediting the deposit would strand that
        //      remainder as a phantom obligation surviving the position's own burn.
        //
        // Both make the ledger claim what the vault cannot pay, which is the exact
        // failure FR-9BR5 and the conservation invariant (NFR-9BRX) exist to catch.
        // Scoped so the two locals release their stack slots before the emit below —
        // mintPositionFor is already close to the EVM's stack-depth limit.
        {
            (uint256 startingUsdc, uint256 startingOutcome) = _owedAmounts(positions[positionId]);
            _creditPrincipal(startingUsdc, startingOutcome, startingOutcome);
        }

        // No interactions: the USDC backing this position was pulled at escrow time
        // (FEAT-3ZRI), so mint makes no external token call. The nonReentrant modifier
        // stays as defense-in-depth (NFR-T7B7) — it guards position, tick, and
        // activeLiquidity state that other guarded paths read, and ensures a future
        // revision that reintroduces an external call cannot silently inherit an
        // unguarded function.

        emit PositionMinted(positionId, lp, tickLower, tickUpper, liquidity, usdcAmount, intentId);
    }

    // ──────────────────────────────────────────────
    // Fee collection (FEAT-U079, UC-U07A)
    // ──────────────────────────────────────────────

    // SC-U07B through SC-U07G: LP collects accumulated trading fees
    /// @notice Withdraws accumulated trading fees from a position without removing it.
    /// @dev No phase restriction — collect works in both Active and WindDown to ensure
    ///      LPs have an unbounded claim window post-resolution. The feeGrowthInsideLastX128
    ///      snapshot prevents double-counting: each collect only pays fees that grew since
    ///      the previous collect (or since mint).
    /// @param positionId The ID of the position to collect fees from
    function collect(uint256 positionId) external nonReentrant {
        // --- Checks ---

        // Cancelled vaults have already distributed all funds
        if (phase == 3) revert VaultCancelled();

        Position storage p = positions[positionId];

        // Position must exist (owner is never set to address(0) during mint)
        if (p.owner == address(0)) revert PositionNotFound();

        // Only the position's owner can collect
        if (p.owner != msg.sender) revert NotPositionOwner();

        // --- Effects ---

        // Compute current feeGrowthInside for this position's tick range
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(p.tickLower, p.tickUpper);

        // Calculate fees accrued since the last collect (or mint).
        uint256 owed = _accruedFees(p.liquidity, feeGrowthInsideX128, p.feeGrowthInsideLastX128);

        // Include previously accumulated fees (e.g., rolled up from mergePositions)
        owed += p.tokensOwed;
        p.tokensOwed = 0;

        // Snapshot update: future collects start from here
        p.feeGrowthInsideLastX128 = feeGrowthInsideX128;

        // Discharge the fee entitlement by what this call actually pays (FR-9BRB) —
        // the transferred amount, not the pre-haircut figure T-006's ratio will scale
        // from, so a haircut never erases an obligation the vault has not settled.
        // Deliberately touches no principal total: a collect leaves the position's
        // liquidity and range untouched, so its principal claim is unchanged (FR-9BR7).
        totalFeesUsdcOwed = _saturatingSub(totalFeesUsdcOwed, owed);

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        if (owed > 0) {
            _safeTransfer(usdc, msg.sender, owed);
            emit FeesCollected(positionId, msg.sender, owed);
        }
    }

    // ──────────────────────────────────────────────
    // Position burn (FEAT-7G40, UC-7G41, UC-7G42)
    // ──────────────────────────────────────────────

    // SC-7G43 through SC-7G4B: LP closes a position they own, with no Operator involvement
    /// @notice Closes a position the caller owns and pays out everything it holds —
    ///         USDC, outcome tokens, or a split of both, plus accrued fees.
    /// @dev Unconditional by design (ADR-7G5G): this function requires no Operator action,
    ///      no Operator signature, and reads no Operator registry state, and it is gated
    ///      behind no declared emergency and no timelock. That is what makes it the escape
    ///      hatch rather than another Operator-gated path — an LP completes it in a vault
    ///      whose entire operator set has been removed by the Admin (NFR-7G5B). Any future
    ///      change that gives this path a dependency on Operator liveness voids the
    ///      protocol's guarantee that LP capital cannot be trapped.
    ///
    ///      Deliberately does NOT refresh lastOperatorActivityTimestamp (FR-7G50). This is
    ///      not an Operator action, and letting LP activity refresh the silence timer would
    ///      let LPs exiting a stalled vault mask a dead Operator from emergencyCancelAll —
    ///      the same reasoning that keeps reclaimDeposit off the heartbeat.
    ///
    ///      Restricted to the owner for timing control, not custody (ADR-7G5I): the payout
    ///      composition depends on currentTick at call time, so an unrestricted caller
    ///      could force an LP's exit at an adversarially chosen moment and lock them into a
    ///      split they never chose, even with the funds landing at the correct owner.
    /// @param positionId The ID of the position to close
    function burnPosition(uint256 positionId) external nonReentrant {
        // --- Checks ---

        Position storage p = _requireBurnable(positionId);

        // Only the position's owner can close it
        if (p.owner != msg.sender) revert NotPositionOwner();

        _burn(positionId);
    }

    // SC-7G4C through SC-7G4K: operator-relayed burn against an LP-signed authorization
    /// @notice Closes a position on the owner's behalf, from an EIP-712 BurnIntent they
    ///         signed off-chain, with the Operator paying the gas. The entire payout goes
    ///         to the position's recorded owner.
    /// @dev Runs the same `_burn` body as `burnPosition`, so the two differ only in their
    ///      authorization checks and in whether the Operator heartbeat is refreshed
    ///      (ADR-7G5E). No payout or accounting arithmetic exists twice, so the paths
    ///      cannot drift.
    ///
    ///      OPERATOR TRUST ASSUMPTION: The Operator chooses whether and when to relay a
    ///      burn, so they can censor, reorder, or delay an exit. What they cannot do is
    ///      initiate one: every burn needs the owner's own signature over a BurnIntent, a
    ///      struct with its own typehash, so a MintIntent or ReclaimIntent the LP signed
    ///      earlier is NOT replayable here (ADR-7G5H). Nor can they redirect the money —
    ///      every asset goes to `position.owner`, read from storage, never to `msg.sender`
    ///      and never to a caller-supplied address. An Operator who simply refuses to relay
    ///      leaves the LP with `burnPosition`, which needs no Operator at all.
    ///
    ///      MEV analysis: this function moves value AND reads a price, which makes it
    ///      different from the other relayed paths. Because the payout composition is a
    ///      function of `currentTick` at execution time (FR-7G4M), an Operator holding a
    ///      signed authorization chooses which block it lands in and therefore which tick
    ///      prices the exit — they can wait for a tick that hands the LP more outcome-token
    ///      inventory and less USDC, or the reverse. The signature does not bind a tick, a
    ///      deadline, or a minimum payout, so this is a real residual risk, accepted in
    ///      ADR-7G5I rather than engineered away. Two things bound it: the Operator gains
    ///      nothing directly, since no payout can be routed to them and no order is placed
    ///      against the LP's assets; and the LP's remedy is unilateral — `burnPosition`
    ///      executes in a block of the LP's own choosing and cannot be blocked by the
    ///      Operator. The burn itself touches no tick and places no order, so it creates no
    ///      sandwich opportunity for a third party.
    /// @param positionId The ID of the position to close
    /// @param lpSignature EIP-712 signature from the position's owner over the BurnIntent
    function burnPositionFor(uint256 positionId, bytes calldata lpSignature)
        external
        onlyOperator
        nonReentrant
        touchesHeartbeat
    {
        // --- Checks ---

        // The digest is a pure function of positionId, so it stays computable after a burn
        // has zeroed the position record. That is what lets the replay guard run BEFORE
        // the liveness check below, so a resubmitted authorization reports
        // IntentAlreadyUsed rather than being absorbed as PositionNotFound (FR-7G55).
        bytes32 digest = _burnIntentDigest(positionId);
        if (usedBurnAuthorizations[digest]) revert IntentAlreadyUsed();

        Position storage p = _requireBurnable(positionId);

        // Operator authority alone never closes a position: the signature must recover to
        // the position's recorded owner, not to any address the caller names.
        _verifyBurnIntent(digest, p.owner, lpSignature);

        // --- Effects ---

        // Check-then-set before any external work, per CLAUDE.md security checklist item 4.
        usedBurnAuthorizations[digest] = true;

        _burn(positionId);
    }

    /// @dev Shared liveness gate for both burn entry points. Returns the position so the
    ///      caller can apply its own authorization check against it.
    ///
    ///      A zero-liquidity record with a live owner is NOT burnable: both
    ///      emergencyCancelAll and mergePositions leave records in that shape, and their
    ///      liquidity has already been removed from tick state or rolled into a survivor.
    ///      Burning one would delete the record while decrementing tick state by zero,
    ///      which is silent corruption rather than an error.
    function _requireBurnable(uint256 positionId) internal view returns (Position storage p) {
        // Cancelled vaults have already distributed all funds
        if (phase == 3) revert VaultCancelled();

        p = positions[positionId];

        // Never minted, already burned (FR-7G4S zeroes the record), or drained by a
        // merge or an emergency cancel.
        if (p.owner == address(0) || p.liquidity == 0) revert PositionNotFound();
    }

    /// @dev The payout a position is owed, split by where `currentTick` sits relative to
    ///      its range (FR-7G4M). Pure function of (position, currentTick) — never the USDC
    ///      amount originally deposited.
    ///
    ///      The split is linear in tick because this vault's tick space is linear: a tick
    ///      is a discrete price slot in the order book's [0, 1] range, not Uniswap v3's
    ///      `1.0001^tick`. Mint spreads an LP's USDC evenly across the slots in their range
    ///      (`L = usdcAmount * PRECISION / rangeWidth`), so an exit just counts the slots
    ///      either side of `currentTick`: those at or above it are still USDC, those below
    ///      it have converted to outcome-token inventory. v3's √P formulation exists to
    ///      serve a constant-product bonding curve, which this vault does not have.
    ///
    ///      `outcomeOwed` is a COMPLETE SET size, not a single-sided token count: the
    ///      caller pays that many yesTokenId AND that many noTokenId (ADR-7G5F). A
    ///      complete set redeems 1:1 for collateral through the ConditionalTokens contract
    ///      with no counterparty, which is what keeps both legs denominated in the same
    ///      base units as USDC and removes any need for a tick-to-price conversion here.
    ///
    ///      Dust: the two in-range divisions each truncate downward, so their sum can fall
    ///      one base unit short of the position's full principal. The remainder stays in
    ///      the vault, matching the Q128 fee-dust convention — never rounded up, which
    ///      would pay out value the vault does not hold.
    ///
    ///      Boundary: at `currentTick == tickLower` the position still counts as in range
    ///      (so FR-7G4Q decrements activeLiquidity for it) while the split degenerates to
    ///      all-USDC. That is the continuous limit of the formula, and the one point where
    ///      FR-7G4M's "a nonzero amount of each" reads as the open interval.
    function _owedAmounts(Position storage p) internal view returns (uint256 usdcOwed, uint256 outcomeOwed) {
        int24 tickLower = p.tickLower;
        int24 tickUpper = p.tickUpper;
        uint256 liquidity = uint256(p.liquidity);
        int24 tick = currentTick;

        if (tick < tickLower) {
            // Entirely below the range: no slot has converted, so the whole principal
            // is still USDC.
            usdcOwed = liquidity * _tickSpan(tickLower, tickUpper) / LIQUIDITY_PRECISION;
        } else if (tick >= tickUpper) {
            // At or above the range: every slot has converted.
            outcomeOwed = liquidity * _tickSpan(tickLower, tickUpper) / LIQUIDITY_PRECISION;
        } else {
            // Inside the range: slots above the tick are still USDC, slots below it have
            // converted. The two spans sum to the full range width.
            usdcOwed = liquidity * _tickSpan(tick, tickUpper) / LIQUIDITY_PRECISION;
            outcomeOwed = liquidity * _tickSpan(tickLower, tick) / LIQUIDITY_PRECISION;
        }
    }

    /// @dev Width of a tick span as an unsigned value. Callers must pass `hi >= lo`, which
    ///      holds for every use here: mint validates `tickLower < tickUpper`, and the
    ///      in-range branch has already established `tickLower <= tick < tickUpper`.
    function _tickSpan(int24 lo, int24 hi) internal pure returns (uint256) {
        // casting to uint256 is safe because callers guarantee hi >= lo, so the
        // difference is non-negative
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(int256(hi - lo));
    }

    // ──────────────────────────────────────────────
    // Solvency ledger — principal side (FEAT-9BQZ, UC-9BR0)
    // ──────────────────────────────────────────────

    /// @dev Records a new obligation on the principal side of the ledger (FR-9BR8).
    ///
    ///      The YES and NO legs are NOT always zero. A position minted while currentTick
    ///      already sits inside its range is split from its first block, so mint records
    ///      an outcome obligation with no price movement involved — see the call site in
    ///      mintPositionFor for why that must come from the split model rather than from
    ///      the deposit amount. Callers pass whatever split the model computes; this
    ///      function fixes only that all three assets are tracked separately (FR-9BR5).
    /// @param usdcAmt USDC principal the new obligation carries
    /// @param yesAmt YES principal the new obligation carries
    /// @param noAmt NO principal the new obligation carries
    function _creditPrincipal(uint256 usdcAmt, uint256 yesAmt, uint256 noAmt) internal {
        if (usdcAmt > 0) totalUsdcOwed += usdcAmt;
        if (yesAmt > 0) totalYesOwed += yesAmt;
        if (noAmt > 0) totalNoOwed += noAmt;
    }

    /// @dev Discharges an obligation from the principal side by what a payout actually
    ///      paid out (FR-9BR9).
    ///
    ///      Saturates at zero rather than reverting on underflow, and that choice is
    ///      load-bearing rather than defensive. NFR-9BRU forbids any ledger write from
    ///      introducing a revert into an exit path, and burnPosition in particular is the
    ///      unconditional escape hatch FEAT-7G40 guarantees. A checked subtraction here
    ///      would turn any ledger drift into a bricked withdrawal — converting an
    ///      accounting error into trapped LP capital, the single outcome this feature
    ///      exists to prevent. An obligation cannot be negative, so clamping is also the
    ///      arithmetically correct floor. Drift is caught by the conservation invariants
    ///      (NFR-9BRX), where finding it costs nobody their exit.
    /// @param usdcAmt USDC principal being discharged
    /// @param yesAmt YES principal being discharged
    /// @param noAmt NO principal being discharged
    function _debitPrincipal(uint256 usdcAmt, uint256 yesAmt, uint256 noAmt) internal {
        totalUsdcOwed = _saturatingSub(totalUsdcOwed, usdcAmt);
        totalYesOwed = _saturatingSub(totalYesOwed, yesAmt);
        totalNoOwed = _saturatingSub(totalNoOwed, noAmt);
    }

    /// @dev Subtraction with a floor at zero, for the ledger decrements that must never
    ///      revert an exit path (NFR-9BRU). See _debitPrincipal for the full reasoning.
    function _saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    // ──────────────────────────────────────────────
    // Solvency ledger — price movement (FEAT-9BQZ, UC-9BR1)
    // ──────────────────────────────────────────────

    /// @dev Moves the principal one traversed tick span converted from one asset side to
    ///      the other (FR-9BRL). Every position spanning the segment converts the same
    ///      per-tick amount, so the vault-wide shift is the identical interpolation
    ///      _owedAmounts performs per position — `liquidity * span / LIQUIDITY_PRECISION`
    ///      — evaluated against `activeLiquidity`. Sharing the formula is what keeps the
    ///      totals equal to the summed splits a later burn will discharge them by.
    ///
    ///      The span is passed as an ordered pair with the direction separate, because
    ///      updateTick's two branches walk their segments from opposite ends.
    ///
    ///      The clamp does more than keep the decrement safe (NFR-9BRT): a saturating
    ///      debit paired with an unconditional credit would manufacture principal on the
    ///      destination side, breaking the conservation FR-9BRL requires. Bounding the
    ///      shift by what the origin actually holds keeps both legs equal in every state.
    /// @param segLower Lower tick of the traversed span
    /// @param segUpper Upper tick of the traversed span
    /// @param toOutcome True when the price rose across the span, so USDC principal
    ///        converts to outcome inventory; false when it fell and the conversion reverses
    function _shiftPrincipal(int24 segLower, int24 segUpper, bool toOutcome) internal {
        uint128 liquidity = activeLiquidity;

        // An empty span is an ordinary tail case rather than an anomaly: a move landing
        // exactly on the tick it last crossed leaves nothing behind it to accumulate.
        if (liquidity == 0 || segUpper <= segLower) return;

        uint256 shift = uint256(liquidity) * _tickSpan(segLower, segUpper) / LIQUIDITY_PRECISION;

        if (toOutcome) {
            if (shift > totalUsdcOwed) shift = totalUsdcOwed;
            totalUsdcOwed -= shift;
            // The outcome leg is a complete set, so both ids take the same credit.
            totalYesOwed += shift;
            totalNoOwed += shift;
        } else {
            // ...and on the way back the pair is the binding constraint, so the clamp
            // reads whichever leg holds less.
            uint256 available = totalYesOwed < totalNoOwed ? totalYesOwed : totalNoOwed;
            if (shift > available) shift = available;
            totalYesOwed -= shift;
            totalNoOwed -= shift;
            totalUsdcOwed += shift;
        }
    }

    /// @dev The one burn body both entry points run (FR-7G4L). Assumes the caller has
    ///      already run `_requireBurnable` and applied its own authorization check.
    ///
    ///      Checks-effects-interactions is load-bearing here, not hygiene (NFR-7G59): the
    ///      ERC-1155 payout calls `onERC1155Received` on the recipient, handing them
    ///      control mid-call. By that point the position record is deleted and both
    ///      boundary ticks are updated, so a reentering recipient finds no live position
    ///      and no residual claim — and the nonReentrant guard on both entry points stops
    ///      them re-entering at all.
    function _burn(uint256 positionId) internal {
        Position storage p = positions[positionId];

        // --- Reads and computation, all before any state is touched ---

        address owner = p.owner;
        int24 tickLower = p.tickLower;
        int24 tickUpper = p.tickUpper;
        uint128 liquidity = p.liquidity;

        // Fees must be computed while both boundary ticks still hold their
        // feeGrowthOutsideX128 — the effects below may delete them.
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(tickLower, tickUpper);
        uint256 feesOwed = _accruedFees(liquidity, feeGrowthInsideX128, p.feeGrowthInsideLastX128) + p.tokensOwed;

        // Likewise the payout split, which reads the position record about to be deleted.
        (uint256 usdcOwed, uint256 outcomeOwed) = _owedAmounts(p);

        // --- Effects ---

        // Exact inverse of the mint deltas in mintPositionFor (FR-7G4O).
        _removeLiquidityFromTick(tickLower, liquidity, true);
        _removeLiquidityFromTick(tickUpper, liquidity, false);

        // Only an in-range position was contributing to activeLiquidity (FR-7G4Q).
        if (tickLower <= currentTick && currentTick < tickUpper) {
            activeLiquidity -= liquidity;
        }

        // Zero the whole record (FR-7G4S). nextPositionId is deliberately untouched, so
        // the id is retired rather than recycled (FR-7G4T) — reuse would let a stale
        // off-chain reference resolve to a different LP's position.
        delete positions[positionId];

        // Discharge the principal this burn is about to pay (FR-9BR9), using the split at
        // burn time rather than the split recorded at mint — price movement has been
        // redistributing it ever since. The outcome leg is a complete set, the same
        // amount of each id, so it discharges YES and NO equally. Still in the effects
        // phase, before any transfer, per NFR-9BRY.
        _debitPrincipal(usdcOwed, outcomeOwed, outcomeOwed);

        // A burn settles the fee entitlement in the same call as the principal (FR-9BRC),
        // which is why no separate collect is needed to retire it.
        totalFeesUsdcOwed = _saturatingSub(totalFeesUsdcOwed, feesOwed);

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // One transfer covers the USDC-side principal and the fees; they are the same
        // asset and splitting them would only cost gas.
        uint256 usdcPayout = usdcOwed + feesOwed;
        if (usdcPayout > 0) {
            _safeTransfer(usdc, owner, usdcPayout);
        }

        // The outcome-token leg is paid as a complete set: the same amount of each id.
        // The vault never trades, swaps, or converts here (FR-7G4N) — no exchange call,
        // no order. The LP disposes of the pair on their own terms: unwind it 1:1 through
        // the ConditionalTokens contract with no counterparty at all, or sell either leg
        // through the exchange subject to market depth.
        if (outcomeOwed > 0) {
            IERC1155 ct = IERC1155(conditionalTokens);
            ct.safeTransferFrom(address(this), owner, yesTokenId, outcomeOwed, "");
            ct.safeTransferFrom(address(this), owner, noTokenId, outcomeOwed, "");
        }

        emit PositionBurned(positionId, owner, usdcOwed, outcomeOwed, feesOwed);
    }

    /// @dev Removes a burned position's liquidity from one of its boundary ticks, and
    ///      deinitializes the tick when nothing references it any more (FR-7G4P).
    ///
    ///      Deleting the tick and clearing its bitmap bit together is what keeps the
    ///      bitmap's meaning intact — a set bit must mean liquidityGross > 0, or a later
    ///      updateTick would cross a tick with no liquidity behind it. Because
    ///      liquidityGross is the sum over positions referencing the tick, reaching zero
    ///      proves no live position still needs its feeGrowthOutsideX128.
    /// @param tick The boundary tick to update
    /// @param liquidity The burned position's liquidity
    /// @param isLower True for the position's tickLower, false for its tickUpper
    function _removeLiquidityFromTick(int24 tick, uint128 liquidity, bool isLower) internal {
        TickInfo storage info = ticks[tick];

        info.liquidityGross -= liquidity;
        if (isLower) {
            info.liquidityNet -= _toInt128(liquidity);
        } else {
            info.liquidityNet += _toInt128(liquidity);
        }

        if (info.liquidityGross == 0) {
            delete ticks[tick];
            _clearTickBitmapBit(tick);
        }
    }

    // ──────────────────────────────────────────────
    // Deposit reclaim (FEAT-JAIJ, UC-JAIK)
    // ──────────────────────────────────────────────

    // SC-JAIL, SC-3Z9L, SC-45IG, SC-JAIM, SC-JAIN, SC-3ZA0, SC-JAIP:
    // two-phase LP escape hatch for unfulfilled mint intents
    /// @notice Allows an LP to reclaim the USDC escrowed against their mint intent when
    ///         the Operator fails to call mintPositionFor. Two-phase operation (ADR-JB78):
    ///         Phase 1 (first call): records intentTimestamps[intentId] = block.timestamp and
    ///         emits ReclaimSubmitted. Phase 2 (after RECLAIM_TIMELOCK): marks usedIntents,
    ///         deletes the escrow, transfers the escrowed amount back to the LP, and emits
    ///         DepositReclaimed.
    /// @dev Permissionless by design: this function requires no Operator signature, no
    ///      Operator action, and reads no Operator registry state (NFR-3Z9X, ADR-3ZA1).
    ///      That independence is what makes it an escape hatch — a path that consulted
    ///      Operator state would fail exactly when it is needed. It also means an Admin
    ///      removing an operator can never strand an LP's deposit.
    ///
    ///      The refund amount and its recipient both come from on-chain escrow, never from
    ///      the caller-supplied `usdcAmount`. Two guards enforce that, and BOTH run before
    ///      Phase 1 records a timestamp, so an attacker cannot even start the clock against
    ///      a victim's intentId. The ownership guard is the security-critical one: neither
    ///      the `msg.sender == lp` gate nor the signature check stops an attacker, because
    ///      they genuinely are themselves and genuinely signed. intentIds are public in the
    ///      DepositEscrowed log, and _verifyMintIntent compares the recovered signer against
    ///      a caller-supplied `lp`, so anyone can produce a valid signature over anyone's
    ///      intentId. Only the recorded depositor settles ownership (FR-45IF).
    /// @param lp LP wallet address — must match msg.sender, the LP EIP-712 signature, and
    ///        the depositor recorded on the intent's escrow
    /// @param tickLower Lower tick bound from the original MintIntent
    /// @param tickUpper Upper tick bound from the original MintIntent
    /// @param usdcAmount USDC amount from the original MintIntent. Part of the signed
    ///        digest only — the refund is the escrowed amount, not this number.
    /// @param intentId Unique identifier from the original MintIntent
    /// @param lpSignature EIP-712 signature from the LP over the MintIntent struct
    function reclaimDeposit(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata lpSignature
    ) external nonReentrant {
        // --- Checks ---

        // Cancelled vaults have already distributed all funds
        if (phase == 3) revert VaultCancelled();

        // Caller must be the LP named in the intent
        if (msg.sender != lp) revert NotIntentOwner();

        // Verify LP's EIP-712 signature over the MintIntent struct
        _verifyMintIntent(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature);

        // Replay protection: intentId must not have been used by mintPositionFor or a prior reclaim
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // Both escrow guards run here, ahead of Phase 1, so a rejected claim cannot
        // start the timelock clock on someone else's intentId.
        PendingDeposit memory deposit = pendingDeposits[intentId];

        // Nothing escrowed under this intentId. This is what stops a caller who
        // deposited nothing from draining the vault's general balance after waiting
        // out the timelock: signing an intent for an arbitrary amount grants no claim
        // on funds the vault never collected for it (FR-3ZVM).
        if (deposit.lp == address(0)) revert NothingToReclaim();

        // Escrowed, but by someone else — see the ownership note in the NatSpec above (FR-45IF).
        if (deposit.lp != lp) revert NotIntentOwner();

        // --- Phase 1: Record submission timestamp ---

        if (intentTimestamps[intentId] == 0) {
            intentTimestamps[intentId] = block.timestamp;
            // Report the escrowed amount, not the caller-supplied one, so the pending
            // refund an indexer or LP UI shows is the number Phase 2 will actually pay.
            emit ReclaimSubmitted(intentId, lp, deposit.amount);
            return;
        }

        // --- Phase 2: Execute reclaim after timelock ---

        // Timelock must have elapsed since Phase 1 submission (±15s Polygon tolerance is negligible at 24h scale)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - intentTimestamps[intentId] < RECLAIM_TIMELOCK) {
            revert TimelockNotElapsed();
        }

        // --- Effects ---

        // Mark intentId as used to prevent double-refund and mutual exclusion with mintPositionFor
        usedIntents[intentId] = true;

        // Refund exactly what was escrowed, then clear the entry so neither a second
        // reclaim nor a mint can draw on it.
        uint256 refund = deposit.amount;
        delete pendingDeposits[intentId];

        // Discharge the obligation by what is actually being refunded (FR-9BRF). This
        // sits in Phase 2 deliberately: Phase 1 above records a timestamp and returns
        // without moving money, so decrementing there would understate what the vault
        // owes for the whole 24-hour timelock while the USDC is still in the vault.
        totalEscrowed -= refund;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        _safeTransfer(usdc, lp, refund);
        emit DepositReclaimed(intentId, lp, refund);
    }

    // SC-3Z9C through SC-3Z9I, SC-45IH: operator-relayed reclaim of an LP's escrow
    /// @notice Refunds an LP's escrowed USDC on their behalf, from an EIP-712
    ///         ReclaimIntent they signed off-chain, with the Operator paying the gas.
    ///         Two-phase and timelocked exactly like `reclaimDeposit`, sharing the same
    ///         `intentTimestamps` slot: a Phase 1 submitted through either entry point
    ///         starts the one clock.
    /// @dev This is the convenience twin for an ordinary voluntary cancellation, not a
    ///      second escape hatch — the LP's own permissionless `reclaimDeposit` is what
    ///      guarantees they can always exit, and this gate does not affect it.
    ///
    ///      OPERATOR TRUST ASSUMPTION: The Operator chooses whether and when to relay a
    ///      reclaim, so they can censor, reorder, or delay a cancellation. What they
    ///      cannot do is initiate one: every refund needs the LP's own signature over a
    ///      ReclaimIntent, a struct with its own typehash. A mint authorization is
    ///      therefore NOT replayable here (ADR-4029) — an Operator holding the signature
    ///      that funded a position cannot use it to unwind that position. Nor can the
    ///      Operator redirect the money: funds always go to the depositor recorded on the
    ///      escrow, never to `msg.sender` and never to a different named LP, so a
    ///      compromised Operator key colluding with an attacker's valid signature still
    ///      cannot move another LP's deposit. An Operator who simply refuses to relay
    ///      leaves the LP with `reclaimDeposit`, which needs no Operator at all.
    ///
    ///      MEV analysis: this function returns an LP's own escrow to that LP. It creates
    ///      no position, touches no tick, reads no price, and changes no fee accounting,
    ///      so its ordering relative to other transactions offers an observer nothing to
    ///      profit from. The one ordering effect is the race against `mintPositionFor` for
    ///      the same intentId — both consume the shared `usedIntents` slot, so whichever
    ///      lands first wins and the other reverts. That race is bounded by
    ///      RECLAIM_TIMELOCK, is settled entirely between the Operator and the LP who
    ///      signed both authorizations, and leaves no third party exposed.
    /// @param lp LP wallet address — must match the ReclaimIntent's signer and the
    ///        depositor recorded on the intent's escrow
    /// @param tickLower Lower tick bound from the original MintIntent
    /// @param tickUpper Upper tick bound from the original MintIntent
    /// @param usdcAmount USDC amount from the original MintIntent. Part of the signed
    ///        digest only — the refund is the escrowed amount, not this number.
    /// @param intentId Unique identifier from the original MintIntent
    /// @param lpSignature EIP-712 signature from the LP over the ReclaimIntent struct
    function reclaimDepositFor(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata lpSignature
    ) external onlyOperator nonReentrant touchesHeartbeat {
        // --- Checks ---

        // Cancelled vaults have already distributed all funds
        if (phase == 3) revert VaultCancelled();

        // Verify the LP authorized this cancellation specifically. Verified against the
        // ReclaimIntent typehash, so the MintIntent that funded the escrow is rejected here.
        _verifyReclaimIntent(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature);

        // Replay protection: shared with mintPositionFor and reclaimDeposit, so an
        // intent settled through any one path cannot be settled again through another.
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // Both escrow guards run ahead of Phase 1, so a rejected relay cannot start the
        // timelock clock on someone else's intentId.
        PendingDeposit memory deposit = pendingDeposits[intentId];

        // Nothing escrowed: the relayed path offers no way around the escrow
        // requirement, so it cannot become a second route to draining the vault (FR-3ZVM).
        if (deposit.lp == address(0)) revert NothingToReclaim();

        // Escrowed by a different LP. This is what stops the Operator redirecting one
        // LP's deposit to another, even holding that other LP's valid signature (FR-45IF).
        if (deposit.lp != lp) revert NotIntentOwner();

        // --- Phase 1: Record submission timestamp ---

        if (intentTimestamps[intentId] == 0) {
            intentTimestamps[intentId] = block.timestamp;
            emit ReclaimSubmitted(intentId, lp, deposit.amount);
            return;
        }

        // --- Phase 2: Execute reclaim after timelock ---

        // The Operator waits out the same period the LP does — gas sponsorship buys
        // convenience, not privilege. (±15s Polygon tolerance is negligible at 24h scale)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - intentTimestamps[intentId] < RECLAIM_TIMELOCK) {
            revert TimelockNotElapsed();
        }

        // --- Effects ---

        usedIntents[intentId] = true;

        uint256 refund = deposit.amount;
        delete pendingDeposits[intentId];

        // Same Phase-2-only placement and the same reasoning as reclaimDeposit above
        // (FR-9BRF): both paths pay the same refund, so both discharge the obligation.
        totalEscrowed -= refund;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // Funds go to the recorded depositor, never to msg.sender.
        _safeTransfer(usdc, lp, refund);
        emit DepositReclaimed(intentId, lp, refund);
    }

    // ──────────────────────────────────────────────
    // Fee notification (FEAT-TOGR, UC-TOGS)
    // ──────────────────────────────────────────────

    // SC-TOGT, SC-TOGU, SC-TOGV, SC-TOGW, SC-TOGX, SC-TOGY: operator-gated fee accumulator update
    /// @notice Increments the global fee accumulator by the Q128-scaled share of new fee revenue.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator is trusted to have deposited at least
    ///      `amount` USDC into the vault before calling. The contract does not verify the
    ///      vault's USDC balance — an Operator who calls notifyFees without funding it creates
    ///      an accounting mismatch that would strand LP claims. This matches the CTF Exchange
    ///      trust model where the operator manages fee sweeps.
    /// @param amount The amount of USDC fee revenue to distribute across active liquidity
    function notifyFees(uint256 amount) external onlyOperator whenNotPaused touchesHeartbeat {
        // Cancelled vaults have already distributed all funds
        if (phase == 3) revert VaultCancelled();

        // Zero-amount guard: notifying zero fees wastes gas and signals a caller bug
        if (amount == 0) revert ZeroAmount();

        // Safety guard: distributing fees against zero liquidity would lock them
        // permanently with no LP able to claim (CLAUDE.md security checklist item 9)
        uint128 activeL = activeLiquidity;
        if (activeL == 0) revert NoActiveLiquidity();

        // Increment the global fee accumulator using overflow-safe Q128 arithmetic.
        // mulDiv computes (amount * 2^128) / activeLiquidity with full intermediate
        // precision, truncating downward. The dust is economically negligible
        // (< 1/2^128 USDC per unit of liquidity per call).
        feeGrowthGlobalX128 += _mulDiv(amount, Q128, uint256(activeL));

        // Record the fee entitlement this notification creates (FR-9BRA). Only the USDC
        // total moves: notifyFees carries a single amount and collect pays USDC, so which
        // asset a fee arrived in is not expressible until FEAT-TOGR changes this signature.
        //
        // The full `amount` is credited even though the Q128 division above truncates, so
        // LPs can collectively claim marginally less. That is self-consistent rather than
        // an overstatement: the Operator deposited the whole amount, so the vault's balance
        // keeps the dust and this total keeps the same dust. The payout ratio computed from
        // the two (FR-9BRM) therefore stays accurate, and the residue errs conservative.
        totalFeesUsdcOwed += amount;

        emit FeesNotified(amount, feeGrowthGlobalX128);
    }

    // ──────────────────────────────────────────────
    // Operator liveness (FEAT-JXQO, UC-JXQW)
    // ──────────────────────────────────────────────

    // SC-3XTZ, SC-3XU1, SC-3XUO, SC-3XU2: dedicated Operator liveness signal
    /// @notice Records that the Operator is still alive, refreshing the emergency-cancel
    ///         silence timer without changing any other vault state.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can call this indefinitely to keep
    ///      `emergencyCancelAll` out of reach without doing any real work. LPs trust the
    ///      Operator not to hold the vault hostage this way. This is the accepted residual
    ///      risk recorded in ADR-3XU3; it is the inverse of the problem this function solves,
    ///      which is a genuinely healthy Operator being unable to prove liveness at all on a
    ///      quiet market, where `updateTick` reverts SameTick and `notifyFees` reverts ZeroAmount.
    ///
    ///      Deliberately not gated by `whenNotPaused`: a pause is an Admin decision about
    ///      trading and says nothing about whether the Operator is alive, so a paused vault
    ///      must not drift toward emergency cancellation while its Operator still responds.
    function heartbeat() external onlyOperator touchesHeartbeat {
        // Cancelled vaults have already distributed all funds — nothing left to protect
        if (phase == 3) revert VaultCancelled();
    }

    // ──────────────────────────────────────────────
    // Tick update (FEAT-TVS0, UC-TVS1)
    // ──────────────────────────────────────────────

    // SC-TVS2 through SC-TVS8: operator-gated tick synchronization
    /// @notice Synchronizes the vault's price tick with the off-chain CLOB mid-price.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can report any tick value. LPs
    ///      trust that the Operator reports the CLOB mid-price accurately. A malicious
    ///      or compromised Operator could report a false tick, causing incorrect fee
    ///      distribution between positions. This matches the ProphetCTFExchange trust model.
    ///      Crosses every initialized tick between currentTick and newTick, flipping
    ///      feeGrowthOutsideX128 and applying liquidityNet to activeLiquidity.
    ///      The bitmap search is bounded by newTick (NFR-5IDG), so this call's cost
    ///      tracks the price move the Operator reported and cannot be inflated by an
    ///      LP initializing a tick far away. That bound is only as tight as newTick
    ///      itself, which is already a trusted input per the assumption above — a
    ///      genuinely huge single-call jump across real empty space can still be
    ///      expensive, so the Operator is expected to chunk large moves, the same way
    ///      MAX_TICK_CROSSINGS already forces chunking on the crossings themselves.
    ///
    ///      MEV analysis: this call now touches the solvency ledger, moving principal
    ///      between the USDC and outcome totals for every span it traverses (FR-9BRL).
    ///      It moves no asset and creates no claim, so there is nothing to sandwich for
    ///      profit; what an observer gains is foreknowledge of the payout ratios, since
    ///      the totals it rewrites are their denominators. That is not exploitable here:
    ///      the shift conserves principal in token terms, so a traversal cannot push a
    ///      covered asset into shortfall, and a claimant racing ahead of one still takes
    ///      the same pooled per-asset haircut as everyone behind them (ADR-9BSH).
    ///      Chunking a move across several calls does NOT currently reach the same totals
    ///      as one call: each segment's shift truncates independently, so the Operator's
    ///      choice of chunk boundaries perturbs the ratio denominators by dust. The
    ///      pending scaled-total representation removes that degree of freedom; until it
    ///      lands, treat the chunking as Operator-influenceable at dust scale.
    /// @param newTick The new price tick to set
    function updateTick(int24 newTick) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat {
        // Phase check: only Active vaults accept tick updates
        if (phase != 1) revert VaultNotActive();

        int24 oldTick = currentTick;
        if (newTick == oldTick) revert SameTick();

        bool movingRight = newTick > oldTick;
        uint256 crossCount = 0;
        int24 tick = oldTick;

        // End of the last span accumulated into the ledger. It tracks the price, not the
        // bitmap cursor: the left-moving branch steps `tick` one past the tick it just
        // crossed so the search cannot re-find it, and taking a span boundary from that
        // cursor would silently drop one tick of conversion per crossing.
        int24 segmentStart = oldTick;

        if (movingRight) {
            // Cross every initialized tick in (oldTick, newTick]
            while (tick < newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, true, newTick);
                if (!found || next > newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                // Accumulated BEFORE the crossing, per FR-9BRI: this span was traversed
                // under the liquidity active up to `next`, not under the liquidity that
                // `next` is about to add or remove.
                _shiftPrincipal(segmentStart, next, true);
                _crossTick(next, true);
                segmentStart = next;
                tick = next;
            }
        } else {
            // Cross every initialized tick in (newTick, oldTick]
            while (tick > newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, false, newTick);
                if (!found || next <= newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                _shiftPrincipal(next, segmentStart, false);
                _crossTick(next, false);
                segmentStart = next;
                tick = next - 1;
            }
        }

        // The span from the last crossing to newTick (FR-9BRJ). Most moves do not land on
        // an initialized tick, so this is the common case rather than an edge case — and
        // when the loop crossed nothing it is the whole move, which is the only
        // accumulation an update inside a single gap performs (FR-9BRK).
        if (movingRight) {
            _shiftPrincipal(segmentStart, newTick, true);
        } else {
            _shiftPrincipal(newTick, segmentStart, false);
        }

        currentTick = newTick;

        emit TickUpdated(oldTick, newTick, crossCount);
    }

    // ──────────────────────────────────────────────
    // Position merge (FEAT-K1M2, UC-K1M8)
    // ──────────────────────────────────────────────

    // SC-K1M9, SC-K1MA, SC-K1MB, SC-K1MC: operator-gated position merge
    /// @notice Combines two or more positions with identical owner, tickLower, and
    ///         tickUpper into a single survivor position (positionIds[0]), preserving
    ///         total liquidity and rolling up accrued fees.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can merge any positions that share
    ///      the same owner and range. LPs must trust that the Operator only merges
    ///      positions for legitimate housekeeping (reducing storage and gas costs for
    ///      overlapping positions).
    ///      No USDC moves during merge — uncollected fees from consumed positions are
    ///      rolled into the survivor's tokensOwed. Tick state (liquidityGross,
    ///      liquidityNet) is unchanged since total liquidity on the range stays the same.
    ///
    ///      SOLVENCY LEDGER: this function deliberately writes no ledger total (FR-9BRH).
    ///      No assets move, the range is unchanged, and fees are rolled up rather than
    ///      paid, so the vault's obligations are the same before and after.
    ///
    ///      It is nonetheless the one path where the totals and the positions behind them
    ///      legitimately disagree. A position's principal is never stored — `_owedAmounts`
    ///      reconstructs it from the truncated `liquidity` — so combining N positions'
    ///      liquidity into one record collapses N downward truncations into one, and the
    ///      survivor can claim up to one base unit per asset leg more than each position
    ///      it consumed contributed. The totals are NOT adjusted to compensate: doing so
    ///      would make merge a ledger writer, which is exactly what FR-9BRH refuses.
    ///      The drift understates obligations, so the payout ratios read marginally more
    ///      solvent than the vault is; it is bounded by the count of positions ever merged
    ///      away and carried as an explicit tolerance in NFR-9BRX's conservation
    ///      invariant. Reasoning and the rejected alternative are in ADR-9Q3Y.
    /// @param positionIds Array of position IDs to merge — must have >= 2 elements,
    ///        all sharing the same owner, tickLower, and tickUpper
    function mergePositions(uint256[] calldata positionIds)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
        touchesHeartbeat
    {
        // Cancelled vaults have already distributed all funds — nothing left to merge.
        // Deliberately Cancelled-only rather than `phase != 1`: FEAT-JGE7 documents that
        // the Operator may still merge positions during WindDown while LPs exit.
        if (phase == 3) revert VaultCancelled();

        // At least two positions required to merge
        if (positionIds.length < 2) revert InsufficientPositions();

        // Load the survivor (first position in the array)
        Position storage survivor = positions[positionIds[0]];
        address ownerAddr = survivor.owner;
        int24 tickLower = survivor.tickLower;
        int24 tickUpper = survivor.tickUpper;

        // Compute current feeGrowthInside for this range (same formula as collect)
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(tickLower, tickUpper);

        // Compute uncollected fees for the survivor before updating its snapshot.
        uint256 survivorFees = _accruedFees(survivor.liquidity, feeGrowthInsideX128, survivor.feeGrowthInsideLastX128);

        // Start accumulation from the survivor's current state
        uint128 totalLiquidity = survivor.liquidity;
        uint256 totalOwed = survivor.tokensOwed + survivorFees;

        // Process each consumed position: validate, accumulate, then zero
        for (uint256 i = 1; i < positionIds.length; i++) {
            Position storage consumed = positions[positionIds[i]];

            // All positions must share the same owner and tick range
            if (consumed.owner != ownerAddr || consumed.tickLower != tickLower || consumed.tickUpper != tickUpper) {
                revert RangeMismatch();
            }

            // Compute uncollected fees for the consumed position.
            uint256 consumedFees =
                _accruedFees(consumed.liquidity, feeGrowthInsideX128, consumed.feeGrowthInsideLastX128);

            // Accumulate liquidity and fees
            totalLiquidity += consumed.liquidity;
            totalOwed += consumed.tokensOwed + consumedFees;

            // Zero the consumed position so it can no longer accrue or claim
            consumed.liquidity = 0;
            consumed.tokensOwed = 0;
            consumed.feeGrowthInsideLastX128 = 0;
        }

        // Update the survivor with accumulated totals and a fresh fee snapshot
        survivor.liquidity = totalLiquidity;
        survivor.tokensOwed = totalOwed;
        survivor.feeGrowthInsideLastX128 = feeGrowthInsideX128;

        emit PositionsMerged(positionIds, positionIds[0]);
    }

    // ──────────────────────────────────────────────
    // Internal: EIP-712 signature verification
    // ──────────────────────────────────────────────

    /// @dev Verifies that `signature` is a valid EIP-712 signature from `lp` over
    ///      a MintIntent struct with the given fields. Rejects malleable signatures
    ///      (high-s) and invalid v values per CLAUDE.md security checklist item 5.
    function _verifyMintIntent(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata signature
    ) internal view {
        // Build the EIP-712 digest: \x19\x01 || domainSeparator || structHash
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        // Decode the 65-byte signature into r, s, v
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // Reject malleable signatures: s must be in the lower half of secp256k1's order
        if (uint256(s) > SECP256K1N_HALF) revert InvalidSignature();

        // v must be 27 or 28 — reject all other values
        if (v != 27 && v != 28) revert InvalidSignature();

        // Recover the signer and verify it matches the declared LP address
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != lp) revert InvalidSignature();
    }

    /// @dev Verifies that `signature` is a valid EIP-712 signature from `lp` over a
    ///      ReclaimIntent struct with the given fields. Identical in shape to
    ///      _verifyMintIntent — including the s-malleability bound and the
    ///      v ∈ {27, 28} check per CLAUDE.md rule 5 — and differing only in the
    ///      typehash, which is what keeps a mint authorization from doubling as a
    ///      cancellation authorization (ADR-4029, FR-3ZVP).
    function _verifyReclaimIntent(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata signature
    ) internal view {
        // Build the EIP-712 digest: \x19\x01 || domainSeparator || structHash
        bytes32 structHash =
            keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        // Decode the 65-byte signature into r, s, v
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // Reject malleable signatures: s must be in the lower half of secp256k1's order
        if (uint256(s) > SECP256K1N_HALF) revert InvalidSignature();

        // v must be 27 or 28 — reject all other values
        if (v != 27 && v != 28) revert InvalidSignature();

        // Recover the signer and verify it matches the declared LP address
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != lp) revert InvalidSignature();
    }

    /// @dev The EIP-712 digest an LP signs to authorize closing `positionId`. Depends on
    ///      nothing but the domain separator and the id, so it remains computable after
    ///      the position record is gone — see BURN_INTENT_TYPEHASH for why that matters.
    function _burnIntentDigest(uint256 positionId) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, positionId));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @dev Verifies that `signature` is a valid EIP-712 signature from `owner` over the
    ///      BurnIntent whose digest the caller already computed. Same shape as
    ///      _verifyMintIntent and _verifyReclaimIntent — including the s-malleability
    ///      bound and the v ∈ {27, 28} check per CLAUDE.md rule 5, which here also
    ///      protects the replay guard: a malleable signature would be a second valid
    ///      encoding of the same authorization, but the guard keys on the digest rather
    ///      than the signature bytes, so rejecting malleability keeps the two in step.
    ///
    ///      Takes the digest rather than recomputing it so burnPositionFor can check the
    ///      replay guard before the position is loaded, without hashing twice.
    /// @param digest The BurnIntent digest from _burnIntentDigest
    /// @param owner The position's recorded owner — the only address whose signature counts
    /// @param signature 65-byte ECDSA signature
    function _verifyBurnIntent(bytes32 digest, address owner, bytes calldata signature) internal pure {
        // Decode the 65-byte signature into r, s, v
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // Reject malleable signatures: s must be in the lower half of secp256k1's order
        if (uint256(s) > SECP256K1N_HALF) revert InvalidSignature();

        // v must be 27 or 28 — reject all other values
        if (v != 27 && v != 28) revert InvalidSignature();

        // Recover the signer and verify it matches the position's owner. A MintIntent or
        // ReclaimIntent signature was produced over a different struct, so it recovers to
        // some other address here and is rejected (FR-7G52).
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != owner) revert InvalidSignature();
    }

    // ──────────────────────────────────────────────
    // Internal: tick management
    // ──────────────────────────────────────────────

    /// @dev Initializes a tick's feeGrowthOutsideX128 on first use (liquidityGross == 0).
    ///      Convention: feeGrowthOutside = feeGrowthGlobal if tick <= currentTick, else 0.
    ///      This ensures that feeGrowthInside for any new position spanning this tick
    ///      starts at the correct value — the position won't claim retroactive fees.
    function _initializeTick(int24 tick) internal {
        if (ticks[tick].liquidityGross == 0) {
            // Tick below or at currentTick: all past fees are "outside" this tick
            if (tick <= currentTick) {
                ticks[tick].feeGrowthOutsideX128 = feeGrowthGlobalX128;
            }
            // Tick above currentTick: feeGrowthOutside stays 0 (storage default)

            // Register this tick in the bitmap so updateTick can locate it in O(1)
            _setTickBitmapBit(tick);
        }
    }

    /// @dev Computes the fee growth that occurred inside [tickLower, tickUpper) since
    ///      the vault's inception. Used to snapshot feeGrowthInsideLastX128 at mint time.
    ///      Formula: feeGrowthInside = global - below(tickLower) - above(tickUpper)
    function _computeFeeGrowthInside(int24 tickLower, int24 tickUpper) internal view returns (uint256) {
        // unchecked: feeGrowthOutside snapshots are taken at different points in time
        // than they're read, so feeGrowthBelow + feeGrowthAbove can legitimately,
        // temporarily exceed feeGrowthGlobalX128 at the moment of subtraction. This
        // is expected to wrap mod 2^256 -- mirroring Uniswap v3's audited fee-growth
        // accounting -- not an "overflow is provably impossible" situation.
        unchecked {
            // feeGrowthBelow: fees that grew while price was below tickLower
            uint256 feeGrowthBelow;
            if (currentTick >= tickLower) {
                feeGrowthBelow = ticks[tickLower].feeGrowthOutsideX128;
            } else {
                feeGrowthBelow = feeGrowthGlobalX128 - ticks[tickLower].feeGrowthOutsideX128;
            }

            // feeGrowthAbove: fees that grew while price was above tickUpper
            uint256 feeGrowthAbove;
            if (currentTick < tickUpper) {
                feeGrowthAbove = ticks[tickUpper].feeGrowthOutsideX128;
            } else {
                feeGrowthAbove = feeGrowthGlobalX128 - ticks[tickUpper].feeGrowthOutsideX128;
            }

            return feeGrowthGlobalX128 - feeGrowthBelow - feeGrowthAbove;
        }
    }

    /// @dev Fees a position has accrued since its last snapshot, from the fee-growth
    ///      accumulators for its range. Excludes `tokensOwed`, which callers add
    ///      themselves — merge rolls it up, collect and burn pay it out.
    ///
    ///      unchecked: feeGrowthInsideX128 and feeGrowthInsideLastX128 are each
    ///      individually wrapped mod 2^256 (see _computeFeeGrowthInside), and this
    ///      subtraction is designed to cancel that wraparound out, mirroring Uniswap
    ///      v3's audited fee-growth accounting. Do NOT route this product through
    ///      _mulDiv: _mulDiv computes the exact mathematical product specifically to
    ///      prevent overflow, which is the opposite of what's needed here -- applied
    ///      to a wrapped near-2^256 delta it would compute an astronomically wrong
    ///      (non-reverting) fee amount instead of the correct small one, a fund-drain
    ///      risk strictly worse than reverting.
    ///
    ///      One helper rather than a copy per call site: audit NM-0986 findings T-001
    ///      and T-004 both landed on this arithmetic, T-004 only because T-001's fix
    ///      missed a duplicate. Five copies would give the next fix five chances to
    ///      miss one.
    function _accruedFees(uint128 liquidity, uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128)
        internal
        pure
        returns (uint256 fees)
    {
        unchecked {
            fees = uint256(liquidity) * (feeGrowthInsideX128 - feeGrowthInsideLastX128) / Q128;
        }
    }

    // ──────────────────────────────────────────────
    // Internal: tick crossing (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev Crosses an initialized tick: flips feeGrowthOutsideX128 and adjusts
    ///      activeLiquidity by the tick's liquidityNet. The flip formula is the
    ///      same in both directions; the liquidityNet sign depends on direction.
    function _crossTick(int24 tick, bool ltr) internal {
        TickInfo storage info = ticks[tick];

        // Flip feeGrowthOutside: the "outside" side swaps relative to currentTick.
        // unchecked: this subtraction is designed to wrap mod 2^256 -- mirroring
        // Uniswap v3's audited fee-growth accounting -- not an "overflow is
        // provably impossible" situation.
        unchecked {
            info.feeGrowthOutsideX128 = feeGrowthGlobalX128 - info.feeGrowthOutsideX128;
        }

        // Apply liquidityNet: positive when moving L-to-R, negated when R-to-L
        int128 liquidityDelta = ltr ? info.liquidityNet : -info.liquidityNet;
        activeLiquidity = _addDelta(activeLiquidity, liquidityDelta);
    }

    /// @dev Adds a signed delta to an unsigned liquidity value. Reverts on underflow
    ///      (activeLiquidity should never go negative — would indicate a logic bug).
    function _addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y >= 0) {
            // casting to uint128 is safe because y >= 0 is checked on the line above
            // forge-lint: disable-next-line(unsafe-typecast)
            z = x + uint128(y);
            if (z < x) revert SafeCastOverflow();
        } else {
            // casting to uint128 is safe because -y is positive when y < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            z = x - uint128(-y);
            if (z > x) revert SafeCastOverflow();
        }
    }

    // ──────────────────────────────────────────────
    // Internal: TickBitmap (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev Decomposes a tick index into its bitmap word position and bit position.
    ///      Uses arithmetic right shift for correct negative-tick handling.
    function _tickPosition(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly {
            // Arithmetic right shift by 8 (sign-extending for negative ticks)
            wordPos := sar(8, signextend(2, tick))
            // Lower 8 bits give the position within the word
            bitPos := and(tick, 0xff)
        }
    }

    /// @dev Sets the bitmap bit for a tick when it becomes initialized.
    function _setTickBitmapBit(int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = _tickPosition(tick);
        // forge-lint: disable-next-line(incorrect-shift)
        tickBitmap[wordPos] |= (1 << bitPos);
    }

    /// @dev Clears the bitmap bit for a tick when it becomes deinitialized.
    ///      Provided for feature 6 (burn) — not called by this feature.
    function _clearTickBitmapBit(int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = _tickPosition(tick);
        // forge-lint: disable-next-line(incorrect-shift)
        tickBitmap[wordPos] &= ~(1 << bitPos);
    }

    /// @dev Finds the next initialized tick relative to the given tick, without
    ///      scanning past the bitmap word that holds `targetTick`.
    ///      searchRight=true: smallest initialized tick strictly greater than `tick`.
    ///      searchRight=false: largest initialized tick less than or equal to `tick`.
    ///      Returns (nextTick, true) if found, or (0, false) when no initialized tick
    ///      exists within the bounded range.
    ///
    ///      Bounding by the caller's target (FR-5IDE) is what keeps the scan
    ///      proportional to the price move the Operator actually reported rather than
    ///      to wherever an LP happened to initialize a tick. An LP picks its own range,
    ///      so it can plant an initialized tick at any aligned position in int24; an
    ///      unbounded scan would then let that distant tick make a later, legitimate
    ///      updateTick exceed the block gas limit (NFR-5IDG). MAX_TICK_CROSSINGS does
    ///      not cover this: it caps how many ticks are crossed, not the cost of
    ///      scanning the empty words between them. See ADR-5IDK.
    ///
    ///      The bound INCLUDES the target's own word — an initialized tick sharing
    ///      that word must still be found, and updateTick's own range check is what
    ///      discards it if it turns out to sit beyond newTick. Stopping one word short
    ///      would silently skip legitimate crossings.
    ///
    ///      Each loop tests for its last word BEFORE stepping, so neither `wordPos++`
    ///      nor `wordPos--` can ever run past int16 and revert with an arithmetic
    ///      panic (FR-5IDF). Both the target bound and the addressable-range bound are
    ///      checked on both sides: the target bound alone would suffice while every
    ///      caller derives it from a real tick, but the extreme-word test costs one
    ///      comparison and removes the panic as a reachable state rather than merely
    ///      an unlikely one.
    /// @param tick The tick to search from
    /// @param searchRight Direction: true searches upward, false downward
    /// @param targetTick The tick the caller is moving to; the search stops at its word
    function _nextInitializedTick(int24 tick, bool searchRight, int24 targetTick)
        internal
        view
        returns (int24 next, bool found)
    {
        (int16 targetWordPos,) = _tickPosition(targetTick);

        if (searchRight) {
            // Start from tick + 1
            int24 startTick = tick + 1;
            (int16 wordPos, uint8 bitPos) = _tickPosition(startTick);

            // Mask out bits at and below bitPos-1 (keep bitPos and above)
            uint256 word = tickBitmap[wordPos] >> bitPos;
            if (word != 0) {
                uint8 offset = _leastSignificantBit(word);
                return (startTick + int24(uint24(offset)), true);
            }

            // Search subsequent words, up to and including the target's own word.
            for (;;) {
                if (wordPos >= targetWordPos || wordPos == type(int16).max) return (0, false);
                wordPos++;
                word = tickBitmap[wordPos];
                if (word != 0) {
                    uint8 offset = _leastSignificantBit(word);
                    return (int24(int256(wordPos)) * 256 + int24(uint24(offset)), true);
                }
            }
        } else {
            // Start from tick itself (search at or below)
            (int16 wordPos, uint8 bitPos) = _tickPosition(tick);

            // Mask out bits above bitPos (keep bitPos and below).
            // unchecked: when bitPos=255, (1 << 256) wraps to 0, 0-1 = type(uint256).max = all bits set.
            uint256 mask;
            unchecked {
                mask = (uint256(1) << (uint256(bitPos) + 1)) - 1;
            }
            uint256 word = tickBitmap[wordPos] & mask;
            if (word != 0) {
                uint8 offset = _mostSignificantBit(word);
                return (int24(int256(wordPos)) * 256 + int24(uint24(offset)), true);
            }

            // Search previous words, down to and including the target's own word.
            for (;;) {
                if (wordPos <= targetWordPos || wordPos == type(int16).min) return (0, false);
                wordPos--;
                word = tickBitmap[wordPos];
                if (word != 0) {
                    uint8 offset = _mostSignificantBit(word);
                    return (int24(int256(wordPos)) * 256 + int24(uint24(offset)), true);
                }
            }
        }
    }

    /// @dev Returns the index of the least significant set bit in `x`.
    ///      Assumes x != 0. Isolates the lowest bit then finds its position via MSB.
    function _leastSignificantBit(uint256 x) internal pure returns (uint8) {
        assembly {
            x := and(x, sub(0, x))
        }
        return _mostSignificantBit(x);
    }

    /// @dev Returns the index of the most significant set bit in `x`.
    ///      Assumes x != 0.
    function _mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        assembly {
            r := 0
            if gt(x, 0x00000000000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) {
                r := 128
                x := shr(128, x)
            }
            if gt(x, 0x000000000000000000000000000000000000000000000000FFFFFFFFFFFFFFFF) {
                r := add(r, 64)
                x := shr(64, x)
            }
            if gt(x, 0x00000000000000000000000000000000000000000000000000000000FFFFFFFF) {
                r := add(r, 32)
                x := shr(32, x)
            }
            if gt(x, 0x000000000000000000000000000000000000000000000000000000000000FFFF) {
                r := add(r, 16)
                x := shr(16, x)
            }
            if gt(x, 0x00000000000000000000000000000000000000000000000000000000000000FF) {
                r := add(r, 8)
                x := shr(8, x)
            }
            if gt(x, 0x000000000000000000000000000000000000000000000000000000000000000F) {
                r := add(r, 4)
                x := shr(4, x)
            }
            if gt(x, 0x0000000000000000000000000000000000000000000000000000000000000003) {
                r := add(r, 2)
                x := shr(2, x)
            }
            if gt(x, 0x0000000000000000000000000000000000000000000000000000000000000001) { r := add(r, 1) }
        }
    }

    // ──────────────────────────────────────────────
    // Internal: EIP-712 domain separator
    // ──────────────────────────────────────────────

    /// @dev Returns the domain separator, recomputing if the chain ID changed (e.g., fork).
    function _domainSeparator() internal view returns (bytes32) {
        if (block.chainid == _cachedChainId) return DOMAIN_SEPARATOR;
        return _computeDomainSeparator();
    }

    /// @dev Computes the EIP-712 domain separator for this vault instance.
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(this))
        );
    }

    // ──────────────────────────────────────────────
    // Internal: safe ERC-20 transfer (inlined per pattern policy)
    // ──────────────────────────────────────────────

    /// @dev Handles both bool-returning and non-bool-returning ERC-20s (USDT semantics).
    ///      The USDC address is set at initialize() and never changes.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Push-direction ERC-20 transfer. Handles both bool-returning and
    ///      non-bool-returning tokens (USDT semantics). Used by collect to pay
    ///      out fees to the position owner.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ──────────────────────────────────────────────
    // Internal: overflow-safe Q128 arithmetic (inlined per pattern policy)
    // ──────────────────────────────────────────────

    /// @dev Overflow-safe (a * b) / denominator with full 512-bit intermediate precision.
    ///      Truncates toward zero (floor division). Inlined from OpenZeppelin Math.mulDiv
    ///      per CLAUDE.md pattern policy — no library import.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // 512-bit multiply: [prod1, prod0] = a * b
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // If the product fits in 256 bits, standard division is sufficient
        if (prod1 == 0) {
            return prod0 / denominator;
        }

        // The product must be less than the denominator for the result to fit in 256 bits
        require(prod1 < denominator, "mulDiv overflow");

        // The remaining steps use modular arithmetic (Montgomery multiplication) where
        // intermediate overflows are intentional and mathematically correct mod 2^256.
        unchecked {
            // Subtract the remainder to make the product exactly divisible
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor out powers of two from the denominator using the largest power-of-two divisor
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Compute the modular inverse of the denominator via Newton's method (6 iterations
            // for 256-bit precision, starting from a 3-bit accurate seed)
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
        }
    }

    // ──────────────────────────────────────────────
    // Internal: safe casts (inlined per pattern policy)
    // ──────────────────────────────────────────────

    /// @dev uint256 → uint96 with overflow check. Used for escrowed USDC amounts,
    ///      which pack alongside the depositor's address in one PendingDeposit slot.
    ///      uint96 holds ~7.9e28 base units (~7.9e22 USDC at 6 decimals), far above
    ///      the token's total supply, so the bound is unreachable in practice — but a
    ///      truncating cast would record an escrow smaller than the USDC collected,
    ///      so it reverts instead.
    function _toUint96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) revert SafeCastOverflow();
        // casting to uint96 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(x);
    }

    /// @dev uint256 → uint128 with overflow check
    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert SafeCastOverflow();
        // casting to uint128 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    /// @dev uint128 → int128 with overflow check (liquidity is always positive)
    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        // casting to int128 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(x);
    }
}
