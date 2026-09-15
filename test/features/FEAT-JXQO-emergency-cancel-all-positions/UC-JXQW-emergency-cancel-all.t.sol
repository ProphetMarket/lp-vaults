// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JXQW: Emergency Cancel All
// Integration tests for every scenario in this use case.
// Covers: SC-JXQX, SC-JXQY, SC-BZBW, SC-BZBX, SC-JXR1, SC-JXR2, SC-3XTZ, SC-3XU0, SC-3XU1, SC-3XUO,
//         SC-3XU2, NFR-BZBV

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for emergency cancel scenarios.
// Deploys factory + vault and mints a position for LP-A.
// ──────────────────────────────────────────────
contract EmergencyCancelTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_A_PK = 0xA11CE;
    address lpA;

    uint256 constant LP_B_PK = 0xB0B;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;

    // Events declared for expectEmit
    event EmergencyCancelExecuted(address indexed caller);

    // Position minted in setUp for LP-A
    uint256 positionIdA;

    function setUp() public virtual {
        lpA = _safeOf(vm.addr(LP_A_PK));
        lpB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // Mint a position for LP-A: range [0, 100) with 1000 USDC
        mockUsdc.mint(lpA, 1_000_000);
        vm.prank(lpA);
        mockUsdc.approve(address(vault), type(uint256).max);

        positionIdA = _escrowAndMint(vault, operatorAddr, LP_A_PK, int24(0), int24(100), 1000, keccak256("mint-a-1"));
    }

    /// @dev Warps block.timestamp past the emergency cancel timelock.
    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
    }
}

// ──────────────────────────────────────────────
// SC-JXQX: The freeze after the silence timelock changes only the phase
// What: After the Operator has been silent for the vault's timelock, a call to
//       emergencyCancelAll() sets the phase to Cancelled (3) and emits
//       EmergencyCancelExecuted. Every position, every tick, every total, the
//       pending escrow, and the vault's balance stay exactly as they were.
// Why:  Decision C9: the freeze pays no one, so it cannot skip a pending
//       escrow (6.7), run out of gas (6.11), or fail on one blacklisted
//       recipient (6.17). Each LP exits alone afterwards.
// Example: LP-A holds 1000 USDC over [0, 100) and LP-B has 600 USDC in escrow;
//          after the freeze both records read the same.
// ──────────────────────────────────────────────
contract FreezeChangesOnlyPhaseTest is EmergencyCancelTestBase {
    bytes32 constant ESCROW_INTENT = keccak256("pending-escrow");

    function setUp() public override {
        super.setUp();
        // A pending escrow of 600 USDC from LP-B, the state audit issue 6.7 describes
        _fundSafe(mockUsdc, lpB, address(vault), 600);
        _escrow(vault, operatorAddr, LP_B_PK, lpB, int24(0), int24(100), 600, ESCROW_INTENT, FAR_DEADLINE);
        _warpPastTimelock();
    }

    // SC-JXQX: phase transitions to Cancelled (3)
    function test_phaseChangesToCancelled() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
    }

    // SC-JXQX: the totals are untouched, activeLiquidity above all
    function test_totalsUnchanged() public {
        uint128 activeLiqBefore = vault.activeLiquidity();
        int24 tickBefore = vault.currentTick();
        uint256 nextIdBefore = vault.nextPositionId();
        uint256 escrowedBefore = vault.totalEscrowed();
        assertTrue(activeLiqBefore > 0, "precondition: activeLiquidity > 0");
        assertEq(escrowedBefore, 600, "precondition: 600 USDC escrowed");

        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity must not move");
        assertEq(vault.currentTick(), tickBefore, "currentTick must not move");
        assertEq(vault.nextPositionId(), nextIdBefore, "nextPositionId must not move");
        assertEq(vault.totalEscrowed(), escrowedBefore, "totalEscrowed must not move");
    }

    // SC-JXQX: the position record is untouched
    function test_positionRecordUnchanged() public {
        (address ownerBefore, int24 lowerBefore, int24 upperBefore, int24 mintBefore, uint128 liqBefore,) =
            vault.positions(positionIdA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        (address owner, int24 lower, int24 upper, int24 mintTick, uint128 liq,) = vault.positions(positionIdA);
        assertEq(owner, ownerBefore, "owner must not move");
        assertEq(lower, lowerBefore, "tickLower must not move");
        assertEq(upper, upperBefore, "tickUpper must not move");
        assertEq(mintTick, mintBefore, "mintTick must not move");
        assertEq(liq, liqBefore, "liquidity must not move");
    }

    // SC-JXQX: both boundary tick records and their bitmap bits are untouched
    function test_tickRecordsAndBitmapUnchanged() public {
        (uint128 grossLowBefore, int128 netLowBefore,,) = vault.ticks(int24(0));
        (uint128 grossUpBefore, int128 netUpBefore,,) = vault.ticks(int24(100));
        uint256 wordBefore = vault.tickBitmap(int16(0));
        assertTrue(grossLowBefore > 0 && grossUpBefore > 0, "precondition: both ticks initialized");

        vm.prank(lpA);
        vault.emergencyCancelAll();

        (uint128 grossLow, int128 netLow,,) = vault.ticks(int24(0));
        (uint128 grossUp, int128 netUp,,) = vault.ticks(int24(100));
        assertEq(grossLow, grossLowBefore, "ticks[0].liquidityGross must not move");
        assertEq(netLow, netLowBefore, "ticks[0].liquidityNet must not move");
        assertEq(grossUp, grossUpBefore, "ticks[100].liquidityGross must not move");
        assertEq(netUp, netUpBefore, "ticks[100].liquidityNet must not move");
        assertEq(vault.tickBitmap(int16(0)), wordBefore, "the bitmap word must not move");
    }

    // SC-JXQX: the escrow record is untouched, so the reclaim still finds it (audit issue 6.7)
    function test_escrowRecordUnchanged() public {
        (address lpBefore, uint96 amountBefore, bytes32 hashBefore) = vault.pendingDeposits(ESCROW_INTENT);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        (address lp, uint96 amount, bytes32 hash) = vault.pendingDeposits(ESCROW_INTENT);
        assertEq(lp, lpBefore, "the escrow's Safe must not move");
        assertEq(amount, amountBefore, "the escrow's amount must not move");
        assertEq(hash, hashBefore, "the escrow's intent hash must not move");
        assertEq(amount, 600, "the escrow still holds 600 USDC");
    }

    // SC-JXQX: no USDC leaves the vault and none reaches the caller
    function test_noAssetMoves() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 lpBefore = mockUsdc.balanceOf(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "the vault's USDC must not move");
        assertEq(mockUsdc.balanceOf(lpA), lpBefore, "the caller receives nothing");
    }

    // SC-JXQX: EmergencyCancelExecuted, carrying the caller, is the only event
    function test_emitsEmergencyCancelExecutedOnly() public {
        vm.recordLogs();
        vm.prank(lpA);
        vault.emergencyCancelAll();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the freeze emits one event and nothing else");
        assertEq(logs[0].emitter, address(vault), "the vault emits it");
        assertEq(logs[0].topics[0], EmergencyCancelExecuted.selector, "the event is EmergencyCancelExecuted");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), lpA, "the event carries the caller");
    }
}

// ──────────────────────────────────────────────
// SC-JXQY: Revert before timelock elapses
// What: emergencyCancelAll() reverts if the vault's operator-silence timelock
//       (copied from the factory at creation) has not yet elapsed since the
//       last operator action, whoever calls it.
// Why:  Prevents premature cancellation — the operator might just be slow,
//       not absent.
// ──────────────────────────────────────────────
contract RevertBeforeTimelockTest is EmergencyCancelTestBase {
    // SC-JXQY: reverts with TimelockNotElapsed, for a holder and for an arbitrary address alike
    function test_revertsBeforeTimelockElapsed() public {
        // Don't warp — timelock has not elapsed
        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXQY: no state change after revert
    function test_noStateChangeOnRevert() public {
        uint8 phaseBefore = vault.phase();
        uint128 activeLiqBefore = vault.activeLiquidity();

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), phaseBefore, "phase unchanged");
        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-BZBW: Any address freezes the vault, with or without a position
// What: An arbitrary EOA with no position and no role, and the Operator, each
//       freeze the vault once the timelock has elapsed. The event carries the
//       caller, and the two positions and activeLiquidity are untouched.
// Why:  Audit issues 6.11 and 6.17, audit-solutions.md Finding 4: the freeze
//       moves no funds, so caller identity protects nothing, and a restricted
//       caller only risks a vault that no holder notices. The ownership loop
//       was the same unbounded shape as the payout loop.
// ──────────────────────────────────────────────
contract AnyAddressFreezesTest is EmergencyCancelTestBase {
    uint256 positionIdB;

    function setUp() public override {
        super.setUp();
        positionIdB = _escrowAndMint(vault, operatorAddr, LP_B_PK, int24(0), int24(50), 500, keccak256("mint-b-1"));
        _warpPastTimelock();
    }

    function _assertFrozenBy(address caller) internal {
        uint128 activeLiqBefore = vault.activeLiquidity();
        (,,,, uint128 liqABefore,) = vault.positions(positionIdA);
        (,,,, uint128 liqBBefore,) = vault.positions(positionIdB);

        vm.expectEmit(true, false, false, false, address(vault));
        emit EmergencyCancelExecuted(caller);
        vm.prank(caller);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity must not move");
        (,,,, uint128 liqA,) = vault.positions(positionIdA);
        (,,,, uint128 liqB,) = vault.positions(positionIdB);
        assertEq(liqA, liqABefore, "LP-A's position must not move");
        assertEq(liqB, liqBBefore, "LP-B's position must not move");
    }

    // SC-BZBW: an arbitrary address with no position and no role freezes the vault
    function test_arbitraryAddressFreezesTheVault() public {
        _assertFrozenBy(makeAddr("no-position"));
    }

    // SC-BZBW: the Operator, who holds no position, freezes the vault too
    function test_operatorFreezesTheVault() public {
        _assertFrozenBy(operatorAddr);
    }
}

// ──────────────────────────────────────────────
// SC-BZBX: An in-range burn after the freeze pays in full
// What: With the vault frozen at tick 6000, Safe A burns its in-range position
//       (300 USDC over [5500, 6500)) and receives 300 USDC; activeLiquidity
//       falls to Safe B's liquidity. Safe A burns its out-of-range position
//       (500 USDC over [7000, 8000), all USDC), and Safe B burns for its 1,000
//       USDC; PositionBurned fires three times, activeLiquidity ends at zero,
//       and the phase stays 3.
// Why:  Decision C9. The audited cancel zeroed activeLiquidity, and an in-range
//       burn after it would have reverted on underflow; the freeze keeps every
//       record, so each LP leaves alone with a full payout.
// ──────────────────────────────────────────────
contract BurnAfterFreezeTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    uint256 constant LP_A_PK = 0xA11CE;
    uint256 constant LP_B_PK = 0xB0B;
    address safeA;
    address safeB;

    // 300 USDC over 1,000 ticks and 1,000 USDC over 2,000 ticks: liquidity = usdc * 1e18 / width
    uint128 constant LIQ_A_IN = 3e23;
    uint128 constant LIQ_B = 5e23;

    uint256 posAIn;
    uint256 posAOut;
    uint256 posB;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 usdcPaid,
        uint256 spreadOwed,
        uint256 spreadPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );

    function setUp() public {
        safeA = _safeOf(vm.addr(LP_A_PK));
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));

        // The vault sits at tick 6000 before every mint, so each mint tick is clamped from 6000
        vm.prank(operatorAddr);
        vault.updateTick(int24(6000));

        posAIn = _escrowAndMint(vault, operatorAddr, LP_A_PK, int24(5500), int24(6500), 300_000_000, keccak256("a-in"));
        posAOut =
            _escrowAndMint(vault, operatorAddr, LP_A_PK, int24(7000), int24(8000), 500_000_000, keccak256("a-out"));
        posB = _escrowAndMint(vault, operatorAddr, LP_B_PK, int24(5000), int24(7000), 1_000_000_000, keccak256("b"));
        assertEq(vault.activeLiquidity(), LIQ_A_IN + LIQ_B, "precondition: the two in-range positions");

        // The freeze by an arbitrary address
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vm.prank(makeAddr("anyone"));
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");
    }

    // SC-BZBX: the in-range burn pays the principal, and activeLiquidity falls by its liquidity
    function test_inRangeBurnAfterFreezePaysInFull() public {
        uint256 before_ = mockUsdc.balanceOf(safeA);

        vm.prank(safeA);
        vault.burnPosition(posAIn);

        assertEq(mockUsdc.balanceOf(safeA) - before_, 300_000_000, "Safe A receives 300 USDC");
        assertEq(vault.activeLiquidity(), LIQ_B, "activeLiquidity falls to Safe B's liquidity");
        (address owner,,,, uint128 liq,) = vault.positions(posAIn);
        assertEq(owner, address(0), "the record is deleted");
        assertEq(liq, 0, "the record is deleted");
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }

    // SC-BZBX: every exit works after the freeze, and activeLiquidity ends at zero
    function test_everyExitAfterFreezeEndsWithZeroActiveLiquidity() public {
        uint256 aBefore = mockUsdc.balanceOf(safeA);
        uint256 bBefore = mockUsdc.balanceOf(safeB);
        vm.recordLogs();

        vm.prank(safeA);
        vault.burnPosition(posAIn);
        assertEq(mockUsdc.balanceOf(safeA) - aBefore, 300_000_000, "Safe A receives 300 USDC for the first burn");

        // The out-of-range position sits above the price, its mint tick clamped to 7000, so it is all USDC
        vm.prank(safeA);
        vault.burnPosition(posAOut);
        assertEq(mockUsdc.balanceOf(safeA) - aBefore, 300_000_000 + 500_000_000, "Safe A receives both principals");
        assertEq(vault.activeLiquidity(), LIQ_B, "the out-of-range burn leaves activeLiquidity alone");

        vm.prank(safeB);
        vault.burnPosition(posB);
        assertEq(mockUsdc.balanceOf(safeB) - bBefore, 1_000_000_000, "Safe B receives its 1,000 USDC principal");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity is zero after every exit");
        assertEq(vault.phase(), 3, "phase stays Cancelled");

        // The vault emits PositionBurned once per exit
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == PositionBurned.selector) burns++;
        }
        assertEq(burns, 3, "PositionBurned three times");
    }
}

// ──────────────────────────────────────────────
// SC-JXR1: Terminal state gates off trading, and every exit stays open
// What: After emergencyCancelAll(), every trading entry point reverts.
//       mintPositionFor, depositForIntent, updateTick, startWindDown revert with
//       VaultNotActive. mergePositions, heartbeat revert with VaultCancelled.
//       emergencyCancelAll itself reverts (already cancelled). mergeCompleteSets
//       merges the 10 pairs the vault holds, and the pending escrow of 600 USDC
//       is reclaimed (decision C9).
// Why:  The Cancelled state stops trading; it never locks an exit. The reclaim
//       step is the exact sequence of audit issue 6.7.
// ──────────────────────────────────────────────
contract TerminalStateGatingTest is EmergencyCancelTestBase {
    bytes32 constant ESCROW_INTENT = keccak256("cancelled-escrow");

    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    function setUp() public override {
        super.setUp();
        // A pending escrow of 600 USDC from LP-B, left behind when the Operator went silent
        _fundSafe(mockUsdc, lpB, address(vault), 600);
        _escrow(vault, operatorAddr, LP_B_PK, lpB, int24(0), int24(100), 600, ESCROW_INTENT, FAR_DEADLINE);
        _warpPastTimelock();

        // Freeze the vault to enter the Cancelled state
        vm.prank(makeAddr("anyone"));
        vault.emergencyCancelAll();
    }

    // SC-JXR1: mintPositionFor reverts with VaultNotActive
    function test_mintPositionForReverts() public {
        bytes32 intentId = keccak256("post-cancel-mint");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lpA, int24(0), int24(100), 500, intentId, FAR_DEADLINE);
    }

    // SC-JXR1, FR-JXQT: depositForIntent reverts with VaultNotActive
    function test_depositForIntentReverts() public {
        bytes32 intentId = keccak256("post-cancel-deposit");
        bytes memory sig =
            _signMintIntent(address(vault), LP_A_PK, lpA, int24(0), int24(100), 500, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.depositForIntent(lpA, int24(0), int24(100), 500, intentId, FAR_DEADLINE, sig);
    }

    // SC-JXR1, FR-JXQT: the pending escrow is reclaimed by its Safe after the freeze (audit issue 6.7)
    function test_reclaimDepositOfPendingEscrowSucceeds() public {
        uint256 before_ = mockUsdc.balanceOf(lpB);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(ESCROW_INTENT, lpB, 600);
        vm.prank(lpB);
        vault.reclaimDeposit(ESCROW_INTENT);

        assertEq(mockUsdc.balanceOf(lpB) - before_, 600, "the Safe reclaims its 600 USDC after the freeze");
        assertEq(vault.totalEscrowed(), 0, "nothing stays escrowed");
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }

    // SC-JXR1, FR-JXQT: the relayed reclaim also succeeds after the freeze
    function test_reclaimDepositForSucceedsInCancelled() public {
        bytes memory sig = _signReclaimIntent(address(vault), LP_B_PK, lpB, ESCROW_INTENT, FAR_DEADLINE);
        uint256 before_ = mockUsdc.balanceOf(lpB);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lpB, ESCROW_INTENT, FAR_DEADLINE, sig);

        assertEq(mockUsdc.balanceOf(lpB) - before_, 600, "the relayed reclaim pays after the freeze");
    }

    // SC-JXR1, FR-JXQT: mergeCompleteSets merges the 10 pairs in the Cancelled phase
    function test_mergeCompleteSetsSucceeds() public {
        _giveOutcomeTokens(address(vault), vault.conditionId(), 10, 10);
        uint256 before_ = mockUsdc.balanceOf(address(vault));

        vm.prank(makeAddr("anyone"));
        vault.mergeCompleteSets();

        assertEq(mockUsdc.balanceOf(address(vault)), before_ + 10, "the merge adds 10 USDC");
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }

    // SC-JXR1: updateTick reverts with VaultNotActive
    function test_updateTickReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(int24(50));
    }

    // SC-JXR1: mergePositions reverts with VaultCancelled.
    // The freeze keeps every record, so without an explicit phase guard the range-match
    // checks would still pass and the Operator could merge inside a frozen vault.
    function test_mergePositionsReverts() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionIdA;
        ids[1] = positionIdA;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.mergePositions(ids);
    }

    // SC-JXR1: heartbeat reverts with VaultCancelled
    function test_heartbeatReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.heartbeat();
    }

    // SC-JXR1: startWindDown reverts with VaultNotActive
    function test_startWindDownReverts() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.startWindDown();
    }

    // SC-JXR1: emergencyCancelAll reverts (already cancelled), for any caller
    function test_emergencyCancelAllRevertsAgain() public {
        vm.prank(makeAddr("anyone-else"));
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-JXR2: Operator activity resets timelock
// What: When the Operator calls updateTick with a changed tick, the tick
//       moves and lastOperatorActivityTimestamp is reset to block.timestamp,
//       preventing an immediate emergencyCancelAll even though the timelock
//       would have elapsed before the operator action.
// Why:  An active operator proves they haven't abandoned the vault. The
//       timelock should only trigger when the operator truly goes silent.
// ──────────────────────────────────────────────
contract OperatorActivityResetsTimelockTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXR2: a changed tick report moves the tick, resets the timer, and defers the cancel
    function test_whenOperatorReportsChangedTickThenTimerResetsAndCancelReverts() public {
        int24 newTick = int24(10);
        assertTrue(vault.currentTick() != newTick, "precondition: the report changes the tick");

        vm.prank(operatorAddr);
        vault.updateTick(newTick);

        assertEq(vault.currentTick(), newTick, "the report moved the tick");
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "updateTick should reset timestamp");

        // Immediately try to cancel — should revert because timer was just reset
        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-3XTZ: Heartbeat defers emergency cancel on a quiet market
// What: On an Active market where the tick has not moved, two Operator calls
//       refresh the silence timer and neither reverts: heartbeat(), and
//       updateTick with the unchanged tick (the keeper's normal 60-second
//       report, SC-TVS7).
// Why:  A healthy Operator on a quiet market must be distinguishable from a
//       silent one, and the keeper's normal report must count as proof of
//       life without a second transaction.
// Example: timelock has elapsed; operator calls heartbeat(); an immediate
//          emergencyCancelAll() reverts with TimelockNotElapsed. Same again
//          with updateTick(currentTick).
// ──────────────────────────────────────────────
contract HeartbeatOnQuietMarketTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-3XTZ: on a quiet Active market both refresh paths succeed
    function test_quietMarketHasTwoRefreshPaths() public {
        // Read the tick up front: an inline call here would consume the prank
        int24 unchangedTick = vault.currentTick();

        // The tick has not moved, and the keeper's report refreshes the timer anyway
        vm.prank(operatorAddr);
        vault.updateTick(unchangedTick);
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "the unchanged report must refresh the timer");
        assertEq(vault.currentTick(), unchangedTick, "the tick must not move");

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-3XTZ: heartbeat refreshes the silence timer
    function test_heartbeatRefreshesSilenceTimer() public {
        vm.prank(operatorAddr);
        vault.heartbeat();

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "heartbeat should refresh the silence timer");
    }

    // SC-3XTZ: refreshing the timer defers emergencyCancelAll that was already in reach
    function test_heartbeatDefersEmergencyCancel() public {
        vm.prank(operatorAddr);
        vault.heartbeat();

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-3XTZ: heartbeat is purely a liveness signal — it moves no accounting state
    function test_heartbeatChangesNoOtherVaultState() public {
        uint128 liquidityBefore = vault.activeLiquidity();
        int24 tickBefore = vault.currentTick();
        uint256 nextIdBefore = vault.nextPositionId();
        uint8 phaseBefore = vault.phase();

        vm.prank(operatorAddr);
        vault.heartbeat();

        assertEq(vault.activeLiquidity(), liquidityBefore, "activeLiquidity must not move");
        assertEq(vault.currentTick(), tickBefore, "currentTick must not move");
        assertEq(vault.nextPositionId(), nextIdBefore, "nextPositionId must not move");
        assertEq(vault.phase(), phaseBefore, "phase must not move");
    }
}

// ──────────────────────────────────────────────
// SC-3XU0: Position minting and merging reset the timelock
// What: mintPositionFor and mergePositions each refresh the silence timer,
//       so active deposit processing and position housekeeping now count as
//       proof of life.
// Why:  Previously neither touched the timer at all — an Operator could be
//       busy onboarding LPs and still be treated as silent.
// Example: timelock has elapsed; operator mints a position; an immediate
//          emergencyCancelAll() reverts with TimelockNotElapsed.
// ──────────────────────────────────────────────
contract MintAndMergeResetTimelockTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-3XU0: minting a position for an LP is proof the Operator is alive
    function test_mintPositionForRefreshesSilenceTimer() public {
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        _escrowAndMint(vault, operatorAddr, LP_B_PK, int24(0), int24(100), 1000, keccak256("mint-b-live"));

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "mint should refresh the silence timer");
    }

    // SC-3XU0: and that refresh actually defers the emergency cancel
    function test_mintPositionForDefersEmergencyCancel() public {
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        _escrowAndMint(vault, operatorAddr, LP_B_PK, int24(0), int24(100), 1000, keccak256("mint-b-defer"));

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-3XU0: merging same-range positions is likewise proof of life
    function test_mergePositionsRefreshesSilenceTimer() public {
        // Give LP-A a second position on the identical range so the two can be merged
        uint256 positionIdA2 =
            _escrowAndMint(vault, operatorAddr, LP_A_PK, int24(0), int24(100), 1000, keccak256("mint-a-2"));

        // Let the timelock lapse again so the merge has something to push back
        _warpPastTimelock();

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionIdA;
        ids[1] = positionIdA2;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "merge should refresh the silence timer");

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-3XU1, SC-3XUO, SC-3XU2: heartbeat access control and phase behavior
// What: heartbeat() is Operator-only, keeps working while trading is paused
//       and while the vault is wound down, and reverts once the vault reaches
//       the terminal Cancelled phase.
// Why:  A non-Operator must not be able to hold off emergencyCancelAll. A
//       pause is an Admin decision about trading, and a wind-down is an Oracle
//       decision about the market. Neither says whether the Operator is alive,
//       and updateTick rejects both states, so heartbeat() is the keeper's
//       refresh path there. Once every position is closed there is nothing
//       left to protect.
// Example: LP calls heartbeat() -> NotOperator; admin pauses, operator
//          heartbeats fine; oracle winds down, operator heartbeats fine;
//          after cancel, heartbeat() -> VaultCancelled.
// ──────────────────────────────────────────────
contract HeartbeatAccessAndPhaseTest is EmergencyCancelTestBase {
    // SC-3XU1: an LP cannot refresh the timer that protects them
    function test_revertsWhenLpCallsHeartbeat() public {
        uint256 before = vault.lastOperatorActivityTimestamp();

        vm.prank(lpA);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.heartbeat();

        assertEq(vault.lastOperatorActivityTimestamp(), before, "a rejected call must not move the timer");
    }

    // SC-3XU1: neither can the Admin or the Oracle — the gate is the Operator role
    function test_revertsWhenAdminOrOracleCallsHeartbeat() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.heartbeat();

        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.heartbeat();
    }

    // SC-3XUO: while paused, every other Operator entry point is gated off by
    // whenNotPaused, leaving heartbeat as the only way to signal liveness
    function test_heartbeatWorksWhileTradingIsPaused() public {
        vm.prank(admin);
        vault.pauseTrading();

        // All four other Operator entry points are gated off by whenNotPaused
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.updateTick(int24(10));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mintPositionFor(lpB, int24(0), int24(100), 1000, keccak256("mint-b-paused"), FAR_DEADLINE);

        bytes memory sigB = _signMintIntent(
            address(vault), LP_B_PK, lpB, int24(0), int24(100), 1000, keccak256("deposit-b-paused"), FAR_DEADLINE
        );
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.depositForIntent(lpB, int24(0), int24(100), 1000, keccak256("deposit-b-paused"), FAR_DEADLINE, sigB);

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionIdA;
        ids[1] = positionIdA;
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mergePositions(ids);

        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vault.heartbeat();

        assertEq(
            vault.lastOperatorActivityTimestamp(), block.timestamp, "heartbeat must still work while trading is paused"
        );
    }

    // SC-3XUO: while wound down, updateTick rejects the keeper's report, so
    // heartbeat is the refresh path
    function test_heartbeatWorksWhileWoundDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();
        assertEq(vault.phase(), 2, "precondition: phase should be WindDown (2)");

        // Read the tick up front: an inline call here would consume the prank
        int24 unchangedTick = vault.currentTick();
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(unchangedTick);

        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vault.heartbeat();

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            block.timestamp,
            "heartbeat must still work while the vault is wound down"
        );
    }

    // SC-3XU2: once the vault is Cancelled there is nothing left to protect
    function test_revertsWhenVaultIsCancelled() public {
        _warpPastTimelock();
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "vault should be in the terminal Cancelled phase");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.heartbeat();
    }
}

// ──────────────────────────────────────────────
// NFR-BZBV: The freeze costs the same gas for any number of positions
// What: Measured with every slot cold (vm.cool) and gasleft() around the call,
//       the freeze on a vault with one position costs exactly what it costs on a
//       vault with five, and both stay under 30,000 gas.
// Why:  Audit issue 6.11: the audited loop cost grew with every position and
//       ran out of gas on a large vault. The freeze reads phase, the heartbeat,
//       and the timelock, and writes phase.
// ──────────────────────────────────────────────
contract FreezeGasTest is EmergencyCancelTestBase {
    uint256 constant GAS_CEILING = 30_000;

    function _coldFreezeGas(LPVault target, address caller) internal returns (uint256 gasUsed) {
        vm.cool(address(target));
        vm.cool(address(factory));
        vm.prank(caller);
        uint256 before = gasleft();
        target.emergencyCancelAll();
        gasUsed = before - gasleft();
        assertEq(target.phase(), 3, "the measured call froze the vault");
    }

    // NFR-BZBV: one position and five positions cost the same, under the ceiling
    function test_freezeGasDoesNotDependOnPositionCount() public {
        // A second vault with five positions, one of them LP-B's
        LPVault five = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(2)), vaultTickSpacing, minFirstLiq));
        _escrowAndMint(five, operatorAddr, LP_A_PK, int24(0), int24(100), 1000, keccak256("five-1"));
        _escrowAndMint(five, operatorAddr, LP_A_PK, int24(0), int24(50), 500, keccak256("five-2"));
        _escrowAndMint(five, operatorAddr, LP_A_PK, int24(200), int24(300), 700, keccak256("five-3"));
        _escrowAndMint(five, operatorAddr, LP_B_PK, int24(0), int24(100), 2000, keccak256("five-4"));
        _escrowAndMint(five, operatorAddr, LP_B_PK, int24(400), int24(500), 900, keccak256("five-5"));
        assertEq(five.nextPositionId(), 5, "precondition: five positions");
        assertEq(vault.nextPositionId(), 1, "precondition: one position");
        _warpPastTimelock();

        address caller = makeAddr("anyone");
        uint256 gasOne = _coldFreezeGas(vault, caller);
        uint256 gasFive = _coldFreezeGas(five, caller);

        assertEq(gasOne, gasFive, "the freeze must cost the same for one position and for five");
        assertLt(gasOne, GAS_CEILING, "the freeze must stay under 30,000 gas on a cold vault");
        emit log_named_uint("freeze call gas, cold vault", gasOne);
    }
}
