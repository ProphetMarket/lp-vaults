// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JAIK: Reclaim Deposit
// Integration tests for every scenario in this use case.
// Covers: SC-JAIL, SC-3Z9L, SC-45IG, SC-JAIN, SC-3ZA0, SC-JAIP, SC-9OYE, NFR-JAIW

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// ReentrantERC20: malicious ERC-20 that attempts to re-enter
// vault.reclaimDeposit during a transfer call. Used by the NFR-JAIW
// reentrancy test. The callback is wrapped in a low-level call so
// the outer transfer succeeds even when the reentrant call reverts.
// ──────────────────────────────────────────────
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentrantCalldata;
    bool public reentrancyAttempted;
    bool public reentrancyReverted;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function setReentrancyTarget(address _target, bytes calldata _calldata) external {
        target = _target;
        reentrantCalldata = _calldata;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // Attempt reentrancy on the first transfer only
        if (!reentrancyAttempted && target != address(0)) {
            reentrancyAttempted = true;
            (bool success,) = target.call(reentrantCalldata);
            reentrancyReverted = !success;
        }

        return true;
    }
}

// ──────────────────────────────────────────────
// Base test contract with shared setup for all reclaimDeposit scenarios.
// Deploys factory + vault and escrows one intent for the LP's Safe that the
// Operator never mints. The Safe reclaims it in one call.
// ──────────────────────────────────────────────
contract ReclaimDepositTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The LP's Safe: the recorded depositor, and the caller of reclaimDeposit.
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 intentId = keccak256("escrowed-intent");
    uint256 escrowAmount = 600;

    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        _fundSafe(mockUsdc, lp, address(vault), escrowAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(20), int24(80), escrowAmount, intentId, FAR_DEADLINE);
    }

    /// @dev Reads the escrow's recorded Safe and amount.
    function _escrowOf(bytes32 id) internal view returns (address recorded, uint96 amount) {
        (recorded, amount,) = vault.pendingDeposits(id);
    }
}

// ──────────────────────────────────────────────
// SC-JAIL: Successful reclaim in one call
// What: The recorded Safe calls reclaimDeposit(intentId) and receives the
//       escrowed amount in the same block, with no wait, no signature, and no
//       Operator involvement. The escrow is deleted, totalEscrowed falls, and
//       the intentId is marked used.
// Why:  The escrow record proves the deposit (ADR-3ZA1, ADR-9OYQ), so the
//       24-hour two-phase reclaim no longer exists. This is the escape hatch
//       that works exactly when the Operator does not.
// Example: escrow 600 for Safe S, S calls reclaimDeposit(X) → S +600.
// ──────────────────────────────────────────────
contract ReclaimOneCallSuccessTest is ReclaimDepositTestBase {
    // SC-JAIL: the Safe's USDC balance increases by the escrowed amount in one call
    function test_transfersEscrowToSafeInOneCall() public {
        uint256 before_ = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive the escrowed amount");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault should hold nothing after the refund");
    }

    // SC-JAIL: the intentId is permanently marked as used
    function test_marksIntentUsed() public {
        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
    }

    // SC-JAIL: the escrow is deleted and totalEscrowed falls by the amount
    function test_deletesEscrowAndReducesTotal() public {
        assertEq(vault.totalEscrowed(), escrowAmount, "precondition: 600 escrowed");

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        (address recorded, uint96 amount) = _escrowOf(intentId);
        assertEq(recorded, address(0), "escrow should be deleted");
        assertEq(amount, 0, "escrow amount should be deleted");
        assertEq(vault.totalEscrowed(), 0, "totalEscrowed should fall to 0");
    }

    // SC-JAIL: DepositReclaimed emitted with the recorded Safe and the recorded amount
    function test_emitsDepositReclaimed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, escrowAmount);

        vm.prank(lp);
        vault.reclaimDeposit(intentId);
    }

    // SC-JAIL: no position is created and the Operator silence timer does not move
    function test_createsNoPositionAndLeavesHeartbeatAlone() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertEq(vault.nextPositionId(), 0, "no position should be created");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reclaim is not Operator activity");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9L: Revert when nothing is escrowed for the intent
// What: reclaimDeposit for an intentId with no escrow reverts with
//       DepositNotEscrowed, whoever calls it.
// Why:  Audit issue 6.1 from the reclaim side: a caller who deposited
//       nothing gets nothing, whatever it signed.
// ──────────────────────────────────────────────
contract ReclaimNothingEscrowedTest is ReclaimDepositTestBase {
    // SC-3Z9L: the recorded Safe of another intent gets DepositNotEscrowed for an unknown intentId
    function test_revertsWhenNothingEscrowed() public {
        bytes32 unknown = keccak256("never-escrowed");

        vm.prank(lp);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.reclaimDeposit(unknown);
    }

    // SC-3Z9L: any other address gets the same error
    function test_revertsForAnyCaller() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.reclaimDeposit(keccak256("never-escrowed"));
    }
}

// ──────────────────────────────────────────────
// SC-45IG: Revert when the caller is not the recorded Safe
// What: Safe B, the owner key of A, and any other address get NotIntentOwner
//       when they call reclaimDeposit for A's escrow. A's escrow is untouched.
// Why:  The recorded Safe is the only ownership proof. intentIds are public
//       in the DepositEscrowed log, so without this check any address could
//       drain any pending deposit (FR-45IF, ADR-45IC).
// ──────────────────────────────────────────────
contract ReclaimNotRecordedSafeTest is ReclaimDepositTestBase {
    function _reclaimAs(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDeposit(intentId);
    }

    // SC-45IG: another Safe reverts
    function test_revertsForAnotherSafe() public {
        _reclaimAs(_safeOf(vm.addr(0xB0B)));
    }

    // SC-45IG: the owner key itself (not its Safe) reverts
    function test_revertsForTheOwnerKey() public {
        _reclaimAs(vm.addr(LP_PK));
    }

    // SC-45IG: an arbitrary address reverts
    function test_revertsForNobody() public {
        _reclaimAs(makeAddr("nobody"));
    }

    // SC-45IG: the Operator reverts too — the direct path is the Safe's alone
    function test_revertsForTheOperator() public {
        _reclaimAs(operatorAddr);
    }

    // SC-45IG: A's escrow stays untouched after a foreign attempt
    function test_escrowUntouchedAfterForeignAttempt() public {
        _reclaimAs(makeAddr("nobody"));

        (address recorded, uint96 amount) = _escrowOf(intentId);
        assertEq(recorded, lp, "escrow should still name the Safe");
        assertEq(amount, escrowAmount, "escrow amount should be untouched");
        assertFalse(vault.usedIntents(intentId), "intentId should stay unused");
    }
}

// ──────────────────────────────────────────────
// SC-JAIN: Revert when intent already fulfilled by mintPositionFor
// What: After the Operator mints the intent, the Safe's reclaimDeposit
//       reverts with IntentAlreadyUsed.
// Why:  A mint and a reclaim of one intentId are mutually exclusive through
//       the shared usedIntents mapping (ADR-JAIY). The mint also deleted the
//       escrow, so there is nothing left to pay.
// ──────────────────────────────────────────────
contract ReclaimIntentAlreadyFulfilledTest is ReclaimDepositTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), escrowAmount, intentId, FAR_DEADLINE);
    }

    // SC-JAIN: reclaim after the mint reverts, and reports the used intent, not the missing escrow
    function test_revertsWhenIntentAlreadyFulfilled() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp), 0, "no USDC should leave the vault");
    }
}

// ──────────────────────────────────────────────
// SC-3ZA0: Reclaim succeeds with no registered operators
// What: The Admin removes every Operator, and the Safe still reclaims its
//       escrow.
// Why:  Audit issue 6.13: the old reclaim needed a live Operator co-signature,
//       so removing that Operator stranded the deposit. The escrow record
//       replaces the co-signature (NFR-3Z9X).
// ──────────────────────────────────────────────
contract ReclaimWithNoOperatorsTest is ReclaimDepositTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
        assertEq(factory.operators(operatorAddr), 0, "precondition: no operator registered");
    }

    // SC-3ZA0: the refund succeeds with the operator set empty
    function test_reclaimSucceedsWithNoOperators() public {
        uint256 before_ = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its escrow");
        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
    }
}

// ──────────────────────────────────────────────
// SC-JAIP: Revert on replay (intentId already reclaimed)
// What: A second reclaimDeposit for the same intentId reverts with
//       IntentAlreadyUsed and pays nothing.
// Why:  Replay protection through the shared usedIntents mapping; the
//       deleted escrow means there is nothing to pay regardless.
// ──────────────────────────────────────────────
contract ReclaimReplayProtectionTest is ReclaimDepositTestBase {
    // SC-JAIP: a replayed reclaim reverts and moves no USDC
    function test_revertsOnReplayAfterSuccessfulReclaim() public {
        vm.prank(lp);
        vault.reclaimDeposit(intentId);
        uint256 afterFirst = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp), afterFirst, "no second payment");
    }
}

// ──────────────────────────────────────────────
// SC-9OYE: Reclaim works in every phase and while paused
// What: The Safe reclaims its escrow while the vault is paused, after the
//       Oracle started the wind-down, and after emergencyCancelAll set phase 3.
// Why:  Audit issue 6.7: the Cancelled phase must never lock a pending
//       deposit. The reclaim applies no phase check and no pause check
//       (FR-9OYO). R10 then changes only emergencyCancelAll.
// ──────────────────────────────────────────────
contract ReclaimInEveryPhaseTest is ReclaimDepositTestBase {
    function _assertReclaimPays() internal {
        uint256 before_ = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(intentId);
        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its escrow");
    }

    // SC-9OYE: paused
    function test_reclaimSucceedsWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();
        _assertReclaimPays();
    }

    // SC-9OYE: WindDown
    function test_reclaimSucceedsInWindDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();
        assertEq(vault.phase(), 2, "precondition: WindDown");
        _assertReclaimPays();
    }

    // SC-9OYE: Cancelled, after a position holder freezes the vault
    function test_reclaimSucceedsAfterEmergencyCancel() public {
        // A second, minted position gives someone the right to cancel; the escrow stays pending.
        // The mint's funding goes through _escrowAndMint, so the escrowed 600 stays in the vault.
        uint256 holderPk = 0xB0B;
        _escrowAndMint(vault, operatorAddr, holderPk, int24(0), int24(100), 1000, keccak256("holder"));
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vm.prank(_safeOf(vm.addr(holderPk)));
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        _assertReclaimPays();
    }
}

// ──────────────────────────────────────────────
// NFR-JAIW: nonReentrant on reclaimDeposit
// What: A token that re-enters reclaimDeposit during the refund transfer has
//       its inner call reverted by the reentrancy guard, and the outer refund
//       completes once.
// Why:  CLAUDE.md security checklist item 1: every external state-changing
//       function that transfers tokens carries nonReentrant. The record is
//       settled before the transfer, so even a successful re-entry would find
//       the intent used; the guard is the first line.
// ──────────────────────────────────────────────
contract ReclaimReentrancyTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    ReentrantERC20 reentrantUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    function setUp() public {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        reentrantUsdc = new ReentrantERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(reentrantUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));
    }

    // NFR-JAIW: the reentrant call reverts and the outer refund completes once
    function test_reentrancyDuringRefundIsBlocked() public {
        uint256 usdcAmount = 1000;
        bytes32 intentId = keccak256("reclaim-reentrant");

        // Escrow through the reentrant token
        reentrantUsdc.mint(lp, usdcAmount);
        vm.prank(lp);
        reentrantUsdc.approve(address(vault), usdcAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(20), int24(80), usdcAmount, intentId, FAR_DEADLINE);

        // Configure the reentrant token to call reclaimDeposit on the next transfer
        reentrantUsdc.setReentrancyTarget(
            address(vault), abi.encodeWithSelector(LPVault.reclaimDeposit.selector, intentId)
        );

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        // The reentrant call was attempted and reverted (nonReentrant guard)
        assertTrue(reentrantUsdc.reentrancyAttempted(), "reentrancy should have been attempted");
        assertTrue(reentrantUsdc.reentrancyReverted(), "reentrant call should have reverted");

        // Outer call succeeded — the Safe got its USDC exactly once
        assertEq(reentrantUsdc.balanceOf(lp), usdcAmount, "the Safe should have received its USDC once");
        assertEq(vault.totalEscrowed(), 0, "the escrow should be settled once");
    }
}

// ──────────────────────────────────────────────
// SC-DU2T: Reclaim merges the vault's free pairs before it pays
// What: The vault holds 200 USDC against a 600 escrow, because the exchange's
//       standing allowance spent 400 on a fill, and it holds 500 YES and 500 NO
//       that no claim is owed. The Safe's reclaim merges the 500 free pairs,
//       receives the full 600, and leaves 100 USDC and no token in the vault.
// Why:  Escrow seniority (decision C7) binds burns and collects and not fills,
//       so a fill can spend escrowed USDC (finding CV-06). Before R15 this
//       reclaim reverted TransferFailed until a keeper merged; the merge inside
//       _refundEscrow (FR-DU2U, ADR-DU2V) removes the wait.
// Example: escrow 600, balance 200, 500 free pairs -> merge 500, pay 600, 100 left.
// ──────────────────────────────────────────────
contract ReclaimMergesFreePairsTest is ReclaimDepositTestBase {
    event CompleteSetsMerged(address indexed caller, uint256 amount);

    // SC-DU2T: the reclaim merges the free pairs and pays the recorded amount in full
    function test_reclaimMergesTheFreePairsAndPaysInFull() public {
        // The fill: the exchange spends 400 of the vault's USDC through the allowance initialize granted
        vm.prank(exchangeAddr);
        assertTrue(mockUsdc.transferFrom(address(vault), exchangeAddr, 400), "the fill should spend");
        assertEq(mockUsdc.balanceOf(address(vault)), 200, "precondition: the balance is below the escrow");
        assertEq(vault.totalEscrowed(), escrowAmount, "precondition: 600 escrowed");

        // The free pairs: 500 YES and 500 NO with no live position, so nothing is owed
        _giveOutcomeTokens(address(vault), vault.conditionId(), 500, 500);
        assertEq(vault.totalYesOwed(), 0, "precondition: no YES owed");
        assertEq(vault.totalNoOwed(), 0, "precondition: no NO owed");

        uint256 before_ = mockUsdc.balanceOf(lp);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(lp, 500);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, escrowAmount);
        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its full escrow");
        assertEq(mockUsdc.balanceOf(address(vault)), 100, "the vault keeps the merge's remainder");
        assertEq(ctf.balanceOf(address(vault), vault.yesTokenId()), 0, "every YES merged");
        assertEq(ctf.balanceOf(address(vault), vault.noTokenId()), 0, "every NO merged");
        assertEq(vault.totalEscrowed(), 0, "the escrow is settled");
    }
}
