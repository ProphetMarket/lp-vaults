// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-6HBN: Complete-Set Merge and Resolution Redemption
// UC-6HBO: Merge Complete Sets
// Integration tests for every scenario in this use case, against the real ConditionalTokens bytecode.
// Covers: SC-6HC9, SC-6HCA, SC-6HCB, SC-6HCC

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {VaultStorage} from "../../fixtures/VaultStorage.sol";

// ──────────────────────────────────────────────
// Base test contract for complete-set merge scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, gives the
// vault B = 500e6 USDC, and funds it with outcome tokens the way fills would, through
// the shared _giveOutcomeTokens fixture.
// ──────────────────────────────────────────────
contract MergeCompleteSetsTestBase is LPVaultFixture {
    using stdStorage for StdStorage;

    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");
    address lp = makeAddr("lp");
    address keeper = makeAddr("keeper");

    bytes32 marketId = bytes32(uint256(1));

    // USDC the vault holds before any merge (B in the scenarios)
    uint256 constant VAULT_USDC = 500e6;

    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event PositionsMerge(
        address indexed stakeholder,
        address collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    function setUp() public virtual {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));

        mockUsdc.mint(address(vault), VAULT_USDC);
    }

    /// @dev Moves YES and NO tokens into the vault, as exchange fills would.
    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    function _vaultYes() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.yesTokenId());
    }

    function _vaultNo() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.noTokenId());
    }
}

// ──────────────────────────────────────────────
// SC-6HC9: Any wallet merges the vault's matched pairs into USDC
// What: With 100 YES and 60 NO in the vault, mergeCompleteSets merges min(100, 60) = 60
//       complete sets through the ConditionalTokens contract. The vault ends with 40 YES,
//       0 NO, and 60 more USDC. The caller receives nothing, and no vault storage changes.
// Why:  Under the claim model a pair holds a claim's principal and its spread, and a
//       payout must turn it into USDC first. One YES plus one NO always pays exactly
//       1 USDC, so the merge moves no value.
// Example: vault 100e6 YES, 60e6 NO, 500e6 USDC → keeper merges → 40e6 YES, 0 NO, 560e6 USDC.
// ──────────────────────────────────────────────
contract MergeMatchedPairsTest is MergeCompleteSetsTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(100e6, 60e6);
    }

    // SC-6HC9: the vault holds 40 YES, 0 NO, and B + 60 USDC after the merge
    function test_mergesMinimumOfBothBalancesIntoUsdc() public {
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(_vaultYes(), 40e6, "vault should keep the 40 unmatched YES");
        assertEq(_vaultNo(), 0, "vault should hold no NO after the merge");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 60e6, "vault should gain 60 USDC");
    }

    // SC-6HC9: the vault emits CompleteSetsMerged(caller, 60)
    function test_emitsCompleteSetsMergedWithCallerAndAmount() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(keeper, 60e6);

        vm.prank(keeper);
        vault.mergeCompleteSets();
    }

    // SC-6HC9: the ConditionalTokens contract emits PositionsMerge for the vault's condition and partition
    function test_conditionalTokensEmitsPositionsMerge() public {
        vm.expectEmit(true, true, true, true, address(ctf));
        emit PositionsMerge(
            address(vault), address(mockUsdc), bytes32(0), vault.conditionId(), _binaryPartition(), 60e6
        );

        vm.prank(keeper);
        vault.mergeCompleteSets();
    }

    // SC-6HC9: the caller's balances do not change
    function test_callerReceivesNothing() public {
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(mockUsdc.balanceOf(keeper), 0, "the caller must receive no USDC");
        assertEq(ctf.balanceOf(keeper, vault.yesTokenId()), 0, "the caller must receive no YES");
        assertEq(ctf.balanceOf(keeper, vault.noTokenId()), 0, "the caller must receive no NO");
    }

    // SC-6HC9: the merge writes no vault storage
    function test_mergeWritesNoVaultState() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(vault.phase(), 1, "phase must not change");
        assertFalse(vault.paused(), "paused must not change");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not change");
        assertEq(vault.nextPositionId(), 0, "nextPositionId must not change");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "the merge must not refresh the heartbeat");
    }
}

// ──────────────────────────────────────────────
// FR-6HC1: Any wallet can merge in Active phase
// What: The Operator, an LP, the Oracle, and an address with no role each merge the
//       vault's pairs. The function has no role check.
// Why:  The call can only turn the vault's own pairs into the vault's own USDC, so it
//       needs no trusted caller.
// Example: 10 pairs arrive before each call → each caller's merge adds 10 USDC to the vault.
// ──────────────────────────────────────────────
contract MergeOpenToAnyWalletTest is MergeCompleteSetsTestBase {
    // FR-6HC1: every role, and a wallet with no role, merges in Active phase
    function test_everyCallerMergesInActivePhase() public {
        address[4] memory callers = [operatorAddr, lp, oracleAddr, keeper];

        for (uint256 i = 0; i < callers.length; i++) {
            _fundVault(10e6, 10e6);
            uint256 usdcBefore = mockUsdc.balanceOf(address(vault));

            vm.prank(callers[i]);
            vault.mergeCompleteSets();

            assertEq(mockUsdc.balanceOf(address(vault)), usdcBefore + 10e6, "each caller's merge adds 10 USDC");
            assertEq(_vaultYes(), 0, "no YES left after each merge");
            assertEq(_vaultNo(), 0, "no NO left after each merge");
        }
    }
}

// ──────────────────────────────────────────────
// SC-6HCA: Nothing to merge changes nothing
// What: With 50 YES and 0 NO, or with no tokens at all, mergeCompleteSets computes
//       amount = 0 and returns. It does not revert, does not call mergePositions, and
//       emits no event.
// Why:  Every payout calls the internal merge first, where it must not revert. A
//       zero-amount mergePositions would still cost gas and emit an event.
// Example: vault 50e6 YES, 0 NO → merge → balances unchanged, zero logs.
// ──────────────────────────────────────────────
contract NothingToMergeTest is MergeCompleteSetsTestBase {
    // SC-6HCA: case A — YES without NO leaves every balance unchanged and emits nothing
    function test_yesWithoutNoChangesNothing() public {
        _fundVault(50e6, 0);

        vm.recordLogs();
        vm.prank(keeper);
        vault.mergeCompleteSets();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "no mergePositions call and no CompleteSetsMerged event");
        assertEq(_vaultYes(), 50e6, "YES balance must not change");
        assertEq(_vaultNo(), 0, "NO balance must not change");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC, "USDC balance must not change");
    }

    // SC-6HCA: the same holds with NO and no YES
    function test_noWithoutYesChangesNothing() public {
        _fundVault(0, 50e6);

        vm.recordLogs();
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(vm.getRecordedLogs().length, 0, "no mergePositions call and no CompleteSetsMerged event");
        assertEq(_vaultNo(), 50e6, "NO balance must not change");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC, "USDC balance must not change");
    }

    // SC-6HCA: case B — an empty vault leaves every balance unchanged and emits nothing
    function test_emptyVaultChangesNothing() public {
        vm.recordLogs();
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(vm.getRecordedLogs().length, 0, "no mergePositions call and no CompleteSetsMerged event");
        assertEq(_vaultYes(), 0, "YES balance must stay 0");
        assertEq(_vaultNo(), 0, "NO balance must stay 0");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC, "USDC balance must not change");
    }
}

// ──────────────────────────────────────────────
// SC-6HCB: Merge works for any wallet in WindDown, in Cancelled, and while paused,
//          without a heartbeat refresh
// What: With 10 YES and 10 NO in the vault, the Operator and a wallet with no role each
//       merge 10 pairs in WindDown phase, in the Cancelled phase, and while trading is
//       paused. lastOperatorActivityTimestamp keeps its value, also when the Operator calls.
// Why:  A merge moves no value, so no phase and no pause has a reason to block it
//       (decision C9). A heartbeat refresh from any wallet would let anyone postpone
//       emergencyCancelAll.
// Example: oracle starts wind-down, a day passes, operator merges → +10 USDC, timer unchanged.
// Setup:   The Cancelled case writes phase 3 through VaultStorage, because the merge reads
//          no other state and the emergency-cancel tests prove the real path to phase 3.
// ──────────────────────────────────────────────
contract MergeInEveryPhaseAndPausedTest is MergeCompleteSetsTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(10e6, 10e6);
    }

    function _mergeAndCheck(address caller) internal {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(caller, 10e6);

        vm.prank(caller);
        vault.mergeCompleteSets();

        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 10e6, "the merge should add 10 USDC");
        assertEq(_vaultYes(), 0, "no YES left after the merge");
        assertEq(_vaultNo(), 0, "no NO left after the merge");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "the merge must not refresh the heartbeat");
    }

    // SC-6HCB: case A — the Operator merges in WindDown and the heartbeat keeps its value
    function test_operatorMergesInWindDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();

        _mergeAndCheck(operatorAddr);
        assertEq(vault.phase(), 2, "phase stays WindDown");
    }

    // SC-6HCB: case A — a wallet with no role merges in WindDown
    function test_walletWithNoRoleMergesInWindDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();

        _mergeAndCheck(keeper);
        assertEq(vault.phase(), 2, "phase stays WindDown");
    }

    // SC-6HCB: case B — the Operator merges while trading is paused and the heartbeat keeps its value
    function test_operatorMergesWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();

        _mergeAndCheck(operatorAddr);
        assertTrue(vault.paused(), "trading stays paused");
    }

    // SC-6HCB: case B — a wallet with no role merges while trading is paused
    function test_walletWithNoRoleMergesWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();

        _mergeAndCheck(keeper);
        assertTrue(vault.paused(), "trading stays paused");
    }

    // SC-6HCB: case C — the Operator merges in the Cancelled phase and the heartbeat keeps its value
    function test_operatorMergesInCancelled() public {
        VaultStorage.setPhase(stdstore, address(vault), 3);

        _mergeAndCheck(operatorAddr);
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }

    // SC-6HCB: case C — a wallet with no role merges in the Cancelled phase
    function test_walletWithNoRoleMergesInCancelled() public {
        VaultStorage.setPhase(stdstore, address(vault), 3);

        _mergeAndCheck(keeper);
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-6HCC: Merge works after an emergency cancel
// What: In the Cancelled phase (3) reached through the real emergencyCancelAll, a wallet
//       merges the vault's 10 pairs, the vault gains 10 USDC, and the phase stays 3.
// Why:  Decision C9: the freeze changes only the phase, and every payout in a frozen
//       vault needs the merge first.
// Example: cancel after the 7-day silence, 10e6 YES and 10e6 NO → merge → +10e6 USDC.
// Setup:   A real position (1000 USDC over [0, 100)) lets the holder trigger the cancel.
// ──────────────────────────────────────────────
contract MergeAfterEmergencyCancelTest is MergeCompleteSetsTestBase {
    uint256 constant LP_PK = 0xA11CE;
    address safe;

    function setUp() public override {
        super.setUp();
        safe = _safeOf(vm.addr(LP_PK));
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("holder"));
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
        vm.prank(safe);
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        _fundVault(10e6, 10e6);
    }

    // SC-6HCC: the merge succeeds and the vault gains 10 USDC
    function test_mergeSucceedsAfterCancel() public {
        uint256 usdcBefore = mockUsdc.balanceOf(address(vault));

        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(keeper, 10e6);

        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(mockUsdc.balanceOf(address(vault)), usdcBefore + 10e6, "the merge should add 10 USDC");
        assertEq(_vaultYes(), 0, "no YES left after the merge");
        assertEq(_vaultNo(), 0, "no NO left after the merge");
    }

    // SC-6HCC: the phase stays Cancelled
    function test_phaseStaysCancelled() public {
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(vault.phase(), 3, "phase must stay Cancelled");
    }
}
