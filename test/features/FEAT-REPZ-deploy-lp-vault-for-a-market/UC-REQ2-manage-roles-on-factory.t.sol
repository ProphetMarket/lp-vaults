// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ2: Manage Roles on Factory
// Integration tests for every scenario in this use case.
// Covers: SC-REQB, SC-REQC, SC-REQD, SC-REQE, SC-REQF, SC-REQG, SC-REQH, SC-FKD4, SC-FKD5,
//         SC-5UJF, SC-5UJG, SC-5UJH, SC-5UJI, SC-5UJJ, SC-5UJK, SC-5UJL, SC-5UJM, SC-5UJN,
//         SC-5UJO, SC-5UJP, SC-5UJQ, SC-5UJR

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ── Shared fixtures ───────────────────────────
/// @dev Shared base for all role-management tests. Deploys the factory
///      with known admin/oracle/operator addresses so every scenario
///      starts from the same registry state.
///      Events are re-declared here because Solidity 0.8.20 does not
///      support ContractName.EventName emit syntax.
contract RoleManagementBase is LPVaultFixture {
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    function setUp() public virtual {
        LPVault impl = new LPVault();
        factory = _deployFactory(
            address(impl), makeAddr("usdc"), makeAddr("exchange"), makeAddr("ct"), admin, oracleAddr, operatorAddr
        );
    }
}

/// @dev Shared base for the propagation tests (SC-FKD4, SC-FKD5, SC-5UJL).
///      Deploys the factory against mock USDC and ConditionalTokens, then
///      creates one vault, so each test proves that a role change on the
///      factory reaches a vault that already exists.
///      Events are re-declared here for the same reason as above.
contract VaultPropagationBase is LPVaultFixture {
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);
    event TradingPaused(address indexed caller);

    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public virtual {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }
}

// SC-REQB: Add operator successfully
// What: Admin can register a new operator address via addOperator, and the
//       registry reflects the change with the correct event emitted.
// Why:  Operators execute transactional functions (mintPositionFor, heartbeat,
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

    // SC-REQH: addAdmin reverts for non-admin
    function test_addAdminRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.addAdmin(nobody);
    }

    // SC-REQH: removeAdmin reverts for non-admin
    function test_removeAdminRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.removeAdmin(admin);
    }

    // SC-REQH: renounceAdminRole reverts for non-admin
    function test_renounceAdminRoleRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.renounceAdminRole();
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

// SC-5UJR: Accept admin reverts when the caller already holds the admin role
// What: acceptAdmin rejects a pending admin that already holds the role,
//       because addAdmin granted it after transferAdmin proposed it.
// Why:  Without the check, adminCount counts one address twice. Later removals
//       can then reach adminCount == 1 with no admin left, and every onlyAdmin
//       function reverts forever.
// Example: transferAdmin(X), addAdmin(X) → acceptAdmin() from X
//          → revert AlreadyAdmin, adminCount stays 2, pendingAdmin stays X.
contract AcceptAdminAlreadyAdminTest is RoleManagementBase {
    address proposedAdmin = makeAddr("proposedAdmin");

    function setUp() public override {
        super.setUp();
        // Propose first, then add directly, so X is both admin and pendingAdmin
        vm.startPrank(admin);
        factory.transferAdmin(proposedAdmin);
        factory.addAdmin(proposedAdmin);
        vm.stopPrank();
    }

    // SC-5UJR: reverts with AlreadyAdmin
    function test_revertsWhenPendingAdminAlreadyHoldsRole() public {
        vm.prank(proposedAdmin);
        vm.expectRevert(LPVaultFactory.AlreadyAdmin.selector);
        factory.acceptAdmin();
    }

    // SC-5UJR: adminCount unchanged
    function test_adminCountUnchangedWhenExistingAdminAccepts() public {
        vm.prank(proposedAdmin);
        vm.expectRevert(LPVaultFactory.AlreadyAdmin.selector);
        factory.acceptAdmin();

        assertEq(factory.adminCount(), 2, "adminCount should not count the same admin twice");
    }

    // SC-5UJR: pendingAdmin kept
    function test_pendingAdminKeptWhenExistingAdminAccepts() public {
        vm.prank(proposedAdmin);
        vm.expectRevert(LPVaultFactory.AlreadyAdmin.selector);
        factory.acceptAdmin();

        assertEq(factory.pendingAdmin(), proposedAdmin, "a rejected accept should not clear pendingAdmin");
    }
}

// SC-5UJF: Add admin successfully
// What: Admin grants the admin role to a new address in one call via
//       addAdmin, and adminCount grows by one.
// Why:  The two-step transfer is the only other way to add an admin. A team
//       that already controls the new key needs a one-step add, as the
//       ctf-exchange Auth.sol reference provides.
// Example: addAdmin(0xNEW) → admins[0xNEW] == 1, adminCount == 2,
//          NewAdmin(0xNEW, admin) emitted.
contract AddAdminSuccessTest is RoleManagementBase {
    address newAdmin = makeAddr("newAdmin");

    // SC-5UJF: admins mapping updated
    function test_addAdminGrantsRole() public {
        vm.prank(admin);
        factory.addAdmin(newAdmin);

        assertEq(factory.admins(newAdmin), 1, "new admin should hold the admin role");
    }

    // SC-5UJF: adminCount incremented
    function test_addAdminIncrementsAdminCount() public {
        vm.prank(admin);
        factory.addAdmin(newAdmin);

        // adminCount starts at 1 from the constructor
        assertEq(factory.adminCount(), 2, "adminCount should grow from 1 to 2");
    }

    // SC-5UJF: NewAdmin event emitted
    function test_addAdminEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit NewAdmin(newAdmin, admin);

        vm.prank(admin);
        factory.addAdmin(newAdmin);
    }

    // SC-5UJF: no pendingAdmin change
    function test_addAdminLeavesPendingAdminUnchanged() public {
        vm.prank(admin);
        factory.addAdmin(newAdmin);

        assertEq(factory.pendingAdmin(), address(0), "addAdmin should not touch pendingAdmin");
    }
}

// SC-5UJG: Add admin reverts on the zero address
// What: addAdmin rejects address(0), which can never sign a transaction.
// Why:  An admin that can never act would still count in adminCount, so a
//       later removal could leave the registry with no admin that can act.
// Example: addAdmin(address(0)) → revert ZeroAddress.
contract AddAdminZeroAddressTest is RoleManagementBase {
    // SC-5UJG: reverts with ZeroAddress
    function test_revertsWhenAddingZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.ZeroAddress.selector);
        factory.addAdmin(address(0));
    }
}

// SC-5UJH: Add admin for an existing admin changes no role state
// What: addAdmin on an address that already holds the role leaves adminCount
//       unchanged, but still emits NewAdmin, as the Auth.sol reference does.
// Why:  adminCount must equal the number of admins. Counting one address twice
//       lets later removals reach adminCount == 1 with no admin left.
// Example: addAdmin(existingAdmin) → adminCount stays 1,
//          NewAdmin(existingAdmin, admin) emitted.
contract AddAdminExistingAdminTest is RoleManagementBase {
    // SC-5UJH: adminCount unchanged
    function test_addAdminForExistingAdminKeepsCount() public {
        vm.prank(admin);
        factory.addAdmin(admin);

        assertEq(factory.adminCount(), 1, "adminCount should not count an existing admin twice");
    }

    // SC-5UJH: NewAdmin still emitted
    function test_addAdminForExistingAdminStillEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit NewAdmin(admin, admin);

        vm.prank(admin);
        factory.addAdmin(admin);
    }
}

// SC-5UJI: Remove admin successfully
// What: Admin revokes another admin's role via removeAdmin, and adminCount
//       drops by one.
// Why:  Audit issue 6.8. Without removeAdmin, a compromised admin key keeps
//       full admin rights on the factory and on every vault forever.
// Example: admins {admin, secondAdmin} → removeAdmin(secondAdmin)
//          → admins[secondAdmin] == 0, adminCount == 1,
//          RemovedAdmin(secondAdmin, admin) emitted.
contract RemoveAdminSuccessTest is RoleManagementBase {
    address secondAdmin = makeAddr("secondAdmin");

    function setUp() public override {
        super.setUp();
        // Two admins, so the removal does not hit the last-admin guard
        vm.prank(admin);
        factory.addAdmin(secondAdmin);
    }

    // SC-5UJI: admins mapping cleared
    function test_removeAdminRevokesRole() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        assertEq(factory.admins(secondAdmin), 0, "removed admin should no longer hold the role");
    }

    // SC-5UJI: adminCount decremented
    function test_removeAdminDecrementsAdminCount() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        assertEq(factory.adminCount(), 1, "adminCount should drop from 2 to 1");
    }

    // SC-5UJI: RemovedAdmin event emitted
    function test_removeAdminEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RemovedAdmin(secondAdmin, admin);

        vm.prank(admin);
        factory.removeAdmin(secondAdmin);
    }

    // SC-5UJI: removed admin is rejected by onlyAdmin on the factory
    function test_removedAdminCannotCallAdminFunctions() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        vm.prank(secondAdmin);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.addOperator(makeAddr("x"));
    }
}

// SC-5UJJ: Remove admin reverts when it would remove the last admin
// What: removeAdmin refuses to revoke the only remaining admin.
// Why:  With zero admins every onlyAdmin function on the factory and on every
//       vault reverts forever, and no upgrade path exists to recover.
// Example: adminCount == 1 → removeAdmin(admin) → revert CannotRemoveLastAdmin.
contract RemoveAdminLastAdminTest is RoleManagementBase {
    // SC-5UJJ: reverts with CannotRemoveLastAdmin
    function test_revertsWhenRemovingLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.CannotRemoveLastAdmin.selector);
        factory.removeAdmin(admin);
    }
}

// SC-5UJK: Remove admin on an address that is not an admin changes no role state
// What: removeAdmin on a non-admin does not revert, even with one admin,
//       leaves adminCount unchanged, and still emits RemovedAdmin, as the
//       Auth.sol reference does.
// Why:  The last-admin guard applies only when a real admin loses the role.
// Example: adminCount == 1 → removeAdmin(nobody) → adminCount stays 1,
//          RemovedAdmin(nobody, admin) emitted.
contract RemoveAdminNonAdminTest is RoleManagementBase {
    // SC-5UJK: adminCount unchanged
    function test_removeAdminOnNonAdminKeepsCount() public {
        vm.prank(admin);
        factory.removeAdmin(nobody);

        assertEq(factory.adminCount(), 1, "removing a non-admin should not change adminCount");
    }

    // SC-5UJK: RemovedAdmin still emitted
    function test_removeAdminOnNonAdminStillEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RemovedAdmin(nobody, admin);

        vm.prank(admin);
        factory.removeAdmin(nobody);
    }
}

// SC-5UJL: Admin removal propagates to existing vaults
// What: After removeAdmin on the factory, an existing vault rejects the
//       removed admin and still accepts the remaining admin.
// Why:  Vaults read factory.admins() at call time. One factory call must
//       revoke a compromised key on every vault, with no vault transaction.
// Example: vault V exists, admins {admin, secondAdmin} → removeAdmin(secondAdmin)
//          → secondAdmin calling pauseTrading on V reverts NotAdmin,
//          admin calling pauseTrading on V succeeds.
contract AdminRemovalPropagationTest is VaultPropagationBase {
    address secondAdmin = makeAddr("secondAdmin");

    function setUp() public override {
        super.setUp();

        // secondAdmin holds the role while the vault already exists
        vm.prank(admin);
        factory.addAdmin(secondAdmin);
    }

    // SC-5UJL: removed admin is rejected by the vault
    function test_removedAdminRejectedByVault() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        vm.prank(secondAdmin);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.pauseTrading();
    }

    // SC-5UJL: remaining admin still pauses the vault
    function test_remainingAdminPausesVault() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        vm.prank(admin);
        vault.pauseTrading();

        assertTrue(vault.paused(), "vault should be paused by the remaining admin");
    }

    // SC-5UJL: vault emits TradingPaused for the remaining admin
    function test_remainingAdminPauseEmitsVaultEvent() public {
        vm.prank(admin);
        factory.removeAdmin(secondAdmin);

        vm.expectEmit(true, false, false, true, address(vault));
        emit TradingPaused(admin);

        vm.prank(admin);
        vault.pauseTrading();
    }

    // SC-5UJL: factory emits RemovedAdmin
    function test_removalEmitsFactoryEvent() public {
        vm.expectEmit(true, true, false, true, address(factory));
        emit RemovedAdmin(secondAdmin, admin);

        vm.prank(admin);
        factory.removeAdmin(secondAdmin);
    }
}

// SC-5UJM: Renounce admin role successfully
// What: An admin gives up its own role via renounceAdminRole, and adminCount
//       drops by one.
// Why:  A departing team member or a retired key must be able to leave the
//       registry without a second admin's transaction.
// Example: admins {admin, secondAdmin} → secondAdmin calls renounceAdminRole()
//          → admins[secondAdmin] == 0, adminCount == 1,
//          RemovedAdmin(secondAdmin, secondAdmin) emitted.
contract RenounceAdminRoleSuccessTest is RoleManagementBase {
    address secondAdmin = makeAddr("secondAdmin");

    function setUp() public override {
        super.setUp();
        // Two admins, so the renounce does not hit the last-admin guard
        vm.prank(admin);
        factory.addAdmin(secondAdmin);
    }

    // SC-5UJM: caller's admins entry cleared
    function test_renounceAdminRoleRevokesCallerRole() public {
        vm.prank(secondAdmin);
        factory.renounceAdminRole();

        assertEq(factory.admins(secondAdmin), 0, "renouncing admin should no longer hold the role");
    }

    // SC-5UJM: adminCount decremented
    function test_renounceAdminRoleDecrementsAdminCount() public {
        vm.prank(secondAdmin);
        factory.renounceAdminRole();

        assertEq(factory.adminCount(), 1, "adminCount should drop from 2 to 1");
    }

    // SC-5UJM: RemovedAdmin event emitted with the caller in both fields
    function test_renounceAdminRoleEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RemovedAdmin(secondAdmin, secondAdmin);

        vm.prank(secondAdmin);
        factory.renounceAdminRole();
    }
}

// SC-5UJN: Renounce admin role reverts for the last admin
// What: renounceAdminRole refuses when the caller is the only admin.
// Why:  Same guard as SC-5UJJ. The registry must never reach zero admins.
// Example: adminCount == 1 → admin calls renounceAdminRole()
//          → revert CannotRemoveLastAdmin.
contract RenounceAdminRoleLastAdminTest is RoleManagementBase {
    // SC-5UJN: reverts with CannotRemoveLastAdmin
    function test_revertsWhenLastAdminRenounces() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.CannotRemoveLastAdmin.selector);
        factory.renounceAdminRole();
    }
}

// SC-5UJO: Removing an admin withdraws its pending proposal
// What: When removeAdmin revokes an address that is also pendingAdmin, the
//       proposal is cleared, so the removed key cannot call acceptAdmin.
// Why:  Without the clear, transferAdmin(X) → addAdmin(X) → removeAdmin(X)
//       leaves pendingAdmin == X, and X regains the role through acceptAdmin.
//       Removal must be final.
// Example: transferAdmin(X), addAdmin(X) → removeAdmin(X)
//          → pendingAdmin == address(0), acceptAdmin() from X → revert NotPendingAdmin.
contract RemoveAdminClearsPendingProposalTest is RoleManagementBase {
    address proposedAdmin = makeAddr("proposedAdmin");

    function setUp() public override {
        super.setUp();
        // Propose first, then add directly, so X is both admin and pendingAdmin
        vm.startPrank(admin);
        factory.transferAdmin(proposedAdmin);
        factory.addAdmin(proposedAdmin);
        vm.stopPrank();
    }

    // SC-5UJO: pendingAdmin cleared by removeAdmin
    function test_removeAdminClearsPendingAdmin() public {
        vm.prank(admin);
        factory.removeAdmin(proposedAdmin);

        assertEq(factory.pendingAdmin(), address(0), "removeAdmin should withdraw the proposal to the removed address");
    }

    // SC-5UJO: removed admin cannot accept the old proposal
    function test_removedAdminCannotAcceptOldProposal() public {
        vm.prank(admin);
        factory.removeAdmin(proposedAdmin);

        vm.prank(proposedAdmin);
        vm.expectRevert(LPVaultFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
    }
}

// SC-5UJP: Removing a proposed-only address withdraws its proposal
// What: removeAdmin on an address that holds no role but is pendingAdmin
//       clears the proposal, and adminCount does not change.
// Why:  A team that calls removeAdmin on a suspect proposed key expects that key
//       to lose every path to the role.
// Example: transferAdmin(Y) → removeAdmin(Y) → pendingAdmin == address(0),
//          acceptAdmin() from Y → revert NotPendingAdmin, adminCount stays 1.
contract RemoveProposedOnlyAddressClearsProposalTest is RoleManagementBase {
    address proposedAdmin = makeAddr("proposedAdmin");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        factory.transferAdmin(proposedAdmin);
    }

    // SC-5UJP: pendingAdmin cleared
    function test_removeAdminOnProposedOnlyAddressClearsPendingAdmin() public {
        vm.prank(admin);
        factory.removeAdmin(proposedAdmin);

        assertEq(factory.pendingAdmin(), address(0), "removeAdmin should withdraw the proposal");
    }

    // SC-5UJP: proposed-only address cannot accept after removal
    function test_proposedOnlyAddressCannotAcceptAfterRemoval() public {
        vm.prank(admin);
        factory.removeAdmin(proposedAdmin);

        vm.prank(proposedAdmin);
        vm.expectRevert(LPVaultFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
    }

    // SC-5UJP: adminCount unchanged
    function test_removeAdminOnProposedOnlyAddressKeepsCount() public {
        vm.prank(admin);
        factory.removeAdmin(proposedAdmin);

        assertEq(factory.adminCount(), 1, "withdrawing a proposal should not change adminCount");
    }
}

// SC-5UJQ: Renouncing withdraws the caller's pending proposal
// What: When an admin that is also pendingAdmin calls renounceAdminRole, the
//       proposal is cleared, so it cannot accept the role back.
// Why:  A team can ask a suspect key to renounce. An attacker who holds that
//       key must not regain the role through an old proposal.
// Example: transferAdmin(X), addAdmin(X) → X calls renounceAdminRole()
//          → pendingAdmin == address(0), acceptAdmin() from X → revert NotPendingAdmin.
contract RenounceClearsPendingProposalTest is RoleManagementBase {
    address proposedAdmin = makeAddr("proposedAdmin");

    function setUp() public override {
        super.setUp();
        // Propose first, then add directly, so X is both admin and pendingAdmin
        vm.startPrank(admin);
        factory.transferAdmin(proposedAdmin);
        factory.addAdmin(proposedAdmin);
        vm.stopPrank();
    }

    // SC-5UJQ: pendingAdmin cleared by renounceAdminRole
    function test_renounceAdminRoleClearsPendingAdmin() public {
        vm.prank(proposedAdmin);
        factory.renounceAdminRole();

        assertEq(factory.pendingAdmin(), address(0), "renounceAdminRole should withdraw the proposal to the caller");
    }

    // SC-5UJQ: renounced admin cannot accept the old proposal
    function test_renouncedAdminCannotAcceptOldProposal() public {
        vm.prank(proposedAdmin);
        factory.renounceAdminRole();

        vm.prank(proposedAdmin);
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
// Example: factory has the initial operator, vault V deployed → admin removes
//          it, adds B → the initial operator calling heartbeat on V reverts,
//          B succeeds.
// ──────────────────────────────────────────────
contract OperatorRotationPropagationTest is VaultPropagationBase {
    address operatorB = makeAddr("operatorB");

    // SC-FKD4: the initial operator is rejected after removal from factory
    function test_oldOperatorRejectedAfterRotation() public {
        // Remove the initial operator from factory
        vm.prank(admin);
        factory.removeOperator(operatorAddr);

        // The initial operator calling an operator-gated function on vault should revert
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.heartbeat();
    }

    // SC-FKD4: new operator B is accepted after addition to factory
    function test_newOperatorAcceptedAfterRotation() public {
        // Add operator B to factory
        vm.prank(admin);
        factory.addOperator(operatorB);

        // Operator B calling an operator-gated function on vault succeeds.
        // heartbeat has no precondition beyond the operator check, so the
        // refreshed timestamp proves B was accepted.
        vm.warp(block.timestamp + 1);
        vm.prank(operatorB);
        vault.heartbeat();
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "B refreshed the heartbeat");
    }

    // SC-FKD4: full rotation cycle — remove the initial operator, add B, verify both
    function test_fullRotationCycleVerifiesBothDirections() public {
        // Rotate: remove the initial operator, add B
        vm.startPrank(admin);
        factory.removeOperator(operatorAddr);
        factory.addOperator(operatorB);
        vm.stopPrank();

        // Initial operator: rejected
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.heartbeat();

        // New operator B: accepted
        vm.warp(block.timestamp + 1);
        vm.prank(operatorB);
        vault.heartbeat();
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "B refreshed the heartbeat");
    }

    // SC-FKD4: events emitted by factory during rotation
    function test_rotationEmitsFactoryEvents() public {
        vm.startPrank(admin);

        vm.expectEmit(true, true, false, false, address(factory));
        emit RemovedOperator(operatorAddr, admin);
        factory.removeOperator(operatorAddr);

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
// Example: factory has the initial oracle, vault V deployed → admin sets oracle
//          to Y → the initial oracle calling setMinimumFirstLiquidity on V
//          reverts, Y succeeds.
// ──────────────────────────────────────────────
contract OracleRotationPropagationTest is VaultPropagationBase {
    address oracleY = makeAddr("oracleY");

    // SC-FKD5: the initial oracle is rejected after rotation
    function test_oldOracleRejectedAfterRotation() public {
        // Rotate oracle on factory
        vm.prank(admin);
        factory.setOracle(oracleY);

        // The initial oracle calling setMinimumFirstLiquidity on vault should revert
        vm.prank(oracleAddr);
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
        // Rotate oracle: initial → Y
        vm.prank(admin);
        factory.setOracle(oracleY);

        // Initial oracle: rejected
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));

        // New oracle Y: accepted
        vm.prank(oracleY);
        vault.setMinimumFirstLiquidity(uint128(2000));
        assertEq(vault.minimumFirstLiquidity(), uint128(2000));
    }
}
