// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market
// FEAT-T7AF: Mint LP Position
// UC-T7AG: Operator Mint Position for LP
// FEAT-TVS0: Update Tick and Cross Ticks
// UC-TVS1: Update Current Tick
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
// UC-6HBO: Merge Complete Sets, UC-6HBP: Redeem Outcome Tokens After Resolution
// FEAT-9BQZ: Vault Solvency Ledger
// UC-9BR0: Maintain Solvency Totals, UC-9BR1: Accumulate Principal Shift, UC-9BR2: Apply Payout Ratios

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
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
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
///         positions and a solvency ledger of what it owes per asset.
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
    ///      (depositForIntent, mintPositionFor, updateTick, mergePositions) revert.
    ///      LP exit paths (burnPosition, burnPositionFor, reclaimDeposit, reclaimDepositFor),
    ///      mergeCompleteSets, and emergencyCancelAll are unaffected.
    ///      Independent of the phase state machine.
    bool public paused;

    /// @dev Running total of liquidity in range
    uint128 public activeLiquidity;

    /// @dev Current tick for the vault's market price
    int24 public currentTick;

    /// @dev The liquidity of the in-range positions whose mint tick is at or below currentTick:
    ///      the NO side of the claim model (decision C26), booked the way activeLiquidity is
    ///      (a per-tick noLiquidityNet that _crossTick applies) (FEAT-9BQZ, ADR-COEW). Since the
    ///      fee accumulator left (R17), currentTick packs into activeLiquidity's slot, and this
    ///      counter takes the next one; a different order is a Part 7 candidate, not this step's.
    uint128 public noSideLiquidity;

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
    }

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        // FEAT-9BQZ: the liquidityNet of the NO sub-ranges [mintTick, tickUpper) that reference
        // this tick, +L at a position's mint tick and -L at its tickUpper (ADR-COEW). Second slot;
        // deleted with the record.
        int128 noLiquidityNet;
    }

    /// @dev positionId => Position record
    mapping(uint256 => Position) public positions;

    /// @dev tick index => per-tick liquidity state
    mapping(int24 => TickInfo) public ticks;

    /// @dev intentId => true if already used (replay protection)
    mapping(bytes32 => bool) public usedIntents;

    // ──────────────────────────────────────────────
    // Exit authorizations (FEAT-7G40)
    // ──────────────────────────────────────────────

    /// @dev BurnIntent struct hash => consumed. A burn hash is a pure function of
    ///      (lp, positionId, deadline), so anyone can compute anyone else's; sharing usedIntents
    ///      would let an attacker escrow a throwaway intent whose intentId is a victim's burn
    ///      hash and block that exit forever (ADR-85DM). Checked before the position, because
    ///      the hash needs only calldata, so a replay reports IntentAlreadyUsed (FR-7G55).
    mapping(bytes32 => bool) public usedBurnAuthorizations;

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
    ///      at least this much with no exchange fill. The USDC ratio's numerator is
    ///      balance + pairs - totalEscrowed (see _availableUsdc), so escrowed USDC never pays an
    ///      exit (decision C7).
    uint256 public totalEscrowed;

    // ──────────────────────────────────────────────
    // Solvency ledger (FEAT-9BQZ)
    // ──────────────────────────────────────────────

    /// @dev Running totals of what the vault owes to its live positions, each held in the
    ///      claim's pre-division unit so that a mint and its burn cancel exactly (FR-9BR3,
    ///      FR-9BR4, ADR-COEN). Truncated only in the getters below.
    ///      USDC principal, in USDC units x PRICE_TICK_ONE x LIQUIDITY_PRECISION (USDC_CLAIM_SCALE).
    uint256 public totalUsdcOwedScaled;
    /// @dev YES tokens, in token units x LIQUIDITY_PRECISION. Never netted against NO (FR-9BR5).
    uint256 public totalYesOwedScaled;
    /// @dev NO tokens, in token units x LIQUIDITY_PRECISION. Never netted against YES (FR-9BR5).
    uint256 public totalNoOwedScaled;

    // ──────────────────────────────────────────────
    // Resolution (FEAT-6HBN)
    // ──────────────────────────────────────────────

    /// @dev The switch (ADR-6HCK): the condition's two payout numerators, copied from the
    ///      ConditionalTokens contract by the Oracle's first successful redeemOutcomeTokens and
    ///      never written again. Both zero until then. The switch is on when the slot is
    ///      non-zero, and the denominator is their sum, which is exact because the factory
    ///      verified two outcome slots at createVault and the ConditionalTokens contract sets
    ///      its denominator to the sum of the reported numerators. One slot, so every payout
    ///      reads the switch in one storage read instead of three external reads. Never an
    ///      argument: the Oracle cannot set a payout (FR-6HC4, NFR-6HC8).
    uint128 internal payoutNumeratorYes;
    uint128 internal payoutNumeratorNo;

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

    uint256 private constant SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @dev ERC-1271's success value: `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
    ///      Also the interface's own ERC-165 id, since it declares exactly one function.
    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev The single value every refusal returns (NFR-C0E4). A distinct constant rather
    ///      than bytes4(0), so a caller can tell a refusal from an empty return.
    bytes4 private constant ERC1271_INVALID_SIGNATURE = 0xffffffff;

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

    /// @dev The unit of the USDC principal total and of the scaled USDC claim: one USDC unit per
    ///      token per level at price 1.00. The one place the PRICE_TICK_ONE cast is written.
    ///      casting to uint256 is safe because PRICE_TICK_ONE is the positive constant 10,000
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 internal constant USDC_CLAIM_SCALE = uint256(int256(PRICE_TICK_ONE)) * LIQUIDITY_PRECISION;

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
    error MarketNotResolved();
    error VaultStillActive();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    // SC-JGEF: emitted when Oracle transitions vault from Active to WindDown
    event VaultWindDownStarted(bytes32 indexed marketId);

    // SC-JXQX: emitted when any address freezes the vault after the silence timelock
    event EmergencyCancelExecuted(address indexed caller);

    // SC-TVS2 through SC-TVS4: emitted on every successful tick update
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    // SC-6HC9, SC-BMF1: emitted when pairs merge into USDC, by the public call and by a burn
    // that merged first; never on a zero merge
    event CompleteSetsMerged(address indexed caller, uint256 amount);

    // SC-6HCD, SC-6HCE, SC-6HCH, SC-6HCI, SC-CYSC: emitted when the vault's tokens redeem into
    // USDC, by the Oracle's call and by a burn after the switch that found a token to redeem;
    // caller is msg.sender, as in CompleteSetsMerged; never when both balances were zero
    event OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount);

    // SC-7G43 through SC-7G45, SC-BMF1 through SC-BMF3, SC-7G4C through SC-7G4E: emitted by both
    // burn paths. usdcOwed is the claim's USDC leg, usdcPaid the prorated usdcOwed, tokenId the
    // YES or NO id of the band (zero when the band is empty), tokenOwed the band's tokens. Before the switch tokenPaid is the tokens transferred
    // and usdcPaid the one USDC transfer; after the switch (SC-CYS7 through SC-CYS9) tokenPaid is
    // the USDC paid for the token leg and the one USDC transfer carries usdcPaid + tokenPaid. A
    // reader knows the mode from payoutNumerators(). An indexer sees a shortfall as paid < owed
    // (decision O2).
    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
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

    /// @dev The three role modifiers and nonReentrant call an internal function that holds the
    ///      old modifier body, the OpenZeppelin Ownable._checkOwner and
    ///      ReentrancyGuard._nonReentrantBefore shape, because the compiler copies a modifier's
    ///      body into every function that uses it and the four together are used 38 times:
    ///      the move recovers about 1,800 bytes of contract size at about 50 gas per guarded
    ///      call and no behavior change (ADR-CYSE in FEAT-J92H). The modifier stays the only
    ///      gate; no function calls a _check*() directly (CLAUDE.md checklist item 2).
    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    modifier onlyOracle() {
        _checkOracle();
        _;
    }

    function _checkAdmin() internal view {
        if (ILPVaultFactory(factory).admins(msg.sender) != 1) revert NotAdmin();
    }

    function _checkOperator() internal view {
        if (ILPVaultFactory(factory).operators(msg.sender) != 1) revert NotOperator();
    }

    function _checkOracle() internal view {
        if (msg.sender != ILPVaultFactory(factory).oracle()) revert NotOracle();
    }

    /// @dev Gates the ERC-1155 receiver hooks. Inside a receiver hook msg.sender is the
    ///      token contract itself, so comparing it to `conditionalTokens` pins the vault
    ///      to its own market's ERC-1155 and rejects every other token contract.
    modifier onlyConditionalTokens() {
        if (msg.sender != conditionalTokens) revert NotConditionalTokens();
        _;
    }

    /// @dev Gates trading entry points while the vault is paused. LP exit paths (burnPosition,
    ///      burnPositionFor, reclaimDeposit, reclaimDepositFor) and mergeCompleteSets are NOT
    ///      gated.
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

    /// @dev Inlined reentrancy guard. _reentrancyGuard is set to 1 in initialize(). The two
    ///      halves live in internal functions for contract size (ADR-CYSE), as above.
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() internal {
        if (_reentrancyGuard != 1) revert Reentrancy();
        _reentrancyGuard = 2;
    }

    function _nonReentrantAfter() internal {
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
    ///      The check is inline, not a modifier: `factory` is not yet stored when a clone
    ///      is initialized, so a modifier that read it would compare against the zero
    ///      address (CLAUDE.md checklist item 7). Role state (operators, oracle, admins) is NOT copied from the factory.
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

        // Store factory address for auth delegation
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
    /// @dev Stateless by design. The vault's position, tick, and ledger accounting is driven
    ///      by mintPositionFor, burnPosition, and updateTick — never by observing an inbound
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
    // SC-C0DT: EIP-1271 reporting so an integrator routes to the POLY_1271 signature type
    /// @notice Reports whether the vault implements a given interface.
    /// @param interfaceId The ERC-165 interface identifier to query.
    /// @return True for IERC1155Receiver (0x4e2312e0), ERC-165 itself (0x01ffc9a7), and
    ///         EIP-1271 (0x1626ba7e). False for everything else, including 0xffffffff.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // The EIP-1271 id is its own magic value: the interface declares a single function,
        // so its ERC-165 id is that function's selector (FR-C0DZ, FR-3WLK).
        return interfaceId == 0x4e2312e0 || interfaceId == 0x01ffc9a7 || interfaceId == ERC1271_MAGIC_VALUE;
    }

    // ──────────────────────────────────────────────
    // Order authorization (FEAT-C0DJ, UC-C0DK)
    // ──────────────────────────────────────────────

    // SC-C0DM through SC-C0DR, SC-CVPZ, SC-CVQ0, SC-CVQ1: the vault vouches to the exchange for an
    // Operator-signed order, only while it trades
    /// @notice Reports whether the vault stands behind `signature` over `hash` (EIP-1271).
    /// @dev OPERATOR TRUST ASSUMPTION: any registered Operator can author orders that spend
    ///      this vault's assets through the exchange. The vault checks WHO signed, never WHAT
    ///      was signed: there is no cap on size, no price band, no side restriction, and no
    ///      per-market policy, so the Operator's order sizes and prices are trusted. LPs are
    ///      trusting Operators not to sign orders that trade against their interest. This does
    ///      not widen the blast radius: the exchange already holds the USDC and ERC-1155
    ///      approvals over this vault that initialize() granted (CLAUDE.md checklist item 11),
    ///      and this function is what makes those approvals reachable (NFR-C0E5).
    ///
    ///      MEV analysis: a view that moves no value and records nothing, so there is no
    ///      ordering advantage to extract from calling it. The recovered signer is the
    ///      authority over whose order it is; the caller check below bounds where the vouch
    ///      can be consumed.
    ///
    ///      Never reverts (FR-C0DW, ADR-C0E7). Every refusal returns ERC1271_INVALID_SIGNATURE,
    ///      because the exchange distinguishes a revert from a wrong return value and callers
    ///      probe this method speculatively. That is also why the caller and pause checks are
    ///      inline rather than modifiers: a modifier reverts where this method must return
    ///      (a recorded departure from the modifiers-only rule, CLAUDE.md checklist item 2).
    ///
    ///      Answers the exchange only (FR-CVPY, ADR-CVQ2): USDC's FiatTokenV2_2 routes a bytes
    ///      signature in permit and transferWithAuthorization to the payer's isValidSignature
    ///      (ERC-7598), so an open vouch would let an Operator key move vault USDC around the
    ///      exchange. Answers only while the vault is Active and not paused (FR-CVPX, decision
    ///      C22, ADR-BZBZ in FEAT-JXQO): a frozen, wound-down, or paused vault takes no new
    ///      fill while its claims are paid at a fixed tick. A resting order posted before the
    ///      transition fails its signature check at match time; the keeper cancels its orders
    ///      when it sees EmergencyCancelExecuted, VaultWindDownStarted, or TradingPaused.
    ///
    ///      No nonce, no intentId, no order record (NFR-C0E1, ADR-C0E8). That breaks the
    ///      replay-protection convention every LP-facing path in this vault follows, and the
    ///      break is deliberate: order hashing, fill accounting, and cancellation live in the
    ///      exchange's _performOrderChecks, and a second ledger here could only duplicate that
    ///      or drift from it.
    ///
    ///      Not an Operator function: the exchange calls it during _validateOrder, so it carries
    ///      neither onlyOperator nor touchesHeartbeat.
    /// @param hash The digest the signature was produced over: the exchange's hashOrder(order)
    /// @param signature 65-byte ECDSA signature from a registered Operator's key
    /// @return ERC1271_MAGIC_VALUE if the vault vouches, ERC1271_INVALID_SIGNATURE otherwise
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        // Only a matched order on the exchange may consume the vouch (FR-CVPY).
        if (msg.sender != exchange) return ERC1271_INVALID_SIGNATURE;

        // Only a vault that trades vouches (FR-CVPX). Checked before the recovery, so a
        // paused or non-Active vault pays no ecrecover.
        if (phase != 1 || paused) return ERC1271_INVALID_SIGNATURE;

        address signer = _recoverSigner(hash, signature);

        // The zero address is _recoverSigner's failure sentinel, so it is excluded before
        // the registry read rather than trusted to be absent from it (FR-C0DV).
        if (signer == address(0)) return ERC1271_INVALID_SIGNATURE;

        // Read at call time, never captured at signing time (FR-C0DY). This is the whole
        // of the revocation mechanism: one removeOperator invalidates every unfilled
        // order that key ever signed, with no per-order revocation list to maintain.
        if (ILPVaultFactory(factory).operators(signer) != 1) return ERC1271_INVALID_SIGNATURE;

        return ERC1271_MAGIC_VALUE;
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
    ///      back to Active. Once in WindDown, depositForIntent, mintPositionFor, and updateTick
    ///      revert (phase guard at the top of each), while burnPosition, burnPositionFor,
    ///      reclaimDeposit, reclaimDepositFor, mergeCompleteSets, and redeemOutcomeTokens remain
    ///      callable so LPs can exit. The Oracle calls this first and
    ///      redeemOutcomeTokens after the result is reported, because the redemption reverts
    ///      while the vault is Active (ADR-6HCK in FEAT-6HBN).
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

    // SC-JXQX, SC-JXQY, SC-BZBW, SC-BZBX, SC-JXR1: any address freezes the vault after the timelock
    /// @notice Freezes the vault after the Operator has been silent for the vault's emergency-cancel
    ///         timelock: sets the phase to Cancelled and changes nothing else.
    /// @dev Any address may call it, because the freeze moves no funds and the timelock is the whole
    ///      condition (audit-solutions.md Finding 4, decision C9, ADR-BZBY). It keeps activeLiquidity,
    ///      every tick, every position, and every total: an in-range burn subtracts from
    ///      activeLiquidity with checked arithmetic, and the exits value each claim from the records.
    ///      No nonReentrant, because the function makes no external call and moves no token
    ///      (CLAUDE.md checklist item 1), the same as startWindDown and pauseTrading.
    ///      After the freeze, burnPosition, burnPositionFor, reclaimDeposit, reclaimDepositFor,
    ///      and mergeCompleteSets work and pay what they pay in WindDown at the
    ///      same tick, so each LP exits in their own transaction and a USDC-blacklisted LP blocks
    ///      only their own exit (audit issue 6.17). The vault approves no new order after the
    ///      freeze, because the order maker accepts an order only while Active and not paused
    ///      (decision C22, ADR-BZBZ, built in R12 as FEAT-C0DJ). The ±15s Polygon tolerance is negligible at
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
    ///      mints. The reported tick before a mint also fixes which side of the solvency ledger
    ///      the position enters on: an in-range mint enters on the NO side of its mint tick
    ///      (FEAT-9BQZ).
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

        // Update tick state: liquidityGross tracks total references (and sets the bitmap bit on
        // the first one), liquidityNet tracks the directional delta applied when the tick is
        // crossed (FR-T7AV)
        _addTickReference(tickLower, liquidity);
        ticks[tickLower].liquidityNet += _toInt128(liquidity);
        _addTickReference(tickUpper, liquidity);
        ticks[tickUpper].liquidityNet -= _toInt128(liquidity);

        // The mint tick anchors the claim (decision C26). Outside the range it clamps to the
        // nearer bound, so every position minted on one side of its range holds the same mix and
        // can merge (FR-AFPO, ADR-AFPP).
        int24 mintTick = currentTick;
        if (mintTick < tickLower) mintTick = tickLower;
        else if (mintTick > tickUpper) mintTick = tickUpper;

        // Create the position record
        positionId = nextPositionId++;
        positions[positionId] =
            Position({owner: lp, tickLower: tickLower, tickUpper: tickUpper, mintTick: mintTick, liquidity: liquidity});

        // Update active liquidity if the position is in-range. An in-range mint has
        // mintTick == currentTick, so it enters on the NO side (FEAT-9BQZ FR-A2ZS).
        if (tickLower <= currentTick && currentTick < tickUpper) {
            activeLiquidity += liquidity;
            noSideLiquidity += liquidity;
        }

        // The ledger: a mint's claim is USDC only, because the clamped mint tick leaves the band
        // empty (FR-9BR8), and its NO sub-range is [mintTick, tickUpper) (ADR-COEW)
        // casting to uint256 is safe because PRICE_TICK_ONE is the positive constant 10,000
        // forge-lint: disable-next-line(unsafe-typecast)
        totalUsdcOwedScaled += uint256(liquidity) * rangeWidth * uint256(int256(PRICE_TICK_ONE));
        _addNoSubRange(tickLower, tickUpper, mintTick, liquidity);

        // No interaction: the USDC entered the vault at depositForIntent

        emit PositionMinted(positionId, lp, tickLower, tickUpper, mintTick, liquidity, usdcAmount, intentId);
    }

    // ──────────────────────────────────────────────
    // Position burn (FEAT-7G40, UC-7G41, UC-7G42)
    // ──────────────────────────────────────────────

    // SC-7G43 through SC-7G4B, SC-BMF1, SC-BMF2, SC-BMF3: the Safe closes a position it owns,
    // with no Operator involvement, in every phase
    /// @notice Closes a position the caller owns and pays what its claim holds: USDC for the
    ///         levels the price never crossed, one outcome token for the band between the mint
    ///         tick and the current tick, after merging the vault's pairs.
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
    ///
    ///      A burn is valued at the last reported tick (decision C8). A fill the keeper has not
    ///      reported yet has already spent the vault's USDC. The ledger's ratio spreads that
    ///      spend over every claim in proportion to its USDC owed, and a burn inside that
    ///      window takes its share as a final cut. The tokens the fill bought belong to no
    ///      claim after the report. They stay in the vault, and at the switch they redeem into
    ///      the USDC ratio. Before a self-service burn, compare totalYesOwed() and
    ///      totalNoOwed() with the vault's two token balances: a balance above the owed total
    ///      and above the free pairs can be an unreported fill. The Operator reports the tick
    ///      before it relays burnPositionFor, which closes this window on the relayed path
    ///      (finding CV-08 of audits/code-validation-round-1.md, and ADR-DYNK in FEAT-7G40).
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
    ///      key's BurnIntent (a struct with its own typehash, ADR-7G5H), cannot replay a mint
    ///      or reclaim signature, cannot redirect the payout (every asset goes to
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
    ///      struct instead of locals, because _burn reads seven values and emits a seven-field
    ///      event, and the compiler's sixteen-slot stack is the limit without via_ir.
    struct BurnAmounts {
        uint256 usdcOwed;
        uint256 usdcPaid;
        uint256 tokenId;
        uint256 tokenOwed;
        uint256 tokenPaid;
        // Both balances and the switch, read once: _settle merges the free pairs before the switch
        // and redeems both balances after it (FEAT-6HBN)
        uint256 yes;
        uint256 no;
        bool resolved;
        // The free pairs, min(yes - min(yes, totalYesOwed()), no - min(no, totalNoOwed())), read
        // before the ledger debit so this position's own band never counts as free (ADR-DFE2).
        // Zero after the switch, where the redemption replaces the merge and nothing reads it.
        uint256 pairs;
        // The same claim in the ledger's pre-division unit (FEAT-9BQZ FR-9BR9)
        uint256 usdcScaled;
        uint256 tokenScaled;
    }

    /// @dev One body for both burn entry points (FR-7G4L). Order, per NFR-7G59 and CLAUDE.md
    ///      checklist item 1: every read first (_burnAmounts), then every state write (the two
    ///      ticks, activeLiquidity, the ledger, the record), then the interactions. Before the
    ///      switch: the merge, the USDC transfer, and the ERC-1155 transfer as the final call,
    ///      because a Safe owner can replace the Safe's fallback handler and re-enter during that
    ///      transfer. After the switch: the redemption, then the one USDC transfer as the final
    ///      call, and no ERC-1155 transfer at all (FR-CYS4). By the first external call the
    ///      record is deleted, both ticks are updated, and the guard on every entry point that
    ///      moves an asset stops a re-entry. The one unguarded entry point, emergencyCancelAll,
    ///      writes only phase, and a re-entry into it is harmless because the burn's effects are
    ///      complete.
    function _burn(uint256 positionId, Position storage p) internal {
        // --- Reads and computation, all before any state is touched ---

        address owner = p.owner;
        int24 tickLower = p.tickLower;
        int24 tickUpper = p.tickUpper;
        int24 mintTick = p.mintTick;
        uint128 liquidity = p.liquidity;
        BurnAmounts memory a = _burnAmounts(p);

        // --- Effects ---

        // The NO sub-range leaves first, so a boundary tick that deinitializes below already
        // holds a zero noLiquidityNet (FR-7G4O, ADR-COEW)
        _removeNoSubRange(tickLower, tickUpper, mintTick, liquidity);

        // Exact inverse of the mint deltas (FR-7G4O); a tick at zero is deinitialized (FR-7G4P)
        _removeLiquidityFromTick(tickLower, liquidity, true);
        _removeLiquidityFromTick(tickUpper, liquidity, false);

        // Only an in-range position contributes to activeLiquidity (FR-7G4Q), and only one on
        // the NO side of its mint tick to noSideLiquidity
        int24 current = currentTick;
        if (tickLower <= current && current < tickUpper) {
            activeLiquidity -= liquidity;
            if (mintTick <= current) noSideLiquidity -= liquidity;
        }

        // The ledger: debit the full scaled claim, whatever the burn pays, so every later
        // claimant meets the same ratio (FR-9BR9); an LP exit never reverts on a ledger write
        // (NFR-9BRT)
        totalUsdcOwedScaled = _saturatingSub(totalUsdcOwedScaled, a.usdcScaled);
        if (a.tokenId == yesTokenId) {
            totalYesOwedScaled = _saturatingSub(totalYesOwedScaled, a.tokenScaled);
        } else if (a.tokenId != 0) {
            totalNoOwedScaled = _saturatingSub(totalNoOwedScaled, a.tokenScaled);
        }

        // Delete the whole record (FR-7G4S). nextPositionId is untouched, so the id is retired,
        // never recycled (FR-7G4T): reuse would let a stale reference resolve to another LP's
        // position.
        delete positions[positionId];

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // The free pairs computed before the debit, or after the switch every token, become the
        // USDC that _usdcRatio already counted (decision C26, FEAT-6HBN). Never a fresh read here:
        // after the debit the exiting position's own band would count as free (ADR-DFE2).
        _settle(a.pairs, a.yes, a.no, a.resolved);

        // One transfer covers the claim's USDC, and after the switch the token leg's USDC too
        // (FR-CYS4)
        uint256 usdcOut = a.resolved ? a.usdcPaid + a.tokenPaid : a.usdcPaid;
        if (usdcOut > 0) {
            _safeTransfer(usdc, owner, usdcOut);
        }

        // Before the switch, the one outcome token of the band, delivered as is: no order, no
        // conversion (FR-7G4N). Last, because the receiver hook hands control to the recipient.
        if (!a.resolved && a.tokenPaid > 0) {
            IConditionalTokens(conditionalTokens).safeTransferFrom(address(this), owner, a.tokenId, a.tokenPaid, "");
        }

        emit PositionBurned(positionId, owner, a.usdcOwed, a.usdcPaid, a.tokenId, a.tokenOwed, a.tokenPaid);
    }

    /// @dev The claim, both token balances, the switch, the free pairs, the USDC balance, the
    ///      ledger totals, and the two amounts to pay, from view reads only. The
    ///      amounts are computable before the settlement because the ConditionalTokens contract
    ///      pays exactly the free pairs computed here for a merge, and exactly balance x
    ///      numerator / denominator per side for a redemption, which _atPayout reproduces
    ///      (NFR-7G59). Pro-rata (decision O2, FR-COEX):
    ///      before the switch each owed amount times its asset's ratio, the smaller of 1 and held
    ///      over the ledger's total, rounded down, and never a revert; after the switch every leg
    ///      is USDC, so one ratio covers the principal and the token leg valued at the stored
    ///      payout, and the two are prorated as one sum (FR-CYS4, FR-CYS5). Two separately
    ///      capped USDC legs could sum to more than the vault holds after a saturated ledger
    ///      debit, and the one transfer would then revert, which decision C6 forbids; one prorate
    ///      of the sum keeps the cap, and paidSum >= usdcPaid always, because the floor of the
    ///      larger product is at least the floor of the smaller one under the same cap.
    function _burnAmounts(Position storage p) internal view returns (BurnAmounts memory a) {
        // One valuation for the payout and for the ledger debit: the scaled claim, truncated here
        (a.usdcScaled, a.tokenId, a.tokenScaled) = _claim(p.tickLower, p.tickUpper, p.mintTick, p.liquidity);
        a.usdcOwed = a.usdcScaled / USDC_CLAIM_SCALE;
        a.tokenOwed = a.tokenScaled / LIQUIDITY_PRECISION;

        (a.yes, a.no) = _tokenBalances();
        a.resolved = _resolved();
        bool isYes = a.tokenId == yesTokenId;

        // The free pairs, once, before any effect (FR-9BRM to FR-9BRO, ADR-DFE2); after the
        // switch the redemption replaces the merge and no pair is counted
        if (!a.resolved) a.pairs = _freePairs(a.yes, a.no);

        // The USDC ratio: escrow stays out (FR-9BRM), and after the switch the token totals join
        // it at the stored payout (FR-CYS5). The USDC leg is prorated once, for both modes.
        (uint256 held, uint256 total) = _usdcRatio(a.pairs, a.yes, a.no, a.resolved);
        a.usdcPaid = _prorate(a.usdcOwed, held, total);

        if (a.resolved) {
            // The token leg in USDC at the stored payout, then one prorate of the sum: tokenPaid
            // is the part of the sum the principal did not take (FR-CYS4)
            uint256 tokenUsdc = _atPayout(isYes ? a.tokenOwed : 0, isYes ? 0 : a.tokenOwed);
            uint256 paidSum = _prorate(a.usdcOwed + tokenUsdc, held, total);
            a.tokenPaid = paidSum - a.usdcPaid;
            return a;
        }

        // The merge consumes the free pairs of each token, so the band's token is what is left,
        // never below the smaller of the balance and the total; the band's ratio is independent
        // of the USDC ratio (FR-9BRN to FR-9BRQ)
        uint256 tokenHeld = (isYes ? a.yes : a.no) - a.pairs;
        a.tokenPaid = _prorate(a.tokenOwed, tokenHeld, isYes ? totalYesOwed() : totalNoOwed());
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
    ///      _mulDiv. The result is the claim in its pre-division unit: USDC scaled by
    ///      USDC_CLAIM_SCALE and tokens by LIQUIDITY_PRECISION. The solvency ledger sums it as is
    ///      (FEAT-9BQZ FR-9BR4), and _burnAmounts truncates it for the payout, rounding down
    ///      (decision C21), so the ledger and the payout never value a claim twice.
    ///      A clamped mint tick (FR-AFPO) needs no special case: a mint below its range has an
    ///      empty YES side, and a mint above it has an empty NO side, which the band == 0 check
    ///      catches before the sum, where a + m - 1 would underflow at a = m = 0.
    /// @return usdcScaled The USDC of the unfilled levels plus the unspent part of the band, x USDC_CLAIM_SCALE
    /// @return tokenId yesTokenId below the mint tick, noTokenId above it, zero when the band is empty
    /// @return tokenScaled One token per unit of liquidity per tick of the band, x LIQUIDITY_PRECISION
    function _claim(int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity)
        internal
        view
        returns (uint256 usdcScaled, uint256 tokenId, uint256 tokenScaled)
    {
        int24 current = currentTick;
        uint256 l = liquidity;
        // casting to uint256 is safe because tickUpper > tickLower is validated at the mint
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 width = uint256(int256(tickUpper - tickLower));
        uint256 one = USDC_CLAIM_SCALE / LIQUIDITY_PRECISION;

        if (current < mintTick) {
            // The YES band [a, m): the levels the price fell through
            int24 a = current < tickLower ? tickLower : current;
            // casting to uint256 is safe because a <= mintTick, and both lie inside [0, 10000]
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 band = uint256(int256(mintTick - a));
            if (band > 0) {
                tokenId = yesTokenId;
                tokenScaled = l * band;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 sumTicks = band * uint256(int256(a) + int256(mintTick) - 1) / 2;
                usdcScaled = l * (width * one - sumTicks);
                return (usdcScaled, tokenId, tokenScaled);
            }
        } else if (current > mintTick) {
            // The NO band [m, b): the levels the price rose through
            int24 b = current > tickUpper ? tickUpper : current;
            // casting to uint256 is safe because b >= mintTick, and both lie inside [0, 10000]
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 band = uint256(int256(b - mintTick));
            if (band > 0) {
                tokenId = noTokenId;
                tokenScaled = l * band;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 sumTicks = band * uint256(int256(mintTick) + int256(b) - 1) / 2;
                usdcScaled = l * ((width - band) * one + sumTicks);
                return (usdcScaled, tokenId, tokenScaled);
            }
        }

        // The price sits at the mint tick, or the clamped side is empty: every level is USDC
        usdcScaled = l * width * one;
    }

    /// @dev The USDC a payout may draw on, the USDC ratio's numerator (decisions C6 and C7,
    ///      FEAT-9BQZ FR-9BRM, FR-CYS5): the balance plus `incoming`, the USDC the settlement is
    ///      about to produce (the free pairs before the switch, the redeemed value after it), less the
    ///      escrow total, floored at zero. On chain a fill turns vault USDC into tokens (decision
    ///      C8), so the balance can sit below totalEscrowed, and a checked subtraction would
    ///      revert every exit.
    function _availableUsdc(uint256 incoming) internal view returns (uint256) {
        uint256 held = IERC20(usdc).balanceOf(address(this)) + incoming;
        uint256 escrowed = totalEscrowed;
        return held > escrowed ? held - escrowed : 0;
    }

    /// @dev The two sides of the USDC ratio, read before the debit, for the burn (FEAT-9BQZ). Before the switch: what the vault holds above escrow counting `pairs`,
    ///      the free pairs the caller computed from _freePairs before any effect, over the
    ///      principal it owes (FR-9BRM). After the switch every asset is USDC: the
    ///      numerator adds what the vault's YES and NO redeem for at the stored payout, and the
    ///      denominator adds what the YES and NO totals redeem for, so one ratio covers every leg
    ///      (FR-CYS5), and `pairs` is not read. The totals themselves stay per asset (ADR-9BSJ).
    function _usdcRatio(uint256 pairs, uint256 yes, uint256 no, bool resolved)
        internal
        view
        returns (uint256 held, uint256 total)
    {
        total = totalUsdcOwed();
        if (resolved) {
            held = _availableUsdc(_atPayout(yes, no));
            total += _atPayout(totalYesOwed(), totalNoOwed());
        } else {
            held = _availableUsdc(pairs);
        }
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

        if (isLower) {
            info.liquidityNet -= _toInt128(liquidity);
        } else {
            info.liquidityNet += _toInt128(liquidity);
        }

        _removeTickReference(tick, liquidity);
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
    ///      Escrow seniority (decision C7) binds burns, which read the balance less
    ///      totalEscrowed, and not fills: the exchange holds an unlimited USDC allowance from
    ///      initialize(), so a fill can spend escrowed USDC. The refund therefore merges the
    ///      vault's free pairs before it transfers (FR-DU2U, ADR-DU2V), so a reclaim never waits
    ///      for a keeper to merge; the keeper keeps its quoted size below the vault's USDC
    ///      balance minus totalEscrowed (finding CV-06 of audits/code-validation-round-1.md).
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
    ///      Escrow seniority (decision C7) binds burns and not fills, because the
    ///      exchange's unlimited USDC allowance can spend escrowed USDC; the shared refund
    ///      merges the vault's free pairs before it transfers (FR-DU2U, ADR-DU2V), so this
    ///      path never waits for a keeper to merge either.
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
    ///      Merges the vault's free pairs first (FR-DU2U, ADR-DU2V), the same _freePairs and
    ///      _mergeCompleteSets every payout runs (FEAT-6HBN ADR-DFE2), because a fill can spend
    ///      escrowed USDC through the exchange's allowance and the refund must not wait for a
    ///      keeper to merge (finding CV-06). The pairs are read before the effects, as in every
    ///      payout; a reclaim changes no owed total, so the number is the same either way. The
    ///      amount paid is the recorded amount, whatever the merge produced.
    function _refundEscrow(bytes32 intentId, PendingDeposit memory escrow) internal {
        // --- Reads ---

        (uint256 yes, uint256 no) = _tokenBalances();
        uint256 pairs = _freePairs(yes, no);

        // --- Effects ---

        usedIntents[intentId] = true;
        delete pendingDeposits[intentId];
        totalEscrowed -= escrow.amount;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        _mergeCompleteSets(pairs);
        _safeTransfer(usdc, escrow.lp, escrow.amount);
        emit DepositReclaimed(intentId, escrow.lp, escrow.amount);
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
    ///      itself (ADR-9J43 in FEAT-TVS0).
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
    ///      or compromised Operator could report a false tick, which misvalues every claim's
    ///      split between USDC and tokens and misclassifies which positions are in range. This
    ///      matches the ProphetCTFExchange trust model.
    ///      Crosses every initialized tick between currentTick and newTick, applying
    ///      liquidityNet to activeLiquidity.
    ///      A call with the current tick refreshes only the heartbeat and returns; while
    ///      the vault is paused or wound down the keeper calls `heartbeat()` instead.
    ///      The bitmap search reads only the words between currentTick and newTick
    ///      (FR-5IDE, ADR-5IDK), so the cost of a call follows the reported move and not
    ///      where any LP initialized a tick. A large jump across empty words still reads one
    ///      word per 256 ticks, so the Operator chunks a very large jump as it chunks
    ///      crossings (ADR-TVUW).
    ///      A reported tick also moves the three totals of the solvency ledger (FEAT-9BQZ,
    ///      UC-9BR1) for every segment the move traverses, with the liquidity split as it stood
    ///      in that segment, and an interior mint tick is crossed like a boundary (ADR-COEW), so
    ///      those totals set every payout's ratio.
    ///
    ///      MEV analysis: the ratio denominators move with the reported tick, which the Operator
    ///      already controls under the trust assumption above. No third party can order a move
    ///      around a payout, because every payout reads the totals in the same transaction it
    ///      pays, and the move itself places no order and moves no token.
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
        // The ledger shift, accrued per segment with the split as it stood during that segment
        // and written once (FR-9BRI to FR-9BRL). segmentEdge is the segment's start when moving
        // up and its end when moving down.
        Shift memory shift;
        int24 segmentEdge = oldTick;

        if (movingRight) {
            // Cross every initialized tick in (oldTick, newTick]
            while (tick < newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, true, newTick);
                if (!found || next > newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                // The segment that ends at the tick, with the split before the crossing (FR-9BRI)
                _accrueSegment(shift, segmentEdge, next, true);
                _crossTick(next, true);
                segmentEdge = next;
                tick = next;
            }
            // The trailing segment, or the whole move when nothing was crossed (FR-9BRJ, FR-9BRK)
            _accrueSegment(shift, segmentEdge, newTick, true);
        } else {
            // Cross every initialized tick in (newTick, oldTick]
            while (tick > newTick) {
                (int24 next, bool found) = _nextInitializedTick(tick, false, newTick);
                if (!found || next <= newTick) break;

                crossCount++;
                if (crossCount > MAX_TICK_CROSSINGS) revert TooManyTicksCrossed();
                // The segment that starts at the tick, with the split before the crossing (FR-9BRI)
                _accrueSegment(shift, next, segmentEdge, false);
                _crossTick(next, false);
                segmentEdge = next;
                tick = next - 1;
            }
            _accrueSegment(shift, newTick, segmentEdge, false);
        }

        _applyShift(shift);
        currentTick = newTick;

        emit TickUpdated(oldTick, newTick, crossCount);
    }

    // ──────────────────────────────────────────────
    // Position merge (FEAT-K1M2, UC-K1M8)
    // ──────────────────────────────────────────────

    // SC-K1M9, SC-K1MA, SC-K1MB: operator-gated position merge
    /// @notice Combines two or more positions with identical owner, tickLower, tickUpper,
    ///         and mintTick into a single survivor position (positionIds[0]), preserving
    ///         total liquidity. This joins LP position records;
    ///         it is not the complete-set merge of outcome tokens into USDC.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can merge any positions that share
    ///      the same owner, range, and mint tick, and it can name each position only once:
    ///      a repeated ID reverts DuplicatePositionId (audit issue 6.14), and a different
    ///      mint tick reverts MintTickMismatch, because the mint tick is part of what a
    ///      claim holds under decision C26. LPs must trust that the Operator only merges
    ///      positions for legitimate housekeeping (reducing storage and gas costs for
    ///      overlapping positions).
    ///      No USDC moves during merge. Tick state (liquidityGross, liquidityNet,
    ///      noLiquidityNet) is unchanged since total liquidity on the range and on the NO
    ///      sub-range stays the same. The merge writes no total of the solvency ledger
    ///      (FEAT-9BQZ FR-9BRH): the claim is linear in liquidity and every merged position
    ///      shares the range and the mint tick.
    ///      A burned record never merges: the survivor's and every consumed record's owner is
    ///      checked before any liquidity is read, because a deleted record reads owner zero,
    ///      range [0, 0), and mint tick 0, so two of them would pass every equality check
    ///      against each other (FR-DU2X, finding CV-03 of audits/code-validation-round-1.md).
    ///
    ///      MEV analysis: the merge moves no asset, reads no price, and writes no ledger total,
    ///      and the Operator controls the timing, so no ordering of this call against a mint,
    ///      a burn, or a tick report changes what any claimant is owed (CLAUDE.md checklist
    ///      item 13).
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

        // SC-DU2W, FR-DU2X: a burned record reads owner zero and would pass every equality
        // check against another burned record (finding CV-03)
        if (ownerAddr == address(0)) revert PositionNotFound();

        int24 tickLower = survivor.tickLower;
        int24 tickUpper = survivor.tickUpper;
        int24 mintTick = survivor.mintTick;

        // Start accumulation from the survivor's current state
        uint128 totalLiquidity = survivor.liquidity;

        // Process each consumed position: validate, accumulate, then zero
        for (uint256 i = 1; i < positionIds.length; i++) {
            Position storage consumed = positions[positionIds[i]];

            // SC-DU2W, FR-DU2X: a burned record never merges (finding CV-03)
            if (consumed.owner == address(0)) revert PositionNotFound();

            // All positions must share the same owner and tick range
            if (consumed.owner != ownerAddr || consumed.tickLower != tickLower || consumed.tickUpper != tickUpper) {
                revert RangeMismatch();
            }
            // SC-AFPR, FR-AFPT: two mint ticks hold two asset mixes under the claim model (C26)
            if (consumed.mintTick != mintTick) revert MintTickMismatch();

            // Accumulate liquidity
            totalLiquidity += consumed.liquidity;

            // Zero the consumed position so it can no longer claim
            consumed.liquidity = 0;
        }

        // Update the survivor with the accumulated liquidity
        survivor.liquidity = totalLiquidity;

        emit PositionsMerged(positionIds, positionIds[0]);
    }

    // ──────────────────────────────────────────────
    // Complete-set merge (FEAT-6HBN, UC-6HBO)
    // ──────────────────────────────────────────────

    // SC-6HC9, SC-6HCA, SC-6HCB, SC-6HCC, SC-DFDV, SC-DFDW: permissionless merge of the free pairs
    /// @notice Merges the vault's free pairs, the complete sets above what the ledger owes in
    ///         both tokens, into USDC held by the vault. Any wallet may call it, in every phase.
    /// @dev No role check, no pause check, no phase check, and no heartbeat refresh (ADR-6HCJ,
    ///      ADR-6HCL, ADR-6HCM): a refresh from any wallet would let anyone postpone
    ///      emergencyCancelAll, and a frozen vault's payouts still need the merge first
    ///      (decision C9).
    ///      MEV analysis: the merge takes only pairs no claim is owed (ADR-DFE2), so it changes
    ///      no claim's token leg and no claim's ratio: a free pair is worth exactly 1 USDC to the
    ///      vault before and after. The caller receives nothing, and front-running, back-running,
    ///      or repeating the call changes no one's position. A wallet that sends the
    ///      complementary token cannot force a merge of another claim's token (finding CV-01 of
    ///      audits/code-validation-round-1.md). Keeper rule: anyone can merge at any time, so
    ///      every order that names the vault as maker must be a BUY order, and no resting order
    ///      may depend on the vault's YES or NO balance.
    function mergeCompleteSets() external nonReentrant {
        (uint256 yes, uint256 no) = _tokenBalances();
        _mergeCompleteSets(_freePairs(yes, no));
    }

    /// @dev The free pairs the vault holds: min(yes - min(yes, totalYesOwed()), no - min(no,
    ///      totalNoOwed())), the complete sets above what the ledger owes in both tokens
    ///      (ADR-DFE2). One definition, because the public merge, the ratio, the burn, and the
    ///      settlement all need the same number. A payout calls it before its ledger debit, so
    ///      the exiting position's own band is never counted as free (finding CV-01). Under
    ///      drift-free fills the free pairs are exactly the round-trip pairs; under drift a pair
    ///      below the owed totals stays unmerged and is paid in kind at each token's ratio. The
    ///      zero-balance guard is correct because a free count is at most the balance, so a zero
    ///      balance on either side gives zero free pairs; it exists so the public merge and the
    ///      escrow refund skip the two ledger reads when either balance is zero.
    function _freePairs(uint256 yes, uint256 no) internal view returns (uint256) {
        if (yes == 0 || no == 0) return 0;
        uint256 yesOwed = totalYesOwed();
        uint256 noOwed = totalNoOwed();
        uint256 freeYes = yes > yesOwed ? yes - yesOwed : 0;
        uint256 freeNo = no > noOwed ? no - noOwed : 0;
        return freeYes < freeNo ? freeYes : freeNo;
    }

    /// @dev The settlement every payout runs as its first interaction: the merge of `pairs`, the
    ///      free pairs the caller computed before its ledger debit, before the switch, and the
    ///      redemption of every token after it (FEAT-6HBN ADR-6HCK), so a token that arrived late
    ///      never strands. Never a read of the free pairs here: _burn calls this after the
    ///      debit, where the exiting position's own band would count as free, and the transfer
    ///      the burn computed would then revert (ADR-DFE2). Both branches return without a call
    ///      when there is nothing to settle.
    function _settle(uint256 pairs, uint256 yes, uint256 no, bool resolved) internal {
        if (resolved) {
            _redeemOutcomeTokens(yes, no);
        } else {
            _mergeCompleteSets(pairs);
        }
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
    ///      can run it unconditionally (FR-6HC0). The caller passes the free pairs from
    ///      _freePairs. No modifier: _burn and _refundEscrow call it inside their guarded entry
    ///      points, as their first interaction. A zero-amount mergePositions would not revert,
    ///      but it costs gas and emits an event.
    function _mergeCompleteSets(uint256 amount) internal {
        if (amount == 0) return;

        IConditionalTokens(conditionalTokens).mergePositions(usdc, bytes32(0), conditionId, _binaryPartition(), amount);
        emit CompleteSetsMerged(msg.sender, amount);
    }

    /// @dev The partition [1, 2]: index set 1 is YES and index set 2 is NO. The merge and the
    ///      redemption both pass it, so it lives in one place.
    function _binaryPartition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }

    // ──────────────────────────────────────────────
    // Outcome-token redemption (FEAT-6HBN, UC-6HBP)
    // ──────────────────────────────────────────────

    // SC-6HCD through SC-6HCI, SC-CYS6: the Oracle redeems the vault's tokens after the market
    // resolves, and that call is the switch
    /// @notice Redeems the vault's whole YES and NO balances through the ConditionalTokens contract
    ///         into USDC held by the vault, after the result of the vault's condition is reported.
    ///         The first successful call copies the payout into the vault, and every later burn
    ///         pays its token leg in USDC at that payout (the switch, ADR-6HCK).
    /// @dev Oracle-only, because the switch changes the ratio shape for every LP. Reverts while
    ///      the vault is Active (FR-6HC7): updateTick and mintPositionFor revert in WindDown and
    ///      Cancelled, so once the switch is on no tick report can move value between claims that
    ///      are now fixed USDC, and no mint can open a claim against a resolved market. Works in
    ///      WindDown and Cancelled, paused or not, and runs again for tokens that arrive later. It
    ///      changes no phase and refreshes no heartbeat. It does not merge first: redeemPositions
    ///      with [1, 2] burns both balances at their payout. A numerator above uint128 reverts
    ///      SafeCastOverflow and leaves the switch off (FR-CYS2), a state every exit works in.
    ///      ORACLE TRUST ASSUMPTION: The Oracle can delay the switch. It cannot set the payout,
    ///      which the vault reads from the ConditionalTokens contract inside this call and never
    ///      from an argument, and it cannot direct the USDC anywhere except the vault, because the
    ///      ConditionalTokens contract pays its caller and the caller is the vault. Before the
    ///      switch an exit pays the winning token in kind, and the LP redeems it at the
    ///      ConditionalTokens contract from the Safe for the same USDC, so no LP waits on the
    ///      Oracle.
    ///
    ///      MEV analysis: the call moves value between nobody; the ConditionalTokens contract pays
    ///      the vault exactly what its tokens are worth. The switch changes the ratio shape from
    ///      three per-asset ratios to one USDC ratio, and the LP chooses the burn moment on both
    ///      sides of it, so no third party can order this call around an exit to gain.
    function redeemOutcomeTokens() external onlyOracle nonReentrant {
        // --- Checks ---

        if (phase == 1) revert VaultStillActive();

        IConditionalTokens ctf = IConditionalTokens(conditionalTokens);
        bytes32 condition = conditionId;

        // The ConditionalTokens contract is the only source of the result (FR-6HC5)
        if (ctf.payoutDenominator(condition) == 0) revert MarketNotResolved();

        // --- Effects ---

        // The switch: written once, from the contract, on the first successful call (FR-6HC4)
        if (!_resolved()) {
            payoutNumeratorYes = _toUint128(ctf.payoutNumerators(condition, 0));
            payoutNumeratorNo = _toUint128(ctf.payoutNumerators(condition, 1));
        }

        // --- Interactions ---

        (uint256 yes, uint256 no) = _tokenBalances();
        _redeemOutcomeTokens(yes, no);
    }

    /// @notice The stored payout: `(0, 0)` until the Oracle's first successful redemption, then
    ///         the two numerators the ConditionalTokens contract reported. The denominator is
    ///         their sum. A non-zero pair means the switch is on.
    function payoutNumerators() external view returns (uint128 numYes, uint128 numNo) {
        return (payoutNumeratorYes, payoutNumeratorNo);
    }

    /// @dev Redeems both balances, and returns without a call when both are zero, so a payout
    ///      can run it unconditionally (FR-6HC7). The caller passes the balances from
    ///      _tokenBalances. No modifier: redeemOutcomeTokens and _burn call it inside their
    ///      guarded entry points, as their first interaction. The event's usdcAmount is
    ///      what redeemPositions pays, reproduced by _atPayout, so no balance read follows the call.
    function _redeemOutcomeTokens(uint256 yes, uint256 no) internal {
        if (yes == 0 && no == 0) return;

        IConditionalTokens(conditionalTokens).redeemPositions(usdc, bytes32(0), conditionId, _binaryPartition());
        emit OutcomeTokensRedeemed(msg.sender, yes, no, _atPayout(yes, no));
    }

    /// @dev One definition of "the switch is on": the stored payout is non-zero. One storage
    ///      read, because both numerators share a slot.
    function _resolved() internal view returns (bool) {
        return (payoutNumeratorYes | payoutNumeratorNo) != 0;
    }

    /// @dev The USDC that `yesAmount` YES and `noAmount` NO redeem for at the stored payout:
    ///      each side rounded down on its own, exactly as redeemPositions pays per index set.
    ///      Meaningful only after the switch (the denominator is zero before it). The products
    ///      go through _mulDiv, the CLAUDE.md product rule. One valuation for the ratio's
    ///      numerator and denominator, the burn's token leg, and the event's usdcAmount.
    function _atPayout(uint256 yesAmount, uint256 noAmount) internal view returns (uint256) {
        uint256 numYes = payoutNumeratorYes;
        uint256 numNo = payoutNumeratorNo;
        uint256 den = numYes + numNo;
        return _mulDiv(yesAmount, numYes, den) + _mulDiv(noAmount, numNo, den);
    }

    // ──────────────────────────────────────────────
    // Solvency ledger views and helpers (FEAT-9BQZ, UC-9BR0, UC-9BR2)
    // ──────────────────────────────────────────────

    // SC-9BS7, SC-COEO: the truncated totals, the monitoring surface (FR-9BR6) and the ratio
    // denominators (FR-9BRM to FR-9BRO)
    /// @notice The USDC principal the vault owes to every live position, in USDC units.
    function totalUsdcOwed() public view returns (uint256) {
        return totalUsdcOwedScaled / USDC_CLAIM_SCALE;
    }

    /// @notice The YES tokens the vault owes to every live position, in token units.
    function totalYesOwed() public view returns (uint256) {
        return totalYesOwedScaled / LIQUIDITY_PRECISION;
    }

    /// @notice The NO tokens the vault owes to every live position, in token units.
    function totalNoOwed() public view returns (uint256) {
        return totalNoOwedScaled / LIQUIDITY_PRECISION;
    }

    // SC-9BSC through SC-9BSG, SC-COEU: one ratio per asset, applied to every payout
    /// @dev owed x min(1, held / totalOwed), rounded down, and never above held (FR-9BRM to
    ///      FR-9BRR, NFR-9BRW). The denominators are the truncated getters read before the
    ///      debit: the sum of every per-position floor never exceeds the floor of the sum, so the
    ///      payouts never exceed what is held, and the final cap keeps decision C6 true even
    ///      against a ledger error. A zero total is a ratio of 1 with no division (FR-9BRP).
    function _prorate(uint256 owed, uint256 held, uint256 totalOwed) internal pure returns (uint256 paid) {
        if (owed == 0) return 0;
        paid = held < totalOwed ? _mulDiv(owed, held, totalOwed) : owed;
        if (paid > held) paid = held;
    }

    /// @dev A ledger debit that saturates at zero, for _burn only: an LP exit never
    ///      reverts on a ledger write (NFR-9BRT, ADR-COEN). The Operator paths use checked
    ///      arithmetic instead, so a ledger bug surfaces there.
    function _saturatingSub(uint256 total, uint256 amount) internal pure returns (uint256) {
        return amount < total ? total - amount : 0;
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
    ///      later relayed burn). Builds the EIP-712 digest, recovers the signer, and
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

        // _recoverSigner returns the zero address for every unusable signature, so the zero
        // check is what makes this fail closed. It is NOT redundant with the comparison: a
        // zero signer would otherwise derive a Safe address and be compared against `safe`.
        address signer = _recoverSigner(digest, signature);
        if (signer == address(0) || _deriveSafe(signer) != safe) revert InvalidSignature();
    }

    /// @dev Decodes a 65-byte signature and recovers the signer, or returns the zero address
    ///      when the signature is unusable for any reason: a length other than 65 bytes, an
    ///      `s` in the upper half of secp256k1's order, a `v` outside {27, 28}, or an
    ///      ecrecover that fails. One copy of the malleability rules (CLAUDE.md security
    ///      checklist item 5) for the LP signature path (FR-T7AZ, NFR-JAIX) and for the
    ///      order maker (FR-C0DX). Returns instead of reverting because isValidSignature
    ///      must never revert (FR-C0DW, ADR-C0E7), and a second copy of these rules is the
    ///      one place where a copy that later diverges is a security bug (ADR-C0YQ). Every
    ///      caller MUST reject address(0) explicitly.
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        // A length check before the decode is what keeps this total: reading r, s, and v
        // out of a shorter buffer would read past the end of calldata.
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // Reject malleable signatures: s must be in the lower half of secp256k1's order
        if (uint256(s) > SECP256K1N_HALF) return address(0);

        // v must be 27 or 28 — refused rather than normalized
        if (v != 27 && v != 28) return address(0);

        // ecrecover returns the zero address on failure, which is already the sentinel
        return ecrecover(digest, v, r, s);
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

    /// @dev Adds one position's liquidity to a tick's reference count, and sets the tick's bitmap
    ///      bit on the first reference so updateTick can locate it in O(1). One place for the rule
    ///      that a set bitmap bit means liquidity behind it (CLAUDE.md checklist item 10), for the
    ///      boundary ticks and for an interior mint tick alike (ADR-COEW); _removeTickReference is
    ///      its exact inverse.
    function _addTickReference(int24 tick, uint128 liquidity) internal {
        TickInfo storage info = ticks[tick];
        if (info.liquidityGross == 0) _setTickBitmapBit(tick);
        info.liquidityGross += liquidity;
    }

    /// @dev The exact inverse of _addTickReference: removes the liquidity and deinitializes the
    ///      tick when nothing references it any more (FR-7G4P, audit issue 6.15). Deleting the
    ///      record and clearing the bit together is what keeps the bitmap's meaning, or a later
    ///      updateTick would cross a tick with no liquidity behind it.
    function _removeTickReference(int24 tick, uint128 liquidity) internal {
        TickInfo storage info = ticks[tick];
        info.liquidityGross -= liquidity;
        if (info.liquidityGross == 0) {
            delete ticks[tick];
            _clearTickBitmapBit(tick);
        }
    }

    /// @dev Books a position's NO sub-range [mintTick, tickUpper) as a liquidityNet pair, the
    ///      way the range itself is booked, and makes an interior mint tick crossable by counting
    ///      the position's liquidity there (FEAT-9BQZ, ADR-COEW). The clamped mint tick
    ///      (ADR-AFPP) keeps the YES side [tickLower, mintTick) and the NO side a partition of
    ///      the range: a mint at its upper bound has no NO side, and a mint at its lower bound
    ///      needs no interior reference because the bound already holds one.
    function _addNoSubRange(int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity) internal {
        if (mintTick == tickUpper) return;
        int128 net = _toInt128(liquidity);
        ticks[mintTick].noLiquidityNet += net;
        ticks[tickUpper].noLiquidityNet -= net;
        if (mintTick != tickLower) _addTickReference(mintTick, liquidity);
    }

    /// @dev The exact inverse of _addNoSubRange. The nets leave before the reference, so a mint
    ///      tick that deinitializes already holds a zero noLiquidityNet.
    function _removeNoSubRange(int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity) internal {
        if (mintTick == tickUpper) return;
        int128 net = _toInt128(liquidity);
        ticks[mintTick].noLiquidityNet -= net;
        ticks[tickUpper].noLiquidityNet += net;
        if (mintTick != tickLower) _removeTickReference(mintTick, liquidity);
    }

    // ──────────────────────────────────────────────
    // Internal: tick crossing (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev Crosses an initialized tick: adjusts activeLiquidity by the tick's liquidityNet and
    ///      noSideLiquidity by its noLiquidityNet. The net signs depend on direction. A pure
    ///      mint tick has liquidityNet == 0, so only its noLiquidityNet moves (ADR-COEW).
    function _crossTick(int24 tick, bool ltr) internal {
        TickInfo storage info = ticks[tick];

        // Apply liquidityNet: positive when moving L-to-R, negated when R-to-L
        int128 liquidityDelta = ltr ? info.liquidityNet : -info.liquidityNet;
        activeLiquidity = _addDelta(activeLiquidity, liquidityDelta);

        // The NO sub-ranges cross the same way (FEAT-9BQZ FR-A2ZS)
        int128 noNet = info.noLiquidityNet;
        if (noNet != 0) noSideLiquidity = _addDelta(noSideLiquidity, ltr ? noNet : -noNet);
    }

    /// @dev The ledger shift of one tick move, in the totals' scaled units, accrued per segment
    ///      and written once by _applyShift (FEAT-9BQZ FR-9BRL).
    struct Shift {
        int256 usdc;
        int256 yes;
        int256 no;
    }

    /// @dev Accrues the shift of one segment of levels [from, to) under the claim model
    ///      (decision C26). With N = noSideLiquidity and Y = activeLiquidity - N, moving up
    ///      each NO-side level buys NO at 1 - t / ONE and each YES-side level's YES returns to
    ///      USDC through a pair worth 1, so NO += N x k, YES -= Y x k, and
    ///      USDC += Y x sum(t) - N x (k x ONE - sum(t)); moving down negates the three. A segment
    ///      with nothing in range is skipped, which also keeps every level inside a position's
    ///      range and so inside [0, 10000]. Every product stays under 2^155 (L < 2^128,
    ///      k x ONE < 2^27), so none needs _mulDiv, and k x (from + to - 1) is always even, so the
    ///      halving is exact.
    function _accrueSegment(Shift memory shift, int24 from, int24 to, bool up) internal view {
        uint256 active = activeLiquidity;
        if (active == 0 || from == to) return;
        uint256 no = noSideLiquidity;
        uint256 yes = active - no;
        // casting to uint256 is safe because active > 0 puts the segment inside a position's
        // range, and every range lies inside [0, 10000] (FR-T7B2)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 s = uint256(int256(from));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 e = uint256(int256(to));
        uint256 k = e - s;
        uint256 sumTicks = k * (s + e - 1) / 2;
        uint256 one = USDC_CLAIM_SCALE / LIQUIDITY_PRECISION;
        // casting to int256 is safe because every product is below 2^155
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 noDelta = int256(no * k);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 yesDelta = int256(yes * k);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 usdcDelta = int256(yes * sumTicks) - int256(no * (k * one - sumTicks));
        if (up) {
            shift.no += noDelta;
            shift.yes -= yesDelta;
            shift.usdc += usdcDelta;
        } else {
            shift.no -= noDelta;
            shift.yes += yesDelta;
            shift.usdc -= usdcDelta;
        }
    }

    /// @dev Writes each nonzero delta once. Checked arithmetic on purpose: a ledger bug on the
    ///      Operator's tick path reverts the report, the way _addDelta does, and never a payout
    ///      (NFR-9BRT, ADR-COEN).
    function _applyShift(Shift memory shift) internal {
        if (shift.usdc != 0) totalUsdcOwedScaled = _applySigned(totalUsdcOwedScaled, shift.usdc);
        if (shift.yes != 0) totalYesOwedScaled = _applySigned(totalYesOwedScaled, shift.yes);
        if (shift.no != 0) totalNoOwedScaled = _applySigned(totalNoOwedScaled, shift.no);
    }

    /// @dev total + delta with checked arithmetic in both directions.
    function _applySigned(uint256 total, int256 delta) internal pure returns (uint256) {
        // casting to uint256 is safe because the sign is checked on each branch
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta >= 0) return total + uint256(delta);
        // forge-lint: disable-next-line(unsafe-typecast)
        return total - uint256(-delta);
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
    ///      non-bool-returning tokens (USDT semantics). Used by the burn and the reclaim
    ///      to pay USDC.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ──────────────────────────────────────────────
    // Internal: overflow-safe mulDiv (inlined per pattern policy)
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
