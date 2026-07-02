// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-J92H: Deploy Contracts
// UC-J92I: Deploy Factory and Implementation
// SLICE-001: deploy-script

import {Script, console} from "forge-std/Script.sol";
import {LPVault} from "../src/LPVault.sol";
import {LPVaultFactory} from "../src/LPVaultFactory.sol";

/// @title DeployScript
/// @notice Deploys the LPVault implementation and LPVaultFactory to any EVM chain.
/// @dev All external addresses and role wallets are read from environment variables.
///      The same script works for Polygon Amoy and mainnet — only --rpc-url changes.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast [--verify]
contract DeployScript is Script {
    /// @dev Reverts when a required address env var is zero.
    error ZeroAddress(string name);

    // SC-J92J, SC-K49S: entry point reads address env vars and delegates to deploy()
    /// @notice Reads address env vars and deploys both contracts.
    /// @dev Signing is handled by Foundry CLI flags (--account, --ledger, --trezor).
    ///      No raw private key is read from environment variables.
    function run() external returns (LPVault lpVault, LPVaultFactory factory) {
        // SC-J92J, SC-J92K: read all required addresses from environment variables
        address usdc = vm.envAddress("USDC_ADDRESS");
        address exchange = vm.envAddress("EXCHANGE_ADDRESS");
        address conditionalTokens = vm.envAddress("CONDITIONAL_TOKENS_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");

        // SC-K49S: no private key read — signing delegated to Foundry CLI wallet management
        vm.startBroadcast();
        (lpVault, factory) = deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr);
        vm.stopBroadcast();

        // SC-J92J: log deployed addresses to stdout
        console.log("LPVault implementation:", address(lpVault));
        console.log("LPVaultFactory:", address(factory));
    }

    // SC-J92J, SC-J92K, SC-K49S: validates addresses and deploys both contracts
    /// @notice Validates all addresses, deploys LPVault implementation + LPVaultFactory.
    /// @dev Separated from run() so tests can call deploy() directly with explicit
    ///      parameters. Does not manage vm.startBroadcast/vm.stopBroadcast —
    ///      the caller (run() or test setUp) handles broadcast context.
    function deploy(
        address usdc,
        address exchange,
        address conditionalTokens,
        address admin,
        address oracleAddr,
        address operatorAddr
    ) public returns (LPVault lpVault, LPVaultFactory factory) {
        // SC-J92K: validate all addresses are non-zero before deploying
        if (usdc == address(0)) revert ZeroAddress("USDC_ADDRESS");
        if (exchange == address(0)) revert ZeroAddress("EXCHANGE_ADDRESS");
        if (conditionalTokens == address(0)) revert ZeroAddress("CONDITIONAL_TOKENS_ADDRESS");
        if (admin == address(0)) revert ZeroAddress("ADMIN_ADDRESS");
        if (oracleAddr == address(0)) revert ZeroAddress("ORACLE_ADDRESS");
        if (operatorAddr == address(0)) revert ZeroAddress("OPERATOR_ADDRESS");

        // SC-J92J: deploy implementation — constructor calls _disableInitializers()
        lpVault = new LPVault();

        // SC-J92J: deploy factory with implementation address and all addresses
        factory =
            new LPVaultFactory(address(lpVault), usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr);
    }
}
