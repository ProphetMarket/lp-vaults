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
// FEAT-7G40: Burn LP Position
// UC-7G41: Burn Position, UC-7G42: Operator Burn Position for LP
// FEAT-6HBN: Complete-Set Merge and Resolution Redemption
// UC-6HBO: Merge Complete Sets
// UC-BMF8: Operator Collect Fees for LP

/// @dev Minimal ERC-20 interface — approve for the exchange setup, balanceOf for the payout rule.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
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
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function mergePositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
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
    function defaultEmergencyCancelTimelock() external view returns (uint32);
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

    // FR-REQN, decision C10 (ADR-BZC5 in FEAT-REPZ): the Operator-silence duration before any
    // address may freeze the vault. Read from the factory's default once, inside initialize, and
    // never written again, so a later default change cannot reach this vault. A uint32 holds 136 years,
    // the factory caps the value at 30 days, and the four bytes pack into this slot with
    // tickSpacing and minimumFirstLiquidity, so the copy adds no storage slot.
    // would be immutable in a non-clone contract; storage because EIP-1167.
    uint32 public emergencyCancelTimelock;

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
    ///      LP exit paths (collect, collectFor, burnPosition, burnPositionFor, reclaimDeposit,
    ///      reclaimDepositFor), mergeCompleteSets, and emergencyCancelAll are unaffected.
    ///      Independent of the phase state machine.
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
        // FR-AFPO: currentTick at the mint, clamped into [tickLower, tickUpper] (ADR-AFPP). Packs
        // into the first slot with owner and the two bounds, so the mint writes no new slot.
        int24 mintTick;
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
    // Exit authorizations (FEAT-7G40, FEAT-U079)
    // ──────────────────────────────────────────────

    /// @dev BurnIntent struct hash => consumed. A burn hash is a pure function of
    ///      (lp, positionId, deadline), so anyone can compute anyone else's; sharing usedIntents
    ///      would let an attacker escrow a throwaway intent whose intentId is a victim's burn
    ///      hash and block that exit forever (ADR-85DM). Checked before the position, because
    ///      the hash needs only calldata, so a replay reports IntentAlreadyUsed (FR-7G55).
    mapping(bytes32 => bool) public usedBurnAuthorizations;

    /// @dev CollectIntent struct hash => consumed. Same reasoning as the burn record; the type
    ///      carries a nonce because a collect repeats over a position's life (FR-BMFA).
    mapping(bytes32 => bool) public usedCollectAuthorizations;

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
    ///      at least this much with no exchange fill. A burn and a collect pay from
    ///      balance - totalEscrowed (see _availableUsdc), so escrowed USDC never pays an exit
    ///      (decision C7).
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

    /// @dev A distinct type for the relayed burn (ADR-7G5H), so a mint authorization never
    ///      doubles as an exit. `lp` is the Safe; the deadline bounds the block the Operator
    ///      may choose (FR-BMF0).
    bytes32 private constant BURN_INTENT_TYPEHASH =
        keccak256("BurnIntent(address lp,uint256 positionId,uint256 deadline)");

    /// @dev A distinct type for the relayed collect. The nonce makes each authorization unique,
    ///      because a collect repeats over a position's life (decision C3, FR-BMFA).
    bytes32 private constant COLLECT_INTENT_TYPEHASH =
        keccak256("CollectIntent(address lp,uint256 positionId,uint256 nonce,uint256 deadline)");

    uint256 private constant SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @dev Scaling factor for liquidity computation: L = usdcAmount * PRECISION / rangeWidth.
    ///      Under the claim model (decision C26) L is the token count on every tick of the
    ///      range, each tick funded with 1 USDC per token (ADR-7G5F in FEAT-7G40).
    uint256 public constant LIQUIDITY_PRECISION = 1e18;

    /// @dev The tick whose price is 1.00: one tick is one basis point, the exchange's own
    ///      priceBps unit, so price(tick) = tick / PRICE_TICK_ONE. Every position range lies
    ///      inside [0, PRICE_TICK_ONE] (FR-T7B2, FR-9OYL, ADR-BMF7 in FEAT-T7AF); tickSpacing
    ///      sets the width of a level. currentTick itself is unbounded.
    int24 public constant PRICE_TICK_ONE = 10_000;

    /// @dev Q128 = 2^128. Scaling factor for fee accumulator fixed-point math.
    uint256 internal constant Q128 = 1 << 128;

    /// @dev Maximum number of initialized ticks that can be crossed in a single
    ///      updateTick call. Prevents gas griefing on large price moves.
    uint256 internal constant MAX_TICK_CROSSINGS = 256;

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
    error VaultCancelled();
    error RangeMismatch();
    error InsufficientPositions();
    // FEAT-K1M2, audit issue 6.14 and decision C16: one error per merge rejection
    error DuplicatePositionId();
    error MintTickMismatch();
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

    // SC-JXQX: emitted when any address freezes the vault after the silence timelock
    event EmergencyCancelExecuted(address indexed caller);

    // SC-TOGT, SC-TOGU: emitted when Operator distributes fee revenue
    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

    // SC-TVS2 through SC-TVS4: emitted on every successful tick update
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    // SC-U07B, SC-U07F, SC-U07G, SC-BMFG: emitted by both collect paths when the paid amount is
    // nonzero; `amount` is what was paid, which a short vault may leave below what was owed
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

    // SC-6HC9, SC-BMF1, SC-BMFE: emitted when pairs merge into USDC, by the public call and by a
    // burn or a collect that merged first; never on a zero merge
    event CompleteSetsMerged(address indexed caller, uint256 amount);

    // SC-7G43 through SC-7G46, SC-BMF1 through SC-BMF3, SC-7G4C through SC-7G4E: emitted by both
    // burn paths. usdcOwed is the claim's USDC leg, feesOwed the accrued fees, usdcPaid the one
    // USDC transfer (at most usdcOwed + feesOwed), tokenId the YES or NO id of the band (zero when
    // the band is empty), tokenOwed the band's tokens, tokenPaid the tokens transferred. An
    // indexer sees a shortfall as paid < owed (decision O2).
    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 feesOwed,
        uint256 usdcPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );

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
        int24 mintTick,
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

    /// @dev Gates trading entry points while the vault is paused. LP exit paths (collect,
    ///      collectFor, burnPosition, burnPositionFor, reclaimDeposit, reclaimDepositFor) and
    ///      mergeCompleteSets are NOT gated.
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
    /// @param minimumFirstLiquidity_ Floor for the first mint, when nextPositionId == 0
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
        // The emergency-cancel timelock is read from the factory once, here, and never again
        // (decision C10): a twelfth parameter does not compile under forge coverage, where the
        // optimizer is off, so the copy is a read instead of an argument. The factory is
        // msg.sender, checked above, so the read is against a trusted contract.
        emergencyCancelTimelock = ILPVaultFactory(factory_).defaultEmergencyCancelTimelock();
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
    ///      The value matters only before the first mint: the floor applies when
    ///      nextPositionId == 0 (decision C15, audit issue 6.9). After the first mint the
    ///      setter still succeeds and changes a value that no mint reads (FR-RG4W).
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
    ///      revert (phase guard at the top of each), while collect, collectFor, burnPosition,
    ///      burnPositionFor, reclaimDeposit, reclaimDepositFor, and mergeCompleteSets remain
    ///      callable so LPs can exit.
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

    // SC-JXQX, SC-JXQY, SC-BZBW, SC-BZBX, SC-JXR1: any address freezes the vault after the timelock
    /// @notice Freezes the vault after the Operator has been silent for the vault's emergency-cancel
    ///         timelock: sets the phase to Cancelled and changes nothing else.
    /// @dev Any address may call it, because the freeze moves no funds and the timelock is the whole
    ///      condition (audit-solutions.md Finding 4, decision C9, ADR-BZBY). It keeps activeLiquidity,
    ///      every tick, every position, and every total: an in-range burn subtracts from
    ///      activeLiquidity with checked arithmetic, and the exits value each claim from the records.
    ///      No nonReentrant, because the function makes no external call and moves no token
    ///      (CLAUDE.md checklist item 1), the same as startWindDown and pauseTrading.
    ///      After the freeze, burnPosition, burnPositionFor, collect, collectFor, reclaimDeposit,
    ///      reclaimDepositFor, and mergeCompleteSets work and pay what they pay in WindDown at the
    ///      same tick, so each LP exits in their own transaction and a USDC-blacklisted LP blocks
    ///      only their own exit (audit issue 6.17). The vault approves no new order after the
    ///      freeze, because the order maker accepts an order only while Active and not paused
    ///      (decision C22, ADR-BZBZ, built in Part 6). The ±15s Polygon tolerance is negligible at
    ///      the day scale of the timelock (CLAUDE.md checklist item 12).
    ///      The Cancelled phase (3) is terminal: every trading entry point reverts after it.
    function emergencyCancelAll() external {
        // Already cancelled: terminal state, nothing to do
        if (phase == 3) revert VaultCancelled();

        // Operator-silence timelock must have elapsed
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - lastOperatorActivityTimestamp < emergencyCancelTimelock) {
            revert TimelockNotElapsed();
        }

        // The freeze writes phase and nothing else (FR-JXQP)
        phase = 3;

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
    ///      The Operator also chooses the position's mint tick, through the order of its
    ///      updateTick and mintPositionFor calls, because the mint reads currentTick. The clamp
    ///      bounds the value to the position's range (FR-AFPO, ADR-AFPP). Under the claim model
    ///      (decision C26) the mint tick anchors which levels hold USDC and which hold outcome
    ///      tokens, so LPs must trust the Operator to report the tick it quoted from before it
    ///      mints.
    ///
    ///      MEV analysis: the mint tick is set from the vault's own currentTick, which only the
    ///      Operator moves, so no third party can front-run it. A stale or wrong report is
    ///      Operator behavior, covered by the trust statement above.
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

        // First-mint floor check (FR-RFS7 from FEAT-REPZ). nextPositionId only grows and no ID is
        // reused, so the floor applies exactly once. activeLiquidity returns to zero whenever the
        // price enters a range with no position, so it cannot mark the first mint (audit issue 6.9).
        if (nextPositionId == 0 && liquidity < minimumFirstLiquidity) {
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

        // The mint tick anchors the claim (decision C26). Outside the range it clamps to the
        // nearer bound, so every position minted on one side of its range holds the same mix and
        // can merge (FR-AFPO, ADR-AFPP).
        int24 mintTick = currentTick;
        if (mintTick < tickLower) mintTick = tickLower;
        else if (mintTick > tickUpper) mintTick = tickUpper;

        // Create the position record
        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: lp,
            tickLower: tickLower,
            tickUpper: tickUpper,
            mintTick: mintTick,
            liquidity: liquidity,
            feeGrowthInsideLastX128: feeGrowthInsideX128,
            tokensOwed: 0
        });

        // Update active liquidity if the position is in-range
        if (tickLower <= currentTick && currentTick < tickUpper) {
            activeLiquidity += liquidity;
        }

        // No interaction: the USDC entered the vault at depositForIntent

        emit PositionMinted(positionId, lp, tickLower, tickUpper, mintTick, liquidity, usdcAmount, intentId);
    }

    // ──────────────────────────────────────────────
    // Fee collection (FEAT-U079, UC-U07A)
    // ──────────────────────────────────────────────

    // SC-U07B through SC-U07G, SC-8L1D, SC-8L1E, SC-BMFD, SC-BMFE, SC-BMFF: the Safe collects
    // its accumulated trading fees
    /// @notice Withdraws accumulated trading fees from a position without removing it.
    /// @dev No phase restriction and no pause check (FR-U07O, decision C9): collect works in
    ///      Active, WindDown, and Cancelled, so LPs have an unbounded claim window. The
    ///      feeGrowthInsideLastX128 snapshot prevents double-counting: each collect only pays
    ///      fees that grew since the previous collect (or since mint). The body is shared with
    ///      collectFor; see _collect for the merge and the pay-what-is-there rule.
    /// @param positionId The ID of the position to collect fees from
    function collect(uint256 positionId) external nonReentrant {
        // --- Checks ---

        Position storage p = positions[positionId];

        // Position must exist (owner is never set to address(0) during mint)
        if (p.owner == address(0)) revert PositionNotFound();

        // Only the position's owner can collect
        if (p.owner != msg.sender) revert NotPositionOwner();

        _collect(positionId, p);
    }

    // SC-BMFG through SC-BMFM, SC-BMG6: operator-relayed collect against the owner key's CollectIntent
    /// @notice Relays the owner key's signed CollectIntent to pay that Safe its accrued fees, with
    ///         the Operator paying the gas.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can delay a relayed collect and chooses which
    ///      block it lands in, which changes nothing about the fees owed, because the accumulator
    ///      only grows and the snapshot only moves forward. The Operator cannot start a collect
    ///      without the owner key's CollectIntent, cannot replay a spent nonce, cannot replay a
    ///      mint, reclaim, or burn signature (distinct typehash), cannot redirect the payout (it
    ///      goes to position.owner, never to msg.sender), and cannot collect for a Safe that does
    ///      not own the position. A refusal leaves the Safe with the self-service collect.
    ///
    ///      MEV analysis: the call moves the vault's USDC to the position's owner and reads no
    ///      price, so no third party can gain from its ordering.
    ///
    ///      Same shape as reclaimDepositFor (R5): the deadline, the signature, the used record,
    ///      the position, then the record set before any external call (FR-BMFA). The deadline is
    ///      inclusive, with Polygon's ±15s tolerance (CLAUDE.md checklist item 12).
    /// @param lp The LP's Safe — must be the position's recorded owner
    /// @param positionId The position to collect from
    /// @param nonce A value the owner key never reuses for this position, so each collect is unique
    /// @param deadline Last block.timestamp at which this collect is accepted
    /// @param signature EIP-712 signature from the Safe's owner key over the CollectIntent struct
    function collectFor(address lp, uint256 positionId, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        onlyOperator
        nonReentrant
        touchesHeartbeat
    {
        // --- Checks ---

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert IntentExpired();

        // The owner key must derive the named Safe (FR-BMFA)
        bytes32 structHash = keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, lp, positionId, nonce, deadline));
        _verifySafeOwnerSignature(lp, structHash, signature);

        // A spent authorization never pays twice (FR-BMFA, ADR-85DM)
        if (usedCollectAuthorizations[structHash]) revert IntentAlreadyUsed();

        // Same guards as collect, with the proven Safe in place of msg.sender
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != lp) revert NotPositionOwner();

        // --- Effects ---

        // Check-then-set before any external work (CLAUDE.md checklist item 4)
        usedCollectAuthorizations[structHash] = true;

        _collect(positionId, p);
    }

    /// @dev One body for both collect entry points. Reads first (the fees, both token balances,
    ///      the USDC balance, and the amount to pay), effects second (the snapshot and the
    ///      remainder), interactions last (the merge, then the transfer), per NFR-U07R. The
    ///      amount to pay is known before the merge because a merge pays exactly min(yes, no)
    ///      USDC. A zero-owed collect reads no balance and merges nothing (FR-U07K).
    function _collect(uint256 positionId, Position storage p) internal {
        // --- Reads ---

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

        // Include previously accumulated fees (rolled up from mergePositions, or the unpaid
        // remainder of an earlier short collect)
        owed += p.tokensOwed;

        // Pay what is there (decision O2, FR-U07K): the smaller of what is owed and the USDC the
        // vault holds above escrow, counting the pairs the merge below turns into USDC.
        uint256 pairs;
        uint256 paid;
        if (owed > 0) {
            (uint256 yes, uint256 no) = _tokenBalances();
            pairs = yes < no ? yes : no;
            uint256 available = _availableUsdc(pairs);
            paid = owed < available ? owed : available;
        }

        // --- Effects ---

        // Snapshot update: future collects start from here. The unpaid remainder waits in
        // tokensOwed for a later collect, because the snapshot has already advanced.
        p.feeGrowthInsideLastX128 = feeGrowthInsideX128;
        p.tokensOwed = owed - paid;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        _mergeCompleteSets(pairs);

        if (paid > 0) {
            _safeTransfer(usdc, p.owner, paid);
            emit FeesCollected(positionId, p.owner, paid);
        }
    }

    // ──────────────────────────────────────────────
    // Position burn (FEAT-7G40, UC-7G41, UC-7G42)
    // ──────────────────────────────────────────────

    // SC-7G43 through SC-7G4B, SC-BMF1, SC-BMF2, SC-BMF3: the Safe closes a position it owns,
    // with no Operator involvement, in every phase
    /// @notice Closes a position the caller owns and pays what its claim holds: USDC for the
    ///         levels the price never crossed, one outcome token for the band between the mint
    ///         tick and the current tick, and the accrued fees, after merging the vault's pairs.
    /// @dev Unconditional by design (ADR-7G5G): this function requires no Operator action, no
    ///      Operator signature, and reads no Operator registry state, and it is gated behind no
    ///      phase, no pause, no declared emergency, and no timelock. That is what makes it the
    ///      escape hatch: an LP completes it in a vault whose entire operator set has been removed
    ///      by the Admin (NFR-7G5B). Any future change that gives this path a dependency on
    ///      Operator liveness voids the guarantee that LP capital is never trapped.
    ///
    ///      Deliberately does NOT refresh lastOperatorActivityTimestamp (FR-7G50). This is not an
    ///      Operator action, and letting LP activity refresh the silence timer would let LPs
    ///      exiting a stalled vault mask a dead Operator from emergencyCancelAll.
    ///
    ///      Restricted to the owner for timing control, not custody (ADR-7G5I): the claim depends
    ///      on currentTick at call time, so an unrestricted caller could force an LP's exit at a
    ///      moment the LP did not choose, even with the funds landing at the correct owner.
    ///
    ///      A zero-liquidity record with a live owner is NOT burnable (FR-7G4W): mergePositions
    ///      leaves records in that shape, and their liquidity already left the ticks. Burning one
    ///      would touch the ticks by zero and could clear a bitmap bit a survivor needs. The freeze
    ///      (emergencyCancelAll) leaves every record intact, so a burn after it pays in full.
    /// @param positionId The ID of the position to close
    function burnPosition(uint256 positionId) external nonReentrant {
        // --- Checks ---

        Position storage p = positions[positionId];

        // Never minted, already burned (the record is deleted), or consumed by a merge
        if (p.owner == address(0) || p.liquidity == 0) revert PositionNotFound();

        // Only the position's owner can close it
        if (p.owner != msg.sender) revert NotPositionOwner();

        _burn(positionId, p);
    }

    // SC-7G4C through SC-7G4K, SC-BMF4, SC-BMF5: operator-relayed burn against the owner key's BurnIntent
    /// @notice Relays the owner key's signed BurnIntent to close that Safe's position and pay
    ///         the Safe, with the Operator paying the gas.
    /// @dev Runs the same _burn body as burnPosition, so the two differ only in their
    ///      authorization checks and in whether the Operator heartbeat is refreshed (ADR-7G5E).
    ///      No payout or accounting arithmetic exists twice, so the paths cannot drift.
    ///
    ///      OPERATOR TRUST ASSUMPTION: The Operator can censor, reorder, or delay a relayed exit,
    ///      and chooses which block it lands in, so which currentTick values the claim, bounded
    ///      by the deadline the LP signed. The Operator cannot start a burn without the owner
    ///      key's BurnIntent (a struct with its own typehash, ADR-7G5H), cannot replay a mint,
    ///      reclaim, or collect signature, cannot redirect the payout (every asset goes to
    ///      position.owner, never to msg.sender), and cannot burn a position for another Safe
    ///      (the recorded owner must equal `lp`). The LP's remedy is burnPosition, which needs no
    ///      Operator at all.
    ///
    ///      MEV analysis: the burn reads a price but places no order and moves no tick, so no
    ///      third party can sandwich it. The one ordering effect is the Operator's own choice of
    ///      block, covered by the trust statement above and bounded by the deadline.
    ///
    ///      Same shape as reclaimDepositFor (R5): the deadline, the signature, the used record,
    ///      the position, then the record set before any external call. The deadline is
    ///      inclusive, with Polygon's ±15s tolerance (CLAUDE.md checklist item 12).
    /// @param lp The LP's Safe — must be the position's recorded owner
    /// @param positionId The position to close
    /// @param deadline Last block.timestamp at which this burn is accepted
    /// @param signature EIP-712 signature from the Safe's owner key over the BurnIntent struct
    function burnPositionFor(address lp, uint256 positionId, uint256 deadline, bytes calldata signature)
        external
        onlyOperator
        nonReentrant
        touchesHeartbeat
    {
        // --- Checks ---

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert IntentExpired();

        // The owner key must derive the named Safe (FR-7G53)
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, lp, positionId, deadline));
        _verifySafeOwnerSignature(lp, structHash, signature);

        // A spent authorization never burns twice, and the check runs before the position so a
        // replay reports IntentAlreadyUsed instead of PositionNotFound (FR-7G55, ADR-85DM)
        if (usedBurnAuthorizations[structHash]) revert IntentAlreadyUsed();

        // Same guards as burnPosition, with the proven Safe in place of msg.sender
        Position storage p = positions[positionId];
        if (p.owner == address(0) || p.liquidity == 0) revert PositionNotFound();
        if (p.owner != lp) revert NotPositionOwner();

        // --- Effects ---

        // Check-then-set before any external work (CLAUDE.md checklist item 4)
        usedBurnAuthorizations[structHash] = true;

        _burn(positionId, p);
    }

    /// @dev Every amount a burn reads or computes, filled before any effect (NFR-7G59). A memory
    ///      struct instead of locals, because _burn reads eight values and emits an eight-field
    ///      event, and the compiler's sixteen-slot stack is the limit without via_ir.
    struct BurnAmounts {
        uint256 usdcOwed;
        uint256 feesOwed;
        uint256 usdcPaid;
        uint256 tokenId;
        uint256 tokenOwed;
        uint256 tokenPaid;
        uint256 pairs;
    }

    /// @dev One body for both burn entry points (FR-7G4L). Order, per NFR-7G59 and CLAUDE.md
    ///      checklist item 1: every read first (_burnAmounts), then every state write (the two
    ///      ticks, activeLiquidity, the record), then the interactions, with the ERC-1155
    ///      transfer as the final call because a Safe owner can replace the Safe's fallback
    ///      handler and re-enter during that transfer. By then the record is deleted, both ticks
    ///      are updated, and the guard on every entry point that moves an asset stops the re-entry.
    ///      The one unguarded entry point, emergencyCancelAll, writes only phase, and a re-entry
    ///      into it during the transfer is harmless because the burn's effects are complete.
    function _burn(uint256 positionId, Position storage p) internal {
        // --- Reads and computation, all before any state is touched ---

        address owner = p.owner;
        int24 tickLower = p.tickLower;
        int24 tickUpper = p.tickUpper;
        uint128 liquidity = p.liquidity;
        BurnAmounts memory a = _burnAmounts(p);

        // --- Effects ---

        // Exact inverse of the mint deltas (FR-7G4O); a tick at zero is deinitialized (FR-7G4P)
        _removeLiquidityFromTick(tickLower, liquidity, true);
        _removeLiquidityFromTick(tickUpper, liquidity, false);

        // Only an in-range position contributes to activeLiquidity (FR-7G4Q)
        if (tickLower <= currentTick && currentTick < tickUpper) {
            activeLiquidity -= liquidity;
        }

        // Delete the whole record (FR-7G4S). nextPositionId is untouched, so the id is retired,
        // never recycled (FR-7G4T): reuse would let a stale reference resolve to another LP's
        // position.
        delete positions[positionId];

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // The pairs become the USDC that _availableUsdc already counted (decision C26)
        _mergeCompleteSets(a.pairs);

        // One transfer covers the claim's USDC and the fees (FR-7G4R)
        if (a.usdcPaid > 0) {
            _safeTransfer(usdc, owner, a.usdcPaid);
        }

        // The one outcome token of the band, delivered as is: no order, no conversion
        // (FR-7G4N). Last, because the receiver hook hands control to the recipient.
        if (a.tokenPaid > 0) {
            IConditionalTokens(conditionalTokens).safeTransferFrom(address(this), owner, a.tokenId, a.tokenPaid, "");
        }

        emit PositionBurned(positionId, owner, a.usdcOwed, a.feesOwed, a.usdcPaid, a.tokenId, a.tokenOwed, a.tokenPaid);
    }

    /// @dev The fees, the claim, both token balances, the USDC balance, and the two amounts to
    ///      pay, from view reads only. The amounts are computable before the merge because the
    ///      ConditionalTokens contract pays exactly min(yes, no) USDC for a merge and burns that
    ///      many of each token (NFR-7G59). Pay what is there (decision O2, FR-BMEZ): the smaller
    ///      of what is owed and what the vault holds, per asset, and never a revert.
    function _burnAmounts(Position storage p) internal view returns (BurnAmounts memory a) {
        // Fees must be computed while both boundary ticks still hold their feeGrowthOutsideX128;
        // the effects in _burn may delete them.
        // unchecked: feeGrowthInsideX128 and feeGrowthInsideLastX128 both wrapped
        // mod 2^256 by the same offset (see _computeFeeGrowthInside), so this
        // subtraction must wrap too: it cancels the offset to the true small delta,
        // mirroring Uniswap v3's fee-growth accounting. That subtraction is the
        // load-bearing part. On a correct delta, liquidity * delta fits in 256 bits
        // for every reachable value, so _mulDiv would return the same number; on a
        // wrong delta both forms return a wrong number. The product stays in this
        // block and never goes through _mulDiv by convention, so every fee site
        // keeps one shape (ADR-8L1F in FEAT-T7AF, CLAUDE.md checklist item 3).
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(p.tickLower, p.tickUpper);
        unchecked {
            a.feesOwed = uint256(p.liquidity) * (feeGrowthInsideX128 - p.feeGrowthInsideLastX128) / Q128;
        }
        a.feesOwed += p.tokensOwed;

        (a.usdcOwed, a.tokenId, a.tokenOwed) = _claim(p.tickLower, p.tickUpper, p.mintTick, p.liquidity);

        (uint256 yes, uint256 no) = _tokenBalances();
        a.pairs = yes < no ? yes : no;

        uint256 usdcTotal = a.usdcOwed + a.feesOwed;
        uint256 available = _availableUsdc(a.pairs);
        a.usdcPaid = usdcTotal < available ? usdcTotal : available;

        // The merge below consumes `pairs` of each token, so the band's token is what is left
        uint256 held = (a.tokenId == yesTokenId ? yes : no) - a.pairs;
        a.tokenPaid = a.tokenOwed < held ? a.tokenOwed : held;
    }

    /// @dev Values a claim under decision C26 (FR-7G4M, ADR-7G5F). Every level of the range holds
    ///      1 USDC per token until the price crosses it. Below the mint tick a level bought YES at
    ///      price t / PRICE_TICK_ONE when the price fell through it; at or above the mint tick a
    ///      level bought NO at 1 - t / PRICE_TICK_ONE when the price rose through it. The level
    ///      exactly at the mint tick, the slot [m, m + 1), belongs to the NO side, the same
    ///      half-open rule as "in range". The band is closed-form: tokens = L * band / 1e18, and
    ///      the USDC the band did not spend is an arithmetic series over its ticks, exact at price
    ///      0.0001 with no loop. band * (a + m - 1) is always even, so the halving is exact.
    ///      Every product stays under 2^156 (L < 2^128, width * ONE < 2^27), so none needs
    ///      _mulDiv, and every division rounds down (decision C21).
    ///      A clamped mint tick (FR-AFPO) needs no special case: a mint below its range has an
    ///      empty YES side, and a mint above it has an empty NO side, which the band == 0 check
    ///      catches before the sum, where a + m - 1 would underflow at a = m = 0.
    /// @return usdcOwed The USDC of the unfilled levels plus the unspent part of the band
    /// @return tokenId yesTokenId below the mint tick, noTokenId above it, zero when the band is empty
    /// @return tokenOwed One token per unit of liquidity per tick of the band
    function _claim(int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity)
        internal
        view
        returns (uint256 usdcOwed, uint256 tokenId, uint256 tokenOwed)
    {
        int24 current = currentTick;
        uint256 l = liquidity;
        // casting to uint256 is safe because tickUpper > tickLower is validated at the mint
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 width = uint256(int256(tickUpper - tickLower));
        // casting to uint256 is safe because PRICE_TICK_ONE is the positive constant 10,000
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 one = uint256(int256(PRICE_TICK_ONE));

        if (current < mintTick) {
            // The YES band [a, m): the levels the price fell through
            int24 a = current < tickLower ? tickLower : current;
            // casting to uint256 is safe because a <= mintTick, and both lie inside [0, 10000]
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 band = uint256(int256(mintTick - a));
            if (band > 0) {
                tokenId = yesTokenId;
                tokenOwed = l * band / LIQUIDITY_PRECISION;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 sumTicks = band * uint256(int256(a) + int256(mintTick) - 1) / 2;
                usdcOwed = l * (width * one - sumTicks) / (one * LIQUIDITY_PRECISION);
                return (usdcOwed, tokenId, tokenOwed);
            }
        } else if (current > mintTick) {
            // The NO band [m, b): the levels the price rose through
            int24 b = current > tickUpper ? tickUpper : current;
            // casting to uint256 is safe because b >= mintTick, and both lie inside [0, 10000]
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 band = uint256(int256(b - mintTick));
            if (band > 0) {
                tokenId = noTokenId;
                tokenOwed = l * band / LIQUIDITY_PRECISION;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 sumTicks = band * uint256(int256(mintTick) + int256(b) - 1) / 2;
                usdcOwed = l * ((width - band) * one + sumTicks) / (one * LIQUIDITY_PRECISION);
                return (usdcOwed, tokenId, tokenOwed);
            }
        }

        // The price sits at the mint tick, or the clamped side is empty: every level is USDC
        usdcOwed = l * width / LIQUIDITY_PRECISION;
    }

    /// @dev The USDC a payout may draw on (decisions C6 and C7): the balance plus the pairs the
    ///      merge is about to turn into USDC, less the escrow total, floored at zero. On chain a
    ///      fill turns vault USDC into tokens (decision C8), so the balance can sit below
    ///      totalEscrowed, and a checked subtraction would revert every exit.
    function _availableUsdc(uint256 pairs) internal view returns (uint256) {
        uint256 held = IERC20(usdc).balanceOf(address(this)) + pairs;
        uint256 escrowed = totalEscrowed;
        return held > escrowed ? held - escrowed : 0;
    }

    /// @dev Removes a burned position's liquidity from one boundary tick, the exact inverse of
    ///      the mint's writes (FR-7G4O), and deinitializes the tick when nothing references it
    ///      any more (FR-7G4P, audit issue 6.15). Deleting the record and clearing the bit
    ///      together is what keeps the bitmap's meaning: a set bit means liquidityGross > 0, or a
    ///      later updateTick would cross a tick with no liquidity behind it.
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

    // SC-TOGT, SC-TOGU, SC-TOGV, SC-TOGW, SC-TOGX, SC-TOGY, SC-ASNK: operator-gated fee accumulator
    // update that takes the USDC it credits from the caller (FR-ASNL, FR-ASNM)
    /// @notice Increments the global fee accumulator by the Q128-scaled share of new fee revenue,
    ///         and takes that revenue from the caller in the same call.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator funds every report in the same call. The
    ///      vault takes `amount` USDC from the Operator wallet with transferFrom, so no credit
    ///      exists without the USDC behind it, and a report the Operator cannot fund reverts
    ///      `TransferFailed`. The Operator can still under-report: the vault cannot know what
    ///      the exchange earned off-chain, so a report smaller than the true income, or no
    ///      report at all, stays inside the trust model. Operational need: each Operator
    ///      wallet holds a standing USDC approval to each vault it reports to (see
    ///      DEPLOYMENT.md). No solvency assertion runs here (decision C6): the report is a
    ///      receipt, not a gate. Decision C19, ADR-ASNR in FEAT-TOGR.
    ///
    ///      Checks-effects-interactions (NFR-ASNN): the phase, amount, and liquidity checks
    ///      run first, the accumulator write second, and the USDC pull last, under the
    ///      inline reentrancy guard because the pull is an external call.
    /// @param amount The amount of USDC fee revenue to distribute across active liquidity
    function notifyFees(uint256 amount) external onlyOperator whenNotPaused nonReentrant touchesHeartbeat {
        // A frozen vault takes no new trading work; its exits stay open (FR-JXQT)
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

        // --- Interactions (external call last, per checks-effects-interactions) ---

        // Take the USDC that the credit above represents. A failed pull reverts the whole
        // call, so the accumulator never records income the vault did not receive (C19).
        _safeTransferFrom(usdc, msg.sender, address(this), amount);

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
        // A frozen vault takes no new trading work; its exits stay open (FR-JXQT). The freeze is
        // terminal, so the silence timer has no further reader and a refresh serves no purpose.
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
    ///      The bitmap search reads only the words between currentTick and newTick
    ///      (FR-5IDE, ADR-5IDK), so the cost of a call follows the reported move and not
    ///      where any LP initialized a tick. A large jump across empty words still reads one
    ///      word per 256 ticks, so the Operator chunks a very large jump as it chunks
    ///      crossings (ADR-TVUW).
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
                (int24 next, bool found) = _nextInitializedTick(tick, true, newTick);
                if (!found || next > newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                _crossTick(next, true);
                tick = next;
            }
        } else {
            // Cross every initialized tick in (newTick, oldTick]
            while (tick > newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, false, newTick);
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
    /// @notice Combines two or more positions with identical owner, tickLower, tickUpper,
    ///         and mintTick into a single survivor position (positionIds[0]), preserving
    ///         total liquidity and rolling up accrued fees. This joins LP position records;
    ///         it is not the complete-set merge of outcome tokens into USDC.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can merge any positions that share
    ///      the same owner, range, and mint tick, and it can name each position only once:
    ///      a repeated ID reverts DuplicatePositionId (audit issue 6.14), and a different
    ///      mint tick reverts MintTickMismatch, because the mint tick is part of what a
    ///      claim holds under decision C26. LPs must trust that the Operator only merges
    ///      positions for legitimate housekeeping (reducing storage and gas costs for
    ///      overlapping positions).
    ///      No USDC moves during merge — uncollected fees from consumed positions are
    ///      rolled into the survivor's tokensOwed. Tick state (liquidityGross,
    ///      liquidityNet) is unchanged since total liquidity on the range stays the same.
    /// @param positionIds Array of distinct position IDs to merge — must have >= 2 elements,
    ///        all sharing the same owner, tickLower, tickUpper, and mintTick
    function mergePositions(uint256[] calldata positionIds)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
        touchesHeartbeat
    {
        // A frozen vault takes no new trading work; its exits stay open (FR-JXQT).
        // Deliberately Cancelled-only rather than `phase != 1`: FEAT-JGE7 documents that
        // the Operator may still merge positions during WindDown while LPs exit.
        if (phase == 3) revert VaultCancelled();

        // At least two positions required to merge
        if (positionIds.length < 2) revert InsufficientPositions();

        // SC-AFPQ, FR-AFPS: a repeated ID would alias the survivor and a consumed position onto
        // one storage slot and double its liquidity (audit issue 6.14). The check is pairwise over
        // calldata, before any position is read, because a merge joins a handful of positions.
        for (uint256 i = 0; i < positionIds.length; i++) {
            for (uint256 j = i + 1; j < positionIds.length; j++) {
                if (positionIds[i] == positionIds[j]) revert DuplicatePositionId();
            }
        }

        // Load the survivor (first position in the array)
        Position storage survivor = positions[positionIds[0]];
        address ownerAddr = survivor.owner;
        int24 tickLower = survivor.tickLower;
        int24 tickUpper = survivor.tickUpper;
        int24 mintTick = survivor.mintTick;

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
            // SC-AFPR, FR-AFPT: two mint ticks hold two asset mixes under the claim model (C26)
            if (consumed.mintTick != mintTick) revert MintTickMismatch();

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
    // Complete-set merge (FEAT-6HBN, UC-6HBO)
    // ──────────────────────────────────────────────

    // SC-6HC9, SC-6HCA, SC-6HCB, SC-6HCC: permissionless merge of matched YES and NO pairs
    /// @notice Merges min(YES balance, NO balance) complete sets of the vault's condition into
    ///         USDC held by the vault. Any wallet may call it, in every phase.
    /// @dev No role check, no pause check, no phase check, and no heartbeat refresh (ADR-6HCJ,
    ///      ADR-6HCL, ADR-6HCM): a refresh from any wallet would let anyone postpone
    ///      emergencyCancelAll, and a frozen vault's payouts still need the merge first
    ///      (decision C9).
    ///      MEV analysis: one YES plus one NO always pays exactly 1 USDC, so a merge moves no value
    ///      between parties. The caller receives nothing, and front-running, back-running, or
    ///      repeating the call changes no one's position. Keeper rule: anyone can merge at any
    ///      time, so every order that names the vault as maker must be a BUY order, and no resting
    ///      order may depend on the vault's YES or NO balance.
    function mergeCompleteSets() external nonReentrant {
        (uint256 yes, uint256 no) = _tokenBalances();
        _mergeCompleteSets(yes < no ? yes : no);
    }

    /// @dev The vault's balance of both outcome tokens, read once. The public merge and both
    ///      payout paths read through it, in their checks phase, so the amounts they pay are
    ///      known before any effect.
    function _tokenBalances() internal view returns (uint256 yes, uint256 no) {
        IConditionalTokens ctf = IConditionalTokens(conditionalTokens);
        yes = ctf.balanceOf(address(this), yesTokenId);
        no = ctf.balanceOf(address(this), noTokenId);
    }

    /// @dev Merges `amount` pairs, and returns without a call when there are none, so a payout
    ///      can run it unconditionally (FR-6HC0). The caller passes min(yes, no) from
    ///      _tokenBalances. No modifier: _burn and _collect call it inside their guarded entry
    ///      points, as their first interaction. A zero-amount mergePositions would not revert,
    ///      but it costs gas and emits an event.
    function _mergeCompleteSets(uint256 amount) internal {
        if (amount == 0) return;

        IConditionalTokens(conditionalTokens).mergePositions(usdc, bytes32(0), conditionId, _binaryPartition(), amount);
        emit CompleteSetsMerged(msg.sender, amount);
    }

    /// @dev The partition [1, 2]: index set 1 is YES and index set 2 is NO. The merge passes it
    ///      now, and the Part 6 redemption passes it later, so it lives in one place.
    function _binaryPartition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
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

        // Every level of the range must have a price, so the claim can value it (ADR-BMF7).
        // A range outside the scale would let a claim count tokens the vault never bought.
        if (tickLower < 0 || tickUpper > PRICE_TICK_ONE) revert InvalidRange();

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

    /// @dev Clears the bitmap bit for a tick when it becomes deinitialized. Called by
    ///      _removeLiquidityFromTick when a burn takes liquidityGross to zero (FR-7G4P,
    ///      audit issue 6.15), so a set bit always means liquidityGross > 0.
    function _clearTickBitmapBit(int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = _tickPosition(tick);
        // forge-lint: disable-next-line(incorrect-shift)
        tickBitmap[wordPos] &= ~(1 << bitPos);
    }

    /// @dev Finds the next initialized tick relative to the given tick, reading no bitmap word
    ///      beyond the one that holds `targetTick`.
    ///      searchRight=true: smallest initialized tick strictly greater than `tick`.
    ///      searchRight=false: largest initialized tick less than or equal to `tick`.
    ///      Returns (nextTick, true) if found, or (0, false) if no initialized tick exists
    ///      within the bounded range.
    ///
    ///      The bound (FR-5IDE, ADR-5IDK): the scan stops at the bitmap word that contains
    ///      `targetTick`, inclusive, so a tick that an LP initialized beyond the Operator's
    ///      target is never read and the cost of a call follows the reported move, not where
    ///      any third party placed a tick (NFR-5IDG). The target's own word is scanned in
    ///      full, so a set bit in that word past the target is returned, and `updateTick`'s
    ///      `next > newTick` or `next <= newTick` check discards it.
    ///
    ///      The extreme-word test (FR-5IDF): each loop checks for `type(int16).max` or
    ///      `type(int16).min` before it steps, so `wordPos` never overflows and reaching the
    ///      end of the scale is reported as "not found", never as an arithmetic panic. For a
    ///      target inside int24 the target-word test already stops at the extreme word, so
    ///      this test is defense in depth that decision C13 keeps on purpose.
    ///
    ///      Upward, `tick + 1` never overflows, because `updateTick` calls with
    ///      `tick < newTick <= type(int24).max`. Downward, the `next - 1` in `updateTick`
    ///      never underflows, because its loop breaks when `next <= newTick`, and
    ///      `newTick >= type(int24).min`.
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

            // Search subsequent words, up to and including the target's word. The bound and
            // the extreme-word test run before the step, so wordPos++ never overflows.
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

            // Search previous words, down to and including the target's word. The bound and
            // the extreme-word test run before the step, so wordPos-- never underflows.
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
