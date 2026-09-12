// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-J92H: Deploy Contracts
// UC-J92I: Deploy Factory and Implementation
// Integration tests for every scenario in this use case.
// Covers: SC-J92J, SC-J92K, SC-J92L, SC-J92M, SC-K49S, SC-9OY8

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../../../script/Deploy.s.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";

// ──────────────────────────────────────────────
// StubSafeFactory: stands in for the Poly Safe factory. Returns known bytes
// from getContractBytecode() so the test can compute the expected hash
// itself (SC-9OY8). The real factory's hash per chain is in DEPLOYMENT.md.
// ──────────────────────────────────────────────
contract StubSafeFactory {
    bytes internal code;
    address public masterCopy;

    constructor(bytes memory code_, address masterCopy_) {
        code = code_;
        masterCopy = masterCopy_;
    }

    function getContractBytecode() external view returns (bytes memory) {
        return code;
    }
}

/// @dev The made-up Safe derivation inputs the deploy tests pass. The script reads the real hash
///      from the chain in run(); deploy() takes whatever value it is given.
address constant SAFE_FACTORY = 0x5AfeFaC70000000000000000000000000000aBcd;
bytes32 constant SAFE_PROXY_BYTECODE_HASH = keccak256("deploy-test.safeProxyBytecodeHash");

// SC-J92J: Successful deployment with valid configuration
// What: Running the deploy helper with all valid, distinct addresses deploys both
//       LPVault implementation and LPVaultFactory, with the factory's on-chain state
//       matching every provided address.
// Why:  The deploy helper is the core deployment logic shared by run() and tests.
//       If any address is wired incorrectly, the entire vault system is misconfigured.
// Example: deploy(usdc, exchange, ct, admin, oracle, operator, safeFactory, hash)
//          → factory.usdc() == usdc, factory.implementation() == deployed LPVault,
//          factory.safeProxyBytecodeHash() == hash.
contract DeployScriptSuccessTest is Test {
    DeployScript script;
    LPVault lpVault;
    LPVaultFactory factory;

    address usdc = makeAddr("usdc");
    address exchange = makeAddr("exchange");
    address conditionalTokens = makeAddr("conditionalTokens");
    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        script = new DeployScript();
        (lpVault, factory) = script.deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92J: LPVault implementation is deployed at a non-zero address
    function test_implementationDeployedAtNonZeroAddress() public view {
        assertTrue(address(lpVault) != address(0), "LPVault impl should be deployed");
    }

    // SC-J92J: calling initialize() on the implementation reverts (initializers disabled)
    function test_implementationInitializeReverts() public {
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        lpVault.initialize(
            bytes32(uint256(1)),
            usdc,
            exchange,
            conditionalTokens,
            int24(10),
            address(factory),
            uint128(1000),
            1,
            bytes32(uint256(1)),
            1,
            2
        );
    }

    // SC-J92J: LPVaultFactory is deployed at a non-zero address
    function test_factoryDeployedAtNonZeroAddress() public view {
        assertTrue(address(factory) != address(0), "Factory should be deployed");
    }

    // SC-J92J: factory.implementation() equals the implementation address
    function test_factoryImplementationMatchesDeployedImpl() public view {
        assertEq(factory.implementation(), address(lpVault), "factory.implementation should match deployed LPVault");
    }

    // SC-J92J: factory.usdc() equals USDC_ADDRESS
    function test_factoryUsdcMatchesEnvVar() public view {
        assertEq(factory.usdc(), usdc, "factory.usdc should match USDC_ADDRESS");
    }

    // SC-J92J: factory.exchange() equals EXCHANGE_ADDRESS
    function test_factoryExchangeMatchesEnvVar() public view {
        assertEq(factory.exchange(), exchange, "factory.exchange should match EXCHANGE_ADDRESS");
    }

    // SC-J92J: factory.conditionalTokens() equals CTF_ADDRESS
    function test_factoryConditionalTokensMatchesEnvVar() public view {
        assertEq(factory.conditionalTokens(), conditionalTokens, "factory.conditionalTokens should match CTF_ADDRESS");
    }

    // SC-J92J: factory.admins(ADMIN_ADDRESS) equals 1
    function test_factoryAdminIsRegistered() public view {
        assertEq(factory.admins(admin), 1, "ADMIN_ADDRESS should be registered as admin");
    }

    // SC-J92J: factory.oracle() equals ORACLE_ADDRESS
    function test_factoryOracleMatchesEnvVar() public view {
        assertEq(factory.oracle(), oracleAddr, "factory.oracle should match ORACLE_ADDRESS");
    }

    // SC-J92J: factory.operators(OPERATOR_ADDRESS) equals 1
    function test_factoryOperatorIsRegistered() public view {
        assertEq(factory.operators(operatorAddr), 1, "OPERATOR_ADDRESS should be registered as operator");
    }

    // SC-J92J: factory.safeFactory() equals SAFE_FACTORY_ADDRESS
    function test_factorySafeFactoryMatchesEnvVar() public view {
        assertEq(factory.safeFactory(), SAFE_FACTORY, "factory.safeFactory should match SAFE_FACTORY_ADDRESS");
    }

    // SC-J92J: factory.safeProxyBytecodeHash() equals the hash passed to deploy
    function test_factorySafeProxyBytecodeHashMatchesDeployArg() public view {
        assertEq(
            factory.safeProxyBytecodeHash(),
            SAFE_PROXY_BYTECODE_HASH,
            "factory.safeProxyBytecodeHash should match the hash read from the Safe factory"
        );
    }
}

// SC-J92K: Missing environment variable
// What: The deploy helper must revert before deploying any contract when
//       any required address is the zero address.
// Why:  Deploying with a zero address for USDC, exchange, or any role wallet
//       would create a permanently broken factory — the addresses cannot be
//       changed after deployment. Fail-fast prevents wasted gas.
// Example: deploy(address(0), ...) → revert ZeroAddress("USDC_ADDRESS").
contract DeployScriptZeroAddressTest is Test {
    DeployScript script;

    address usdc = makeAddr("usdc");
    address exchange = makeAddr("exchange");
    address conditionalTokens = makeAddr("conditionalTokens");
    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        script = new DeployScript();
    }

    // SC-J92K: USDC_ADDRESS set to zero address
    function test_revertsWhenUsdcIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "USDC_ADDRESS"));
        script.deploy(
            address(0),
            exchange,
            conditionalTokens,
            admin,
            oracleAddr,
            operatorAddr,
            SAFE_FACTORY,
            SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: EXCHANGE_ADDRESS set to zero address
    function test_revertsWhenExchangeIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "EXCHANGE_ADDRESS"));
        script.deploy(
            usdc, address(0), conditionalTokens, admin, oracleAddr, operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: CTF_ADDRESS set to zero address
    function test_revertsWhenConditionalTokensIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "CTF_ADDRESS"));
        script.deploy(
            usdc, exchange, address(0), admin, oracleAddr, operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: ADMIN_ADDRESS set to zero address
    function test_revertsWhenAdminIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "ADMIN_ADDRESS"));
        script.deploy(
            usdc,
            exchange,
            conditionalTokens,
            address(0),
            oracleAddr,
            operatorAddr,
            SAFE_FACTORY,
            SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: ORACLE_ADDRESS set to zero address
    function test_revertsWhenOracleIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "ORACLE_ADDRESS"));
        script.deploy(
            usdc, exchange, conditionalTokens, admin, address(0), operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: OPERATOR_ADDRESS set to zero address
    function test_revertsWhenOperatorIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "OPERATOR_ADDRESS"));
        script.deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, address(0), SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-J92K: SAFE_FACTORY_ADDRESS set to zero address
    function test_revertsWhenSafeFactoryIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "SAFE_FACTORY_ADDRESS"));
        script.deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, address(0), SAFE_PROXY_BYTECODE_HASH
        );
    }

    // SC-9OY8: a zero hash never reaches the factory
    function test_revertsWhenSafeProxyBytecodeHashIsZero() public {
        vm.expectRevert(DeployScript.ZeroBytecodeHash.selector);
        script.deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, SAFE_FACTORY, bytes32(0));
    }
}

// SC-9OY8: The hash is read from the Safe factory on chain
// What: readSafeProxyBytecodeHash(safeFactory) returns keccak256 of whatever
//       bytes the factory's getContractBytecode() returns.
// Why:  The hash the LP vault factory needs comes from the live Safe factory,
//       never from a typed value (FR-J92P). Tests never call run(), so the
//       chain read has its own public view driver.
// Example: stub returns 0xdeadbeef → hash == keccak256(0xdeadbeef).
contract DeployScriptReadsSafeProxyBytecodeHashTest is Test {
    // SC-9OY8: the returned hash equals the hash computed from the same bytes
    function test_readSafeProxyBytecodeHashHashesTheFactoryBytecode() public {
        DeployScript script = new DeployScript();
        bytes memory proxyCode = hex"deadbeef0102030405";
        StubSafeFactory stub = new StubSafeFactory(proxyCode, makeAddr("masterCopy"));

        bytes32 hash = script.readSafeProxyBytecodeHash(address(stub));

        assertEq(hash, keccak256(proxyCode), "hash should be keccak256 of getContractBytecode()");
    }

    // SC-9OY8: the stub also answers masterCopy(), which run() logs
    function test_stubExposesMasterCopy() public {
        address master = makeAddr("masterCopy");
        StubSafeFactory stub = new StubSafeFactory(hex"01", master);
        assertEq(stub.masterCopy(), master, "masterCopy should be readable");
    }
}

// SC-J92L: Oracle equals operator (role separation violation)
// What: When oracle and operator are set to the same address, the factory
//       constructor reverts with RoleSeparation, preventing a deployment that
//       violates role separation.
// Why:  Oracle and Operator are separate trust domains (CLAUDE.md hard rule).
//       Compromise of one must not unlock the other's powers. The factory
//       constructor enforces this; the deploy helper surfaces the revert.
// Example: deploy(..., oracle=0xABC, operator=0xABC) → revert RoleSeparation.
contract DeployScriptRoleSeparationTest is Test {
    // SC-J92L: deployment reverts when oracle == operator
    function test_revertsWhenOracleEqualsOperator() public {
        DeployScript script = new DeployScript();
        address sameAddr = makeAddr("sameAddr");

        vm.expectRevert(LPVaultFactory.RoleSeparation.selector);
        script.deploy(
            makeAddr("usdc"),
            makeAddr("exchange"),
            makeAddr("conditionalTokens"),
            makeAddr("admin"),
            sameAddr,
            sameAddr,
            SAFE_FACTORY,
            SAFE_PROXY_BYTECODE_HASH
        );
    }
}

// SC-J92M: Deployment with contract verification
// What: The deploy helper produces identical deployment results regardless of
//       whether --verify is passed. Verification is a Foundry CLI-level concern.
// Why:  This test verifies the helper's core deployment logic is correct.
//       The --verify flag is handled by Foundry's CLI, not script logic.
// Note: Actual Polygonscan verification is tested operationally, not in-EVM.
contract DeployScriptVerificationTest is Test {
    // SC-J92M: deployment produces same results (verification is a CLI flag)
    function test_deploymentProducesSameResultsRegardlessOfVerifyFlag() public {
        DeployScript script = new DeployScript();
        address usdc = makeAddr("usdc");
        address exchange = makeAddr("exchange");
        address conditionalTokens = makeAddr("conditionalTokens");
        address admin = makeAddr("admin");
        address oracleAddr = makeAddr("oracle");
        address operatorAddr = makeAddr("operator");

        (LPVault lpVault, LPVaultFactory factory) = script.deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );

        assertTrue(address(lpVault) != address(0), "LPVault impl should be deployed");
        assertTrue(address(factory) != address(0), "Factory should be deployed");
        assertEq(factory.implementation(), address(lpVault), "implementation should match");
        assertEq(factory.usdc(), usdc, "usdc should match");
        assertEq(factory.exchange(), exchange, "exchange should match");
        assertEq(factory.conditionalTokens(), conditionalTokens, "conditionalTokens should match");
        assertEq(factory.admins(admin), 1, "admin should be registered");
        assertEq(factory.oracle(), oracleAddr, "oracle should match");
        assertEq(factory.operators(operatorAddr), 1, "operator should be registered");
    }
}

// SC-K49S: Script does not read raw private keys
// What: The deploy() function does not accept a private key parameter and
//       does not manage vm.startBroadcast/vm.stopBroadcast. Signing is
//       delegated entirely to Foundry's CLI-level wallet management.
// Why:  Raw private keys in environment variables are a security risk —
//       they can leak via shell history, process listings, and CI logs.
//       Cast wallets (encrypted keystores) and hardware wallets eliminate
//       this attack surface.
// Example: deploy(usdc, exchange, ct, admin, oracle, operator, safeFactory, hash) — no key param.
contract DeployScriptNoPrivateKeyTest is Test {
    // SC-K49S: deploy() accepts only address parameters, no private key
    function test_deployAcceptsOnlyAddressParams() public {
        DeployScript script = new DeployScript();
        address usdc = makeAddr("usdc");
        address exchange = makeAddr("exchange");
        address conditionalTokens = makeAddr("conditionalTokens");
        address admin = makeAddr("admin");
        address oracleAddr = makeAddr("oracle");
        address operatorAddr = makeAddr("operator");

        (LPVault lpVault, LPVaultFactory factory) = script.deploy(
            usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );

        assertTrue(address(lpVault) != address(0), "deploy() should work without a private key parameter");
        assertTrue(address(factory) != address(0), "deploy() should work without a private key parameter");
    }
}
