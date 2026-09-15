// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-6HBN: Complete-Set Merge and Resolution Redemption
// UC-6HBO: Merge Complete Sets
// Integration tests for every scenario in this use case, against the real ConditionalTokens bytecode.
// Covers: SC-6HC9, SC-6HCA, SC-6HCB, SC-6HCC, SC-DFDV, SC-DFDW

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {KeeperFillFixture} from "../../fixtures/KeeperFillFixture.sol";
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
// What: With 100 YES and 60 NO in the vault and no token owed, mergeCompleteSets merges the
//       free pairs, min(100 − 0, 60 − 0) = 60 complete sets, through the ConditionalTokens
//       contract. The vault ends with 40 YES, 0 NO, and 60 more USDC. The caller receives
//       nothing, and no vault storage changes.
// Why:  Under the claim model a round-trip pair holds a claim's principal and its spread, and
//       a payout must turn it into USDC first. The merge takes no token a claim is owed.
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
// Why:  The merge takes no token a claim is owed, so no phase and no pause has a reason
//       to block it (decision C9). A heartbeat refresh from any wallet would let anyone postpone
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
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
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

// ──────────────────────────────────────────────
// SC-DFDV: The merge leaves every claim's band token in the vault
// What: Safe A holds the R9 example minted at 6000 and Safe B the same range minted at
//       5500. Drift-free fills moved the vault to 5700: the fall to 5500 bought 150 YES on
//       A's levels, and the rise to 5700 bought 60 NO on A's levels and 60 NO on B's. The
//       vault holds 150 YES and 120 NO, and the ledger owes 90 YES (A) and 60 NO (B). The
//       merge takes the free pairs, min(150 − 90, 120 − 60) = 60, and leaves 90 YES, 60 NO,
//       and above the base's donated B exactly the USDC the ledger owes. A second call
//       merges nothing.
// Why:  Finding CV-01 of audits/code-validation-round-1.md: a merge of min(150, 120) = 120
//       pairs would net A's YES against B's NO, pay both a cut token leg, and strand 60
//       USDC in the vault. The state is reached through the driver port, the mints and the
//       tick reports, and the fill fixture, never through a storage setter.
// Example: 150e6 YES, 120e6 NO, 90e6 and 60e6 owed → merge → 90e6 YES, 60e6 NO, +60e6 USDC.
// ──────────────────────────────────────────────
contract MergeLeavesOwedTokensTest is MergeCompleteSetsTestBase, KeeperFillFixture {
    uint256 constant LP_A_PK = 0xA11CE;
    uint256 constant LP_B_PK = 0xB0B;
    int24 constant LOWER = 5500;
    int24 constant UPPER = 6500;
    uint256 constant PRINCIPAL = 300e6;

    // The two claims' USDC after the fills, and what the ledger owes them (SC-DFDX)
    uint256 constant FILLS_LEFT = 460_951_500;
    uint256 constant USDC_OWED = 520_951_500;

    function setUp() public override {
        super.setUp();
        _moveTick(6000);
        _escrowAndMint(vault, operatorAddr, LP_A_PK, LOWER, UPPER, PRINCIPAL, keccak256("A"));
        _moveTick(5500);
        _fillMove(vault, exchangeAddr, 6000, 5500, 0);
        _escrowAndMint(vault, operatorAddr, LP_B_PK, LOWER, UPPER, PRINCIPAL, keccak256("B"));
        _moveTick(5700);
        _fillMove(vault, exchangeAddr, 5500, 5700, 0);
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    // SC-DFDV: the fills leave the two-claim state of the finding
    function test_theFillsLeaveTheTwoClaimState() public view {
        assertEq(_vaultYes(), 150e6, "150 YES bought on the fall");
        assertEq(_vaultNo(), 120e6, "60 NO bought on each claim's levels on the rise");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + FILLS_LEFT, "the USDC the fills left");
        assertEq(vault.totalYesOwed(), 90e6, "A's band owes 90 YES");
        assertEq(vault.totalNoOwed(), 60e6, "B's band owes 60 NO");
        assertEq(vault.totalUsdcOwed(), USDC_OWED, "the two claims' USDC");
    }

    // SC-DFDV: the merge takes 60 pairs and leaves exactly what the ledger owes
    function test_whenClaimsHoldBothTokensThenTheMergeTakesOnlyTheFreePairs() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(keeper, 60e6);

        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(_vaultYes(), 90e6, "A's 90 YES stay in the vault");
        assertEq(_vaultNo(), 60e6, "B's 60 NO stay in the vault");
        assertEq(mockUsdc.balanceOf(address(vault)) - VAULT_USDC, USDC_OWED, "above B, exactly the USDC owed");
        assertEq(mockUsdc.balanceOf(address(vault)) - VAULT_USDC, vault.totalUsdcOwed(), "the ledger agrees");
    }

    // SC-DFDV: a second call finds no free pair and merges nothing
    function test_whenTheFreePairsAreGoneThenASecondCallMergesNothing() public {
        vm.prank(keeper);
        vault.mergeCompleteSets();

        vm.recordLogs();
        vm.prank(keeper);
        vault.mergeCompleteSets();

        assertEq(vm.getRecordedLogs().length, 0, "no mergePositions call and no event on the second call");
        assertEq(_vaultYes(), 90e6, "the owed YES stay");
        assertEq(_vaultNo(), 60e6, "the owed NO stay");
    }
}

// ──────────────────────────────────────────────
// SC-DFDW: A donated token merges nothing when no pair is free
// What: The vault at 5700 holds one R9 position minted at 6000, so the ledger owes 90 YES,
//       and the vault holds exactly the 90 YES its fill bought and 0 NO. A stranger sends
//       50 NO through the receiver hook and calls mergeCompleteSets. The free pairs are
//       min(90 − 90, 50 − 0) = 0: no mergePositions call, no event, the vault still holds
//       90 YES and 50 NO, and the position's burn pays the 90 YES in full.
// Why:  Closes the griefing path of finding CV-01: under min(yes, no) a wallet could force
//       a merge of another claim's token by sending the complement.
// Example: 90e6 YES owed and held, 50e6 NO donated → merge → nothing; burn → 90e6 YES paid.
// ──────────────────────────────────────────────
contract DonationMergesNothingTest is MergeCompleteSetsTestBase, KeeperFillFixture {
    uint256 constant LP_A_PK = 0xA11CE;
    address safeA;
    uint256 positionId;
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        safeA = _safeOf(vm.addr(LP_A_PK));
        vm.prank(operatorAddr);
        vault.updateTick(6000);
        positionId = _escrowAndMint(vault, operatorAddr, LP_A_PK, 5500, 6500, 300e6, keccak256("A"));
        vm.prank(operatorAddr);
        vault.updateTick(5700);
        _fillMove(vault, exchangeAddr, 6000, 5700, 0);
        assertEq(_vaultYes(), 90e6, "precondition: the fill bought the 90 YES the band owes");
        assertEq(vault.totalYesOwed(), 90e6, "precondition: the ledger owes 90 YES");

        // The stranger splits 50 USDC into 50 YES and 50 NO and sends the NO to the vault
        _mintCompleteSets(mockUsdc, stranger, vault.conditionId(), 50e6);
        uint256 noId = vault.noTokenId();
        vm.prank(stranger);
        ctf.safeTransferFrom(stranger, address(vault), noId, 50e6, "");
    }

    // SC-DFDW: no free pair, so no merge call and no event
    function test_whenNoPairIsFreeThenADonatedTokenMergesNothing() public {
        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();

        assertEq(vm.getRecordedLogs().length, 0, "no mergePositions call and no CompleteSetsMerged event");
        assertEq(_vaultYes(), 90e6, "the owed YES stay");
        assertEq(_vaultNo(), 50e6, "the donated NO stay");
    }

    // SC-DFDW: the position's burn still pays its 90 YES in full
    function test_whenNoPairIsFreeThenTheBurnPaysTheBandInFull() public {
        vm.prank(stranger);
        vault.mergeCompleteSets();

        vm.prank(safeA);
        vault.burnPosition(positionId);

        assertEq(ctf.balanceOf(safeA, vault.yesTokenId()), 90e6, "the Safe receives the whole band");
        assertEq(_vaultYes(), 0, "no YES left in the vault");
        assertEq(_vaultNo(), 50e6, "the donation stays in the vault");
    }
}
