// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ0: Deploy Factory
// SLICE-001: deploy-factory-with-role-registry

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
    // Errors
    // ──────────────────────────────────────────────

    error NotAdmin();
    error NotOperator();
    error NotOracle();
    error RoleSeparation();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);

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
}
