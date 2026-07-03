// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-KX5O: Schedule and Apply Implementation Upgrade
// SLICE-001: schedule-apply-cancel-impl-upgrade

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// Minimal mocks — only the methods LPVault.initialize() calls are included.
// This test never mints, transfers, or reads balances, so the full ERC-20
// interface would be dead code.

contract MockERC20 {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockConditionalTokens {
    function setApprovalForAll(address, bool) external {}
}

// ──────────────────────────────────────────────
// Base test contract for implementation upgrade scenarios.
// Deploys factory with an initial LPVault implementation and provides
// helpers for scheduling, warping past timelock, and deploying a
// second implementation for upgrade tests.
// ──────────────────────────────────────────────
contract ImplUpgradeTestBase is Test {
    LPVaultFactory factory;
    LPVault implV1;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant TIMELOCK = 7 days;

    event ImplementationScheduled(address indexed newImpl, uint256 unlockAt);
    event ImplementationApplied(address indexed newImpl, uint256 version);
    event ImplementationCancelled(address indexed cancelledImpl);

    function setUp() public virtual {
        implV1 = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(implV1), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    function _deployNewImpl() internal returns (address) {
        return address(new LPVault());
    }

    function _scheduleAndWarp(address newImpl) internal {
        vm.prank(admin);
        factory.scheduleImplementation(newImpl);
        vm.warp(block.timestamp + TIMELOCK);
    }
}

// ──────────────────────────────────────────────
// SC-KX5P: Admin schedules a new implementation
// What: When Admin calls scheduleImplementation(newImpl), the factory stores
//       the pending address and sets unlockAt 7 days out. The active pointer
//       and version counter are unchanged.
// Why:  The schedule step records intent without immediate effect. Getting
//       the pending state or unlock timestamp wrong would break the entire
//       two-step flow.
// ──────────────────────────────────────────────
contract ImplUpgradeScheduleTest is ImplUpgradeTestBase {
    // SC-KX5P: pendingImplementation set to new address
    function test_pendingImplementationSet() public {
        address newImpl = _deployNewImpl();

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        assertEq(factory.pendingImplementation(), newImpl, "pendingImplementation should match");
    }

    // SC-KX5P: unlockAt set to block.timestamp + 7 days
    function test_unlockAtSet() public {
        address newImpl = _deployNewImpl();
        uint256 expectedUnlock = block.timestamp + TIMELOCK;

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        assertEq(factory.implementationUnlockAt(), expectedUnlock, "unlockAt should be now + 7 days");
    }

    // SC-KX5P: ImplementationScheduled event emitted
    function test_emitsScheduledEvent() public {
        address newImpl = _deployNewImpl();
        uint256 expectedUnlock = block.timestamp + TIMELOCK;

        vm.expectEmit(true, false, false, true, address(factory));
        emit ImplementationScheduled(newImpl, expectedUnlock);

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);
    }

    // SC-KX5P: implementation unchanged after schedule
    function test_implementationUnchanged() public {
        address implBefore = factory.implementation();
        address newImpl = _deployNewImpl();

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        assertEq(factory.implementation(), implBefore, "implementation should not change on schedule");
    }

    // SC-KX5P: implementationVersion unchanged after schedule
    function test_versionUnchanged() public {
        uint256 versionBefore = factory.implementationVersion();
        address newImpl = _deployNewImpl();

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        assertEq(factory.implementationVersion(), versionBefore, "version should not change on schedule");
    }
}

// ──────────────────────────────────────────────
// SC-KX5Q: Admin applies after timelock
// What: After 7 days, applyImplementation() updates the active pointer,
//       increments the version counter, and clears pending state.
// Why:  This is the commit step. All four state changes (impl, version,
//       pendingImpl, unlockAt) must happen atomically.
// Example: schedule newImpl, warp 7 days, apply → impl = newImpl, version = 2.
// ──────────────────────────────────────────────
contract ImplUpgradeApplyTest is ImplUpgradeTestBase {
    // SC-KX5Q: implementation updated to pending address
    function test_implementationUpdated() public {
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);

        vm.prank(admin);
        factory.applyImplementation();

        assertEq(factory.implementation(), newImpl, "implementation should be updated");
    }

    // SC-KX5Q: implementationVersion incremented by 1
    function test_versionIncremented() public {
        uint256 versionBefore = factory.implementationVersion();
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);

        vm.prank(admin);
        factory.applyImplementation();

        assertEq(factory.implementationVersion(), versionBefore + 1, "version should increment by 1");
    }

    // SC-KX5Q: pending state cleared
    function test_pendingCleared() public {
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);

        vm.prank(admin);
        factory.applyImplementation();

        assertEq(factory.pendingImplementation(), address(0), "pendingImplementation should be cleared");
        assertEq(factory.implementationUnlockAt(), 0, "unlockAt should be cleared");
    }

    // SC-KX5Q: ImplementationApplied event emitted
    function test_emitsAppliedEvent() public {
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);

        // Version starts at 1, apply increments to 2
        vm.expectEmit(true, false, false, true, address(factory));
        emit ImplementationApplied(newImpl, 2);

        vm.prank(admin);
        factory.applyImplementation();
    }
}

// ──────────────────────────────────────────────
// SC-KX5R: New vault uses updated implementation and version
// What: After applying an upgrade, createVault clones the new implementation
//       and the vault stores the factory's current version counter.
// Why:  End-to-end proof that the upgrade takes effect for new vaults.
//       Existing vaults must remain on their original version.
// ──────────────────────────────────────────────
contract ImplUpgradeNewVaultTest is ImplUpgradeTestBase {
    // SC-KX5R: new vault's implementationVersion matches factory counter
    function test_newVaultHasUpdatedVersion() public {
        // Create a vault at version 1 (pre-upgrade)
        vm.prank(oracleAddr);
        address vaultV1 = factory.createVault(bytes32(uint256(1)), int24(10), uint128(1e18));

        // Upgrade implementation to version 2
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);
        vm.prank(admin);
        factory.applyImplementation();

        // Create a vault at version 2 (post-upgrade)
        vm.prank(oracleAddr);
        address vaultV2 = factory.createVault(bytes32(uint256(2)), int24(10), uint128(1e18));

        assertEq(LPVault(vaultV2).implementationVersion(), 2, "new vault should have version 2");
        assertEq(LPVault(vaultV1).implementationVersion(), 1, "old vault should stay at version 1");
    }

    // SC-KX5R: old vault's version unchanged after upgrade
    function test_oldVaultVersionUnchanged() public {
        // Create vault before upgrade
        vm.prank(oracleAddr);
        address vaultV1 = factory.createVault(bytes32(uint256(1)), int24(10), uint128(1e18));
        uint256 oldVersion = LPVault(vaultV1).implementationVersion();

        // Perform upgrade
        address newImpl = _deployNewImpl();
        _scheduleAndWarp(newImpl);
        vm.prank(admin);
        factory.applyImplementation();

        // Old vault's version is unchanged
        assertEq(LPVault(vaultV1).implementationVersion(), oldVersion, "old vault version must not change");
    }
}

// ──────────────────────────────────────────────
// SC-KX5S: Admin cancels pending schedule
// What: cancelScheduledImplementation() clears the pending state without
//       touching the active implementation.
// Why:  The escape hatch for aborting a bad upgrade before timelock expires.
// ──────────────────────────────────────────────
contract ImplUpgradeCancelTest is ImplUpgradeTestBase {
    // SC-KX5S: pending state cleared after cancel
    function test_pendingCleared() public {
        address newImpl = _deployNewImpl();
        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        vm.prank(admin);
        factory.cancelScheduledImplementation();

        assertEq(factory.pendingImplementation(), address(0), "pending should be cleared");
        assertEq(factory.implementationUnlockAt(), 0, "unlockAt should be cleared");
    }

    // SC-KX5S: implementation unchanged after cancel
    function test_implementationUnchanged() public {
        address implBefore = factory.implementation();
        address newImpl = _deployNewImpl();

        vm.prank(admin);
        factory.scheduleImplementation(newImpl);
        vm.prank(admin);
        factory.cancelScheduledImplementation();

        assertEq(factory.implementation(), implBefore, "implementation unchanged after cancel");
    }

    // SC-KX5S: ImplementationCancelled event emitted
    function test_emitsCancelledEvent() public {
        address newImpl = _deployNewImpl();
        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        vm.expectEmit(true, false, false, false, address(factory));
        emit ImplementationCancelled(newImpl);

        vm.prank(admin);
        factory.cancelScheduledImplementation();
    }
}

// ──────────────────────────────────────────────
// SC-KX5T: Apply reverts before timelock
// What: applyImplementation() reverts if block.timestamp < unlockAt.
// Why:  The 7-day window gives stakeholders time to review the scheduled
//       implementation. Bypassing it defeats the purpose.
// ──────────────────────────────────────────────
contract ImplUpgradeEarlyApplyTest is ImplUpgradeTestBase {
    // SC-KX5T: reverts with TimelockNotElapsed
    function test_revertsBeforeTimelock() public {
        address newImpl = _deployNewImpl();
        vm.prank(admin);
        factory.scheduleImplementation(newImpl);

        // Warp to 1 second before unlock
        vm.warp(block.timestamp + TIMELOCK - 1);

        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.TimelockNotElapsed.selector);
        factory.applyImplementation();
    }
}

// ──────────────────────────────────────────────
// SC-KX5U: Revert when no pending schedule
// What: apply and cancel both revert when no schedule is pending.
// Why:  Applying or cancelling nothing is always a caller bug.
// ──────────────────────────────────────────────
contract ImplUpgradeNoPendingTest is ImplUpgradeTestBase {
    // SC-KX5U: apply reverts with NoPendingSchedule
    function test_applyRevertsNoPending() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.NoPendingSchedule.selector);
        factory.applyImplementation();
    }

    // SC-KX5U: cancel reverts with NoPendingSchedule
    function test_cancelRevertsNoPending() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.NoPendingSchedule.selector);
        factory.cancelScheduledImplementation();
    }
}

// ──────────────────────────────────────────────
// SC-KX5V: Revert on zero address
// What: scheduleImplementation(address(0)) reverts.
// Why:  Setting implementation to address(0) would brick all future vaults.
// ──────────────────────────────────────────────
contract ImplUpgradeZeroAddressTest is ImplUpgradeTestBase {
    // SC-KX5V: reverts with ZeroAddress
    function test_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.ZeroAddress.selector);
        factory.scheduleImplementation(address(0));
    }
}

// ──────────────────────────────────────────────
// SC-KX5W: Non-admin callers revert
// What: Operator and arbitrary addresses get NotAdmin on all three functions.
// Why:  Only Admins should control the implementation pointer.
// ──────────────────────────────────────────────
contract ImplUpgradeAccessControlTest is ImplUpgradeTestBase {
    // SC-KX5W: operator cannot schedule
    function test_operatorCannotSchedule() public {
        address newImpl = _deployNewImpl();
        vm.prank(operatorAddr);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.scheduleImplementation(newImpl);
    }

    // SC-KX5W: operator cannot apply
    function test_operatorCannotApply() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.applyImplementation();
    }

    // SC-KX5W: operator cannot cancel
    function test_operatorCannotCancel() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.cancelScheduledImplementation();
    }

    // SC-KX5W: arbitrary address cannot schedule
    function test_arbitraryCannotSchedule() public {
        address newImpl = _deployNewImpl();
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.scheduleImplementation(newImpl);
    }
}

// ──────────────────────────────────────────────
// SC-KX5P: Double-schedule guard
// What: scheduleImplementation reverts with ScheduleAlreadyPending
//       when a schedule is already active.
// Why:  Prevents overwriting a pending schedule without explicit cancel.
// ──────────────────────────────────────────────
contract ImplUpgradeDoubleScheduleTest is ImplUpgradeTestBase {
    function test_revertsOnDoubleSchedule() public {
        address impl1 = _deployNewImpl();
        address impl2 = _deployNewImpl();

        vm.prank(admin);
        factory.scheduleImplementation(impl1);

        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.ScheduleAlreadyPending.selector);
        factory.scheduleImplementation(impl2);
    }
}
