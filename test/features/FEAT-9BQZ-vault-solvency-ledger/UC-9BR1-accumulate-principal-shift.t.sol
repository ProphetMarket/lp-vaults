// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR1: Accumulate Principal Shift
// Integration tests for every scenario in this use case.
// Covers: SC-9BS8, SC-9BS9, SC-9BSA, SC-9BSB, SC-COEQ, SC-COER, SC-COES

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for the segment-shift scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, reports tick 6000,
// and mints position A, the worked example of decision C26: 300 USDC over [5500, 6500) at
// 6000, so liquidity = 3e23 and mintTick = 6000, an initialized interior mint tick. Every
// expected total below is the per-level claim of FR-7G4M summed over the live positions.
// ──────────────────────────────────────────────
contract PrincipalShiftTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address safe;

    int24 constant LOWER = 5500;
    int24 constant UPPER = 6500;
    int24 constant MINT_TICK = 6000;
    uint256 constant PRINCIPAL = 300e6;
    uint128 constant LIQUIDITY_A = 3e23;
    // Position B: 300 USDC over [5500, 6000) minted at 5800, so liquidity = 6e23
    uint128 constant LIQUIDITY_B = 6e23;

    // A's claim at 5700 (SC-7G44) and at 6300 (SC-7G45)
    uint256 constant A_FELL_USDC = 247_354_500;
    uint256 constant A_ROSE_USDC = 265_345_500;
    uint256 constant BAND_TOKENS = 90e6;

    uint256 positionA;

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public virtual {
        safe = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));

        _moveTick(MINT_TICK);
        positionA = _mintExample(keccak256("a"));
    }

    function _mintExample(bytes32 intentId) internal returns (uint256) {
        return _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, UPPER, PRINCIPAL, intentId);
    }

    /// @dev Position B, minted with the vault at 5800 and then the price reported back at 6000.
    function _mintB() internal returns (uint256 id) {
        _moveTick(5800);
        id = _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, MINT_TICK, PRINCIPAL, keccak256("b"));
        _moveTick(MINT_TICK);
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    /// @dev One move with its event asserted.
    function _moveExpecting(int24 from, int24 to, uint256 crossings) internal {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(from, to, crossings);
        _moveTick(to);
    }

    function _assertTotals(uint256 usdc, uint256 yes, uint256 no, string memory where) internal view {
        assertEq(vault.totalUsdcOwed(), usdc, string.concat("USDC total ", where));
        assertEq(vault.totalYesOwed(), yes, string.concat("YES total ", where));
        assertEq(vault.totalNoOwed(), no, string.concat("NO total ", where));
    }
}

// ──────────────────────────────────────────────
// SC-9BS8: A move across several initialized ticks accrues each segment with its own split
// What: With A minted at 6000 and B ([5500, 6000) minted at 5800) out of range above, a move
//       from 6000 to 5700 crosses 6000 and 5800 and lands on the two positions' claims at
//       5700: 150 YES, no NO, and 512,857,500 USDC units.
// Why:  FR-9BRI: the segment [5800, 6000) counts A on the YES side and B on the NO side, and
//       [5700, 5800) counts both on the YES side; a single split for the whole move would
//       misattribute one of them.
// ──────────────────────────────────────────────
contract ShiftAcrossSeveralTicksTest is PrincipalShiftTestBase {
    function setUp() public override {
        super.setUp();
        _mintB();
        _assertTotals(550_794_000, 0, 120e6, "before the move");
        assertEq(vault.noSideLiquidity(), LIQUIDITY_A, "precondition: only A is in range, on the NO side");
    }

    // SC-9BS8: the totals after the move are the two claims at 5700
    function test_whenSeveralTicksAreCrossedThenEachSegmentUsesItsOwnSplit() public {
        _moveExpecting(MINT_TICK, 5700, 2);

        _assertTotals(A_FELL_USDC + 265_503_000, 150e6, 0, "after the move");
    }

    // SC-9BS8: the counters after the move
    function test_whenSeveralTicksAreCrossedThenCountersFollow() public {
        _moveTick(5700);

        assertEq(vault.activeLiquidity(), LIQUIDITY_A + LIQUIDITY_B, "both positions in range");
        assertEq(vault.noSideLiquidity(), 0, "both on the YES side of their mint ticks");
    }
}

// ──────────────────────────────────────────────
// SC-9BS9: A move that crosses no tick still moves the totals
// What: A move from 6000 to 6300 crosses nothing and lands on the SC-7G45 claim, 90 NO and
//       265,345,500 USDC units; a move back to 6100 crosses nothing and lands on 30 NO.
// Why:  FR-9BRK: a move inside a gap redistributes the principal of every position spanning
//       it exactly as a longer move does.
// ──────────────────────────────────────────────
contract ShiftWithoutCrossingTest is PrincipalShiftTestBase {
    // SC-9BS9: the move up
    function test_whenNoTickIsCrossedUpwardThenTotalsStillMove() public {
        _moveExpecting(MINT_TICK, 6300, 0);

        _assertTotals(A_ROSE_USDC, 0, BAND_TOKENS, "at 6300");
        assertEq(vault.noSideLiquidity(), LIQUIDITY_A, "no crossing, no counter write");
    }

    // SC-9BS9: the move back down
    function test_whenNoTickIsCrossedDownwardThenTotalsStillMove() public {
        _moveTick(6300);

        _moveExpecting(6300, 6100, 0);

        _assertTotals(288_148_500, 0, 30e6, "at 6100");
    }
}

// ──────────────────────────────────────────────
// SC-9BSA: A move that ends between ticks accrues its trailing segment
// What: The SC-9BS8 setup, moved to 5750 instead: the trailing segment [5750, 5800) after
//       the last crossing counts 50 levels for both positions, so the totals read 105 YES and
//       538,617,750 USDC units instead of the values at 5800.
// Why:  FR-9BRJ: most moves do not land on an initialized tick, so an accrual inside the loop
//       alone is wrong on the common case.
// ──────────────────────────────────────────────
contract ShiftTrailingSegmentTest is PrincipalShiftTestBase {
    function setUp() public override {
        super.setUp();
        _mintB();
    }

    // SC-9BSA: the trailing segment counts
    function test_whenTheMoveEndsBetweenTicksThenTheTrailingSegmentIsAccrued() public {
        _moveExpecting(MINT_TICK, 5750, 2);

        _assertTotals(538_617_750, 105e6, 0, "at 5750");
    }

    // SC-9BSA: the values at 5800 are what a missing trailing segment would leave. A move down
    // crosses the ticks in (newTick, oldTick], so a move that ends at 5800 crosses 6000 only
    // and accrues [5800, 6000) as its trailing segment.
    function test_whenTheMoveStopsAtTheLastCrossingThenTotalsAreTheValuesAt5800() public {
        _moveExpecting(MINT_TICK, 5800, 1);

        _assertTotals(564_603_000, 60e6, 0, "at 5800");
    }
}

// ──────────────────────────────────────────────
// SC-9BSB: Each segment is accrued before its tick's liquidity change is applied
// What: A alone, a move from 6000 to 5400 leaves the range: the segment [5500, 6000) is
//       accrued against A's liquidity and only then does the crossing of 5500 take
//       activeLiquidity to zero, so the totals read 150 YES and 213,757,500 USDC units.
// Why:  FR-9BRI: applying liquidityNet first would attribute the segment to zero liquidity
//       and leave the totals at their mint values, a silent drift.
// ──────────────────────────────────────────────
contract ShiftBeforeLiquidityChangeTest is PrincipalShiftTestBase {
    // SC-9BSB: the segment is accrued against the liquidity that was in range across it
    function test_whenTheMoveLeavesTheRangeThenTheSegmentIsAccruedBeforeTheCrossing() public {
        _moveExpecting(MINT_TICK, 5400, 2);

        _assertTotals(213_757_500, 150e6, 0, "at 5400");
        assertEq(vault.activeLiquidity(), 0, "the crossing of 5500 emptied the range");
        assertEq(vault.noSideLiquidity(), 0, "nothing in range");
    }

    // SC-9BSB: the trailing segment below the range is skipped
    function test_whenNothingIsInRangeThenTheTrailingSegmentAccruesNothing() public {
        _moveTick(5400);
        uint256 usdcBefore = vault.totalUsdcOwedScaled();
        uint256 yesBefore = vault.totalYesOwedScaled();

        _moveExpecting(5400, 5100, 0);

        assertEq(vault.totalUsdcOwedScaled(), usdcBefore, "no liquidity across [5100, 5400)");
        assertEq(vault.totalYesOwedScaled(), yesBefore, "no liquidity across [5100, 5400)");
    }
}

// ──────────────────────────────────────────────
// SC-COEQ: Three chunks equal one call, and a reversal restores the mint totals
// What: 6000 -> 5700 in one call, back to 6000, then 6000 -> 5900 -> 5750 -> 5700: the
//       reversal reads the mint values exactly, and the three chunks read the one call's
//       values exactly, in the scaled unit.
// Why:  FR-9BRL: every product is exact in the scaled unit, so chunking loses nothing and the
//       shift is its own inverse.
// ──────────────────────────────────────────────
contract ShiftChunksAndReversalTest is PrincipalShiftTestBase {
    // SC-COEQ: the reversal restores the mint totals
    function test_whenTheMoveIsReversedThenTheScaledTotalsReturnToTheMintValues() public {
        uint256 usdcAtMint = vault.totalUsdcOwedScaled();

        _moveTick(5700);
        _moveTick(MINT_TICK);

        assertEq(vault.totalUsdcOwedScaled(), usdcAtMint, "the scaled USDC total is back");
        assertEq(vault.totalYesOwedScaled(), 0, "the scaled YES total is back");
        assertEq(vault.noSideLiquidity(), LIQUIDITY_A, "A is back on the NO side");
    }

    // SC-COEQ: three chunks land on the one call's totals
    function test_whenTheMoveIsChunkedThenTheScaledTotalsEqualTheOneCall() public {
        _moveTick(5700);
        uint256 usdcOneCall = vault.totalUsdcOwedScaled();
        uint256 yesOneCall = vault.totalYesOwedScaled();
        _moveTick(MINT_TICK);

        _moveTick(5900);
        _moveTick(5750);
        _moveTick(5700);

        assertEq(vault.totalUsdcOwedScaled(), usdcOneCall, "the chunked USDC total");
        assertEq(vault.totalYesOwedScaled(), yesOneCall, "the chunked YES total");
        assertEq(vault.totalUsdcOwed(), A_FELL_USDC, "the truncated USDC total");
        assertEq(vault.totalYesOwed(), BAND_TOKENS, "the truncated YES total");
    }
}

// ──────────────────────────────────────────────
// SC-COER: A mint tick is crossed like a boundary
// What: A's mint tick 6000 is an initialized interior tick with liquidityGross 3e23,
//       liquidityNet 0, and noLiquidityNet 3e23. A move to 5990 crosses it: ticksCrossed
//       counts 1, noSideLiquidity falls to zero, and activeLiquidity is unchanged.
// Why:  ADR-COEW: the NO side is booked the way the range is, and _crossTick moves both
//       counters.
// ──────────────────────────────────────────────
contract MintTickCrossingTest is PrincipalShiftTestBase {
    // SC-COER: the mint tick's record
    function test_whenMintedThenTheInteriorMintTickIsInitialized() public view {
        (uint128 gross, int128 net, uint256 outside, int128 noNet) = vault.ticks(MINT_TICK);
        assertEq(gross, LIQUIDITY_A, "liquidityGross counts the position");
        assertEq(net, 0, "no liquidityNet: no position bounds the tick");
        assertEq(outside, 0, "feeGrowthOutside starts at the global value, zero here");
        assertEq(noNet, int128(LIQUIDITY_A), "the NO sub-range starts here");
        (,,, int128 noNetUpper) = vault.ticks(UPPER);
        assertEq(noNetUpper, -int128(LIQUIDITY_A), "the NO sub-range ends at tickUpper");
    }

    // SC-COER: crossing the mint tick moves noSideLiquidity and counts in the event
    function test_whenTheMintTickIsCrossedThenNoSideLiquidityMovesAndTheEventCounts() public {
        _moveExpecting(MINT_TICK, 5990, 1);

        assertEq(vault.noSideLiquidity(), 0, "A moved to the YES side");
        assertEq(vault.activeLiquidity(), LIQUIDITY_A, "A stays in range");

        _moveExpecting(5990, MINT_TICK, 1);

        assertEq(vault.noSideLiquidity(), LIQUIDITY_A, "A is back on the NO side");
    }
}

// ──────────────────────────────────────────────
// SC-COES: A clamped mint enters the range on the side its mint tick gives
// What: The Operator reported 5000 before the mint, so the position holds mintTick = 5500
//       and no interior reference; a move to 5800 crosses 5500 and accrues [5500, 5800) on
//       the NO side: 90 NO and 260,845,500 USDC units, the SC-BMF3 claim.
// Why:  ADR-AFPP: the clamp keeps the YES and the NO sub-ranges a partition of the range.
// ──────────────────────────────────────────────
contract ClampedMintEntryTest is PrincipalShiftTestBase {
    uint256 positionC;

    function setUp() public override {
        super.setUp();
        // A is burned first, so the clamped position is the only one
        vm.prank(safe);
        vault.burnPosition(positionA);
        _moveTick(5000);
        positionC = _mintExample(keccak256("c"));
    }

    // SC-COES: the NO sub-range sits at the bounds, with no interior reference
    function test_whenClampedBelowThenTheNoSubRangeIsTheWholeRange() public view {
        (,,, int24 mintTick,,,) = vault.positions(positionC);
        assertEq(mintTick, LOWER, "clamped to the lower bound");
        (uint128 grossLower,,, int128 noNetLower) = vault.ticks(LOWER);
        (,,, int128 noNetUpper) = vault.ticks(UPPER);
        (uint128 grossInterior,,,) = vault.ticks(MINT_TICK);
        assertEq(noNetLower, int128(LIQUIDITY_A), "the NO sub-range starts at tickLower");
        assertEq(noNetUpper, -int128(LIQUIDITY_A), "the NO sub-range ends at tickUpper");
        assertEq(grossLower, LIQUIDITY_A, "the bound holds the one reference");
        assertEq(grossInterior, 0, "no interior mint tick");
        assertEq(vault.noSideLiquidity(), 0, "out of range");
    }

    // SC-COES: the rise into the range fills the NO side
    function test_whenThePriceRisesIntoTheRangeThenTheNoSideFills() public {
        _moveExpecting(5000, 5800, 1);

        _assertTotals(260_845_500, 0, BAND_TOKENS, "at 5800");
        assertEq(vault.activeLiquidity(), LIQUIDITY_A, "in range");
        assertEq(vault.noSideLiquidity(), LIQUIDITY_A, "on the NO side from its first level");
    }
}
