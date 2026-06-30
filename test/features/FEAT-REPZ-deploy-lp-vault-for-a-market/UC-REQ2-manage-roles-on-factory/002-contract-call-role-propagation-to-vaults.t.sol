// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ2: Manage Roles on Factory
// SLICE-002: role-propagation-to-vaults

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockConditionalTokens {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// SC-FKD4: Operator rotation propagates to existing vaults
// What: When admin rotates operators on the factory (removeOperator old,
//       addOperator new), existing vaults immediately reject the old
//       operator and accept the new one for operator-gated functions.
// Why:  With vault modifiers delegating to factory storage, a single
//       factory rotation call propagates to every deployed vault without
//       needing per-vault transactions. This is the core security property
//       that makes key rotation operationally viable.
// Example: factory has operator A, vault V deployed → admin removes A,
//          adds B → A calling notifyFees on V reverts, B succeeds.
// ──────────────────────────────────────────────
contract OperatorRotationPropagationTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorA = makeAddr("operatorA");
    address operatorB = makeAddr("operatorB");

    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorA
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // SC-FKD4: old operator A is rejected after removal from factory
    function test_oldOperatorRejectedAfterRotation() public {
        // Remove operator A from factory
        vm.prank(admin);
        factory.removeOperator(operatorA);

        // Operator A calling an operator-gated function on vault should revert
        vm.prank(operatorA);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);
    }

    // SC-FKD4: new operator B is accepted after addition to factory
    function test_newOperatorAcceptedAfterRotation() public {
        // Add operator B to factory
        vm.prank(admin);
        factory.addOperator(operatorB);

        // Operator B calling an operator-gated function on vault should succeed.
        // notifyFees requires activeLiquidity > 0 to succeed fully, but the
        // access control check (onlyOperator) runs first. If we get past the
        // operator check, we'll hit NoActiveLiquidity — which proves B was accepted.
        vm.prank(operatorB);
        vm.expectRevert(LPVault.NoActiveLiquidity.selector);
        vault.notifyFees(100);
    }

    // SC-FKD4: full rotation cycle — remove A, add B, verify both
    function test_fullRotationCycleVerifiesBothDirections() public {
        // Rotate: remove A, add B
        vm.startPrank(admin);
        factory.removeOperator(operatorA);
        factory.addOperator(operatorB);
        vm.stopPrank();

        // Old operator A: rejected
        vm.prank(operatorA);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);

        // New operator B: accepted (hits NoActiveLiquidity, which is past the auth check)
        vm.prank(operatorB);
        vm.expectRevert(LPVault.NoActiveLiquidity.selector);
        vault.notifyFees(100);
    }

    // SC-FKD4: events emitted by factory during rotation
    function test_rotationEmitsFactoryEvents() public {
        vm.startPrank(admin);

        vm.expectEmit(true, true, false, false, address(factory));
        emit RemovedOperator(operatorA, admin);
        factory.removeOperator(operatorA);

        vm.expectEmit(true, true, false, false, address(factory));
        emit NewOperator(operatorB, admin);
        factory.addOperator(operatorB);

        vm.stopPrank();
    }
}

// ──────────────────────────────────────────────
// SC-FKD5: Oracle rotation propagates to existing vaults
// What: When admin calls setOracle(newOracle) on the factory, existing
//       vaults immediately reject the old oracle and accept the new one
//       for oracle-gated functions (e.g. setMinimumFirstLiquidity).
// Why:  Oracle key rotation is a critical security operation. Without
//       propagation, a compromised oracle key remains valid on every
//       deployed vault until each is individually wound down.
// Example: factory has oracle X, vault V deployed → admin sets oracle to Y
//          → X calling setMinimumFirstLiquidity on V reverts, Y succeeds.
// ──────────────────────────────────────────────
contract OracleRotationPropagationTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleX = makeAddr("oracleX");
    address oracleY = makeAddr("oracleY");
    address operatorAddr = makeAddr("operator");

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleX, operatorAddr
        );

        vm.prank(oracleX);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // SC-FKD5: old oracle X is rejected after rotation
    function test_oldOracleRejectedAfterRotation() public {
        // Rotate oracle on factory
        vm.prank(admin);
        factory.setOracle(oracleY);

        // Old oracle X calling setMinimumFirstLiquidity on vault should revert
        vm.prank(oracleX);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));
    }

    // SC-FKD5: new oracle Y is accepted and can update vault parameters
    function test_newOracleAcceptedAfterRotation() public {
        // Rotate oracle on factory
        vm.prank(admin);
        factory.setOracle(oracleY);

        // New oracle Y calling setMinimumFirstLiquidity on vault should succeed
        vm.prank(oracleY);
        vault.setMinimumFirstLiquidity(uint128(2000));

        assertEq(vault.minimumFirstLiquidity(), uint128(2000));
    }

    // SC-FKD5: MinimumFirstLiquidityUpdated event emitted after rotation
    function test_newOracleEmitsEventOnVault() public {
        // Rotate oracle
        vm.prank(admin);
        factory.setOracle(oracleY);

        // New oracle updates vault parameter
        vm.expectEmit(false, false, false, true, address(vault));
        emit MinimumFirstLiquidityUpdated(uint128(1000), uint128(3000));

        vm.prank(oracleY);
        vault.setMinimumFirstLiquidity(uint128(3000));
    }

    // SC-FKD5: full oracle rotation — verify both old and new in one test
    function test_fullOracleRotationVerifiesBothDirections() public {
        // Rotate oracle X → Y
        vm.prank(admin);
        factory.setOracle(oracleY);

        // Old oracle X: rejected
        vm.prank(oracleX);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));

        // New oracle Y: accepted
        vm.prank(oracleY);
        vault.setMinimumFirstLiquidity(uint128(2000));
        assertEq(vault.minimumFirstLiquidity(), uint128(2000));
    }
}
