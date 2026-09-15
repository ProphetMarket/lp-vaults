// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-TVS0: Update Tick and Cross Ticks (FR-A2ZS, FR-5IDF, NFR-5IDG)
// FEAT-T7AF: Mint LP Position (the two liquidity invariants in its Data Model)
// FEAT-K1M2: Merge Positions (FR-AFPU, the merge conservation invariant)
// FEAT-7G40: Burn LP Position (FR-7G4O, FR-7G4P, the bitmap invariant)
// FEAT-JXQO: Emergency Cancel All Positions (FR-JXQP, the freeze keeps activeLiquidity)
// FEAT-9BQZ: Vault Solvency Ledger (the per-mint-tick state, ADR-COEW in FEAT-TVS0)
// Invariants required by CLAUDE.md's Foundry conventions (an invariant on every
// state-machine property), for the tick state machine under mints, tick moves,
// merges, and burns, with the target-bounded bitmap search:
//   1. activeLiquidity == Σ position.liquidity over positions whose range holds currentTick,
//      and noSideLiquidity == the same sum over those whose mintTick <= currentTick
//   2. ticks[t].liquidityGross == Σ position.liquidity over positions that reference t as
//      tickLower, as tickUpper, or as an interior mint tick, and ticks[t].noLiquidityNet ==
//      Σ L over positions with mintTick == t < tickUpper − Σ L over positions with
//      tickUpper == t > mintTick
//   3. updateTick reverts only for a documented reason (never an arithmetic panic, FR-5IDF)
//   4. a move of at most 2,000 ticks costs less than 200,000 gas plus 30,000 per tick it
//      crossed, so a zero-crossing move stays under 200,000 (NFR-5IDG)
//   5. Σ liquidityGross over the distinct referenced ticks == Σ position.liquidity x
//      (2 + [tickLower < mintTick < tickUpper]), so a merge never creates or loses
//      liquidity (FR-AFPU). This is the summed form of invariant 2, kept as its own named
//      check because audit issue 6.14 asked for it.
//   6. mergePositions([a, a]) always reverts DuplicatePositionId (FR-AFPS), so the
//      rejection is documented in the run and not mistaken for a gap
//   7. every tick a mint ever referenced has its bitmap bit set exactly when its
//      liquidityGross is above zero (FR-7G4P), which a burn that clears the bit keeps true
//   8. a burn reverts only for a documented reason (never an arithmetic panic)
//   9. the checks above hold after a freeze, which writes `phase` and nothing else
//      (FEAT-JXQO FR-JXQP): the handler's freeze action warps past the vault's
//      emergency-cancel timelock and calls emergencyCancelAll from a random address,
//      after which the burns keep running and the mints and the Operator actions stop
// A search that skipped a legitimate crossing would break invariant 1 without a
// revert, and a search that scanned to the end of the scale would break 3 or 4,
// so the proof of the bounded search lives here. Every expected value is read
// from the vault's own position records, with no handler mirror, so the burn
// actions change no earlier check: a burned record reads zero and adds nothing.
// The freeze is gated to one pick in eight: with eight actions the fuzzer freezes
// about six runs in ten, at the median around call 39 of 50, so most runs prove
// phase 3 and the Active-phase coverage R6 and R9 measured stays.

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
    /// @dev Every planted tick stays inside the price scale [0, SCALE], aligned to SPACING
    ///      (FR-T7B2): a mint outside it reverts InvalidRange since R9.
    int24 constant SCALE = 10000;

    uint256 internal intentNonce;
    uint256[] internal positionIds;

    /// @dev The first revert selector of updateTick that is not a documented rejection. Zero
    ///      while every revert was documented.
    bytes4 public undocumentedRevert;
    /// @dev The allowance for one crossing. Measured at 12,339 gas on 2026-09-13 with a probe
    ///      of 200 crossings. Raised from 30,000 on 2026-09-15 (step R18): a tick crossed for the
    ///      first time now also writes its spread growth snapshot from zero to a nonzero value,
    ///      which costs 20,000 gas on its own (FEAT-E943 ADR-E94R).
    uint256 constant GAS_PER_CROSSING = 40_000;

    /// @dev The move whose gas above its crossing allowance is the highest so far: that gas,
    ///      its (from, to) pair, and its crossing count. A zero-crossing move has no allowance,
    ///      so its whole gas counts.
    uint256 public worstGasAboveAllowance;
    int24 public worstMoveFrom;
    int24 public worstMoveTo;
    uint256 public worstMoveCrossings;
    /// @dev How many moves succeeded, so the gas ceiling proves something.
    uint256 public completedMoves;

    /// @dev How many mergeDuplicate calls ran, and the first revert selector that was not
    ///      DuplicatePositionId. Zero while every duplicate merge was rejected as documented.
    uint256 public duplicateMergeAttempts;
    bytes4 public undocumentedDuplicateMergeRevert;

    /// @dev Every tick a mint ever referenced, both bounds and the mint tick, with repeats, so
    ///      the bitmap invariant can read a tick after the burn that deleted the position which
    ///      referenced it.
    int24[] public referencedTicks;
    /// @dev How many burns completed, and the first burn revert selector that is not a
    ///      documented rejection. Zero while every burn revert was documented.
    uint256 public completedBurns;
    bytes4 public undocumentedBurnRevert;
    uint256 internal burnDeadlineNonce;
    /// @dev How many freezes completed. At most one per run; read for the report, never as a guard,
    ///      because a guard would need a prologue freeze that freezes every run.
    uint256 public completedFreezes;

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    constructor(LPVault vault_, MockERC20 mockUsdc_, address operatorAddr_) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        operatorAddr = operatorAddr_;
        lp = _safeOf(vm.addr(LP_PK));
    }

    /// @dev Mints one position. Near mode places tickLower within 3,000 ticks of currentTick,
    ///      clamped into the scale (the tick can drift outside it over a run). Extreme mode
    ///      places the range within 2,000 ticks of tick 0 or of tick 10000, the two edges of the
    ///      scale. One time in four, when positions exist, the range copies a live existing
    ///      position's range, so the merge action finds a pair; a burned record reads zero and
    ///      is placed at random instead. Liquidity is at most
    ///      1e6 * 1e18 / 10 = 1e23 per position, so liquidityGross on a shared tick stays far
    ///      below uint128 over any run.
    function mintPosition(uint256 placementSeed, uint256 widthSeed, uint256 usdcSeed, bool nearCurrentTick) public {
        // A mint in a frozen vault reverts VaultNotActive, and the mint runs with no try/catch
        if (vault.phase() == 3) return;
        int24 tickLower;
        int24 tickUpper;
        uint128 copiedLiquidity;
        if (positionIds.length > 0 && placementSeed % 4 == 0) {
            (, tickLower, tickUpper,, copiedLiquidity,) =
                vault.positions(positionIds[placementSeed % positionIds.length]);
        }
        // A burned record reads zero, so its range cannot be copied; place the mint at random instead
        if (copiedLiquidity == 0) {
            int24 width = int24(int256(bound(widthSeed, 1, 50))) * SPACING;
            int256 low;
            int256 high;
            if (nearCurrentTick) {
                int256 current = int256(vault.currentTick());
                low = _clamp(current - 3000, 0, SCALE - width);
                high = _clamp(current + 3000, 0, SCALE - width);
            } else if (placementSeed % 2 == 0) {
                low = SCALE - width - 2000;
                high = SCALE - width;
            } else {
                low = 0;
                high = 2000;
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
        referencedTicks.push(tickLower);
        referencedTicks.push(tickUpper);
        (,,, int24 mintTick,,) = vault.positions(id);
        referencedTicks.push(mintTick);
    }

    function referencedTickCount() external view returns (uint256) {
        return referencedTicks.length;
    }

    /// @dev The owning Safe burns a random position. A live one when the pick is live, else
    ///      the documented PositionNotFound of a burned or merged-away record. The vault holds
    ///      no outcome token in this harness, so the token leg pays zero and the USDC leg pays
    ///      from the principal the mints left.
    function burn(uint256 seed) public {
        uint256 count = positionIds.length;
        if (count == 0) return;
        uint256 id = positionIds[seed % count];
        vm.prank(lp);
        try vault.burnPosition(id) {
            completedBurns++;
        } catch (bytes memory reason) {
            _recordBurnRevert(reason);
        }
    }

    /// @dev The Operator relays a burn the owner key signed. The deadline changes per call, so a
    ///      replayed struct hash never blocks a live position; a burned one reports
    ///      PositionNotFound, which is documented.
    function burnFor(uint256 seed) public {
        uint256 count = positionIds.length;
        if (count == 0) return;
        uint256 id = positionIds[seed % count];
        uint256 deadline = FAR_DEADLINE - (burnDeadlineNonce++);
        bytes memory sig = _signBurnIntent(address(vault), LP_PK, lp, id, deadline);
        vm.prank(operatorAddr);
        try vault.burnPositionFor(lp, id, deadline, sig) {
            completedBurns++;
        } catch (bytes memory reason) {
            _recordBurnRevert(reason);
        }
    }

    function _recordBurnRevert(bytes memory reason) internal {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
        bool documented = selector == LPVault.PositionNotFound.selector || selector == LPVault.NotPositionOwner.selector
            || selector == LPVault.IntentAlreadyUsed.selector;
        if (undocumentedBurnRevert == bytes4(0) && !documented) undocumentedBurnRevert = selector;
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

    /// @dev Merges two distinct positions that share a range and a mint tick, when such a pair
    ///      exists. The pair matches on the mint tick too, because mergePositions rejects a
    ///      different mint tick (FR-AFPT) and a range-only pick would rarely merge after a move.
    function merge(uint256 seedA, uint256 seedB) public {
        uint256 count = positionIds.length;
        if (count < 2) return;
        uint256 a = positionIds[seedA % count];
        (, int24 lowerA, int24 upperA, int24 mintTickA,,) = vault.positions(a);
        uint256 b = 0;
        bool foundPair = false;
        for (uint256 i = 0; i < count; i++) {
            uint256 candidate = positionIds[(seedB % count + i) % count];
            if (candidate == a) continue;
            (, int24 lowerB, int24 upperB, int24 mintTickB,,) = vault.positions(candidate);
            if (lowerB == lowerA && upperB == upperA && mintTickB == mintTickA) {
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

    /// @dev Calls mergePositions([a, a]) on a random position, the audit issue 6.14 input. The
    ///      call must revert DuplicatePositionId every time (FR-AFPS): the handler records the
    ///      attempt and the first selector that is not that error, and invariant 6 reads both.
    function mergeDuplicate(uint256 seed) public {
        // mergePositions checks the phase before the duplicate check, so a frozen vault would
        // revert VaultCancelled and count as an undocumented duplicate-merge revert
        if (vault.phase() == 3) return;
        uint256 count = positionIds.length;
        if (count == 0) return;
        uint256 a = positionIds[seed % count];
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = a;
        duplicateMergeAttempts++;
        vm.prank(operatorAddr);
        try vault.mergePositions(ids) {
            if (undocumentedDuplicateMergeRevert == bytes4(0)) undocumentedDuplicateMergeRevert = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
            if (undocumentedDuplicateMergeRevert == bytes4(0) && selector != LPVault.DuplicatePositionId.selector) {
                undocumentedDuplicateMergeRevert = selector;
            }
        }
    }

    /// @dev Freezes the vault, one pick in eight, from a random non-zero address after the vault's
    ///      emergency-cancel timelock has elapsed (FEAT-JXQO FR-JXQP). No try/catch: a revert fails
    ///      the run, because after the warp nothing documented can reject the call.
    function freeze(uint256 seed) public {
        if (vault.phase() == 3 || seed % 8 != 0) return;
        vm.warp(block.timestamp + vault.emergencyCancelTimelock());
        // casting to 'uint160' is safe because bound keeps the value inside [1, type(uint160).max]
        // forge-lint: disable-next-line(unsafe-typecast)
        address caller = address(uint160(bound(seed, 1, type(uint160).max)));
        vm.prank(caller);
        vault.emergencyCancelAll();
        completedFreezes++;
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

    function _clamp(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}

/// @dev fail-on-revert makes any handler-level revert fail the run. The mint and the freeze run
///      with no try/catch on purpose, so a mint rejection or a freeze rejection fails the run; the
///      move, the merge, and the two burns absorb the vault's documented rejections in try/catch,
///      so only an unexpected revert reaches here.
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
        int24 mintTick;
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

        // Prologue: run each guarded action once, so the afterInvariant guards below hold by
        // construction. With six actions a 50-call run skips one of them a few times in a
        // thousand, which made the guards flake once R9 added the two burn actions. The
        // prologue still catches a harness whose action never works: a move, a duplicate
        // merge, or a burn that failed here would leave its counter at zero.
        handler.mintPosition(1, 5, 1_000, true);
        handler.moveTick(100);
        handler.mergeDuplicate(0);
        handler.burn(0);
    }

    // FR-A2ZS: activeLiquidity equals the sum of the liquidity of every position whose range
    // contains currentTick, and noSideLiquidity the same sum over the positions on the NO side
    // of their mint tick. A consumed position has zero liquidity and adds nothing.
    function invariant_activeLiquidityEqualsInRangeLiquidity() public view {
        PositionView[] memory all = _positions();
        int24 currentTick = vault.currentTick();
        uint256 sum = 0;
        uint256 noSide = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].tickLower <= currentTick && currentTick < all[i].tickUpper) {
                sum += all[i].liquidity;
                if (all[i].mintTick <= currentTick) noSide += all[i].liquidity;
            }
        }
        assertEq(vault.activeLiquidity(), sum, "activeLiquidity must equal the in-range position liquidity");
        assertEq(vault.noSideLiquidity(), noSide, "noSideLiquidity must equal the in-range NO-side liquidity");
    }

    // FR-A2ZS: each referenced tick's liquidityGross equals the sum of the liquidity of every
    // position that references it as tickLower, as tickUpper, or as an interior mint tick, and
    // its noLiquidityNet equals the net of the NO sub-ranges [mintTick, tickUpper) at it.
    function invariant_liquidityGrossEqualsReferencingLiquidity() public view {
        PositionView[] memory all = _positions();
        for (uint256 i = 0; i < all.length; i++) {
            _assertTickState(all, all[i].tickLower);
            _assertTickState(all, all[i].tickUpper);
            if (_isInteriorMintTick(all[i])) _assertTickState(all, all[i].mintTick);
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

    // FR-AFPU: the sum of liquidityGross over the distinct ticks the positions reference equals
    // the sum of every position's liquidity times its reference count, two for the bounds plus
    // one for an interior mint tick. A merge that created or lost liquidity would break it, since
    // a merge never touches tick state. This is the summed form of invariant 2, read from vault
    // state only.
    function invariant_mergeConservesLiquidity() public view {
        PositionView[] memory all = _positions();
        uint256 weightedSum = 0;
        uint256 grossSum = 0;
        for (uint256 i = 0; i < all.length; i++) {
            weightedSum += uint256(all[i].liquidity) * (_isInteriorMintTick(all[i]) ? 3 : 2);
            if (_firstReferenceIndex(all, all[i].tickLower) == i) grossSum += _liquidityGrossAt(all[i].tickLower);
            if (_firstReferenceIndex(all, all[i].tickUpper) == i) grossSum += _liquidityGrossAt(all[i].tickUpper);
            if (_isInteriorMintTick(all[i]) && _firstReferenceIndex(all, all[i].mintTick) == i) {
                grossSum += _liquidityGrossAt(all[i].mintTick);
            }
        }
        assertEq(weightedSum, grossSum, "a merge must conserve the sum of position liquidity");
    }

    // FR-AFPS: every mergePositions([a, a]) in the run reverted DuplicatePositionId, so a merge
    // can never count one position twice. This check is a documented rejection, not a gap.
    function invariant_duplicateMergeAlwaysRejected() public view {
        assertEq(
            handler.undocumentedDuplicateMergeRevert(),
            bytes4(0),
            "mergePositions([a, a]) succeeded or reverted with a selector other than DuplicatePositionId"
        );
    }

    // FR-7G4P: every tick a mint ever referenced has its bitmap bit set exactly when its
    // liquidityGross is above zero. A burn that takes liquidityGross to zero must clear the bit,
    // or a later updateTick would cross a tick with no liquidity behind it (audit issue 6.15).
    function invariant_zeroLiquidityTickHasNoBit() public view {
        uint256 count = handler.referencedTickCount();
        for (uint256 i = 0; i < count; i++) {
            int24 tick = handler.referencedTicks(i);
            (uint128 liquidityGross,,, uint256 spreadOutside) = vault.ticks(tick);
            assertEq(
                _bitIsSet(tick),
                liquidityGross > 0,
                string.concat("the bitmap bit of tick ", vm.toString(tick), " must match liquidityGross > 0")
            );
            // FEAT-E943: a burn that takes liquidityGross to zero deletes the whole record, the
            // spread growth snapshot with it, so a tick that is referenced again starts clean
            if (liquidityGross == 0) {
                assertEq(
                    spreadOutside,
                    0,
                    string.concat("the deleted tick ", vm.toString(tick), " must read a zero spread snapshot")
                );
            }
        }
    }

    // FR-7G4W, FR-7G55: a burn never reverted for an undocumented reason, so no burn panicked.
    function invariant_burnRevertsOnlyForDocumentedReasons() public view {
        assertEq(
            handler.undocumentedBurnRevert(),
            bytes4(0),
            "a burn reverted with a selector that is not a documented rejection"
        );
    }

    /// @dev At least one move completed, so the gas ceiling proved something, at least one
    ///      duplicate merge was attempted, so invariant 6 proved something, and at least one
    ///      burn completed, so invariants 7 and 8 proved something. The setUp prologue makes
    ///      each one true when its action works, and false when it does not.
    function afterInvariant() public view {
        assertGt(handler.completedMoves(), 0, "the run must include at least one completed move");
        assertGt(handler.duplicateMergeAttempts(), 0, "the run must include at least one duplicate merge attempt");
        assertGt(handler.completedBurns(), 0, "the run must include at least one completed burn");
    }

    /// @dev The same decomposition as LPVault._tickPosition.
    function _bitIsSet(int24 tick) internal view returns (bool) {
        // casting to 'int16' is safe because an int24 shifted right by 8 fits in 16 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        int16 wordPos = int16(tick >> 8);
        // casting to 'uint8' is safe because the mask keeps eight bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 bitPos = uint8(uint24(tick) & 0xff);
        return (vault.tickBitmap(wordPos) >> bitPos) & 1 == 1;
    }

    /// @dev A position references its mint tick on its own only when the tick lies strictly
    ///      inside the range; at a bound the bound's own reference already covers it.
    function _isInteriorMintTick(PositionView memory p) internal pure returns (bool) {
        return p.tickLower < p.mintTick && p.mintTick < p.tickUpper;
    }

    /// @dev The index of the first position that references `tick`, so each tick is counted once.
    function _firstReferenceIndex(PositionView[] memory all, int24 tick) internal pure returns (uint256) {
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].tickLower == tick || all[i].tickUpper == tick) return i;
            if (_isInteriorMintTick(all[i]) && all[i].mintTick == tick) return i;
        }
        revert("a referenced tick must have a referencing position");
    }

    function _liquidityGrossAt(int24 tick) internal view returns (uint256) {
        (uint128 liquidityGross,,,) = vault.ticks(tick);
        return liquidityGross;
    }

    /// @dev Every position record the vault holds, from 0 to nextPositionId - 1, without the
    ///      records a burn deleted: a deleted record reads tickLower == tickUpper == 0, so it
    ///      would count tick 0 twice in the summed check. A merged-away record keeps its range
    ///      and its zero liquidity, and stays in the view.
    function _positions() internal view returns (PositionView[] memory all) {
        uint256 count = vault.nextPositionId();
        PositionView[] memory every = new PositionView[](count);
        uint256 live = 0;
        for (uint256 i = 0; i < count; i++) {
            (address owner, int24 tickLower, int24 tickUpper, int24 mintTick, uint128 liquidity,) = vault.positions(i);
            if (owner == address(0)) continue;
            every[live++] = PositionView(tickLower, tickUpper, mintTick, liquidity);
        }
        all = new PositionView[](live);
        for (uint256 i = 0; i < live; i++) {
            all[i] = every[i];
        }
    }

    function _assertTickState(PositionView[] memory all, int24 tick) internal view {
        uint256 sum = 0;
        int256 noNet = 0;
        for (uint256 i = 0; i < all.length; i++) {
            PositionView memory p = all[i];
            if (p.tickLower == tick || p.tickUpper == tick) sum += p.liquidity;
            if (_isInteriorMintTick(p) && p.mintTick == tick) sum += p.liquidity;
            // The NO sub-range [mintTick, tickUpper): +L at its start, -L at its end, when it exists
            if (p.mintTick < p.tickUpper) {
                if (p.mintTick == tick) noNet += int256(uint256(p.liquidity));
                if (p.tickUpper == tick) noNet -= int256(uint256(p.liquidity));
            }
        }
        (uint128 liquidityGross,, int128 noLiquidityNet,) = vault.ticks(tick);
        assertEq(
            liquidityGross,
            sum,
            string.concat("liquidityGross at tick ", vm.toString(tick), " must equal the referencing liquidity")
        );
        assertEq(
            int256(noLiquidityNet),
            noNet,
            string.concat("noLiquidityNet at tick ", vm.toString(tick), " must equal the NO sub-ranges' net")
        );
    }
}
