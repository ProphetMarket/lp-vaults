// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-J92H: Deploy Contracts
// UC-J92I: Deploy Factory and Implementation

import {Script, console} from "forge-std/Script.sol";
import {LPVault} from "../src/LPVault.sol";
import {LPVaultFactory} from "../src/LPVaultFactory.sol";

/// @dev The two Poly Safe factory reads the script makes. getContractBytecode() returns the proxy
///      creation code concatenated with the ABI-encoded master copy, which is the CREATE2 init code
///      the LP vault factory hashes into every Safe derivation (FR-J92P, FR-9OYI).
interface IPolySafeFactory {
    function getContractBytecode() external view returns (bytes memory);
    function masterCopy() external view returns (address);
}

/// @title DeployScript
/// @notice Deploys the LPVault implementation and LPVaultFactory to any EVM chain.
/// @dev All external addresses and role wallets are read from environment variables.
///      The same script works for Polygon Amoy and mainnet — only --rpc-url changes.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast [--verify]
contract DeployScript is Script {
    /// @dev Reverts when a required address env var is zero.
    error ZeroAddress(string name);

    /// @dev Reverts when the Safe factory returns bytes that hash to zero, which cannot happen for
    ///      a real factory; a zero hash never reaches the LP vault factory.
    error ZeroBytecodeHash();

    // SC-J92J, SC-K49S: entry point reads address env vars and delegates to deploy()
    /// @notice Reads address env vars, reads the Safe proxy bytecode hash from the chain, and
    ///         deploys both contracts.
    /// @dev Signing is handled by Foundry CLI flags (--account, --ledger, --trezor).
    ///      No raw private key is read from environment variables.
    function run() external returns (LPVault lpVault, LPVaultFactory factory) {
        // SC-J92J, SC-J92K: read all required addresses from environment variables
        address usdc = vm.envAddress("USDC_ADDRESS");
        address exchange = vm.envAddress("EXCHANGE_ADDRESS");
        address conditionalTokens = vm.envAddress("CTF_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");
        address safeFactory = vm.envAddress("SAFE_FACTORY_ADDRESS");

        // SC-J92J, SC-9OY8: the hash comes from the live Safe factory, never from a typed value.
        // The deployer compares the logged hash with the value in DEPLOYMENT.md for the chain.
        if (safeFactory == address(0)) revert ZeroAddress("SAFE_FACTORY_ADDRESS");
        bytes32 safeProxyBytecodeHash = readSafeProxyBytecodeHash(safeFactory);
        console.log("Safe factory:", safeFactory);
        console.log("Safe master copy:", IPolySafeFactory(safeFactory).masterCopy());
        console.log("Safe proxy bytecode hash:");
        console.logBytes32(safeProxyBytecodeHash);

        // SC-K49S: no private key read — signing delegated to Foundry CLI wallet management
        vm.startBroadcast();
        (lpVault, factory) = deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, safeFactory, safeProxyBytecodeHash
        );
        vm.stopBroadcast();

        // SC-J92J: log deployed addresses to stdout
        console.log("LPVault implementation:", address(lpVault));
        console.log("LPVaultFactory:", address(factory));
    }

    // SC-9OY8: the chain read has its own public view driver, because tests never call run()
    /// @notice Returns keccak256 of the Safe factory's proxy bytecode, the init code hash of the
    ///         CREATE2 derivation that every vault performs for an owner-key signature.
    /// @param safeFactory The Poly Safe factory on the target chain
    function readSafeProxyBytecodeHash(address safeFactory) public view returns (bytes32) {
        return keccak256(IPolySafeFactory(safeFactory).getContractBytecode());
    }

    // SC-J92J, SC-J92K, SC-K49S, SC-9OY8: validates addresses and deploys both contracts
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
        address operatorAddr,
        address safeFactory,
        bytes32 safeProxyBytecodeHash
    ) public returns (LPVault lpVault, LPVaultFactory factory) {
        // SC-J92K: validate all addresses are non-zero before deploying
        if (usdc == address(0)) revert ZeroAddress("USDC_ADDRESS");
        if (exchange == address(0)) revert ZeroAddress("EXCHANGE_ADDRESS");
        if (conditionalTokens == address(0)) revert ZeroAddress("CTF_ADDRESS");
        if (admin == address(0)) revert ZeroAddress("ADMIN_ADDRESS");
        if (oracleAddr == address(0)) revert ZeroAddress("ORACLE_ADDRESS");
        if (operatorAddr == address(0)) revert ZeroAddress("OPERATOR_ADDRESS");
        if (safeFactory == address(0)) revert ZeroAddress("SAFE_FACTORY_ADDRESS");
        if (safeProxyBytecodeHash == bytes32(0)) revert ZeroBytecodeHash();

        // SC-J92J: deploy implementation — constructor calls _disableInitializers()
        lpVault = new LPVault();

        // SC-J92J: deploy factory with implementation address, all addresses, and the hash
        factory = new LPVaultFactory(
            address(lpVault),
            usdc,
            exchange,
            conditionalTokens,
            admin,
            oracleAddr,
            operatorAddr,
            safeFactory,
            safeProxyBytecodeHash
        );
    }
}
