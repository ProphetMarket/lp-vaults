// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-TVS0: Update Tick and Cross Ticks (FR-A2ZS, FR-5IDF, NFR-5IDG)
// FEAT-T7AF: Mint LP Position (the two liquidity invariants in its Data Model)
// Invariants required by CLAUDE.md's Foundry conventions (an invariant on every
// state-machine property), for the tick state machine under mints, tick moves,
// and merges, with the target-bounded bitmap search:
//   1. activeLiquidity == Σ position.liquidity over positions whose range holds currentTick
//   2. ticks[t].liquidityGross == Σ position.liquidity over positions that reference t
//   3. updateTick reverts only for a documented reason (never an arithmetic panic, FR-5IDF)
//   4. a move of at most 2,000 ticks costs less than 200,000 gas plus 30,000 per tick it
//      crossed, so a zero-crossing move stays under 200,000 (NFR-5IDG)
// A search that skipped a legitimate crossing would break invariant 1 without a
// revert, and a search that scanned to the end of the scale would break 3 or 4,
// so the proof of the bounded search lives here. Every expected value is read
// from the vault's own position records, with no handler mirror, so a later
// burn action (R9) changes no check.

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Handler: bounded action surface the invariant fuzzer drives. The mint runs
// with no try/catch: with a first-mint floor of 1 and these bounds no documented
// mint rejection is reachable, so any revert fails the run. The move and the
// merge run inside try/catch, and the move records the first revert selector
// that is not a documented rejection, so a panic surfaces as an invariant
// failure instead of being swallowed.
// ──────────────────────────────────────────────
contract TickStateHandler is LPVaultFixture {
    LPVault public vault;
    MockERC20 public mockUsdc;
    address public operatorAddr;

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The one Safe that owns every position, so any two same-range positions can merge.
    address public lp;

    /// @dev The vault's tick spacing, in ticks.
    int24 constant SPACING = 10;
    /// @dev The widest aligned range the handler plants, in ticks.
    int24 constant MAX_WIDTH = 50 * SPACING;
    /// @dev Every planted tick stays inside [-8388600, 8388600], aligned to SPACING.
    int24 constant EDGE = 8388600;

    uint256 internal intentNonce;
    uint256[] internal positionIds;

    /// @dev The first revert selector of updateTick that is not a documented rejection. Zero
    ///      while every revert was documented.
    bytes4 public undocumentedRevert;
    /// @dev The allowance for one crossing. Measured at 12,339 gas on 2026-09-13 with a probe
    ///      of 200 crossings, so this is about 2.4 times the real cost.
    uint256 constant GAS_PER_CROSSING = 30_000;

    /// @dev The move whose gas above its crossing allowance is the highest so far: that gas,
    ///      its (from, to) pair, and its crossing count. A zero-crossing move has no allowance,
    ///      so its whole gas counts.
    uint256 public worstGasAboveAllowance;
    int24 public worstMoveFrom;
    int24 public worstMoveTo;
    uint256 public worstMoveCrossings;
    /// @dev How many moves succeeded, so the gas ceiling proves something.
    uint256 public completedMoves;

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    constructor(LPVault vault_, MockERC20 mockUsdc_, address operatorAddr_) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        operatorAddr = operatorAddr_;
        lp = _safeOf(vm.addr(LP_PK));
    }

    /// @dev Mints one position. Near mode places tickLower within 3,000 ticks of currentTick.
    ///      Extreme mode places the range within 2,000 ticks of an edge, so words 32767 and
    ///      -32768 get bits during a run. One time in four, when positions exist, the range
    ///      copies an existing position's range, so the merge action finds a pair. Liquidity is
    ///      at most 1e6 * 1e18 / 10 = 1e23 per position, so liquidityGross on a shared tick
    ///      stays far below uint128 over any run.
    function mintPosition(uint256 placementSeed, uint256 widthSeed, uint256 usdcSeed, bool nearCurrentTick) public {
        int24 tickLower;
        int24 tickUpper;
        if (positionIds.length > 0 && placementSeed % 4 == 0) {
            (, tickLower, tickUpper,,,) = vault.positions(positionIds[placementSeed % positionIds.length]);
        } else {
            int24 width = int24(int256(bound(widthSeed, 1, 50))) * SPACING;
            int256 low;
            int256 high;
            if (nearCurrentTick) {
                int256 current = int256(vault.currentTick());
                low = _max(current - 3000, -EDGE);
                high = _min(current + 3000, EDGE - width);
            } else if (placementSeed % 2 == 0) {
                low = EDGE - width - 2000;
                high = EDGE - width;
            } else {
                low = -EDGE;
                high = -EDGE + 2000;
            }
            // Pick in units of SPACING so the result is aligned. The hard edges are exact
            // multiples of SPACING; the soft near-mode edges may round by less than one unit.
            int256 unit = bound(int256(placementSeed), low / SPACING, high / SPACING);
            tickLower = int24(unit) * SPACING;
            tickUpper = tickLower + width;
        }
        uint256 usdcAmount = bound(usdcSeed, 1, 1_000_000);

        bytes32 intentId = keccak256(abi.encode("tick-state-mint", intentNonce++));
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
        positionIds.push(id);
    }

    /// @dev Moves the tick by at most 2,000 ticks, clamped to int24. A zero move is skipped.
    ///      On success the gas of the call above its crossing allowance is recorded when it is
    ///      the worst so far. On a revert the first undocumented selector is recorded; an
    ///      arithmetic panic (0x4e487b71) counts.
    function moveTick(int256 moveSeed) public {
        int256 delta = bound(moveSeed, -2000, 2000);
        if (delta == 0) return;
        int256 target = int256(vault.currentTick()) + delta;
        if (target > type(int24).max) target = type(int24).max;
        if (target < type(int24).min) target = type(int24).min;
        int24 from = vault.currentTick();
        int24 to = int24(target);
        if (from == to) return;

        vm.recordLogs();
        vm.prank(operatorAddr);
        uint256 before = gasleft();
        try vault.updateTick(to) {
            uint256 gasUsed = before - gasleft();
            uint256 crossings = _ticksCrossed(vm.getRecordedLogs());
            uint256 allowance = crossings * GAS_PER_CROSSING;
            uint256 gasAboveAllowance = gasUsed > allowance ? gasUsed - allowance : 0;
            completedMoves++;
            if (gasAboveAllowance > worstGasAboveAllowance) {
                worstGasAboveAllowance = gasAboveAllowance;
                worstMoveFrom = from;
                worstMoveTo = to;
                worstMoveCrossings = crossings;
            }
        } catch (bytes memory reason) {
            bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
            if (undocumentedRevert == bytes4(0) && !_isDocumentedRejection(selector)) {
                undocumentedRevert = selector;
            }
        }
    }

    /// @dev Merges two distinct positions that share a range, when such a pair exists. The IDs
    ///      are distinct on purpose: mergePositions([a, a]) doubles the survivor's liquidity with
    ///      no tick change, which is audit issue 6.14 and belongs to R7. R7 adds that call here
    ///      as a documented rejection.
    function merge(uint256 seedA, uint256 seedB) public {
        uint256 count = positionIds.length;
        if (count < 2) return;
        uint256 a = positionIds[seedA % count];
        (, int24 lowerA, int24 upperA,,,) = vault.positions(a);
        uint256 b = 0;
        bool foundPair = false;
        for (uint256 i = 0; i < count; i++) {
            uint256 candidate = positionIds[(seedB % count + i) % count];
            if (candidate == a) continue;
            (, int24 lowerB, int24 upperB,,,) = vault.positions(candidate);
            if (lowerB == lowerA && upperB == upperA) {
                b = candidate;
                foundPair = true;
                break;
            }
        }
        if (!foundPair) return;

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(operatorAddr);
        try vault.mergePositions(ids) {} catch {}
    }

    /// @dev The ticksCrossed of the one TickUpdated log a successful move emits.
    function _ticksCrossed(Vm.Log[] memory logs) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == TickUpdated.selector) return abi.decode(logs[i].data, (uint256));
        }
        revert("a successful move must emit TickUpdated");
    }

    /// @dev The rejections that updateTick documents. There is no SameTick on this branch.
    function _isDocumentedRejection(bytes4 selector) internal pure returns (bool) {
        return selector == LPVault.NotOperator.selector || selector == LPVault.TradingIsPaused.selector
            || selector == LPVault.VaultNotActive.selector || selector == LPVault.TooManyTicksCrossed.selector;
    }

    function _max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    function _min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }
}

/// @dev fail-on-revert makes any handler-level revert fail the run. The mint runs with no
///      try/catch on purpose, so a mint rejection fails the run; the move and the merge absorb
///      the vault's documented rejections in try/catch, so only an unexpected revert reaches here.
/// forge-config: default.invariant.fail-on-revert = true
contract TickStateInvariantTest is StdInvariant, LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    TickStateHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    /// @dev The ceiling on a move of at most 2,000 ticks, after the handler subtracts 30,000 gas
    ///      per tick crossed, so a zero-crossing move is held to the whole ceiling. The user chose
    ///      the ceiling on 2026-09-12: the measured values are 12,883 gas with the bound and
    ///      76,618,321 without it, so it sits two orders of magnitude from both and cannot flake.
    uint256 constant GAS_CEILING = 200_000;

    struct PositionView {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        // A floor of 1 keeps the first-mint check of issue 6.9 from rejecting any plant.
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));

        handler = new TickStateHandler(vault, mockUsdc, operatorAddr);
        targetContract(address(handler));
    }

    // FR-A2ZS: activeLiquidity equals the sum of the liquidity of every position whose range
    // contains currentTick. A consumed position has zero liquidity and adds nothing.
    function invariant_activeLiquidityEqualsInRangeLiquidity() public view {
        PositionView[] memory all = _positions();
        int24 currentTick = vault.currentTick();
        uint256 sum = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].tickLower <= currentTick && currentTick < all[i].tickUpper) sum += all[i].liquidity;
        }
        assertEq(vault.activeLiquidity(), sum, "activeLiquidity must equal the in-range position liquidity");
    }

    // FR-A2ZS: each referenced tick's liquidityGross equals the sum of the liquidity of every
    // position that references it as tickLower or tickUpper.
    function invariant_liquidityGrossEqualsReferencingLiquidity() public view {
        PositionView[] memory all = _positions();
        for (uint256 i = 0; i < all.length; i++) {
            _assertLiquidityGross(all, all[i].tickLower);
            _assertLiquidityGross(all, all[i].tickUpper);
        }
    }

    // FR-5IDF: updateTick never reverted for an undocumented reason, so no move panicked.
    function invariant_updateTickRevertsOnlyForDocumentedReasons() public view {
        assertEq(
            handler.undocumentedRevert(),
            bytes4(0),
            "updateTick reverted with a selector that is not a documented rejection"
        );
    }

    // NFR-5IDG: every move of at most 2,000 ticks stays under the ceiling plus its crossing
    // allowance, whatever ticks the run planted against the extreme words. A zero-crossing move
    // has no allowance, so the check on it is the user's 200,000-gas ceiling exactly.
    function invariant_zeroCrossingMoveGasStaysBounded() public view {
        assertLt(
            handler.worstGasAboveAllowance(),
            GAS_CEILING,
            string.concat(
                "the move from ",
                vm.toString(handler.worstMoveFrom()),
                " to ",
                vm.toString(handler.worstMoveTo()),
                " with ",
                vm.toString(handler.worstMoveCrossings()),
                " crossings cost more than the ceiling plus its allowance"
            )
        );
    }

    /// @dev At least one move completed in the run, so the gas ceiling proved something.
    function afterInvariant() public view {
        assertGt(handler.completedMoves(), 0, "the run must include at least one completed move");
    }

    /// @dev Every position record the vault holds, from 0 to nextPositionId - 1.
    function _positions() internal view returns (PositionView[] memory all) {
        uint256 count = vault.nextPositionId();
        all = new PositionView[](count);
        for (uint256 i = 0; i < count; i++) {
            (, int24 tickLower, int24 tickUpper, uint128 liquidity,,) = vault.positions(i);
            all[i] = PositionView(tickLower, tickUpper, liquidity);
        }
    }

    function _assertLiquidityGross(PositionView[] memory all, int24 tick) internal view {
        uint256 sum = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].tickLower == tick || all[i].tickUpper == tick) sum += all[i].liquidity;
        }
        (uint128 liquidityGross,,) = vault.ticks(tick);
        assertEq(
            liquidityGross,
            sum,
            string.concat("liquidityGross at tick ", vm.toString(tick), " must equal the referencing liquidity")
        );
    }
}
