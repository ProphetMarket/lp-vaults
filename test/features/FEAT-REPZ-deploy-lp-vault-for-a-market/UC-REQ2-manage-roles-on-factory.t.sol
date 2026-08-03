// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ2: Manage Roles on Factory
// Integration tests for every scenario in this use case.
// Covers: SC-REQB, SC-REQC, SC-REQD, SC-REQE, SC-REQF, SC-REQG, SC-REQH, SC-FKD4, SC-FKD5

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ── Mocks ─────────────────────────────────────
contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ── Shared fixtures ───────────────────────────
/// @dev Shared base for all role-management tests. Deploys the factory
///      with known admin/oracle/operator addresses so every scenario
///      starts from the same registry state.
///      Events are re-declared here because Solidity 0.8.20 does not
///      support ContractName.EventName emit syntax.
contract RoleManagementBase is Test {
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    function setUp() public virtual {
        LPVault impl = new LPVault();
        factory = new LPVaultFactory(
            address(impl), makeAddr("usdc"), makeAddr("exchange"), makeAddr("ct"), admin, oracleAddr, operatorAddr
        );
    }
}

// SC-REQB: Add operator successfully
// What: Admin can register a new operator address via addOperator, and the
//       registry reflects the change with the correct event emitted.
// Why:  Operators execute transactional functions (mintPositionFor, notifyFees,
//       updateTick). If addOperator doesn't work, no new operator wallets can
//       be onboarded after factory deployment.
// Example: addOperator(0xNEW) where 0xNEW != oracle
//          → operators[0xNEW] == 1, NewOperator(0xNEW, admin) emitted.
contract AddOperatorSuccessTest is RoleManagementBase {
    // SC-REQB: operators mapping updated
    function test_addOperatorRegistersAddress() public {
        address newOp = makeAddr("newOperator");

        // Admin adds a new operator that is not the oracle
        vm.prank(admin);
        factory.addOperator(newOp);

        // Verify the operator is registered in the mapping
        assertEq(factory.operators(newOp), 1, "new operator should be registered with value 1");
    }

    // SC-REQB: NewOperator event emitted
    function test_addOperatorEmitsEvent() public {
        address newOp = makeAddr("newOperator");

        // Expect the NewOperator event with the new operator and admin as caller
        vm.expectEmit(true, true, false, true);
        emit NewOperator(newOp, admin);

        vm.prank(admin);
        factory.addOperator(newOp);
    }
}

// SC-REQC: Add operator reverts when address is current oracle
// What: addOperator rejects addresses that are the current oracle, enforcing
//       the invariant that no address can be both oracle and operator.
// Why:  NFR-RER1 mandates that oracle and operator are separate accounts.
//       Compromise of one must not unlock the other's powers.
// Example: addOperator(oracleAddress) → revert RoleSeparation.
contract AddOperatorRoleSeparationTest is RoleManagementBase {
    // SC-REQC: reverts with RoleSeparation
    function test_revertsWhenAddingOracleAsOperator() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.RoleSeparation.selector);
        factory.addOperator(oracleAddr);
    }
}

// SC-REQD: Remove operator successfully
// What: Admin can deregister an existing operator via removeOperator, setting
//       their mapping entry to 0 and emitting the removal event.
// Why:  Operator keys can be compromised or rotated. If removeOperator doesn't
//       work, a compromised operator retains transactional powers indefinitely.
// Example: removeOperator(existingOperator) → operators[existingOperator] == 0,
//          RemovedOperator(existingOperator, admin) emitted.
contract RemoveOperatorTest is RoleManagementBase {
    // SC-REQD: operators mapping cleared
    function test_removeOperatorClearsMapping() public {
        // operatorAddr was set in constructor — confirm before removal
        assertEq(factory.operators(operatorAddr), 1, "operator should start registered");

        vm.prank(admin);
        factory.removeOperator(operatorAddr);

        // Mapping entry should now be 0
        assertEq(factory.operators(operatorAddr), 0, "operator should be deregistered after removal");
    }

    // SC-REQD: RemovedOperator event emitted
    function test_removeOperatorEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RemovedOperator(operatorAddr, admin);

        vm.prank(admin);
        factory.removeOperator(operatorAddr);
    }
}

// SC-REQE: Set oracle successfully
// What: Admin can update the oracle address via setOracle when the new address
//       is not a current operator.
// Why:  The oracle controls vault lifecycle (createVault, startWindDown).
//       Rotating the oracle wallet is a standard operational procedure.
// Example: setOracle(newOracle) where newOracle is not an operator
//          → oracle == newOracle.
contract SetOracleSuccessTest is RoleManagementBase {
    // SC-REQE: oracle updated
    function test_setOracleUpdatesAddress() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(admin);
        factory.setOracle(newOracle);

        // Oracle storage should reflect the new address
        assertEq(factory.oracle(), newOracle, "oracle should be updated to new address");
    }
}

// SC-REQF: Set oracle reverts when address is current operator
// What: setOracle rejects addresses that are currently registered operators,
//       enforcing role separation.
// Why:  Same invariant as SC-REQC — oracle and operator cannot be the same
//       address (NFR-RER1).
// Example: setOracle(operatorAddress) → revert RoleSeparation.
contract SetOracleRoleSeparationTest is RoleManagementBase {
    // SC-REQF: reverts with RoleSeparation
    function test_revertsWhenSettingOperatorAsOracle() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.RoleSeparation.selector);
        factory.setOracle(operatorAddr);
    }
}

// SC-REQG: Two-step admin transfer
// What: Admin initiates a transfer via transferAdmin (stores pendingAdmin),
//       and the proposed admin completes it via acceptAdmin (grants the role,
//       increments adminCount, clears pendingAdmin). Both steps emit events.
// Why:  Two-step transfer prevents accidental admin loss from typos or wrong
//       addresses. The new admin must prove key ownership by calling acceptAdmin.
// Example: transferAdmin(0xNEW) → pendingAdmin == 0xNEW, admins[0xNEW] == 0;
//          acceptAdmin() from 0xNEW → admins[0xNEW] == 1, adminCount++,
//          pendingAdmin == address(0).
contract TwoStepAdminTransferTest is RoleManagementBase {
    address proposedAdmin = makeAddr("proposedAdmin");

    // SC-REQG: transferAdmin sets pendingAdmin
    function test_transferAdminSetsPendingAdmin() public {
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        assertEq(factory.pendingAdmin(), proposedAdmin, "pendingAdmin should be set to proposed address");
    }

    // SC-REQG: transferAdmin does not grant role yet
    function test_transferAdminDoesNotGrantRole() public {
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        // The proposed admin should NOT have the admin role until acceptAdmin is called
        assertEq(factory.admins(proposedAdmin), 0, "proposed admin should not have admin role yet");
    }

    // SC-REQG: transferAdmin emits AdminTransferProposed
    function test_transferAdminEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit AdminTransferProposed(admin, proposedAdmin);

        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);
    }

    // SC-REQG: acceptAdmin grants role
    function test_acceptAdminGrantsRole() public {
        // Step 1: propose
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        // Step 2: accept
        vm.prank(proposedAdmin);
        factory.acceptAdmin();

        assertEq(factory.admins(proposedAdmin), 1, "new admin should have admin role after accepting");
    }

    // SC-REQG: acceptAdmin increments adminCount
    function test_acceptAdminIncrementsAdminCount() public {
        uint256 countBefore = factory.adminCount();

        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        vm.prank(proposedAdmin);
        factory.acceptAdmin();

        // adminCount should increase by exactly 1 (was 1, now 2)
        assertEq(factory.adminCount(), countBefore + 1, "adminCount should increment by 1");
    }

    // SC-REQG: acceptAdmin clears pendingAdmin
    function test_acceptAdminClearsPendingAdmin() public {
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        vm.prank(proposedAdmin);
        factory.acceptAdmin();

        assertEq(factory.pendingAdmin(), address(0), "pendingAdmin should be cleared after acceptance");
    }

    // SC-REQG: acceptAdmin emits NewAdmin
    function test_acceptAdminEmitsEvent() public {
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);

        vm.expectEmit(true, true, false, true);
        emit NewAdmin(proposedAdmin, proposedAdmin);

        vm.prank(proposedAdmin);
        factory.acceptAdmin();
    }
}

// SC-REQH: Non-admin caller reverts on all role management functions
// What: Any caller without the Admin role (operator, oracle, random address)
//       is rejected by the onlyAdmin modifier on every role management function.
// Why:  Admin is registry-only. If non-admins could call role management
//       functions, the entire trust model collapses — a compromised operator
//       could elevate itself or replace the oracle.
// Example: operator calls addOperator(addr) → revert NotAdmin.
contract NonAdminRevertsTest is RoleManagementBase {
    // SC-REQH: addOperator reverts for non-admin
    function test_addOperatorRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.addOperator(makeAddr("x"));
    }

    // SC-REQH: removeOperator reverts for non-admin
    function test_removeOperatorRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.removeOperator(operatorAddr);
    }

    // SC-REQH: setOracle reverts for non-admin
    function test_setOracleRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.setOracle(makeAddr("x"));
    }

    // SC-REQH: transferAdmin reverts for non-admin
    function test_transferAdminRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.transferAdmin(makeAddr("x"));
    }
}

// FR-REQX: transferAdmin reverts when proposed address is zero
// What: transferAdmin rejects address(0) as a proposed admin to prevent
//       accidentally setting pendingAdmin to a black-hole address.
// Why:  If address(0) could be proposed and then someone calls acceptAdmin()
//       from address(0) (impossible in practice but defensive guard),
//       the admin role would be permanently lost. Cheap up-front check.
// Example: transferAdmin(address(0)) → revert ZeroAddress.
contract TransferAdminZeroAddressTest is RoleManagementBase {
    // FR-REQX: reverts with ZeroAddress when newAdmin is address(0)
    function test_revertsWhenProposingZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.ZeroAddress.selector);
        factory.transferAdmin(address(0));
    }
}

// FR-REQX: transferAdmin reverts when proposed address is already an admin
// What: transferAdmin rejects an address that already holds the admin role,
//       avoiding a no-op transfer that would still emit AdminTransferProposed
//       and overwrite pendingAdmin with a meaningless value.
// Why:  Proposing an existing admin is almost always a mistake — either a
//       typo or stale config. Failing fast gives operators a clear signal
//       instead of a silently-no-op transfer that could mask the real intent.
// Example: transferAdmin(existingAdmin) → revert AlreadyAdmin.
contract TransferAdminAlreadyAdminTest is RoleManagementBase {
    // FR-REQX: reverts with AlreadyAdmin when newAdmin is already an admin
    function test_revertsWhenProposingExistingAdmin() public {
        // `admin` is the only admin set during constructor — propose it again
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.AlreadyAdmin.selector);
        factory.transferAdmin(admin);
    }
}

// FR-REQY: acceptAdmin reverts when caller is not the pending admin
// What: acceptAdmin only completes the two-step transfer when invoked by the
//       address stored in pendingAdmin. Any other caller — even the current
//       admin or a stranger — is rejected with NotPendingAdmin.
// Why:  Without this guard, the second step of the two-step transfer collapses
//       into a one-step grab where anyone can claim admin. Pairs with
//       transferAdmin to enforce the proof-of-key-ownership flow.
// Example: nobody calls acceptAdmin() with no transfer pending → revert NotPendingAdmin.
contract AcceptAdminNotPendingAdminTest is RoleManagementBase {
    // FR-REQY: reverts when caller is not the pending admin (no transfer pending)
    function test_revertsWhenCallerIsNotPendingAdmin() public {
        // pendingAdmin defaults to address(0) — any non-zero caller mismatches
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
    }

    // FR-REQY: reverts when wrong caller invokes after a transfer was proposed
    function test_revertsWhenWrongCallerAfterTransferProposed() public {
        // Admin proposes a specific new admin
        address proposed = makeAddr("proposedAdmin");
        vm.prank(admin);
        factory.transferAdmin(proposed);

        // A different address tries to claim — must be rejected
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
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

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorA
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleX, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleX);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
