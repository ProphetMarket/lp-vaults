// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TVS1: Update Current Tick
// Integration tests for every scenario in this use case.
// Covers: SC-TVS2, SC-TVS3, SC-TVS4, SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8, SC-5IDH, SC-5IDI, SC-5IDJ, SC-5IDL, SC-A2ZT

import {Test, Vm} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {VaultStorage} from "../../fixtures/VaultStorage.sol";

// ──────────────────────────────────────────────
// Base test contract for updateTick scenarios.
// Deploys factory + vault clone, mints two positions to set up initialized
// ticks at 0, 100, 200, notifies fees to give feeGrowthGlobalX128 > 0.
//
// Tick state after setUp:
//   tick 0:   liquidityGross=10e18, liquidityNet=+10e18, feeGrowthOutside=feeGrowthGlobal
//   tick 100: liquidityGross=30e18, liquidityNet=+10e18, feeGrowthOutside=0
//   tick 200: liquidityGross=20e18, liquidityNet=-20e18, feeGrowthOutside=0
//   currentTick=0, activeLiquidity=10e18
// ──────────────────────────────────────────────
contract UpdateTickTestBase is LPVaultFixture {
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
    uint128 minFirstLiq = uint128(10e18);

    // Declare events for vm.expectEmit matching
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // Position A: [0, 100) with 1000 USDC → liquidity = 10e18
        _mintPosition(int24(0), int24(100), 1000, keccak256("pos-a"));

        // Position B: [100, 200) with 2000 USDC → liquidity = 20e18
        _mintPosition(int24(100), int24(200), 2000, keccak256("pos-b"));

        // Notify 500 USDC fees → feeGrowthGlobalX128 = mulDiv(500, 2^128, 10e18)
        _notifyFees(vault, operatorAddr, 500);
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
    }
}

// ──────────────────────────────────────────────
// SC-TVS2: Price increases crossing initialized ticks (left-to-right)
// What: Operator calls updateTick(150) from currentTick=0. Tick 100 is the
//       only initialized tick in (0, 150]. The crossing flips feeGrowthOutside
//       at tick 100 and adds its +10e18 liquidityNet to activeLiquidity.
// Why:  L-to-R is the primary happy path. feeGrowthOutside flip correctness
//       is critical — every subsequent collect depends on it.
// ──────────────────────────────────────────────
contract UpdateTickLeftToRightTest is UpdateTickTestBase {
    // SC-TVS2: currentTick advances to newTick
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        assertEq(vault.currentTick(), int24(150), "currentTick should be 150");
    }

    // SC-TVS2: activeLiquidity reflects cumulative liquidityNet
    // Position A exits range at tick 100, position B enters → net +10e18
    function test_activeLiquidityAdjusted() public {
        uint128 before_ = vault.activeLiquidity();
        assertEq(before_, 10e18, "precondition: activeLiquidity should be 10e18");

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        // tick 100 liquidityNet = -10e18 (from A upper) + 20e18 (from B lower) = +10e18
        assertEq(vault.activeLiquidity(), 20e18, "activeLiquidity should be 20e18 after crossing tick 100");
    }

    // SC-TVS2: feeGrowthOutsideX128 at tick 100 flipped
    function test_feeGrowthOutsideFlipped() public {
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        (,, uint256 feeGrowthOutsideBefore,) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideBefore, 0, "precondition: tick 100 feeGrowthOutside should be 0");

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        (,, uint256 feeGrowthOutsideAfter,) = vault.ticks(int24(100));
        assertEq(
            feeGrowthOutsideAfter, feeGrowthGlobal, "tick 100 feeGrowthOutside should equal feeGrowthGlobal after flip"
        );
    }

    // SC-TVS2: TickUpdated event emitted with correct values
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(150), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));
    }

    // SC-TVS2: lastOperatorActivityTimestamp recorded
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(1000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        assertEq(vault.lastOperatorActivityTimestamp(), 1000, "lastOperatorActivityTimestamp should be block.timestamp");
    }
}

// ──────────────────────────────────────────────
// SC-TVS3: Price decreases crossing initialized ticks (right-to-left)
// What: Starting from currentTick=150 (after a forward move), Operator calls
//       updateTick(50). Tick 100 is crossed R-to-L: feeGrowthOutside flips
//       back, activeLiquidity has liquidityNet subtracted.
// Why:  R-to-L is the reverse path. The liquidityNet subtraction and
//       feeGrowthOutside double-flip must produce symmetric state.
// ──────────────────────────────────────────────
contract UpdateTickRightToLeftTest is UpdateTickTestBase {
    function setUp() public override {
        super.setUp();
        // Move to tick 150 first (crosses tick 100 L-to-R)
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));
    }

    // SC-TVS3: currentTick set to newTick
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.currentTick(), int24(50), "currentTick should be 50");
    }

    // SC-TVS3: activeLiquidity reverts to pre-forward-move value
    // Crossing tick 100 R-to-L subtracts liquidityNet (+10e18) → 20e18 - 10e18 = 10e18
    function test_activeLiquidityAdjusted() public {
        assertEq(vault.activeLiquidity(), 20e18, "precondition: activeLiquidity should be 20e18 at tick 150");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.activeLiquidity(), 10e18, "activeLiquidity should be 10e18 after R-to-L crossing");
    }

    // SC-TVS3: feeGrowthOutsideX128 at tick 100 flips back to 0
    function test_feeGrowthOutsideFlippedBack() public {
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        (,, uint256 feeGrowthOutsideBefore,) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideBefore, feeGrowthGlobal, "precondition: tick 100 fGO should be feeGrowthGlobal");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        (,, uint256 feeGrowthOutsideAfter,) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideAfter, 0, "tick 100 feeGrowthOutside should flip back to 0");
    }

    // SC-TVS3: flip formula is `global - old`, not `global` alone.
    // After setUp, tick 100 fGO = G1 (the first feeGrowthGlobal). We then
    // notify a second fee batch so feeGrowthGlobal becomes G2 > G1. When we
    // cross tick 100 R-to-L, fGO should become G2 - G1, NOT G2.
    // A mutation like `info.feeGrowthOutsideX128 = feeGrowthGlobalX128`
    // would set fGO to G2, which this test catches.
    function test_feeGrowthOutsideFlipUsesOldValue() public {
        uint256 g1 = vault.feeGrowthGlobalX128();
        (,, uint256 fGOBefore,) = vault.ticks(int24(100));
        assertEq(fGOBefore, g1, "precondition: tick 100 fGO equals G1");

        // Second fee batch — activeLiquidity is now 20e18 (after L-to-R cross)
        // so the increment is mulDiv(750, Q128, 20e18) — strictly smaller than G1
        // but additive, so G2 > G1 and (G2 - G1) != G2 and (G2 - G1) != 0.
        _notifyFees(vault, operatorAddr, 750);
        uint256 g2 = vault.feeGrowthGlobalX128();
        assertGt(g2, g1, "precondition: G2 > G1");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        (,, uint256 fGOAfter,) = vault.ticks(int24(100));
        assertEq(fGOAfter, g2 - g1, "tick 100 fGO should be G2 - G1, not G2");
        assertGt(fGOAfter, 0, "fGO must be non-zero (guards against `new = global - global` mutation)");
        assertTrue(fGOAfter != g2, "fGO must differ from G2 (guards against `new = global` mutation)");
    }

    // SC-TVS3: TickUpdated event emitted for R-to-L direction
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(150), int24(50), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));
    }

    // SC-TVS3: lastOperatorActivityTimestamp updated
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(2000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.lastOperatorActivityTimestamp(), 2000, "lastOperatorActivityTimestamp should be 2000");
    }
}

// ──────────────────────────────────────────────
// SC-TVS4: No initialized ticks in range
// What: Operator calls updateTick(50) from currentTick=0. The only initialized
//       ticks above 0 are 100 and 200, both outside (0, 50]. No crossings
//       occur; activeLiquidity stays the same.
// Why:  The TickBitmap must correctly report "no initialized ticks in range"
//       and the function must still update currentTick and timestamp.
// ──────────────────────────────────────────────
contract UpdateTickNoTicksCrossedTest is UpdateTickTestBase {
    // SC-TVS4: currentTick advances even with no crossings
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.currentTick(), int24(50), "currentTick should be 50");
    }

    // SC-TVS4: activeLiquidity unchanged
    function test_activeLiquidityUnchanged() public {
        uint128 before_ = vault.activeLiquidity();

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.activeLiquidity(), before_, "activeLiquidity should be unchanged");
    }

    // SC-TVS4: TickUpdated event with ticksCrossed = 0
    function test_emitsTickUpdatedWithZeroCrossings() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(50), 0);

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));
    }

    // SC-TVS4: lastOperatorActivityTimestamp still updated
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(3000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.lastOperatorActivityTimestamp(), 3000, "timestamp should be updated even with 0 crossings");
    }
}

// ──────────────────────────────────────────────
// SC-TVS5: Too many initialized ticks to cross
// What: A vault with tickSpacing=1 and 258 initialized ticks in the crossing
//       range. updateTick must revert with TooManyTicksCrossed when the count
//       exceeds the MAX_TICK_CROSSINGS cap (256).
// Why:  Gas griefing prevention. Without the cap, a large price move could
//       exhaust the block gas limit.
// ──────────────────────────────────────────────
contract UpdateTickTooManyTicksTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        // Create vault with tickSpacing=1 for dense tick initialization
        vault = LPVault(_createVault(factory, oracleAddr, keccak256("many-ticks"), int24(1), uint128(1)));

        // Fund LP generously

        // First position [0, 300) — meets minimumFirstLiquidity floor
        _mintPositionOnVault(int24(0), int24(300), 300, keccak256("big-pos"));

        // Mint 129 positions to create 258 initialized ticks in (0, 260]
        // Each position [2i+1, 2i+2) creates ticks at odd and even indices
        for (uint256 i = 0; i < 129; i++) {
            // casting is safe because i < 129 so i*2+2 <= 260, well within int24 range
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 lower = int24(int256(i * 2 + 1));
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 upper = int24(int256(i * 2 + 2));
            bytes32 intentId = keccak256(abi.encode("many-", i));
            _mintPositionOnVault(lower, upper, 1, intentId);
        }
    }

    function _mintPositionOnVault(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-TVS5: reverts when crossing more than 256 initialized ticks
    function test_revertsWithTooManyTicksCrossed() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(260));
    }

    // SC-TVS5: state unchanged after revert (implicit in EVM revert semantics,
    // but we verify currentTick for belt-and-suspenders)
    function test_stateUnchangedAfterRevert() public {
        int24 tickBefore = vault.currentTick();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(260));

        assertEq(vault.currentTick(), tickBefore, "currentTick should be unchanged after revert");
    }

    // SC-TVS5: R-to-L direction also reverts with TooManyTicksCrossed
    // Moves the tick forward first, then tries a large reverse move.
    function test_revertsRightToLeftTooManyTicks() public {
        // First move forward to tick 260 (crossing ≤256 ticks since
        // some positions share ticks). Use a tick with exactly 256 crossings.
        // Move to tick 258 — crosses ticks 1..258 = 258 ticks. But we have
        // only 258 initialized ticks in (0, 260], so moving to 258 crosses
        // ticks 1..258 = 258 > 256. That also reverts. Let me move to 256.
        // ticks in (0, 256]: 1..256 = 256 ticks exactly. At the boundary.
        vm.prank(operatorAddr);
        vault.updateTick(int24(256));

        // Now try to move back from 256 to -1. Ticks in (-1, 256]:
        // 0, 1, 2, ..., 256 = 257 ticks > 256. Should revert.
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(-1));
    }
}

// ──────────────────────────────────────────────
// SC-TVS6: Non-operator caller
// What: LP, Admin, Oracle, and arbitrary addresses all get NotOperator when
//       calling updateTick. Only registered Operators may move the tick.
// Why:  Access control prevents unauthorized price manipulation.
// ──────────────────────────────────────────────
contract UpdateTickNonOperatorTest is UpdateTickTestBase {
    // SC-TVS6: LP calling reverts
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: Admin calling reverts
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: Oracle calling reverts
    function test_revertsWhenOracleCalls() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: arbitrary address calling reverts
    function test_revertsWhenArbitraryAddressCalls() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }
}

// ──────────────────────────────────────────────
// SC-TVS7: Same tick refreshes only the heartbeat
// What: Operator calls updateTick(currentTick). The call succeeds, refreshes
//       lastOperatorActivityTimestamp, and does nothing else: no crossing, no
//       event, no change to the tick, the liquidity, or the fee accumulator.
// Why:  The keeper reports every 60 seconds and after fills, and most markets
//       keep the same price, so the unchanged report is the normal case. A
//       revert would cost gas and refresh nothing (ADR-9J43).
// Example: currentTick=100 with ticks at 0 and 200 around it; updateTick(100)
//          succeeds, emits nothing, and moves only the heartbeat.
// ──────────────────────────────────────────────
contract UpdateTickSameTickTest is UpdateTickTestBase {
    function setUp() public override {
        super.setUp();
        // Put an initialized tick on each side of the current one: 0 below, 200 above.
        vm.prank(operatorAddr);
        vault.updateTick(int24(100));
        vm.warp(block.timestamp + 60);
    }

    // SC-TVS7: the unchanged report succeeds and refreshes the heartbeat
    function test_whenTickIsUnchangedThenHeartbeatRefreshes() public {
        uint256 before = vault.lastOperatorActivityTimestamp();
        assertLt(before, block.timestamp, "precondition: the heartbeat is stale");

        vm.prank(operatorAddr);
        vault.updateTick(int24(100));

        assertEq(
            vault.lastOperatorActivityTimestamp(), block.timestamp, "the unchanged report must refresh the heartbeat"
        );
    }

    // SC-TVS7: no TickUpdated event, because the tick did not move
    function test_whenTickIsUnchangedThenNoEventIsEmitted() public {
        vm.recordLogs();

        vm.prank(operatorAddr);
        vault.updateTick(int24(100));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "an unchanged report must emit nothing");
    }

    // SC-TVS7: nothing else moves — tick, liquidity, fee accumulator, tick records
    function test_whenTickIsUnchangedThenNoOtherStateChanges() public {
        int24 tickBefore = vault.currentTick();
        uint128 liquidityBefore = vault.activeLiquidity();
        uint256 feeGrowthBefore = vault.feeGrowthGlobalX128();
        bytes32 tickRecordsBefore = _tickRecordsHash();

        vm.prank(operatorAddr);
        vault.updateTick(int24(100));

        assertEq(vault.currentTick(), tickBefore, "currentTick must not move");
        assertEq(vault.activeLiquidity(), liquidityBefore, "activeLiquidity must not move");
        assertEq(vault.feeGrowthGlobalX128(), feeGrowthBefore, "feeGrowthGlobalX128 must not move");
        assertEq(_tickRecordsHash(), tickRecordsBefore, "the tick records at 0, 100, and 200 must not move");
    }

    /// @dev One hash over the three initialized tick records (liquidityGross,
    ///      liquidityNet, feeGrowthOutsideX128 at ticks 0, 100, and 200).
    function _tickRecordsHash() internal view returns (bytes32) {
        (uint128 g0, int128 n0, uint256 o0,) = vault.ticks(int24(0));
        (uint128 g100, int128 n100, uint256 o100,) = vault.ticks(int24(100));
        (uint128 g200, int128 n200, uint256 o200,) = vault.ticks(int24(200));
        return keccak256(abi.encode(g0, n0, o0, g100, n100, o100, g200, n200, o200));
    }
}

// ──────────────────────────────────────────────
// SC-TVS8: Vault not in Active phase
// What: When the vault phase is not Active (e.g., WindDown), updateTick
//       reverts with VaultNotActive because price updates don't apply to
//       resolved markets.
// Why:  After wind-down there are no more trades, so tick updates are invalid.
// ──────────────────────────────────────────────
contract UpdateTickNotActiveTest is UpdateTickTestBase {
    function setUp() public override {
        super.setUp();
        // Move the vault to WindDown (phase 2) through the Oracle.
        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-TVS8: reverts with VaultNotActive
    function test_revertsWhenVaultNotActive() public {
        assertEq(vault.phase(), 2, "precondition: phase should be WindDown (2)");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(int24(150));
    }
}

// ──────────────────────────────────────────────
// FR-TVSJ: TickBitmap tracks initialized ticks
// What: After minting positions, the TickBitmap correctly reflects which
//       ticks are initialized. The bitmap enables O(1) per-word lookup of
//       the next initialized tick.
// Why:  The bitmap is the backbone of updateTick's efficiency. Without it,
//       the function would need to iterate every tick in the range.
// ──────────────────────────────────────────────
contract TickBitmapTest is UpdateTickTestBase {
    // FR-TVSJ: bitmap bit set at tick 0 (word 0, bit 0)
    function test_bitmapSetAtTick0() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 0) != 0, "tick 0 should be set in bitmap word 0");
    }

    // FR-TVSJ: bitmap bit set at tick 100 (word 0, bit 100)
    function test_bitmapSetAtTick100() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 100) != 0, "tick 100 should be set in bitmap word 0");
    }

    // FR-TVSJ: bitmap bit set at tick 200 (word 0, bit 200)
    function test_bitmapSetAtTick200() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 200) != 0, "tick 200 should be set in bitmap word 0");
    }

    // FR-TVSJ: uninitialized tick has no bitmap bit
    function test_uninitializedTickNotInBitmap() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 50) == 0, "tick 50 should NOT be set in bitmap");
    }

    // FR-TVSJ: cross-word boundary — tick 260 (word 1, bit 4) via a new position
    function test_bitmapCrossWordBoundary() public {
        // Mint a position at [260, 270) to initialize ticks in word 1
        _mintPosition(int24(260), int24(270), 1000, keccak256("pos-word1"));

        // Tick 260 is word 1 (260 >> 8 = 1), bit 4 (260 & 0xFF = 4)
        uint256 word1 = vault.tickBitmap(int16(1));
        assertTrue(word1 & (1 << 4) != 0, "tick 260 should be set in bitmap word 1");

        // Tick 270 is word 1, bit 14 (270 & 0xFF = 14)
        assertTrue(word1 & (1 << 14) != 0, "tick 270 should be set in bitmap word 1");
    }

    // FR-TVSJ: updateTick crosses word boundary correctly
    function test_updateTickCrossesWordBoundary() public {
        // Mint a position at [260, 270) so tick 260 is initialized in word 1
        _mintPosition(int24(260), int24(270), 1000, keccak256("pos-cross-word"));

        // Move from 0 to 265 — should cross ticks 100, 200 (word 0) and 260 (word 1)
        vm.prank(operatorAddr);
        vault.updateTick(int24(265));

        assertEq(vault.currentTick(), int24(265), "currentTick should be 265");
    }
}

// ── Regression: fee-growth wraparound (audit NM-0986-Prophet) ──
//   Tick crossing succeeds even when a tick's feeGrowthOutside flip
//   wraps mod 2^256
// ─────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────
// Base test contract for the _crossTick wraparound reproduction.
//
// _crossTick's flip (`info.feeGrowthOutsideX128 = feeGrowthGlobalX128 -
// info.feeGrowthOutsideX128`) uses the identical mod-2^256 pattern as
// _computeFeeGrowthInside, mirroring Uniswap v3's audited _crossTick exactly.
// This test constructs a tick whose feeGrowthOutsideX128 exceeds the current
// feeGrowthGlobalX128 directly with a storage write, pinning FR-TVSA's contract:
// "the flip must not revert regardless of how the tick's outside snapshot
// arrived at that value" -- the same defensive posture Uniswap v3 itself
// applies to this exact line.
// ──────────────────────────────────────────────
contract CrossTickWraparoundTestBase is LPVaultFixture {
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

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    uint256 posId;

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // A position spanning [0, 200) initializes ticks 0 and 200, and
        // keeps activeLiquidity nonzero so notifyFees can run.
        posId = _mintPosition(int24(0), int24(200), 1000, keccak256("wide"));
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        returns (uint256)
    {
        return _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
    }

    /// @dev Overwrites ticks[tick].feeGrowthOutsideX128 directly.
    function _setFeeGrowthOutside(int24 tick, uint256 value) internal {
        VaultStorage.setFeeGrowthOutside(stdstore, address(vault), tick, value);
    }
}

// ──────────────────────────────────────────────
// FR-TVSA: crossing a tick succeeds even when its feeGrowthOutside snapshot
// exceeds the current feeGrowthGlobalX128
// What: _crossTick's flip (feeGrowthGlobalX128 - tick.feeGrowthOutsideX128)
//       underflows if the tick's stored feeGrowthOutsideX128 is larger than
//       the current global -- a state that can arise as the wrapped,
//       mod-2^256-consistent result of the same tick's fee-growth history.
//       Before the fix, crossing such a tick reverts the whole updateTick
//       call; after the fix, the flip wraps mod 2^256 and the crossing
//       succeeds, exactly mirroring Uniswap v3's own audited pattern for
//       this line.
// ──────────────────────────────────────────────
contract CrossTickWraparoundTest is CrossTickWraparoundTestBase {
    function setUp() public override {
        super.setUp();

        // Give feeGrowthGlobalX128 a modest, known value...
        _notifyFees(vault, operatorAddr, 100);

        // ...then force tick 200 (the position's upper bound, about to be
        // crossed) to a feeGrowthOutsideX128 that exceeds the current global.
        _setFeeGrowthOutside(int24(200), type(uint256).max - 1000);
    }

    // FR-TVSA: crossing tick 200 succeeds instead of reverting. The target
    // is exactly tick 200 (not beyond it) so the crossing loop's outer
    // `while (tick < newTick)` condition is satisfied the instant tick 200
    // is reached -- exercising only _crossTick's flip on tick 200. This
    // vault has no initialized tick above 200, and the search stops at the
    // target's word (FR-5IDE), so no scan past 200 runs.
    function test_crossingSucceedsDespiteOutsideExceedingGlobal() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(200));

        assertEq(vault.currentTick(), int24(200), "currentTick should advance to 200");
    }

    // FR-TVSA: TickUpdated is still emitted with the correct crossing count.
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(200), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(200));
    }

    // FR-TVSA: activeLiquidity still adjusts correctly by the tick's
    // liquidityNet despite the wrapped feeGrowthOutside flip.
    function test_activeLiquidityStillAdjustsCorrectly() public {
        uint128 before_ = vault.activeLiquidity();

        vm.prank(operatorAddr);
        vault.updateTick(int24(200));

        // Tick 200 is the position's upper bound (liquidityNet negative);
        // crossing L-to-R removes it from activeLiquidity. Position liquidity
        // = usdcAmount(1000) * LIQUIDITY_PRECISION(1e18) / rangeWidth(200) = 5e18.
        assertEq(vault.activeLiquidity(), before_ - 5e18, "activeLiquidity should drop by the position's liquidity");
    }
}

// ──────────────────────────────────────────────
// Base test contract for the bounded tick search (FR-5IDE, FR-5IDF, NFR-5IDG).
// Deploys a fresh vault with minimumFirstLiquidity = 1 and no positions, so
// every scenario states exact numbers from one mint, and the first-mint floor
// never rejects a plant. Positions are planted through _escrowAndMint at
// currentTick = 0, out of range, and only then is the start tick written to
// storage, so activeLiquidity stays consistent at both ticks.
//
// The existing UpdateTickTestBase keeps its three positions and its floor of
// 10e18 and serves no contract below: a storage-written tick above its
// positions would leave activeLiquidity stale.
// ──────────────────────────────────────────────
contract BoundedTickSearchTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;

    /// @dev The Polygon block gas limit. A move that a planted tick pushed past
    ///      it is the denial of service of audit issue 6.10.
    uint256 constant POLYGON_BLOCK_GAS_LIMIT = 30_000_000;

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public virtual {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, keccak256("bounded-search"), int24(10), uint128(1)));
    }

    /// @dev Writes the start tick. Call it after every plant, and only with no position in range
    ///      at the old tick, at the new one, or between them (see VaultStorage.setCurrentTick):
    ///      the write books nothing in the solvency ledger (FEAT-9BQZ), so a position the price
    ///      skipped would be crossed back later with no shift to reverse.
    function _setCurrentTick(int24 tick) internal {
        VaultStorage.setCurrentTick(stdstore, address(vault), tick);
    }

    /// @dev Plants an initialized tick through storage, with no position behind it: liquidityGross
    ///      of 1 and the bitmap bit. The extreme-word tests use it because a mint is bounded to the
    ///      price scale [0, 10000] (FEAT-T7AF FR-T7B2), so no mint can reach tick 8,388,590.
    function _plantTick(int24 tick) internal {
        VaultStorage.plantTick(stdstore, address(vault), tick, uint128(1));
    }

    /// @dev Plants one position, which initializes its two ticks in the bitmap.
    function _plant(int24 tickLower, int24 tickUpper, uint256 usdcAmount) internal returns (uint256) {
        return _escrowAndMint(
            vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, keccak256(abi.encode(tickLower, tickUpper))
        );
    }

    /// @dev Runs one Operator move and returns the gas the call used.
    function _move(int24 newTick) internal returns (uint256 gasUsed) {
        vm.prank(operatorAddr);
        uint256 before = gasleft();
        vault.updateTick(newTick);
        gasUsed = before - gasleft();
    }
}

// ──────────────────────────────────────────────
// SC-5IDH: Initialized tick far above the target is never searched
// What: Ticks 8388590 and 8388600, planted in storage, put two bits in the
//       highest bitmap word (32767). From currentTick = 100 the Operator moves
//       to 300. The search stops at the word that holds 300 and never reads
//       toward word 32767.
// Why:  Audit issue 6.10, upward. Without the bound the move reads more than
//       32,000 words and costs 76,618,321 gas, past the Polygon block limit.
// ──────────────────────────────────────────────
contract BoundedTickSearchFarAboveTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        _plantTick(int24(8388590));
        _plantTick(int24(8388600));
        _setCurrentTick(int24(100));
    }

    // SC-5IDH: the move succeeds with zero crossings and stays under the block gas limit
    function test_whenTickIsPlantedFarAboveThenMoveCompletesWithinBlockGasLimit() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(100), int24(300), 0);

        uint256 gasUsed = _move(int24(300));

        assertEq(vault.currentTick(), int24(300), "currentTick should be 300");
        assertLt(gasUsed, POLYGON_BLOCK_GAS_LIMIT, "the move must fit in one Polygon block");
    }

    // SC-5IDH: activeLiquidity is unchanged and the planted ticks are untouched
    function test_whenTickIsPlantedFarAboveThenPlantedTicksAreUntouched() public {
        (uint128 gLower, int128 nLower, uint256 oLower,) = vault.ticks(int24(8388590));
        (uint128 gUpper, int128 nUpper, uint256 oUpper,) = vault.ticks(int24(8388600));

        _move(int24(300));

        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not move");
        (uint128 gLowerAfter, int128 nLowerAfter, uint256 oLowerAfter,) = vault.ticks(int24(8388590));
        (uint128 gUpperAfter, int128 nUpperAfter, uint256 oUpperAfter,) = vault.ticks(int24(8388600));
        assertEq(gLowerAfter, gLower, "tick 8388590 liquidityGross must not move");
        assertEq(nLowerAfter, nLower, "tick 8388590 liquidityNet must not move");
        assertEq(oLowerAfter, oLower, "tick 8388590 feeGrowthOutside must not move");
        assertEq(gUpperAfter, gUpper, "tick 8388600 liquidityGross must not move");
        assertEq(nUpperAfter, nUpper, "tick 8388600 liquidityNet must not move");
        assertEq(oUpperAfter, oUpper, "tick 8388600 feeGrowthOutside must not move");
    }

    // SC-5IDH: the heartbeat is refreshed
    function test_whenTickIsPlantedFarAboveThenHeartbeatRefreshes() public {
        vm.warp(4000);
        _move(int24(300));
        assertEq(vault.lastOperatorActivityTimestamp(), 4000, "lastOperatorActivityTimestamp should be 4000");
    }
}

// ──────────────────────────────────────────────
// SC-5IDI: Initialized tick far below the target is never searched
// What: Ticks -8388600 and -8388590, planted in storage, put two bits in the
//       lowest bitmap word (-32768). From currentTick = 300 the Operator moves
//       down to 100. The search stops at the word that holds 100.
// Why:  Audit issue 6.10, downward.
// ──────────────────────────────────────────────
contract BoundedTickSearchFarBelowTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        _plantTick(int24(-8388600));
        _plantTick(int24(-8388590));
        _setCurrentTick(int24(300));
    }

    // SC-5IDI: the move succeeds with zero crossings and stays under the block gas limit
    function test_whenTickIsPlantedFarBelowThenMoveCompletesWithinBlockGasLimit() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(300), int24(100), 0);

        uint256 gasUsed = _move(int24(100));

        assertEq(vault.currentTick(), int24(100), "currentTick should be 100");
        assertLt(gasUsed, POLYGON_BLOCK_GAS_LIMIT, "the move must fit in one Polygon block");
    }

    // SC-5IDI: activeLiquidity is unchanged and the planted ticks are untouched
    function test_whenTickIsPlantedFarBelowThenPlantedTicksAreUntouched() public {
        (uint128 gLower, int128 nLower, uint256 oLower,) = vault.ticks(int24(-8388600));
        (uint128 gUpper, int128 nUpper, uint256 oUpper,) = vault.ticks(int24(-8388590));

        _move(int24(100));

        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not move");
        (uint128 gLowerAfter, int128 nLowerAfter, uint256 oLowerAfter,) = vault.ticks(int24(-8388600));
        (uint128 gUpperAfter, int128 nUpperAfter, uint256 oUpperAfter,) = vault.ticks(int24(-8388590));
        assertEq(gLowerAfter, gLower, "tick -8388600 liquidityGross must not move");
        assertEq(nLowerAfter, nLower, "tick -8388600 liquidityNet must not move");
        assertEq(oLowerAfter, oLower, "tick -8388600 feeGrowthOutside must not move");
        assertEq(gUpperAfter, gUpper, "tick -8388590 liquidityGross must not move");
        assertEq(nUpperAfter, nUpper, "tick -8388590 liquidityNet must not move");
        assertEq(oUpperAfter, oUpper, "tick -8388590 feeGrowthOutside must not move");
    }

    // SC-5IDI: the heartbeat is refreshed
    function test_whenTickIsPlantedFarBelowThenHeartbeatRefreshes() public {
        vm.warp(5000);
        _move(int24(100));
        assertEq(vault.lastOperatorActivityTimestamp(), 5000, "lastOperatorActivityTimestamp should be 5000");
    }
}

// ──────────────────────────────────────────────
// SC-5IDJ: Initialized tick inside the target's own word is still crossed
// What: A position at [260, 600) with 3400 USDC gives liquidity 10e18 and
//       puts tick 260 in bitmap word 1, the word that also holds the target
//       300. The move from 100 to 300 crosses 260 and not 600.
// Why:  A bound that stopped one word short of the target would skip a
//       legitimate crossing. This proves the bound includes the target's word.
// ──────────────────────────────────────────────
contract BoundedTickSearchTargetWordTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        _plant(int24(260), int24(600), 3400);
        _setCurrentTick(int24(100));
    }

    // SC-5IDJ: tick 260 is crossed and activeLiquidity becomes 10e18
    function test_whenTickIsInTargetWordThenItIsCrossed() public {
        assertEq(vault.activeLiquidity(), 0, "precondition: activeLiquidity should be 0");

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(100), int24(300), 1);

        _move(int24(300));

        assertEq(vault.currentTick(), int24(300), "currentTick should be 300");
        assertEq(vault.activeLiquidity(), 10e18, "activeLiquidity should be 10e18 after crossing tick 260");
    }

    // SC-5IDJ: tick 260's feeGrowthOutside flipped, tick 600's did not
    function test_whenTickIsInTargetWordThenOnlyThatTickFlips() public {
        // Give feeGrowthGlobalX128 a nonzero value, so a flip is observable.
        // notifyFees needs active liquidity, so a second position in range at 100 pays for it.
        _plant(int24(0), int24(200), 200);
        _notifyFees(vault, operatorAddr, 100);
        uint256 global = vault.feeGrowthGlobalX128();
        assertGt(global, 0, "precondition: feeGrowthGlobalX128 should be nonzero");
        (,, uint256 outside600Before,) = vault.ticks(int24(600));

        _move(int24(300));

        (,, uint256 outside260,) = vault.ticks(int24(260));
        (,, uint256 outside600,) = vault.ticks(int24(600));
        assertEq(outside260, global, "tick 260 feeGrowthOutside should flip to feeGrowthGlobal");
        assertEq(outside600, outside600Before, "tick 600 must not be crossed");
    }
}

// ──────────────────────────────────────────────
// SC-5IDL: Target in the highest bitmap word with no initialized ticks
// What: No positions. currentTick is written to 8388000 (word 32765) and the
//       Operator moves to 8388600 (word 32767, the highest). The search steps
//       into word 32767, checks it, and stops instead of stepping past it.
// Why:  Audit issue 6.12, upward: the loop reached word 32767 and wordPos++
//       overflowed with an arithmetic panic.
// ──────────────────────────────────────────────
contract BoundedTickSearchHighestWordTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(8388000));
    }

    // SC-5IDL: the move succeeds with zero crossings
    function test_whenTargetIsInHighestWordThenMoveSucceeds() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(8388000), int24(8388600), 0);

        _move(int24(8388600));

        assertEq(vault.currentTick(), int24(8388600), "currentTick should be 8388600");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not move");
    }

    // SC-5IDL: the heartbeat is refreshed
    function test_whenTargetIsInHighestWordThenHeartbeatRefreshes() public {
        vm.warp(6000);
        _move(int24(8388600));
        assertEq(vault.lastOperatorActivityTimestamp(), 6000, "lastOperatorActivityTimestamp should be 6000");
    }
}

// ──────────────────────────────────────────────
// SC-A2ZT: Start inside the lowest bitmap word with no initialized ticks
// What: No positions. currentTick is written to -8388400, inside the lowest
//       word (-32768), and the Operator moves down to -8388600. The start
//       word has no set bit, and the search stops at the lowest word instead
//       of stepping below it.
// Why:  Audit issue 6.12, downward: the wordPos-- before the loop overflowed
//       with an arithmetic panic when the start sat in the lowest word.
// ──────────────────────────────────────────────
contract BoundedTickSearchLowestWordTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(-8388400));
    }

    // SC-A2ZT: the move succeeds with zero crossings
    function test_whenStartIsInLowestWordThenMoveSucceeds() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(-8388400), int24(-8388600), 0);

        _move(int24(-8388600));

        assertEq(vault.currentTick(), int24(-8388600), "currentTick should be -8388600");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not move");
    }

    // SC-A2ZT: the heartbeat is refreshed
    function test_whenStartIsInLowestWordThenHeartbeatRefreshes() public {
        vm.warp(7000);
        _move(int24(-8388600));
        assertEq(vault.lastOperatorActivityTimestamp(), 7000, "lastOperatorActivityTimestamp should be 7000");
    }
}

// ──────────────────────────────────────────────
// FR-5IDE, FR-5IDF: fuzz tests over both search directions
// What: Random start ticks and moves, with a plant far outside the fuzz
//       window or no plant at all, in both directions and in both extreme
//       words, and a plant inside the target's word whose crossing count the
//       test computes. Every precondition of VaultStorage.setCurrentTick
//       holds: the start tick and the target never fall inside a planted
//       range, so no position is in range at either tick.
// Why:  The scenarios pin exact values. The fuzz tests prove the search
//       terminates and reports the right result across the whole scale.
//       They assert success and crossing counts, not gas: the gas ceiling
//       lives in test/invariants/TickState.t.sol.
// ──────────────────────────────────────────────
contract BoundedTickSearchFuzzTest is BoundedTickSearchTestBase {
    /// @dev The ticks of bitmap word 32767, the highest.
    int24 constant HIGHEST_WORD_FIRST_TICK = 8388352;
    int24 constant HIGHEST_WORD_LAST_TICK = 8388607;
    /// @dev The ticks of bitmap word -32768, the lowest.
    int24 constant LOWEST_WORD_FIRST_TICK = -8388608;
    int24 constant LOWEST_WORD_LAST_TICK = -8388353;

    // FR-5IDE: an upward move past empty words completes with zero crossings
    // whatever sits in the highest word. Start in [-8,000,000, 7,999,999], move
    // in [1, 200,000], target clamped to 8,000,000; the ticks planted at
    // 8388590 and 8388600 are outside the window.
    function testFuzz_upwardMoveCompletesPastEmptyWords(int256 startSeed, uint256 moveSeed) public {
        _plantTick(int24(8388590));
        _plantTick(int24(8388600));
        int24 start = int24(bound(startSeed, -8_000_000, 7_999_999));
        int256 targetWide = int256(start) + int256(bound(moveSeed, 1, 200_000));
        int24 target = int24(targetWide > 8_000_000 ? int256(8_000_000) : targetWide);
        _setCurrentTick(start);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, 0);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must stay 0");
    }

    // FR-5IDE: a downward move past empty words completes with zero crossings
    // whatever sits in the lowest word. Start in [-7,999,999, 8,000,000], move
    // in [1, 200,000], target clamped to -8,000,000; the ticks planted at
    // -8388600 and -8388590 are outside the window.
    function testFuzz_downwardMoveCompletesPastEmptyWords(int256 startSeed, uint256 moveSeed) public {
        _plantTick(int24(-8388600));
        _plantTick(int24(-8388590));
        int24 start = int24(bound(startSeed, -7_999_999, 8_000_000));
        int256 targetWide = int256(start) - int256(bound(moveSeed, 1, 200_000));
        int24 target = int24(targetWide < -8_000_000 ? int256(-8_000_000) : targetWide);
        _setCurrentTick(start);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, 0);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must stay 0");
    }

    // FR-5IDF: every move inside the highest word completes, in both directions.
    // No plant, so the search reaches the extreme word and must stop there.
    function testFuzz_movesInsideHighestWordComplete(int256 startSeed, int256 targetSeed) public {
        int24 start = int24(bound(startSeed, HIGHEST_WORD_FIRST_TICK, HIGHEST_WORD_LAST_TICK));
        int24 target = int24(bound(targetSeed, HIGHEST_WORD_FIRST_TICK, HIGHEST_WORD_LAST_TICK));
        vm.assume(start != target);
        _setCurrentTick(start);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, 0);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
    }

    // FR-5IDF: every move inside the lowest word completes, in both directions.
    function testFuzz_movesInsideLowestWordComplete(int256 startSeed, int256 targetSeed) public {
        int24 start = int24(bound(startSeed, LOWEST_WORD_FIRST_TICK, LOWEST_WORD_LAST_TICK));
        int24 target = int24(bound(targetSeed, LOWEST_WORD_FIRST_TICK, LOWEST_WORD_LAST_TICK));
        vm.assume(start != target);
        _setCurrentTick(start);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, 0);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
    }

    // FR-5IDE: a tick inside the target's own word is crossed exactly when the
    // target reaches it. One plant at [L, L + 10) with L a multiple of 10 in
    // [1000, 5000], liquidity 1000 * 1e18 / 10 = 100e18. The start L - 300 is
    // below the plant, so the plant is out of range when the start is written.
    // The target ranges over the whole word of L, which is always above the
    // start, so the crossing count is 0 below L, 1 inside [L, L + 10), and 2
    // at or above L + 10.
    function testFuzz_tickInsideTargetWordIsCrossed(uint256 lowerSeed, int256 targetSeed) public {
        int24 lower = int24(int256(bound(lowerSeed, 100, 500) * 10));
        int24 upper = lower + 10;
        _plant(lower, upper, 1000);
        int24 start = lower - 300;
        _setCurrentTick(start);

        int24 wordFirstTick = (lower >> 8) << 8;
        int24 target = int24(bound(targetSeed, wordFirstTick, wordFirstTick + 255));
        assertGt(target, start, "precondition: the target is above the start");

        uint256 expectedCrossings = (target >= lower ? 1 : 0) + (target >= upper ? 1 : 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, expectedCrossings);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
        assertEq(
            vault.activeLiquidity(),
            expectedCrossings == 1 ? 100e18 : 0,
            "activeLiquidity holds the plant exactly while the target is inside its range"
        );
    }

    // FR-5IDE: the downward mirror. The start L + 300 is above the plant, at
    // least one word above L, so the search must step down into a lower word
    // to find the plant. Moving down crosses a tick t when target < t <= start,
    // so the count is 0 at or above L + 10, 1 inside [L, L + 10), and 2 below L.
    function testFuzz_tickInsideTargetWordIsCrossedDownward(uint256 lowerSeed, int256 targetSeed) public {
        int24 lower = int24(int256(bound(lowerSeed, 100, 500) * 10));
        int24 upper = lower + 10;
        _plant(lower, upper, 1000);
        int24 start = lower + 300;
        // A real move, not the storage write: the price passes through the plant on its way up,
        // and the solvency ledger (FEAT-9BQZ) must book that crossing before the move down
        // crosses back, or its NO total would underflow on a band it never recorded.
        _move(start);

        int24 wordFirstTick = (lower >> 8) << 8;
        int24 target = int24(bound(targetSeed, wordFirstTick, wordFirstTick + 255));
        assertLt(target, start, "precondition: the target is below the start");

        uint256 expectedCrossings = (target < upper ? 1 : 0) + (target < lower ? 1 : 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(start, target, expectedCrossings);

        _move(target);

        assertEq(vault.currentTick(), target, "currentTick should equal the target");
        assertEq(
            vault.activeLiquidity(),
            expectedCrossings == 1 ? 100e18 : 0,
            "activeLiquidity holds the plant exactly while the target is inside its range"
        );
    }
}
