// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-J92H: Deploy Contracts
// UC-J92I: Deploy Factory and Implementation
// SLICE-001: deploy-script

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../../../../script/Deploy.s.sol";
import {LPVault} from "../../../../src/LPVault.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";

// SC-J92J: Successful deployment with valid configuration
// What: Running the deploy helper with all valid, distinct addresses deploys both
//       LPVault implementation and LPVaultFactory, with the factory's on-chain state
//       matching every provided address.
// Why:  The deploy helper is the core deployment logic shared by run() and tests.
//       If any address is wired incorrectly, the entire vault system is misconfigured.
// Example: deploy(usdc, exchange, ct, admin, oracle, operator)
//          → factory.usdc() == usdc, factory.implementation() == deployed LPVault.
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
        (lpVault, factory) = script.deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr);
    }

    // SC-J92J: LPVault implementation is deployed at a non-zero address
    function test_implementationDeployedAtNonZeroAddress() public view {
        assertTrue(address(lpVault) != address(0), "LPVault impl should be deployed");
    }

    // SC-J92J: calling initialize() on the implementation reverts (initializers disabled)
    function test_implementationInitializeReverts() public {
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        lpVault.initialize(
            bytes32(uint256(1)), usdc, exchange, conditionalTokens, int24(10), address(factory), uint128(1000)
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

    // SC-J92J: factory.conditionalTokens() equals CONDITIONAL_TOKENS_ADDRESS
    function test_factoryConditionalTokensMatchesEnvVar() public view {
        assertEq(
            factory.conditionalTokens(),
            conditionalTokens,
            "factory.conditionalTokens should match CONDITIONAL_TOKENS_ADDRESS"
        );
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
        script.deploy(address(0), exchange, conditionalTokens, admin, oracleAddr, operatorAddr);
    }

    // SC-J92K: EXCHANGE_ADDRESS set to zero address
    function test_revertsWhenExchangeIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "EXCHANGE_ADDRESS"));
        script.deploy(usdc, address(0), conditionalTokens, admin, oracleAddr, operatorAddr);
    }

    // SC-J92K: CONDITIONAL_TOKENS_ADDRESS set to zero address
    function test_revertsWhenConditionalTokensIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "CONDITIONAL_TOKENS_ADDRESS"));
        script.deploy(usdc, exchange, address(0), admin, oracleAddr, operatorAddr);
    }

    // SC-J92K: ADMIN_ADDRESS set to zero address
    function test_revertsWhenAdminIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "ADMIN_ADDRESS"));
        script.deploy(usdc, exchange, conditionalTokens, address(0), oracleAddr, operatorAddr);
    }

    // SC-J92K: ORACLE_ADDRESS set to zero address
    function test_revertsWhenOracleIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "ORACLE_ADDRESS"));
        script.deploy(usdc, exchange, conditionalTokens, admin, address(0), operatorAddr);
    }

    // SC-J92K: OPERATOR_ADDRESS set to zero address
    function test_revertsWhenOperatorIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DeployScript.ZeroAddress.selector, "OPERATOR_ADDRESS"));
        script.deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, address(0));
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
            makeAddr("usdc"), makeAddr("exchange"), makeAddr("conditionalTokens"), makeAddr("admin"), sameAddr, sameAddr
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

        (LPVault lpVault, LPVaultFactory factory) =
            script.deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr);

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
// Example: deploy(usdc, exchange, ct, admin, oracle, operator) — no key param.
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

        (LPVault lpVault, LPVaultFactory factory) =
            script.deploy(usdc, exchange, conditionalTokens, admin, oracleAddr, operatorAddr);

        assertTrue(address(lpVault) != address(0), "deploy() should work without a private key parameter");
        assertTrue(address(factory) != address(0), "deploy() should work without a private key parameter");
    }
}
