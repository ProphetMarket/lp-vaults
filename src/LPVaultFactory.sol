// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LPVault} from "./LPVault.sol";

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory, UC-REQ1: Create Vault for Market
// UC-REQ0-001: deploy-factory-with-role-registry
// UC-REQ1-001: create-vault-and-initialize

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

    /// @notice LPVault implementation used as the EIP-1167 clone target
    address public immutable implementation;

    /// @notice USDC ERC-20 contract address
    address public immutable usdc;

    /// @notice ProphetCTFExchange contract address
    address public immutable exchange;

    /// @notice Gnosis ConditionalTokens (ERC-1155) contract address
    address public immutable conditionalTokens;

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

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);

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

        // Store immutable external contract addresses
        implementation = implementation_;
        usdc = usdc_;
        exchange = exchange_;
        conditionalTokens = conditionalTokens_;

        // Initialize Auth registry: one admin, one oracle, one operator
        admins[admin_] = 1;
        adminCount = 1;
        oracle = oracle_;
        operators[operator_] = 1;
    }

    // ──────────────────────────────────────────────
    // Vault lifecycle
    // ──────────────────────────────────────────────

    // SC-REQ6, SC-REQ7, SC-REQ8, SC-RG74: create and initialize a new vault clone
    /// @notice Deploys an EIP-1167 minimal-proxy clone of the LPVault implementation,
    ///         initializes it for the given market, and registers it in vaultForMarket.
    /// @param marketId_ Unique market identifier — must not already have a vault
    /// @param tickSpacing_ Minimum tick increment for concentrated-liquidity positions
    /// @param minimumFirstLiquidity_ Floor for the first mint — must be > 0
    /// @return vault Address of the newly-deployed vault clone
    function createVault(bytes32 marketId_, int24 tickSpacing_, uint128 minimumFirstLiquidity_)
        external
        onlyOracle
        returns (address vault)
    {
        // Enforce minimum first liquidity > 0
        if (minimumFirstLiquidity_ == 0) revert ZeroFloor();

        // Prevent duplicate vaults for the same market
        if (vaultForMarket[marketId_] != address(0)) revert DuplicateMarket();

        // Deploy EIP-1167 minimal proxy clone
        vault = _createClone(implementation);

        // CEI: register before external interaction (initialize calls approve on USDC/CT)
        vaultForMarket[marketId_] = vault;

        // Initialize the clone with per-market configuration
        LPVault(vault).initialize(
            marketId_, usdc, exchange, conditionalTokens, oracle, tickSpacing_, address(this), minimumFirstLiquidity_
        );

        emit VaultCreated(marketId_, vault, minimumFirstLiquidity_);
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
}
