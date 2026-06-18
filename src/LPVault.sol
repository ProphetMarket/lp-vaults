// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market
// UC-REQ0-001: deploy-factory-with-role-registry
// UC-REQ1-001: create-vault-and-initialize
// FEAT-T7AF: Mint LP Position
// UC-T7AG: Operator Mint Position for LP
// UC-T7AG-001: operator-mint-position

/// @dev Minimal ERC-20 interface — only approve needed for exchange setup.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC-1155 interface — only setApprovalForAll for exchange setup.
interface IERC1155 {
    function setApprovalForAll(address operator, bool approved) external;
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
    // Auth registry (inlined — see pattern policy in CLAUDE.md)
    // ──────────────────────────────────────────────

    /// @dev 1 = active admin
    mapping(address => uint256) public admins;

    /// @dev 1 = active operator
    mapping(address => uint256) public operators;

    /// @dev Always >= 1; cannot remove the last admin
    uint256 public adminCount;

    /// @dev Single oracle wallet; must never be an operator (role separation)
    address public oracle;

    /// @dev Two-step admin transfer target
    address public pendingAdmin;

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

    /// @dev Phase lifecycle: 1 = Active
    uint8 public phase;

    /// @dev Running total of liquidity in range
    uint128 public activeLiquidity;

    /// @dev Global fee accumulator (Q128 fixed-point)
    uint256 public feeGrowthGlobalX128;

    /// @dev Current tick for the vault's market price
    int24 public currentTick;

    /// @dev Counter for minting new positions
    uint256 public nextPositionId;

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
    // EIP-712 (inlined per pattern policy in CLAUDE.md)
    // ──────────────────────────────────────────────

    bytes32 public DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");

    uint256 private constant SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @dev Scaling factor for liquidity computation: L = usdcAmount * PRECISION / rangeWidth
    uint256 public constant LIQUIDITY_PRECISION = 1e18;

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

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

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
        if (admins[msg.sender] != 1) revert NotAdmin();
        _;
    }

    modifier onlyOperator() {
        if (operators[msg.sender] != 1) revert NotOperator();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotOracle();
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
    ///      Approval scope: setApprovalForAll(exchange, true) on the ConditionalTokens
    ///      is acceptable BECAUSE the vault holds outcome tokens for exactly one market —
    ///      token IDs for other markets cannot enter the vault (no entry point exists).
    /// @param marketId_ Unique market identifier from the CTF Exchange
    /// @param usdc_ USDC ERC-20 address
    /// @param exchange_ ProphetCTFExchange address
    /// @param conditionalTokens_ Gnosis ConditionalTokens (ERC-1155) address
    /// @param oracle_ Oracle wallet address (lifecycle control)
    /// @param tickSpacing_ Minimum tick increment for positions
    /// @param factory_ Factory contract address — must equal msg.sender
    /// @param minimumFirstLiquidity_ Floor for the first mint when activeLiquidity == 0
    function initialize(
        bytes32 marketId_,
        address usdc_,
        address exchange_,
        address conditionalTokens_,
        address oracle_,
        int24 tickSpacing_,
        address factory_,
        uint128 minimumFirstLiquidity_,
        address initialAdmin_,
        address initialOperator_
    ) external initializer {
        // Factory guard: caller must be the factory that deployed this clone
        if (msg.sender != factory_) revert NotFactory();

        // Store factory address for future onlyFactory checks
        factory = factory_;

        // Store per-vault configuration
        marketId = marketId_;
        usdc = usdc_;
        exchange = exchange_;
        conditionalTokens = conditionalTokens_;
        oracle = oracle_;
        tickSpacing = tickSpacing_;
        minimumFirstLiquidity = minimumFirstLiquidity_;

        // Copy initial role registry from factory (FR-REQN)
        admins[initialAdmin_] = 1;
        adminCount = 1;
        operators[initialOperator_] = 1;

        // Set vault lifecycle to Active
        phase = 1;

        // Enable reentrancy guard for nonReentrant functions
        _reentrancyGuard = 1;

        // Cache EIP-712 domain separator for signature verification
        _cachedChainId = block.chainid;
        DOMAIN_SEPARATOR = _computeDomainSeparator();

        // Pre-approve the exchange to spend USDC and outcome tokens on behalf of this vault
        IERC20(usdc_).approve(exchange_, type(uint256).max);
        IERC1155(conditionalTokens_).setApprovalForAll(exchange_, true);
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

    // ──────────────────────────────────────────────
    // Position minting (FEAT-T7AF, UC-T7AG)
    // ──────────────────────────────────────────────

    // SC-T7AH through SC-T7AR: operator-gated LP position mint via EIP-712 signed intent
    /// @notice Executes an LP's signed EIP-712 mint intent to create a concentrated-liquidity position.
    /// @dev OPERATOR TRUST ASSUMPTION: The Operator can submit any LP's signed intent
    ///      at any time. LPs must trust that the Operator submits their intent promptly.
    ///      This trust is bounded by the reclaimDeposit escape hatch planned in feature 7.
    /// @param lp LP wallet address — must match the signer of the EIP-712 intent
    /// @param tickLower Lower tick bound — must be < tickUpper and aligned to tickSpacing
    /// @param tickUpper Upper tick bound — must be > tickLower and aligned to tickSpacing
    /// @param usdcAmount USDC to pull from the LP's wallet — must be > 0
    /// @param intentId Unique identifier for replay protection
    /// @param signature EIP-712 signature from the LP over the MintIntent struct
    /// @return positionId The ID of the newly created position
    function mintPositionFor(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes calldata signature
    ) external onlyOperator nonReentrant returns (uint256 positionId) {
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

        // Replay protection: each intentId can only be used once
        if (usedIntents[intentId]) revert IntentAlreadyUsed();
        usedIntents[intentId] = true;

        // --- Effects ---

        // Compute liquidity weight from USDC and range width
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

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        // Pull USDC from the LP's wallet into the vault
        _safeTransferFrom(usdc, lp, address(this), usdcAmount);

        emit PositionMinted(positionId, lp, tickLower, tickUpper, liquidity, usdcAmount, intentId);
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
        }
    }

    /// @dev Computes the fee growth that occurred inside [tickLower, tickUpper) since
    ///      the vault's inception. Used to snapshot feeGrowthInsideLastX128 at mint time.
    ///      Formula: feeGrowthInside = global - below(tickLower) - above(tickUpper)
    function _computeFeeGrowthInside(int24 tickLower, int24 tickUpper) internal view returns (uint256) {
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

    // ──────────────────────────────────────────────
    // Internal: safe casts (inlined per pattern policy)
    // ──────────────────────────────────────────────

    /// @dev uint256 → uint128 with overflow check
    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert SafeCastOverflow();
        return uint128(x);
    }

    /// @dev uint128 → int128 with overflow check (liquidity is always positive)
    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        return int128(x);
    }
}
