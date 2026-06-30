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

/// @dev Minimal ERC-20 interface — only approve needed for exchange setup.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC-1155 interface — only setApprovalForAll for exchange setup.
interface IERC1155 {
    function setApprovalForAll(address operator, bool approved) external;
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

    /// @dev Tracks the most recent block.timestamp at which an Operator called
    ///      updateTick. Used by feature 8 to detect prolonged Operator silence.
    uint256 public lastOperatorActivityTimestamp;

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

    bytes32 private constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");

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
    error SameTick();
    error TooManyTicksCrossed();
    error NotPositionOwner();
    error PositionNotFound();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    // SC-TOGT, SC-TOGU: emitted when Operator distributes fee revenue
    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

    // SC-TVS2 through SC-TVS4: emitted on every successful tick update
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    // SC-U07B, SC-U07F, SC-U07G: emitted when LP collects nonzero fees
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

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
    ///      is acceptable BECAUSE the vault holds outcome tokens for exactly one market —
    ///      token IDs for other markets cannot enter the vault (no entry point exists).
    /// @param marketId_ Unique market identifier from the CTF Exchange
    /// @param usdc_ USDC ERC-20 address
    /// @param exchange_ ProphetCTFExchange address
    /// @param conditionalTokens_ Gnosis ConditionalTokens (ERC-1155) address
    /// @param tickSpacing_ Minimum tick increment for positions
    /// @param factory_ Factory contract address — must equal msg.sender
    /// @param minimumFirstLiquidity_ Floor for the first mint when activeLiquidity == 0
    function initialize(
        bytes32 marketId_,
        address usdc_,
        address exchange_,
        address conditionalTokens_,
        int24 tickSpacing_,
        address factory_,
        uint128 minimumFirstLiquidity_
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
        tickSpacing = tickSpacing_;
        minimumFirstLiquidity = minimumFirstLiquidity_;

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

        Position storage p = positions[positionId];

        // Position must exist (owner is never set to address(0) during mint)
        if (p.owner == address(0)) revert PositionNotFound();

        // Only the position's owner can collect
        if (p.owner != msg.sender) revert NotPositionOwner();

        // --- Effects ---

        // Compute current feeGrowthInside for this position's tick range
        uint256 feeGrowthInsideX128 = _computeFeeGrowthInside(p.tickLower, p.tickUpper);

        // Calculate fees accrued since the last collect (or mint)
        uint256 owed = uint256(p.liquidity) * (feeGrowthInsideX128 - p.feeGrowthInsideLastX128) / Q128;

        // Snapshot update: future collects start from here
        p.feeGrowthInsideLastX128 = feeGrowthInsideX128;

        // --- Interactions (external calls last, per checks-effects-interactions) ---

        if (owed > 0) {
            _safeTransfer(usdc, msg.sender, owed);
            emit FeesCollected(positionId, msg.sender, owed);
        }
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
    function notifyFees(uint256 amount) external onlyOperator {
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
    /// @param newTick The new price tick to set
    function updateTick(int24 newTick) external onlyOperator nonReentrant {
        // Phase check: only Active vaults accept tick updates
        if (phase != 1) revert VaultNotActive();

        int24 oldTick = currentTick;
        if (newTick == oldTick) revert SameTick();

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
        lastOperatorActivityTimestamp = block.timestamp;

        emit TickUpdated(oldTick, newTick, crossCount);
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

            // Register this tick in the bitmap so updateTick can locate it in O(1)
            _setTickBitmapBit(tick);
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
    // Internal: tick crossing (FEAT-TVS0)
    // ──────────────────────────────────────────────

    /// @dev Crosses an initialized tick: flips feeGrowthOutsideX128 and adjusts
    ///      activeLiquidity by the tick's liquidityNet. The flip formula is the
    ///      same in both directions; the liquidityNet sign depends on direction.
    function _crossTick(int24 tick, bool ltr) internal {
        TickInfo storage info = ticks[tick];

        // Flip feeGrowthOutside: the "outside" side swaps relative to currentTick
        info.feeGrowthOutsideX128 = feeGrowthGlobalX128 - info.feeGrowthOutsideX128;

        // Apply liquidityNet: positive when moving L-to-R, negated when R-to-L
        int128 liquidityDelta = ltr ? info.liquidityNet : -info.liquidityNet;
        activeLiquidity = _addDelta(activeLiquidity, liquidityDelta);
    }

    /// @dev Adds a signed delta to an unsigned liquidity value. Reverts on underflow
    ///      (activeLiquidity should never go negative — would indicate a logic bug).
    function _addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y >= 0) {
            z = x + uint128(y);
            if (z < x) revert SafeCastOverflow();
        } else {
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
        tickBitmap[wordPos] |= (1 << bitPos);
    }

    /// @dev Clears the bitmap bit for a tick when it becomes deinitialized.
    ///      Provided for feature 6 (burn) — not called by this feature.
    function _clearTickBitmapBit(int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = _tickPosition(tick);
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
        return uint128(x);
    }

    /// @dev uint128 → int128 with overflow check (liquidity is always positive)
    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        return int128(x);
    }
}
