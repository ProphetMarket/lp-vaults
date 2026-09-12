// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JXQW: Emergency Cancel All
// Integration tests for every scenario in this use case.
// Covers: SC-JXQX, SC-JXQY, SC-JXQZ, SC-JXR0, SC-JXR1, SC-JXR2

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {ConditionalTokensFixture} from "../../fixtures/ConditionalTokensFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {VaultStorage} from "../../fixtures/VaultStorage.sol";

// ──────────────────────────────────────────────
// Base test contract for emergency cancel scenarios.
// Deploys factory + vault, mints a position for LP-A, distributes fees.
// ──────────────────────────────────────────────
contract EmergencyCancelTestBase is ConditionalTokensFixture {
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
    uint256 constant Q128 = 2 ** 128;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Events declared for expectEmit
    event EmergencyCancelExecuted(address indexed caller);
    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

    // Position minted in setUp for LP-A
    uint256 positionIdA;

    function setUp() public virtual {
        lpA = vm.addr(LP_A_PK);
        lpB = vm.addr(LP_B_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // Mint a position for LP-A: range [0, 100) with 1000 USDC
        mockUsdc.mint(lpA, 1_000_000);
        vm.prank(lpA);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sigA = _signMintIntent(LP_A_PK, lpA, int24(0), int24(100), 1000, keccak256("mint-a-1"));
        vm.prank(operatorAddr);
        positionIdA = vault.mintPositionFor(lpA, int24(0), int24(100), 1000, keccak256("mint-a-1"), sigA);

        // Distribute fees so position has accrued fees
        mockUsdc.mint(address(vault), 500);
        vm.prank(operatorAddr);
        vault.notifyFees(500);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Warps block.timestamp past the emergency cancel timelock.
    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
    }
}

// ──────────────────────────────────────────────
// SC-JXQX: Successful emergency cancel after silence timelock
// What: When a position holder calls emergencyCancelAll() after the operator
//       has been silent for >= EMERGENCY_CANCEL_TIMELOCK, all positions are
//       closed, principal + fees distributed to owners, phase transitions to
//       Cancelled (3), and EmergencyCancelExecuted is emitted.
// Why:  This is the core safety-net mechanism — if the Operator disappears,
//       LPs must be able to recover their capital without any trusted party.
// ──────────────────────────────────────────────
contract SuccessfulEmergencyCancelTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXQX: phase transitions to Cancelled (3)
    function test_phaseChangesToCancelled() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
    }

    // SC-JXQX: activeLiquidity zeroed
    function test_activeLiquidityZeroed() public {
        assertTrue(vault.activeLiquidity() > 0, "precondition: activeLiquidity > 0");

        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should be zeroed");
    }

    // SC-JXQX: position liquidity zeroed
    function test_positionLiquidityZeroed() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        (,,, uint128 liquidity,,) = vault.positions(positionIdA);
        assertEq(liquidity, 0, "position liquidity should be zeroed");
    }

    // SC-JXQX: LP receives principal + accrued fees
    function test_lpReceivesPrincipalPlusFees() public {
        uint256 lpBalBefore = mockUsdc.balanceOf(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpBalAfter = mockUsdc.balanceOf(lpA);
        // LP deposited 1000 USDC and 500 in fees were distributed
        // Principal = liquidity * rangeWidth / PRECISION = 10e18 * 100 / 1e18 = 1000
        // Fees = liquidity * feeGrowthDelta / Q128 (should be ~500 minus Q128 truncation dust)
        assertTrue(lpBalAfter > lpBalBefore, "LP should receive USDC");
        assertTrue(lpBalAfter - lpBalBefore >= 1400, "LP should receive at least principal + most fees");
    }

    // SC-JXQX: EmergencyCancelExecuted event emitted
    function test_emitsEmergencyCancelExecutedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit EmergencyCancelExecuted(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();
    }

    // SC-JXQX: vault USDC balance is zero (or dust)
    function test_vaultBalanceZeroOrDust() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        // Allow up to 1 wei of dust from Q128 truncation
        assertLe(mockUsdc.balanceOf(address(vault)), 1, "vault should have zero or dust USDC");
    }
}

// ──────────────────────────────────────────────
// SC-JXQY: Revert before timelock elapses
// What: emergencyCancelAll() reverts if the operator-silence timelock has not
//       yet elapsed since the last operator action.
// Why:  Prevents premature cancellation — the operator might just be slow,
//       not absent.
// ──────────────────────────────────────────────
contract RevertBeforeTimelockTest is EmergencyCancelTestBase {
    // SC-JXQY: reverts with TimelockNotElapsed
    function test_revertsBeforeTimelockElapsed() public {
        // Don't warp — timelock has not elapsed
        vm.prank(lpA);
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
// SC-JXQZ: Revert if caller holds no position
// What: emergencyCancelAll() reverts if the caller does not own any position
//       in the vault, even if the timelock has elapsed.
// Why:  Prevents griefing by external addresses with no stake in the vault.
// ──────────────────────────────────────────────
contract RevertIfNoPositionTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXQZ: arbitrary address with no position reverts
    function test_revertsWhenCallerHasNoPosition() public {
        address noPositionAddr = makeAddr("no-position");
        vm.prank(noPositionAddr);
        vm.expectRevert(LPVault.NoPositionHeld.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXQZ: operator with no position reverts
    function test_revertsWhenOperatorHasNoPosition() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NoPositionHeld.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-JXR0: Multi-LP distribution
// What: When multiple LPs have positions and emergencyCancelAll is triggered,
//       each LP receives their proportional share (principal + fees) across
//       all their positions.
// Why:  Proves the iteration distributes correctly to multiple owners with
//       different liquidity amounts and ranges.
// ──────────────────────────────────────────────
contract MultiLPDistributionTest is EmergencyCancelTestBase {
    uint256 positionIdA2;
    uint256 positionIdB;

    function setUp() public override {
        super.setUp();

        // Mint a second position for LP-A: range [0, 50) with 500 USDC
        bytes memory sigA2 = _signMintIntent(LP_A_PK, lpA, int24(0), int24(50), 500, keccak256("mint-a-2"));
        vm.prank(operatorAddr);
        positionIdA2 = vault.mintPositionFor(lpA, int24(0), int24(50), 500, keccak256("mint-a-2"), sigA2);

        // Mint a position for LP-B: range [0, 100) with 2000 USDC
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, int24(0), int24(100), 2000, keccak256("mint-b-1"));
        vm.prank(operatorAddr);
        positionIdB = vault.mintPositionFor(lpB, int24(0), int24(100), 2000, keccak256("mint-b-1"), sigB);

        // Distribute more fees
        mockUsdc.mint(address(vault), 1000);
        vm.prank(operatorAddr);
        vault.notifyFees(1000);

        _warpPastTimelock();
    }

    // SC-JXR0: LP-A receives correct total for both positions
    function test_lpAReceivesCorrectTotal() public {
        uint256 lpABalBefore = mockUsdc.balanceOf(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpAReceived = mockUsdc.balanceOf(lpA) - lpABalBefore;
        // LP-A deposited 1000 + 500 = 1500 USDC total principal
        assertTrue(lpAReceived >= 1500, "LP-A should receive at least principal");
    }

    // SC-JXR0: LP-B receives correct total for their position
    function test_lpBReceivesCorrectTotal() public {
        uint256 lpBBalBefore = mockUsdc.balanceOf(lpB);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpBReceived = mockUsdc.balanceOf(lpB) - lpBBalBefore;
        // LP-B deposited 2000 USDC principal
        assertTrue(lpBReceived >= 2000, "LP-B should receive at least principal");
    }

    // SC-JXR0: vault USDC balance is zero or dust after multi-LP distribution
    function test_vaultBalanceZeroOrDust() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertLe(mockUsdc.balanceOf(address(vault)), 3, "vault should have zero or dust");
    }

    // SC-JXR0: all 3 positions have liquidity == 0
    function test_allPositionsZeroed() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        (,,, uint128 liq0,,) = vault.positions(positionIdA);
        (,,, uint128 liq1,,) = vault.positions(positionIdA2);
        (,,, uint128 liq2,,) = vault.positions(positionIdB);
        assertEq(liq0, 0, "positionA1 liquidity zeroed");
        assertEq(liq1, 0, "positionA2 liquidity zeroed");
        assertEq(liq2, 0, "positionB liquidity zeroed");
    }

    // SC-JXR0: phase is Cancelled
    function test_phaseCancelled() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-JXR1: Terminal state gates off all operations
// What: After emergencyCancelAll(), every state-changing function reverts.
//       mintPositionFor, updateTick, startWindDown revert with VaultNotActive.
//       collect, notifyFees revert with VaultCancelled.
//       emergencyCancelAll itself reverts (already cancelled).
// Why:  The Cancelled state is terminal — no further operations should succeed
//       on a vault where all funds have been distributed.
// ──────────────────────────────────────────────
contract TerminalStateGatingTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();

        // Execute emergency cancel to enter Cancelled state
        vm.prank(lpA);
        vault.emergencyCancelAll();
    }

    // SC-JXR1: mintPositionFor reverts with VaultNotActive
    function test_mintPositionForReverts() public {
        bytes32 intentId = keccak256("post-cancel-mint");
        bytes memory sig = _signMintIntent(LP_A_PK, lpA, int24(0), int24(100), 500, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lpA, int24(0), int24(100), 500, intentId, sig);
    }

    // SC-JXR1: collect reverts with VaultCancelled
    function test_collectReverts() public {
        vm.prank(lpA);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.collect(positionIdA);
    }

    // SC-JXR1: notifyFees reverts with VaultCancelled
    function test_notifyFeesReverts() public {
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.notifyFees(100);
    }

    // SC-JXR1: updateTick reverts with VaultNotActive
    function test_updateTickReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(int24(50));
    }

    // SC-JXR1: mergePositions reverts with VaultCancelled.
    // emergencyCancelAll zeroes each position's liquidity but preserves its owner and
    // tick range, so without an explicit phase guard the range-match checks would still
    // pass and the merge would succeed against a fully distributed vault.
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

    // SC-JXR1: emergencyCancelAll reverts (already cancelled)
    function test_emergencyCancelAllRevertsAgain() public {
        vm.prank(lpA);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-JXR2: Operator activity resets timelock
// What: When the Operator calls notifyFees, lastOperatorActivityTimestamp is
//       reset to block.timestamp, preventing an immediate emergencyCancelAll
//       even though the timelock would have elapsed before the operator action.
// Why:  An active operator proves they haven't abandoned the vault. The
//       timelock should only trigger when the operator truly goes silent.
// ──────────────────────────────────────────────
contract OperatorActivityResetsTimelockTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXR2: notifyFees resets lastOperatorActivityTimestamp
    function test_notifyFeesResetsTimestamp() public {
        // Fund and call notifyFees — this should reset the timer
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vault.notifyFees(100);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "timestamp should be reset");
    }

    // SC-JXR2: emergencyCancelAll reverts after operator activity resets timer
    function test_emergencyCancelRevertsAfterOperatorActivity() public {
        // Operator acts — resets the timer
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vault.notifyFees(100);

        // Immediately try to cancel — should revert because timer was just reset
        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXR2: updateTick also resets timer (already implemented, sanity check)
    function test_updateTickResetsTimestamp() public {
        // updateTick already updates lastOperatorActivityTimestamp
        vm.prank(operatorAddr);
        vault.updateTick(int24(10));

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "updateTick should reset timestamp");
    }
}

// ──────────────────────────────────────────────
// SC-3XTZ: Heartbeat defers emergency cancel on a quiet market
// What: On an Active market where the tick has not moved and no fee revenue
//       arrived, two Operator calls refresh the silence timer and neither
//       reverts: heartbeat(), and updateTick with the unchanged tick (the
//       keeper's normal 60-second report, SC-TVS7). notifyFees(0) still
//       reverts ZeroAmount.
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

    // SC-3XTZ: on a quiet Active market both refresh paths succeed, and only
    // the zero-income report still reverts
    function test_quietMarketHasTwoRefreshPaths() public {
        // Read the tick up front: an inline call here would consume the prank
        int24 unchangedTick = vault.currentTick();

        // No fee revenue arrived, so notifyFees has nothing to distribute
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.notifyFees(0);

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
        uint256 feeGrowthBefore = vault.feeGrowthGlobalX128();
        uint256 nextIdBefore = vault.nextPositionId();
        uint8 phaseBefore = vault.phase();

        vm.prank(operatorAddr);
        vault.heartbeat();

        assertEq(vault.activeLiquidity(), liquidityBefore, "activeLiquidity must not move");
        assertEq(vault.currentTick(), tickBefore, "currentTick must not move");
        assertEq(vault.feeGrowthGlobalX128(), feeGrowthBefore, "feeGrowthGlobalX128 must not move");
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

        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, int24(0), int24(100), 1000, keccak256("mint-b-live"));
        vm.prank(operatorAddr);
        vault.mintPositionFor(lpB, int24(0), int24(100), 1000, keccak256("mint-b-live"), sigB);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "mint should refresh the silence timer");
    }

    // SC-3XU0: and that refresh actually defers the emergency cancel
    function test_mintPositionForDefersEmergencyCancel() public {
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, int24(0), int24(100), 1000, keccak256("mint-b-defer"));
        vm.prank(operatorAddr);
        vault.mintPositionFor(lpB, int24(0), int24(100), 1000, keccak256("mint-b-defer"), sigB);

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-3XU0: merging same-range positions is likewise proof of life
    function test_mergePositionsRefreshesSilenceTimer() public {
        // Give LP-A a second position on the identical range so the two can be merged
        bytes memory sigA2 = _signMintIntent(LP_A_PK, lpA, int24(0), int24(100), 1000, keccak256("mint-a-2"));
        vm.prank(operatorAddr);
        uint256 positionIdA2 = vault.mintPositionFor(lpA, int24(0), int24(100), 1000, keccak256("mint-a-2"), sigA2);

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

        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.notifyFees(100);

        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, int24(0), int24(100), 1000, keccak256("mint-b-paused"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mintPositionFor(lpB, int24(0), int24(100), 1000, keccak256("mint-b-paused"), sigB);

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

// ── Regression: fee-growth wraparound (audit NM-0986-Prophet) ──
//   Emergency cancel succeeds and pays out correctly even when a
//   position's fee delta wraps mod 2^256
// ─────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────
// Base test contract for the emergencyCancelAll wraparound reproduction.
//
// _computeFeeGrowthInside (fixed in T-001) can legitimately return a value
// that is small relative to a position's OWN feeGrowthInsideLastX128
// snapshot, whenever that snapshot was itself the wrapped (mod-2^256) result
// of an earlier _computeFeeGrowthInside call -- exactly what the audit
// describes happening at mint time for a position sharing an
// already-initialized tick. emergencyCancelAll's per-position payout loop
// then computes `fees = liquidity * (fresh - snapshot) / Q128`, which
// underflows if the fresh value is smaller than the stored snapshot.
//
// Rather than re-deriving the exact multi-step mint/cross/notify sequence
// that produces a wrapped snapshot naturally (already exercised end-to-end
// in UC-U07A's fee-growth-wraparound regression section), this test
// constructs the condition
// directly, with a storage write on the position's own feeGrowthInsideLastX128 slot --
// pinning FR-JXQP's contract precisely: "the payout loop must not revert
// regardless of how the stored snapshot arrived at that value."
// ──────────────────────────────────────────────
contract EmergencyCancelWraparoundTestBase is ConditionalTokensFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(1e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 posOrdinary;
    uint256 posWrapped;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        returns (uint256)
    {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _notifyFees(uint256 amount) internal {
        mockUsdc.mint(address(vault), amount);
        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    /// @dev Overwrites positions[id].feeGrowthInsideLastX128 directly, bypassing
    ///      the normal mint/collect/merge write paths.
    function _setFeeGrowthInsideLast(uint256 id, uint256 value) internal {
        VaultStorage.setFeeGrowthInsideLast(stdstore, address(vault), id, value);
    }

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
    }
}

// ──────────────────────────────────────────────
// FR-JXQP: emergency cancel succeeds and pays out correctly despite a
// wrapped fee-delta snapshot on one of the positions being force-closed
// What: a position's feeGrowthInsideLastX128 snapshot can legitimately be a
//       wrapped (mod-2^256), near-type(uint256).max value -- the correct
//       representation _computeFeeGrowthInside produces per FR-U07H when a
//       stale tick is involved (see UC-U07A's fee-growth-wraparound
//       regression section). When
//       emergencyCancelAll later recomputes a small, ordinary feeGrowthInside
//       for the SAME range, its own `fresh - snapshot` line underflows unless
//       wrapped in unchecked. Before the fix, this reverts the ENTIRE
//       transaction -- bricking the one recovery path this feature exists to
//       guarantee, stranding every other position holder's principal too.
// Why:  This is the highest-severity consequence named in audit
//       NM-0986-Prophet: an attacker can "mine" a tick into this state to
//       brick emergencyCancelAll for every LP in the vault, not just the
//       position sharing the tick.
// ──────────────────────────────────────────────
contract EmergencyCancelWraparoundTest is EmergencyCancelWraparoundTestBase {
    event EmergencyCancelExecuted(address indexed caller);

    function setUp() public override {
        super.setUp();

        // An ordinary, unrelated position so the vault has activeLiquidity
        // and something else to pay out alongside the wrapped one.
        posOrdinary = _mintPosition(int24(0), int24(1000), 5000, keccak256("ordinary"));
        _notifyFees(1000);

        // A position whose snapshot models the exact wrapped value
        // _computeFeeGrowthInside can legitimately produce: near
        // type(uint256).max, representing "a small negative number" mod 2^256.
        posWrapped = _mintPosition(int24(100), int24(200), 500, keccak256("wrapped"));
        _setFeeGrowthInsideLast(posWrapped, type(uint256).max - 1000);

        _warpPastTimelock();
    }

    // FR-JXQP: emergencyCancelAll succeeds instead of reverting on the
    // position whose snapshot is a wrapped value.
    function test_emergencyCancelSucceedsDespiteWrappedSnapshot() public {
        vm.prank(lp);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "vault should transition to Cancelled");
    }

    // FR-JXQP: every position -- the ordinary one and the wrapped one -- is
    // zeroed and every owner is paid at least their principal. No position
    // gets stranded because one of them required wraparound arithmetic.
    function test_allPositionsArePaidAndZeroedDespiteWrappedSnapshot() public {
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.emergencyCancelAll();

        (,,, uint128 liqOrdinary,,) = vault.positions(posOrdinary);
        (,,, uint128 liqWrapped,,) = vault.positions(posWrapped);
        assertEq(liqOrdinary, 0, "ordinary position liquidity should be zeroed");
        assertEq(liqWrapped, 0, "wrapped-snapshot position liquidity should be zeroed");

        // LP deposited 5000 (ordinary) + 500 (wrapped) = 5500 USDC principal.
        assertGe(mockUsdc.balanceOf(lp) - lpBalBefore, 5500, "LP should receive at least the total principal back");
    }

    // FR-JXQP: EmergencyCancelExecuted is still emitted.
    function test_emitsEmergencyCancelExecutedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit EmergencyCancelExecuted(lp);

        vm.prank(lp);
        vault.emergencyCancelAll();
    }
}
