// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LPVault, IConditionalTokens} from "./LPVault.sol";

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market, UC-REQ2: Manage Roles on Factory
// UC-REQ0-001: deploy-factory-with-role-registry
// UC-REQ1-001: create-vault-and-initialize
// UC-REQ2-001: factory-role-management
// FEAT-KX5N: Upgradeable Vault Implementation Pointer
// UC-KX5O: Schedule and Apply Implementation Upgrade
// UC-KX5O-001: schedule-apply-cancel-impl-upgrade

/// @title LPVaultFactory
/// @notice Deploys per-market LP vault clones (EIP-1167) and manages the factory-level role registry.
/// @dev Auth pattern inlined from ctf-exchange/lib/ctf-exchange/src/exchange/mixins/Auth.sol
///      with the addition of `oracle` role and role-separation checks.
contract LPVaultFactory {
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
    // Immutables
    // ──────────────────────────────────────────────

    /// @notice USDC ERC-20 contract address
    address public immutable usdc;

    /// @notice ProphetCTFExchange contract address
    address public immutable exchange;

    /// @notice Gnosis ConditionalTokens (ERC-1155) contract address
    address public immutable conditionalTokens;

    // ──────────────────────────────────────────────
    // Implementation pointer (FEAT-KX5N)
    // ──────────────────────────────────────────────

    /// @notice LPVault implementation used as the EIP-1167 clone target.
    ///         Was immutable; now regular storage so applyImplementation() can update it.
    address public implementation;

    /// @notice Scheduled implementation address awaiting timelock.
    address public pendingImplementation;

    /// @notice Timestamp after which applyImplementation() succeeds.
    uint256 public implementationUnlockAt;

    /// @notice Monotonically increasing counter incremented on each apply.
    ///         Passed to vault initialize() so off-chain systems can identify code version.
    uint256 public implementationVersion;

    /// @dev 7-day delay between schedule and apply. Polygon block.timestamp
    ///      tolerance is ±15s, negligible at this scale.
    uint256 public constant IMPLEMENTATION_TIMELOCK = 7 days;

    // ──────────────────────────────────────────────
    // Vault registry
    // ──────────────────────────────────────────────

    /// @notice Maps each marketId to its vault clone address. Non-zero means a vault exists.
    mapping(bytes32 => address) public vaultForMarket;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error NotAdmin();
    error NotOperator();
    error NotOracle();
    error RoleSeparation();
    error DuplicateMarket();
    error ZeroFloor();
    error CloneDeployFailed();
    error NotPendingAdmin();
    error ZeroAddress();
    error AlreadyAdmin();
    error CannotRemoveLastAdmin();
    error NoPendingSchedule();
    error ScheduleAlreadyPending();
    error TimelockNotElapsed();

    // SC-6HBV, SC-6HBW, SC-6HBX: one error per outcome-token identity defect
    error ZeroConditionId();
    error ZeroTokenId();
    error DuplicateTokenId();
    error NotBinaryCondition();
    error TokenIdMismatch();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);

    // SC-KX5P: emitted when Admin schedules a new implementation
    event ImplementationScheduled(address indexed newImpl, uint256 unlockAt);
    // SC-KX5Q: emitted when Admin applies the scheduled implementation
    event ImplementationApplied(address indexed newImpl, uint256 version);
    // SC-KX5S: emitted when Admin cancels a pending schedule
    event ImplementationCancelled(address indexed cancelledImpl);

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

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

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    // SC-REQ3, SC-REQ4: constructor initializes role registry and stores addresses
    /// @param implementation_ LPVault implementation for EIP-1167 cloning
    /// @param usdc_ USDC ERC-20 address
    /// @param exchange_ ProphetCTFExchange address
    /// @param conditionalTokens_ Gnosis ConditionalTokens (ERC-1155) address
    /// @param admin_ Initial admin wallet
    /// @param oracle_ Initial oracle wallet (must differ from operator_)
    /// @param operator_ Initial operator wallet (must differ from oracle_)
    constructor(
        address implementation_,
        address usdc_,
        address exchange_,
        address conditionalTokens_,
        address admin_,
        address oracle_,
        address operator_
    ) {
        // Role separation: oracle and operator must be distinct wallets.
        // Compromise of one must not unlock the other's powers.
        if (oracle_ == operator_) revert RoleSeparation();

        // Store external contract addresses
        implementation = implementation_;
        usdc = usdc_;
        exchange = exchange_;
        conditionalTokens = conditionalTokens_;

        // Start version counter at 1 (the initial deployment is version 1)
        implementationVersion = 1;

        // Initialize Auth registry: one admin, one oracle, one operator
        admins[admin_] = 1;
        adminCount = 1;
        oracle = oracle_;
        operators[operator_] = 1;
    }

    // ──────────────────────────────────────────────
    // Vault lifecycle
    // ──────────────────────────────────────────────

    // SC-REQ6, SC-REQ7, SC-REQ8, SC-RG74, SC-6HBV, SC-6HBW, SC-6HBX: create and initialize a new vault clone
    /// @notice Deploys an EIP-1167 minimal-proxy clone of the LPVault implementation,
    ///         initializes it for the given market, and registers it in vaultForMarket.
    /// @dev The outcome-token identity is verified before the clone exists, because a clone can
    ///      never correct its identity after initialize() (ADR-6HBU).
    /// @param marketId_ Unique market identifier — must not already have a vault
    /// @param tickSpacing_ Minimum tick increment for concentrated-liquidity positions
    /// @param minimumFirstLiquidity_ Floor for the first mint — must be > 0
    /// @param conditionId_ ConditionalTokens condition ID of the market — a prepared 2-outcome condition
    /// @param yesTokenId_ Index set 1 (YES) position ID of (usdc, conditionId_)
    /// @param noTokenId_ Index set 2 (NO) position ID of (usdc, conditionId_)
    /// @return vault Address of the newly-deployed vault clone
    function createVault(
        bytes32 marketId_,
        int24 tickSpacing_,
        uint128 minimumFirstLiquidity_,
        bytes32 conditionId_,
        uint256 yesTokenId_,
        uint256 noTokenId_
    ) external onlyOracle returns (address vault) {
        // Enforce minimum first liquidity > 0
        if (minimumFirstLiquidity_ == 0) revert ZeroFloor();

        // Prevent duplicate vaults for the same market
        if (vaultForMarket[marketId_] != address(0)) revert DuplicateMarket();

        // Prove the identity names this market's two outcome tokens
        _validateOutcomeIdentity(conditionId_, yesTokenId_, noTokenId_);

        // Deploy EIP-1167 minimal proxy clone
        vault = _createClone(implementation);

        // CEI: register before external interaction (initialize calls approve on USDC/CT)
        vaultForMarket[marketId_] = vault;

        // Initialize the clone with per-market configuration (role state delegated, not copied)
        LPVault(vault)
            .initialize(
                marketId_,
                usdc,
                exchange,
                conditionalTokens,
                tickSpacing_,
                address(this),
                minimumFirstLiquidity_,
                implementationVersion,
                conditionId_,
                yesTokenId_,
                noTokenId_
            );

        emit VaultCreated(marketId_, vault, minimumFirstLiquidity_);
    }

    // SC-6HBV, SC-6HBW, SC-6HBX: outcome-token identity check (FR-6HBQ, FR-6HBR, FR-6HBS)
    /// @dev Reverts unless the identity names the two outcome tokens of a prepared binary condition
    ///      with USDC collateral and parentCollectionId == bytes32(0), the only market shape Prophet's
    ///      Resolution.sol prepares. Index set 1 is YES and index set 2 is NO, as in Resolution.sol
    ///      (payout [1,0] means YES wins), so a swapped pair reverts. The three value checks are
    ///      redundant for safety, because the two contract checks below also reject those inputs.
    ///      They stay because each names the wrong argument and reverts before any external call.
    function _validateOutcomeIdentity(bytes32 conditionId_, uint256 yesTokenId_, uint256 noTokenId_) private view {
        if (conditionId_ == bytes32(0)) revert ZeroConditionId();
        if (yesTokenId_ == 0 || noTokenId_ == 0) revert ZeroTokenId();
        if (yesTokenId_ == noTokenId_) revert DuplicateTokenId();

        IConditionalTokens ctf = IConditionalTokens(conditionalTokens);

        // An unprepared condition returns 0. The complete-set merge and the redemption use the
        // partition [1, 2], which mints a third token instead of paying USDC on a condition with
        // 3 or more outcomes.
        if (ctf.getOutcomeSlotCount(conditionId_) != 2) revert NotBinaryCondition();

        uint256 expectedYes = ctf.getPositionId(usdc, ctf.getCollectionId(bytes32(0), conditionId_, 1));
        uint256 expectedNo = ctf.getPositionId(usdc, ctf.getCollectionId(bytes32(0), conditionId_, 2));
        if (yesTokenId_ != expectedYes || noTokenId_ != expectedNo) revert TokenIdMismatch();
    }

    // ──────────────────────────────────────────────
    // Internal: EIP-1167 clone deployment (inlined per pattern policy)
    // ──────────────────────────────────────────────

    /// @dev Deploys an EIP-1167 minimal proxy clone of the given implementation.
    ///      Inlined from OpenZeppelin Clones.sol per CLAUDE.md pattern policy.
    function _createClone(address impl) internal returns (address clone) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            clone := create(0, ptr, 0x37)
        }
        if (clone == address(0)) revert CloneDeployFailed();
    }

    // ──────────────────────────────────────────────
    // Implementation upgrade (FEAT-KX5N, UC-KX5O)
    // ──────────────────────────────────────────────

    // SC-KX5P: admin-only schedule with zero-address guard and double-schedule guard
    /// @notice Schedules a new LPVault implementation address for upgrade after
    ///         IMPLEMENTATION_TIMELOCK elapses. Does not change the active pointer.
    /// @param newImpl Address of the new implementation contract
    function scheduleImplementation(address newImpl) external onlyAdmin {
        if (newImpl == address(0)) revert ZeroAddress();
        if (pendingImplementation != address(0)) revert ScheduleAlreadyPending();

        pendingImplementation = newImpl;
        uint256 unlockAt = block.timestamp + IMPLEMENTATION_TIMELOCK;
        implementationUnlockAt = unlockAt;

        emit ImplementationScheduled(newImpl, unlockAt);
    }

    // SC-KX5Q: admin-only apply after timelock, increments version
    /// @notice Applies the scheduled implementation, updating the active pointer
    ///         and incrementing the version counter. Clears the pending state.
    function applyImplementation() external onlyAdmin {
        if (pendingImplementation == address(0)) revert NoPendingSchedule();
        // ±15s Polygon tolerance is negligible at 7-day scale
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < implementationUnlockAt) revert TimelockNotElapsed();

        address newImpl = pendingImplementation;

        // Update active pointer and bump version
        implementation = newImpl;
        implementationVersion += 1;

        // Clear pending state
        pendingImplementation = address(0);
        implementationUnlockAt = 0;

        emit ImplementationApplied(newImpl, implementationVersion);
    }

    // SC-KX5S: admin-only cancel, clears pending state
    /// @notice Cancels a pending implementation schedule without changing the active pointer.
    function cancelScheduledImplementation() external onlyAdmin {
        if (pendingImplementation == address(0)) revert NoPendingSchedule();

        address cancelled = pendingImplementation;

        // Clear pending state
        pendingImplementation = address(0);
        implementationUnlockAt = 0;

        emit ImplementationCancelled(cancelled);
    }

    // ──────────────────────────────────────────────
    // Role management (UC-REQ2-001)
    // ──────────────────────────────────────────────

    // SC-REQB, SC-REQC: register a new operator with role-separation enforcement
    /// @notice Registers a new operator address.
    /// @dev OPERATOR TRUST ASSUMPTION: Operators can execute transactional functions
    ///      (mintPositionFor, notifyFees, updateTick, mergePositions). Users must
    ///      trust that operators act honestly when crediting positions and reporting fees.
    /// @param operator_ Address to register as operator — must not be the current oracle
    function addOperator(address operator_) external onlyAdmin {
        // Role separation: oracle and operator must be distinct wallets
        if (operator_ == oracle) revert RoleSeparation();

        operators[operator_] = 1;
        emit NewOperator(operator_, msg.sender);
    }

    // SC-REQD: deregister an existing operator
    /// @notice Removes an address from the operator set.
    /// @param operator_ Address to deregister
    function removeOperator(address operator_) external onlyAdmin {
        operators[operator_] = 0;
        emit RemovedOperator(operator_, msg.sender);
    }

    // SC-REQE, SC-REQF: update oracle with role-separation enforcement
    /// @notice Updates the oracle address.
    /// @dev The oracle controls vault lifecycle (createVault, startWindDown).
    ///      Cannot be set to an address that is currently an operator (role separation).
    /// @param newOracle Address to set as the new oracle
    function setOracle(address newOracle) external onlyAdmin {
        // Role separation: the new oracle must not already be an operator
        if (operators[newOracle] == 1) revert RoleSeparation();

        oracle = newOracle;
    }

    // SC-REQG: first step of two-step admin transfer — store the proposed admin
    /// @notice Proposes a new admin. The proposed address must call acceptAdmin() to complete.
    /// @dev Two-step transfer prevents accidental admin loss from typos or wrong addresses.
    /// @param newAdmin Address to propose as admin — must not be zero or already an admin
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (admins[newAdmin] == 1) revert AlreadyAdmin();

        pendingAdmin = newAdmin;
        emit AdminTransferProposed(msg.sender, newAdmin);
    }

    // SC-REQG, SC-5UJR: second step — proposed admin claims the role
    /// @notice Completes the two-step admin transfer. Only callable by the pending admin.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        // addAdmin can grant the role after transferAdmin proposed it. Accepting
        // again would count the same admin twice in adminCount.
        if (admins[msg.sender] == 1) revert AlreadyAdmin();

        admins[msg.sender] = 1;
        adminCount += 1;
        pendingAdmin = address(0);

        emit NewAdmin(msg.sender, msg.sender);
    }

    // SC-5UJF, SC-5UJG, SC-5UJH: one-step admin grant
    /// @notice Grants the admin role to an address. Only callable by an admin.
    /// @dev A repeated add changes no state but still emits NewAdmin, so that
    ///      adminCount never counts one address twice.
    /// @param admin_ Address to grant the admin role — must not be zero
    function addAdmin(address admin_) external onlyAdmin {
        if (admin_ == address(0)) revert ZeroAddress();
        if (admins[admin_] != 1) {
            admins[admin_] = 1;
            adminCount++;
        }
        emit NewAdmin(admin_, msg.sender);
    }

    // SC-5UJI, SC-5UJJ, SC-5UJK, SC-5UJL, SC-5UJO, SC-5UJP: revoke another admin
    /// @notice Revokes the admin role of an address. Only callable by an admin.
    /// @dev Vaults read admins() from this factory at call time, so the removed
    ///      address loses admin rights on every vault in the same block.
    ///      Removing an address that holds no role changes no role state but still emits RemovedAdmin.
    ///      A pending admin proposal to the address is withdrawn in both cases (ADR-5UJS).
    /// @param admin Address whose admin role is revoked
    function removeAdmin(address admin) external onlyAdmin {
        if (admins[admin] == 1) {
            if (adminCount <= 1) revert CannotRemoveLastAdmin();
            admins[admin] = 0;
            adminCount--;
        }
        // A removed address must not complete an earlier transferAdmin proposal.
        if (pendingAdmin == admin) pendingAdmin = address(0);
        emit RemovedAdmin(admin, msg.sender);
    }

    // SC-5UJM, SC-5UJN, SC-5UJQ: caller gives up its own admin role
    /// @notice Revokes the caller's admin role. Reverts if the caller is the last admin.
    /// @dev A pending admin proposal to the caller is withdrawn (ADR-5UJS).
    function renounceAdminRole() external onlyAdmin {
        if (adminCount <= 1) revert CannotRemoveLastAdmin();
        admins[msg.sender] = 0;
        adminCount--;
        // A renounced address must not complete an earlier transferAdmin proposal.
        if (pendingAdmin == msg.sender) pendingAdmin = address(0);
        emit RemovedAdmin(msg.sender, msg.sender);
    }
}
