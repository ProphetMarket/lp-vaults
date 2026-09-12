// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market
// FEAT-T7AF: Mint LP Position
// UC-T7AG: Operator Mint Position for LP
// FEAT-TOGR: Notify and Distribute Fees
// UC-TOGS: Operator Notify Fee Revenue
// FEAT-TVS0: Update Tick and Cross Ticks
// UC-TVS1: Update Current Tick
// FEAT-U079: Collect Fees on a Position
// UC-U07A: Collect Position Fees
// FEAT-JGE7: Vault Wind-Down Lifecycle
// UC-JGEE: Start Wind Down
// FEAT-JXQO: Emergency Cancel All Positions
// UC-JXQW: Emergency Cancel All
// FEAT-K1M2: Merge Positions
// UC-K1M8: Merge Same-Range Positions
// FEAT-K1MD: Pause Trading
// UC-K1MK: Pause and Unpause Vault
// FEAT-3ZRI: Escrow Deposit for Mint Intent
// UC-3Z92: Operator Escrow Deposit for Intent
// FEAT-JAIJ: LP Escape Hatch
// UC-JAIK: Reclaim Deposit
// UC-3Z93: Operator Reclaim Deposit for LP

/// @dev Minimal ERC-20 interface — only approve needed for exchange setup.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal Gnosis ConditionalTokens interface — only the calls this repo makes.
///      Collateral is typed `address`, so it does not clash with the inline IERC20 above.
///      LPVaultFactory imports it from this file.
interface IConditionalTokens {
    function setApprovalForAll(address operator, bool approved) external;
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);
}

/// @dev Minimal factory interface for auth delegation (FR-FKD0, FR-FKD1, FR-FKD2) and for the two
///      Safe derivation inputs (FR-9OYI). Vault modifiers read role state from the factory at call
///      time, and _deriveSafe reads the derivation inputs the same way: both are immutable on the
///      factory, and the vault's factory pointer is fixed at initialize(), so no Admin can change them.
interface ILPVaultFactory {
    function operators(address) external view returns (uint256);
    function oracle() external view returns (address);
    function admins(address) external view returns (uint256);
    function safeFactory() external view returns (address);
    function safeProxyBytecodeHash() external view returns (bytes32);
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

    // FR-REQN: condition ID of the market, verified by LPVaultFactory before the clone exists (ADR-6HBU)
    // would be immutable in a non-clone contract; storage because EIP-1167.
    bytes32 public conditionId;

    // Index set 1 (YES) position ID of (usdc, conditionId)
    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint256 public yesTokenId;

    // Index set 2 (NO) position ID of (usdc, conditionId)
    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint256 public noTokenId;

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
    ///      LP exit paths (collect, reclaimDeposit, reclaimDepositFor) and emergencyCancelAll
    ///      are unaffected. Independent of the phase state machine.
    bool public paused;

    /// @dev Running total of liquidity in range
    uint128 public activeLiquidity;

    /// @dev Global fee accumulator (Q128 fixed-point)
    uint256 public feeGrowthGlobalX128;

    /// @dev Current tick for the vault's market price
    int24 public currentTick;

    /// @dev Counter for minting new positions
    uint256 public nextPositionId;

    /// @dev Tracks the most recent block.timestamp of any successful Operator call
    ///      (every Operator function carries touchesHeartbeat). Used by
    ///      emergencyCancelAll to detect prolonged Operator silence.
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
    // Escrow state (FEAT-3ZRI)
    // ──────────────────────────────────────────────

    /// @dev One escrow per mint intent. `lp` is the Safe that paid and the only address that
    ///      may consume the entry; address(0) means no escrow (ADR-45IC). `amount` packs with
    ///      `lp` into one slot, and the inline SafeCast in depositForIntent keeps it exact
    ///      (FR-45IA). `structHash` is the MintIntent hash that authorized the escrow, so the
    ///      mint can bind the range, the amount, and the deadline without a second signature
    ///      check (FR-3Z9W).
    struct PendingDeposit {
        address lp;
        uint96 amount;
        bytes32 structHash;
    }

    /// @dev intentId => escrow. Written once by depositForIntent, then only deleted, by
    ///      mintPositionFor or by a reclaim. Never incremented and never reassigned.
    mapping(bytes32 => PendingDeposit) public pendingDeposits;

    /// @dev Sum of every pendingDeposits[*].amount (FR-9OYM). USDC.balanceOf(vault) is always
    ///      at least this much. R9 pays burns and collects from balance - totalEscrowed, so
    ///      escrowed USDC never pays an exit (decision C7).
    uint256 public totalEscrowed;

    // ──────────────────────────────────────────────
    // TickBitmap (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev One uint256 word per 256 consecutive ticks. Bit N is set when the
    ///      tick at (wordPosition * 256 + N) is initialized. Enables O(1) per-word
    ///      lookup of the next initialized tick during updateTick.
    mapping(int16 => uint256) public tickBitmap;

    // ──────────────────────────────────────────────
    // EIP-712 (inlined per pattern policy in CLAUDE.md)
    // ──────────────────────────────────────────────

    bytes32 public DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Every LP-signed type carries a deadline (FR-9OYJ, ADR-9OYP). `lp` is the LP's Safe.
    bytes32 private constant MINT_INTENT_TYPEHASH = keccak256(
        "MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId,uint256 deadline)"
    );

    /// @dev A distinct type for the relayed reclaim, so a mint authorization never doubles as a
    ///      cancellation (ADR-4029). The refund comes from the escrow record, so the type carries
    ///      neither the range nor the amount.
    bytes32 private constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,bytes32 intentId,uint256 deadline)");

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
    error UnknownTokenId();
    // FEAT-3ZRI, FEAT-JAIJ: one error per escrow state
    error DepositNotEscrowed();
    error DepositAlreadyEscrowed();
    error IntentMismatch();
    error IntentExpired();

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

    // SC-3Z94: emitted on every successful escrow; lp is the Safe that paid
    event DepositEscrowed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // SC-JAIL, SC-3Z9D: emitted by both reclaim paths with the recorded Safe and the recorded amount
    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // SC-K1M9: emitted when Operator merges same-range positions
    event PositionsMerged(uint256[] positionIds, uint256 survivorId);

    // SC-K1ML: emitted when Admin pauses trading
    event TradingPaused(address indexed caller);

    // SC-K1MM: emitted when Admin unpauses trading
    event TradingUnpaused(address indexed caller);

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
    ///      LP exit paths (collect, reclaimDeposit, reclaimDepositFor) are NOT gated.
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
    ///      No identity check runs here: only the factory can call initialize(), and the
    ///      factory verifies conditionId, yesTokenId, and noTokenId before it deploys the clone.
    ///      Approval scope: setApprovalForAll(exchange, true) on the ConditionalTokens
    ///      is acceptable BECAUSE the vault holds outcome tokens for exactly one market.
    ///      The receiver hooks enforce this: they revert on every token ID other than
    ///      yesTokenId and noTokenId, which the factory verified at createVault, so the
    ///      unscoped approval covers this market's two tokens only.
    /// @param marketId_ Unique market identifier from the CTF Exchange
    /// @param usdc_ USDC ERC-20 address
    /// @param exchange_ ProphetCTFExchange address
    /// @param conditionalTokens_ Gnosis ConditionalTokens (ERC-1155) address
    /// @param tickSpacing_ Minimum tick increment for positions
    /// @param factory_ Factory contract address — must equal msg.sender
    /// @param minimumFirstLiquidity_ Floor for the first mint when activeLiquidity == 0
    /// @param version_ Implementation version from the factory's counter
    /// @param conditionId_ ConditionalTokens condition ID of the market
    /// @param yesTokenId_ Index set 1 (YES) position ID of (usdc, conditionId)
    /// @param noTokenId_ Index set 2 (NO) position ID of (usdc, conditionId)
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
        IConditionalTokens(conditionalTokens_).setApprovalForAll(exchange_, true);
    }

    // ──────────────────────────────────────────────
    // ERC-1155 reception (FR-3WLI, FR-3WLJ, FR-3WLK, FR-6HBT)
    // ──────────────────────────────────────────────

    // SC-3WLL, SC-3WLN, SC-6HBY: acknowledge single transfers of this vault's two outcome tokens from its CTF
    /// @notice Accepts a single ERC-1155 transfer of the vault's YES or NO token.
    /// @dev Stateless by design. The vault's position, tick, and fee accounting is driven
    ///      by mintPositionFor, collect, and notifyFees — never by observing an inbound
    ///      transfer — so this hook deliberately records nothing. Reconciling raw token
    ///      balances against position accounting is the Operator's off-chain job.
    ///      No nonReentrant guard: the hook mutates nothing and makes no external call, and
    ///      guarding it would revert legitimate transfers that occur inside an already-
    ///      guarded vault call.
    ///      Reverts UnknownTokenId for any ID other than yesTokenId and noTokenId. The hook never
    ///      merges: it runs inside the exchange's settlement transaction, so a revert there
    ///      reverts the match (ADR-3WLP).
    /// @return The ERC-1155 single-transfer acknowledgement value.
    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        view
        onlyConditionalTokens
        returns (bytes4)
    {
        _requireOwnTokenId(id, yesTokenId, noTokenId);
        return 0xf23a6e61;
    }

    // SC-3WLM, SC-3WLN, SC-6HBY: acknowledge batch transfers of this vault's two outcome tokens from its CTF
    /// @notice Accepts a batch ERC-1155 transfer drawn from the vault's YES and NO tokens.
    /// @dev Stateless for the same reasons as onERC1155Received above. Reverts UnknownTokenId
    ///      when any element of `ids` is outside {yesTokenId, noTokenId}.
    /// @return The ERC-1155 batch-transfer acknowledgement value.
    function onERC1155BatchReceived(address, address, uint256[] calldata ids, uint256[] calldata, bytes calldata)
        external
        view
        onlyConditionalTokens
        returns (bytes4)
    {
        // Both IDs are read once, outside the loop (CLAUDE.md priority 2). The loop has no
        // length cap: the token contract sets the length, and the sender pays for it.
        uint256 yesId = yesTokenId;
        uint256 noId = noTokenId;
        for (uint256 i = 0; i < ids.length; i++) {
            _requireOwnTokenId(ids[i], yesId, noId);
        }
        return 0xbc197c81;
    }

    /// @dev Reverts unless `id` is one of the vault's two outcome token IDs (FR-6HBT).
    function _requireOwnTokenId(uint256 id, uint256 yesId, uint256 noId) internal pure {
        if (id != yesId && id != noId) revert UnknownTokenId();
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
    ///      back to Active. Once in WindDown, depositForIntent and mintPositionFor
    ///      revert (phase guard at the top of each), while collect, reclaimDeposit,
    ///      and reclaimDepositFor remain callable so LPs can exit.
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
    /// @notice Halts all trading entry points (depositForIntent, mintPositionFor,
    ///         notifyFees, updateTick, mergePositions) while keeping LP exit paths live.
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
            // unchecked: feeGrowthInsideX128 and feeGrowthInsideLastX128 both wrapped
            // mod 2^256 by the same offset (see _computeFeeGrowthInside), so this
            // subtraction must wrap too: it cancels the offset to the true small delta,
            // mirroring Uniswap v3's fee-growth accounting. That subtraction is the
            // load-bearing part. On a correct delta, liquidity * delta fits in 256 bits
            // for every reachable value, so _mulDiv would return the same number; on a
            // wrong delta both forms return a wrong number. The product stays in this
            // block and never goes through _mulDiv by convention, so every fee site
            // keeps one shape (ADR-8L1F in FEAT-T7AF, CLAUDE.md checklist item 3).
            uint256 fees;
            unchecked {
                fees = uint256(p.liquidity) * (feeGrowthInsideX128 - p.feeGrowthInsideLastX128) / Q128;
            }
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

    // SC-3Z94 through SC-3Z9B, SC-9OY9, SC-9OYA, SC-9OYB, SC-9OYD: operator-gated per-intent escrow
    /// @notice Pulls an LP's USDC from the LP's Safe against a signed mint intent and records the
    ///         escrow under the intentId, so the mint and the reclaim spend exactly what was recorded.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator chooses whether and when to escrow an intent.
    ///      The Operator cannot fabricate a deposit, cannot pull from a Safe whose owner key did not
    ///      sign this exact intent and approve the vault, and cannot escrow more than the signed
    ///      amount. A refusal leaves the USDC in the Safe, so there is nothing to rescue (ADR-3Z9Z).
    ///      Once escrowed, the LP's exit is the one-call reclaimDeposit (FEAT-JAIJ).
    ///
    ///      MEV analysis: the escrow creates no position, touches no tick, and reads no price.
    ///      The only ordering effect is that one escrow blocks a second on the same intentId,
    ///      and the signature binds that intentId to one Safe, so no third party is exposed.
    ///
    ///      The signer is the Safe's owner key, never the Safe: the vault requires that the Safe
    ///      derived from the recovered key equals `lp` (ADR-9OYP). A valid signature never proves
    ///      ownership of an intentId; the recorded Safe does (ADR-45IC).
    ///      Deadline check: `block.timestamp > deadline` reverts. A deadline is inclusive. Polygon's
    ///      block.timestamp tolerance is ±15s, so an intent signed with a deadline that close to the
    ///      current block may land on either side (CLAUDE.md checklist item 12). The deadline applies
    ///      once, here; the mint reads no clock (decision C1).
    ///      Checks-effects-interactions (NFR-3Z9U): every check first, the record and totalEscrowed
    ///      second, the USDC pull last, so a failed pull leaves no record behind (SC-9OYD).
    /// @param lp The LP's Safe — the recorded depositor and the USDC source
    /// @param tickLower Lower tick bound — must be < tickUpper and aligned to tickSpacing
    /// @param tickUpper Upper tick bound — must be > tickLower and aligned to tickSpacing
    /// @param usdcAmount USDC to pull from the Safe — must be > 0
    /// @param intentId Unique identifier for replay protection, shared with the mint and the reclaims
    /// @param deadline Last block.timestamp at which this deposit is accepted
    /// @param signature EIP-712 signature from the Safe's owner key over the MintIntent struct
    function depositForIntent(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat {
        // --- Checks ---

        // An escrow only funds a mint, and mints are Active-only
        if (phase != 1) revert VaultNotActive();

        // A zero escrow could never mint (FR-3Z9O)
        if (usdcAmount == 0) revert ZeroAmount();

        // The deadline applies once, at the deposit (FR-9OYK)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert IntentExpired();

        // Never take USDC for an intent the mint always rejects (FR-9OYL)
        _requireValidRange(tickLower, tickUpper);

        // The owner key must derive the named Safe (FR-3Z9Q)
        bytes32 structHash = _mintIntentHash(lp, tickLower, tickUpper, usdcAmount, intentId, deadline);
        _verifySafeOwnerSignature(lp, structHash, signature);

        // A spent intent can never be funded again, and never twice (FR-3Z9N)
        if (usedIntents[intentId]) revert IntentAlreadyUsed();
        if (pendingDeposits[intentId].lp != address(0)) revert DepositAlreadyEscrowed();

        // --- Effects ---

        pendingDeposits[intentId] = PendingDeposit({lp: lp, amount: _toUint96(usdcAmount), structHash: structHash});
        totalEscrowed += usdcAmount;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // Pull USDC from the Safe, which approved the vault through a relayed Safe transaction (C25)
        _safeTransferFrom(usdc, lp, address(this), usdcAmount);

        emit DepositEscrowed(intentId, lp, usdcAmount);
    }

    // ──────────────────────────────────────────────
    // Position minting (FEAT-T7AF, UC-T7AG)
    // ──────────────────────────────────────────────

    // SC-T7AH through SC-T7AR, SC-3Z9J, SC-45IE, SC-3Z9K: operator-gated mint that consumes an escrow
    /// @notice Creates the concentrated-liquidity position that an escrowed mint intent authorizes.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator chooses when to mint an escrowed intent. The
    ///      Operator cannot change its range, amount, or deadline (the recorded struct hash binds
    ///      them), cannot mint an intent that was never escrowed, and cannot give one Safe's deposit
    ///      to another (the recorded Safe must equal `lp`). LPs must trust that the Operator mints
    ///      promptly; the LP's exit is the one-call reclaimDeposit (FEAT-JAIJ), which the Operator
    ///      cannot block.
    ///      The mint verifies no signature and moves no USDC: the escrow did both (FEAT-3ZRI).
    ///      It reads no clock either. `deadline` is an argument only because the struct hash
    ///      needs it, so a deposit made near its deadline can still mint (decision C1).
    ///      The mint makes no external call. The nonReentrant guard stays as defense in depth
    ///      (NFR-T7B7), so a later revision that adds an external call cannot inherit an
    ///      unguarded function.
    /// @param lp The LP's Safe — must be the escrow's recorded depositor
    /// @param tickLower Lower tick bound — must be < tickUpper and aligned to tickSpacing
    /// @param tickUpper Upper tick bound — must be > tickLower and aligned to tickSpacing
    /// @param usdcAmount USDC amount of the intent — must be > 0 and equal the escrowed amount
    /// @param intentId Unique identifier for replay protection
    /// @param deadline The deadline the owner key signed — part of the recorded hash
    /// @return positionId The ID of the newly created position
    function mintPositionFor(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat returns (uint256 positionId) {
        // --- Checks ---

        // Vault must be active (not wound down)
        if (phase != 1) revert VaultNotActive();

        // USDC amount must be non-zero
        if (usdcAmount == 0) revert ZeroAmount();

        // Range must be valid and aligned (FR-T7B2, FR-T7B3)
        _requireValidRange(tickLower, tickUpper);

        // Replay protection, read before the escrow so a replay reports IntentAlreadyUsed (FR-T7B1)
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // The escrow is the only proof of deposit and of ownership (FR-45ID, FR-3Z9W)
        PendingDeposit memory escrow = pendingDeposits[intentId];
        if (escrow.lp == address(0)) revert DepositNotEscrowed();
        if (escrow.lp != lp) revert NotIntentOwner();
        if (escrow.structHash != _mintIntentHash(lp, tickLower, tickUpper, usdcAmount, intentId, deadline)) {
            revert IntentMismatch();
        }

        // --- Effects ---

        // Consume the escrow before any other state, for mutual exclusion with the reclaims (FR-3ZVK)
        usedIntents[intentId] = true;
        delete pendingDeposits[intentId];
        totalEscrowed -= escrow.amount;

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

        // No interaction: the USDC entered the vault at depositForIntent

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
        // unchecked: feeGrowthInsideX128 and feeGrowthInsideLastX128 both wrapped
        // mod 2^256 by the same offset (see _computeFeeGrowthInside), so this
        // subtraction must wrap too: it cancels the offset to the true small delta,
        // mirroring Uniswap v3's fee-growth accounting. That subtraction is the
        // load-bearing part. On a correct delta, liquidity * delta fits in 256 bits
        // for every reachable value, so _mulDiv would return the same number; on a
        // wrong delta both forms return a wrong number. The product stays in this
        // block and never goes through _mulDiv by convention, so every fee site
        // keeps one shape (ADR-8L1F in FEAT-T7AF, CLAUDE.md checklist item 3).
        uint256 owed;
        unchecked {
            owed = uint256(p.liquidity) * (feeGrowthInsideX128 - p.feeGrowthInsideLastX128) / Q128;
        }

        // Include previously accumulated fees (e.g., rolled up from mergePositions)
        owed += p.tokensOwed;
        p.tokensOwed = 0;

        // Snapshot update: future collects start from here
        p.feeGrowthInsideLastX128 = feeGrowthInsideX128;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        if (owed > 0) {
            _safeTransfer(usdc, msg.sender, owed);
            emit FeesCollected(positionId, msg.sender, owed);
        }
    }

    // ──────────────────────────────────────────────
    // Deposit reclaim (FEAT-JAIJ, UC-JAIK, UC-3Z93)
    // ──────────────────────────────────────────────

    // SC-JAIL, SC-3Z9L, SC-45IG, SC-JAIN, SC-3ZA0, SC-JAIP, SC-9OYE: one-call LP escape hatch
    /// @notice Refunds the USDC escrowed against an intent to the Safe that paid it, in one call.
    /// @dev The escrow record proves the deposit (ADR-3ZA1, ADR-9OYQ), so this path needs no
    ///      signature, no Operator co-signature, no timelock, no phase check, and no pause check.
    ///      It reads no Operator state, so it works with every Operator removed (NFR-3Z9X) and in
    ///      every phase, including Cancelled (FR-9OYO). The caller must be the recorded Safe:
    ///      a valid signature never proves ownership of an intentId (ADR-45IC).
    ///      A mint and a reclaim of one intentId share usedIntents on purpose, so exactly one of
    ///      them can happen (ADR-JAIY).
    /// @param intentId The escrowed intent to refund
    function reclaimDeposit(bytes32 intentId) external nonReentrant {
        // --- Checks ---

        // Replay protection, read before the escrow so a replay reports IntentAlreadyUsed (FR-JAIS, FR-JAIU)
        if (usedIntents[intentId]) revert IntentAlreadyUsed();

        // The escrow is the only proof of deposit and of ownership (FR-3ZVM, FR-45IF)
        PendingDeposit memory escrow = pendingDeposits[intentId];
        if (escrow.lp == address(0)) revert DepositNotEscrowed();
        if (escrow.lp != msg.sender) revert NotIntentOwner();

        // --- Effects and interactions ---

        _refundEscrow(intentId, escrow);
    }

    // SC-3Z9D through SC-3Z9I, SC-45IH, SC-9OYF, SC-9OYG, SC-9OYH: operator-relayed reclaim
    /// @notice Relays the owner key's signed ReclaimIntent to refund that Safe's escrowed USDC.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can censor, reorder, or delay a relayed
    ///      cancellation. The Operator cannot start one without the owner key's ReclaimIntent,
    ///      cannot replay a MintIntent as a reclaim (distinct typehash, ADR-4029), cannot redirect
    ///      the money (the refund goes to the recorded Safe, never to msg.sender), and cannot
    ///      refund a Safe other than the one that paid. A refusal leaves the Safe with the
    ///      self-service reclaimDeposit.
    ///
    ///      MEV analysis: the call returns a Safe's own escrow. The one ordering effect is the
    ///      race with mintPositionFor for the same intentId through the shared usedIntents, and
    ///      that race is between the Operator and the LP who signed both messages. No third party
    ///      is exposed, and no price is read.
    ///
    ///      Same deadline rule as depositForIntent: inclusive, with Polygon's ±15s tolerance
    ///      (CLAUDE.md checklist item 12). No phase check and no pause check (FR-9OYO).
    /// @param lp The LP's Safe — must be the escrow's recorded depositor
    /// @param intentId The escrowed intent to refund
    /// @param deadline Last block.timestamp at which this reclaim is accepted
    /// @param signature EIP-712 signature from the Safe's owner key over the ReclaimIntent struct
    function reclaimDepositFor(address lp, bytes32 intentId, uint256 deadline, bytes calldata signature)
        external
        onlyOperator
        nonReentrant
        touchesHeartbeat
    {
        // --- Checks ---

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert IntentExpired();

        // The owner key must derive the named Safe (FR-3ZVP, NFR-JAIX)
        _verifySafeOwnerSignature(lp, keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, intentId, deadline)), signature);

        // Same guards as reclaimDeposit, with the proven Safe in place of msg.sender
        if (usedIntents[intentId]) revert IntentAlreadyUsed();
        PendingDeposit memory escrow = pendingDeposits[intentId];
        if (escrow.lp == address(0)) revert DepositNotEscrowed();
        if (escrow.lp != lp) revert NotIntentOwner();

        // --- Effects and interactions ---

        _refundEscrow(intentId, escrow);
    }

    /// @dev One body for both reclaim entry points. Settles the record before the transfer
    ///      (NFR-JAIW), and pays the recorded Safe the recorded amount, never a caller value.
    function _refundEscrow(bytes32 intentId, PendingDeposit memory escrow) internal {
        // --- Effects ---

        usedIntents[intentId] = true;
        delete pendingDeposits[intentId];
        totalEscrowed -= escrow.amount;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        _safeTransfer(usdc, escrow.lp, escrow.amount);
        emit DepositReclaimed(intentId, escrow.lp, escrow.amount);
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
    ///      risk recorded in ADR-3XU3.
    ///
    ///      This is the refresh path while the vault is paused or wound down, where
    ///      `updateTick` reverts, and for an Operator with no report to send. On an Active
    ///      market the keeper's `updateTick` with the current tick refreshes the heartbeat
    ///      itself (ADR-9J43 in FEAT-TVS0); `notifyFees` reverts ZeroAmount on a quiet market.
    ///
    ///      Deliberately not gated by `whenNotPaused` and not gated to the Active phase: a
    ///      pause is an Admin decision about trading, and a wind-down is an Oracle decision
    ///      about the market. Neither says whether the Operator is alive, so neither state
    ///      must drift toward emergency cancellation while its Operator still responds.
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
    ///      A call with the current tick refreshes only the heartbeat and returns; while
    ///      the vault is paused or wound down the keeper calls `heartbeat()` instead.
    /// @param newTick The new price tick to set
    function updateTick(int24 newTick) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat {
        // Phase check: only Active vaults accept tick updates
        if (phase != 1) revert VaultNotActive();

        int24 oldTick = currentTick;

        // Unchanged report: the keeper reports every 60 seconds and after fills, and
        // most markets keep the same price, so this is the normal case. The
        // touchesHeartbeat modifier has already refreshed the heartbeat. Return with
        // no crossing, no bitmap read, no other storage write, and no event
        // (ADR-9J43 in FEAT-TVS0, SC-TVS7).
        if (newTick == oldTick) return;

        bool movingRight = newTick > oldTick;
        uint256 crossCount = 0;
        int24 tick = oldTick;

        if (movingRight) {
            // Cross every initialized tick in (oldTick, newTick]
            while (tick < newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, true);
                if (!found || next > newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                _crossTick(next, true);
                tick = next;
            }
        } else {
            // Cross every initialized tick in (newTick, oldTick]
            while (tick > newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, false);
                if (!found || next <= newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                _crossTick(next, false);
                tick = next - 1;
            }
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
        // unchecked: feeGrowthInsideX128 and feeGrowthInsideLastX128 both wrapped
        // mod 2^256 by the same offset (see _computeFeeGrowthInside), so this
        // subtraction must wrap too: it cancels the offset to the true small delta,
        // mirroring Uniswap v3's fee-growth accounting. That subtraction is the
        // load-bearing part. On a correct delta, liquidity * delta fits in 256 bits
        // for every reachable value, so _mulDiv would return the same number; on a
        // wrong delta both forms return a wrong number. The product stays in this
        // block and never goes through _mulDiv by convention, so every fee site
        // keeps one shape (ADR-8L1F in FEAT-T7AF, CLAUDE.md checklist item 3).
        uint256 survivorFees;
        unchecked {
            survivorFees = uint256(survivor.liquidity) * (feeGrowthInsideX128 - survivor.feeGrowthInsideLastX128) / Q128;
        }

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
            // unchecked: same wraparound-cancellation as survivorFees above, and the
            // same one-shape convention keeps this product out of _mulDiv.
            uint256 consumedFees;
            unchecked {
                consumedFees =
                    uint256(consumed.liquidity) * (feeGrowthInsideX128 - consumed.feeGrowthInsideLastX128) / Q128;
            }

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
    // Internal: intent hashing and range validation
    // ──────────────────────────────────────────────

    /// @dev The MintIntent struct hash. The deposit records it and the mint recomputes it, from
    ///      one function, so the two can never disagree on the field order (FR-3Z9W).
    function _mintIntentHash(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId, deadline));
    }

    /// @dev The range and alignment checks the deposit and the mint share (FR-T7B2, FR-T7B3,
    ///      FR-9OYL). The deposit runs them so the vault never takes USDC it can only refund.
    function _requireValidRange(int24 tickLower, int24 tickUpper) internal view {
        // Range must be valid: lower < upper
        if (tickLower >= tickUpper) revert InvalidRange();

        // Both ticks must align to the vault's tickSpacing
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) revert TickNotAligned();
    }

    // ──────────────────────────────────────────────
    // Internal: Safe owner-key signature verification (ADR-9OYP)
    // ──────────────────────────────────────────────

    /// @dev The one check every relayed LP path calls (the deposit, the relayed reclaim, and the
    ///      later relayed burn and collect). Builds the EIP-712 digest, recovers the signer, and
    ///      requires that the Safe the Poly Safe factory derives from that signer equals `safe`.
    ///      A Safe has no private key, so ecrecover can never return a Safe address; the owner key
    ///      signs, and the derivation binds it to its Safe, exactly as the exchange checks orders.
    ///      Known property: a Safe owner who swaps the owner key leaves the old key able to derive
    ///      the same Safe, so the old key keeps the relayed paths until the vault holds nothing for
    ///      that Safe. The exchange has the same property for orders.
    ///      This check never proves ownership of an intentId: any owner key can sign over any
    ///      intentId naming its own Safe. Every path that spends an escrow checks the recorded
    ///      Safe (ADR-45IC).
    function _verifySafeOwnerSignature(address safe, bytes32 structHash, bytes calldata signature) internal view {
        // Build the EIP-712 digest: \x19\x01 || domainSeparator || structHash
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        address signer = _recoverSigner(digest, signature);
        if (_deriveSafe(signer) != safe) revert InvalidSignature();
    }

    /// @dev Decodes a 65-byte signature and recovers the signer. Rejects malleable signatures
    ///      (high-s) and invalid v values per CLAUDE.md security checklist item 5, and a zero
    ///      recovery. One copy for every LP signature (FR-T7AZ, NFR-JAIX).
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
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

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }

    /// @dev The address the Poly Safe factory deploys for `owner`: the CREATE2 address with the
    ///      factory as deployer, keccak256(abi.encode(owner)) as salt, and the combined proxy
    ///      bytecode hash as init code hash, as in the exchange's PolySafeLib. Both inputs are
    ///      immutable on the factory and read here at call time (FR-9OYI).
    function _deriveSafe(address owner) internal view returns (address) {
        ILPVaultFactory f = ILPVaultFactory(factory);
        bytes32 salt = keccak256(abi.encode(owner));
        bytes32 raw = keccak256(abi.encodePacked(bytes1(0xff), f.safeFactory(), salt, f.safeProxyBytecodeHash()));
        // casting to uint160 keeps the low 20 bytes, which is the CREATE2 address by definition
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(raw)));
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
        // unchecked: a tick initialized late assumes all past growth sits on one
        // side of it, so feeGrowthBelow + feeGrowthAbove can exceed
        // feeGrowthGlobalX128 at the moment of subtraction. The result must wrap mod
        // 2^256 -- mirroring Uniswap v3's fee-growth accounting -- and a position
        // stores that wrapped value as its snapshot. A later inside - snapshot
        // subtraction, also unchecked, cancels the offset to the true delta. This is
        // the exception to CLAUDE.md checklist item 3 that ADR-8L1F (FEAT-T7AF)
        // records, not an "overflow is provably impossible" situation.
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

    /// @dev Finds the next initialized tick relative to the given tick.
    ///      searchRight=true: smallest initialized tick strictly greater than `tick`.
    ///      searchRight=false: largest initialized tick less than or equal to `tick`.
    ///      Returns (nextTick, true) if found, or (0, false) if no initialized tick exists.
    function _nextInitializedTick(int24 tick, bool searchRight) internal view returns (int24 next, bool found) {
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

            // Search subsequent words
            wordPos++;
            for (; wordPos <= type(int16).max; wordPos++) {
                word = tickBitmap[wordPos];
                if (word != 0) {
                    uint8 offset = _leastSignificantBit(word);
                    return (int24(int256(wordPos)) * 256 + int24(uint24(offset)), true);
                }
            }
            return (0, false);
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

            // Search previous words
            wordPos--;
            for (; wordPos >= type(int16).min; wordPos--) {
                word = tickBitmap[wordPos];
                if (word != 0) {
                    uint8 offset = _mostSignificantBit(word);
                    return (int24(int256(wordPos)) * 256 + int24(uint24(offset)), true);
                }
                if (wordPos == type(int16).min) break;
            }
            return (0, false);
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

    /// @dev uint256 → uint128 with overflow check
    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert SafeCastOverflow();
        // casting to uint128 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    /// @dev uint256 → uint96 with overflow check. The escrow amount packs with the Safe into one
    ///      slot (FR-45IA); a silent truncation would record less than the USDC collected.
    function _toUint96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) revert SafeCastOverflow();
        // casting to uint96 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(x);
    }

    /// @dev uint128 → int128 with overflow check (liquidity is always positive)
    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        // casting to int128 is safe because overflow is checked on the line above
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(x);
    }
}
