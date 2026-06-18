// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ2: Manage Roles on Factory
// SLICE-001: factory-role-management

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

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
            address(impl),
            makeAddr("usdc"),
            makeAddr("exchange"),
            makeAddr("ct"),
            admin,
            oracleAddr,
            operatorAddr
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
