// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-9BQZ: Vault Solvency Ledger (NFR-9BRX, the exact conservation invariant; NFR-9BRW)
// UC-9BR0: Maintain Solvency Totals, UC-9BR1: Accumulate Principal Shift, UC-9BR2: Apply Payout Ratios
// Invariants required by CLAUDE.md's Foundry conventions and by the ledger requirement of
// audit-solutions.md (FR-2J6D), for the ledger under mints, burns, collects, fee reports,
// merges, freezes, and tick moves:
//   1. the four scaled totals equal the sum over every live position of its scaled claim
//      at currentTick and its scaled fee claim, exactly, with no tolerance (NFR-9BRX). The
//      claim is computed per level in this file, not from the vault's closed form, so a wrong
//      closed form is caught too
//   2. noSideLiquidity == Σ liquidity over in-range positions whose mintTick <= currentTick
//   3. no burn or collect paid more of an asset than the vault held, and every burn paid
//      exactly floor(owed x min(1, held / total)) per asset (NFR-9BRW, FR-9BRR)
//   4. updateTick and the exits reverted only for a documented reason
// The handler's moves are clamped to [-300, 10300] and bounded to 700 ticks, so they cross
// nothing, end between ticks, cross mint ticks, and leave the price scale; its deposits
// rarely divide by the range width, so only a scaled ledger stays exact; and it freezes the
// vault one pick in ten, after which the exits keep running. Every expected value is read
// from the vault's own records, with no handler mirror.
// Mutation checks of 2026-09-14: invariant 1 fails at once with the trailing segment
// removed, with the segment before a crossing removed, and with liquidityNet applied
// before the segment.

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "../fixtures/LPVaultFixture.sol";
import {ITestConditionalTokens} from "../fixtures/ConditionalTokensFixture.sol";
import {MockERC20} from "../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Handler: bounded action surface the invariant fuzzer drives. The mint and the fee report
// run with no try/catch, because no documented rejection is reachable inside their bounds.
// The move, the collect, the burn, and the merge absorb the vault's documented rejections and
// record the first selector that is not one, so a panic surfaces as an invariant failure.
// ──────────────────────────────────────────────
contract SolvencyLedgerHandler is LPVaultFixture {
    LPVault public vault;
    MockERC20 public mockUsdc;
    address public operatorAddr;
    address public exchangeAddr;

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The one Safe that owns every position, so any two same-range positions can merge.
    address public lp;

    uint256 internal intentNonce;
    uint256[] internal positionIds;

    uint256 public completedMoves;
    uint256 public completedBurns;
    uint256 public completedCollects;
    uint256 public completedMerges;
    uint256 public completedFreezes;
    /// @dev How many payouts left the vault short of an asset it owed, so invariant 3 proved
    ///      the ratio on a real cut and not only on a ratio of 1.
    uint256 public cutPayouts;

    /// @dev The first undocumented revert selector of each guarded action. Zero while every
    ///      revert was documented.
    bytes4 public undocumentedMoveRevert;
    bytes4 public undocumentedExitRevert;
    /// @dev Set when a burn's paid amount was not floor(owed x min(1, held / total)) on some
    ///      asset, or when a payout exceeded what the vault held (invariant 3).
    bool public payoutMismatch;
    string public payoutMismatchReason;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 feesOwed,
        uint256 usdcPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );

    constructor(
        LPVault vault_,
        MockERC20 mockUsdc_,
        ITestConditionalTokens ctf_,
        address operatorAddr_,
        address exchangeAddr_
    ) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        ctf = ctf_;
        // The fixture's token funding reads the collateral the vault's condition was split against
        collateralOf[vault_.conditionId()] = address(mockUsdc_);
        operatorAddr = operatorAddr_;
        exchangeAddr = exchangeAddr_;
        lp = _safeOf(vm.addr(LP_PK));
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function positionIdAt(uint256 i) external view returns (uint256) {
        return positionIds[i];
    }

    /// @dev Mints one position near the current tick, so moves keep crossing mint ticks and
    ///      boundaries, with a deposit that rarely divides by the width. One time in four,
    ///      when positions exist, the range copies a live position's, so the merge finds a pair.
    function mint(int256 lowerSeed, uint256 widthSeed, uint256 usdcSeed, bool copyRange) public {
        if (vault.phase() == 3) return;
        int24 tickLower;
        int24 tickUpper;
        if (copyRange && positionIds.length > 0) {
            (, int24 lo, int24 hi,, uint128 liq,,) = vault.positions(positionIds[widthSeed % positionIds.length]);
            if (liq > 0) {
                tickLower = lo;
                tickUpper = hi;
            }
        }
        if (tickUpper == 0) {
            int256 c = int256(vault.currentTick());
            int256 lo = bound(lowerSeed, c - 600, c + 600);
            if (lo < 0) lo = 0;
            if (lo > 9000) lo = 9000;
            tickLower = int24(lo / 10 * 10);
            tickUpper = tickLower + int24(uint24(bound(widthSeed, 1, 60) * 10));
            if (tickUpper > 10000) tickUpper = 10000;
        }
        uint256 usdcAmount = bound(usdcSeed, 1e6, 1_000_003e6);
        bytes32 intentId = keccak256(abi.encode("ledger-mint", intentNonce++));
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
        positionIds.push(id);
    }

    /// @dev Moves the tick by at most 700 ticks, clamped to [-300, 10300] so the price leaves
    ///      the scale on both sides. TooManyTicksCrossed is the one documented rejection.
    function move(int256 moveSeed) public {
        if (vault.phase() == 3) return;
        int256 delta = bound(moveSeed, -700, 700);
        if (delta == 0) return;
        int256 target = int256(vault.currentTick()) + delta;
        if (target < -300) target = -300;
        if (target > 10300) target = 10300;
        vm.prank(operatorAddr);
        try vault.updateTick(int24(target)) {
            completedMoves++;
        } catch (bytes memory reason) {
            bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
            if (undocumentedMoveRevert == bytes4(0) && selector != LPVault.TooManyTicksCrossed.selector) {
                undocumentedMoveRevert = selector;
            }
        }
    }

    /// @dev Reports fees, funded from the Operator wallet as the keeper does.
    function notify(uint256 amountSeed) public {
        if (vault.phase() == 3 || vault.activeLiquidity() == 0) return;
        _notifyFees(vault, operatorAddr, bound(amountSeed, 1, 10_000e6));
    }

    /// @dev Moves USDC out of the vault through the exchange's standing approval, as a fill
    ///      would (decision C8), one pick in six, so some payouts meet a USDC shortfall.
    function drain(uint256 seed) public {
        if (seed % 6 != 0) return;
        uint256 balance = mockUsdc.balanceOf(address(vault));
        uint256 escrowed = vault.totalEscrowed();
        if (balance <= escrowed) return;
        uint256 amount = bound(seed, 1, balance - escrowed);
        vm.prank(exchangeAddr);
        mockUsdc.transferFrom(address(vault), exchangeAddr, amount);
    }

    /// @dev Gives the vault outcome tokens, as the keeper's fills would, one pick in four, so a
    ///      token leg meets a ratio between 0 and 1 and not only 0.
    function fund(uint256 seed) public {
        if (seed % 4 != 0) return;
        uint256 yes = bound(seed, 0, 200e6);
        uint256 no = bound(seed >> 8, 0, 200e6);
        if (yes == 0 && no == 0) return;
        _giveOutcomeTokens(address(vault), vault.conditionId(), yes, no);
    }

    /// @dev The Safe collects a random position. The paid amount must equal the owed amount
    ///      times the USDC ratio, read before the call, and never exceed what the vault held.
    function collect(uint256 idSeed) public {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[idSeed % positionIds.length];
        uint256 usdcHeld = _usdcAvailable();
        uint256 usdcTotal = vault.totalUsdcOwed() + vault.totalFeesOwed();
        uint256 before = mockUsdc.balanceOf(lp);
        vm.recordLogs();
        vm.prank(lp);
        try vault.collect(id) {
            completedCollects++;
            uint256 paid = mockUsdc.balanceOf(lp) - before;
            _checkCollectedLog(vm.getRecordedLogs(), paid, usdcHeld, usdcTotal);
        } catch (bytes memory reason) {
            _recordExitRevert(reason);
        }
    }

    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amountOwed, uint256 amountPaid);

    /// @dev A collect that owed something emits its owed and paid amounts; the paid amount must
    ///      be the transfer and the ratio's share of the owed amount.
    function _checkCollectedLog(Vm.Log[] memory logs, uint256 paid, uint256 usdcHeld, uint256 usdcTotal) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FeesCollected.selector) continue;
            (uint256 owed, uint256 eventPaid) = abi.decode(logs[i].data, (uint256, uint256));
            if (eventPaid != paid) _mismatch("a collect's event does not match its transfer");
            _checkLeg(owed, paid, usdcHeld, usdcTotal, "USDC (collect)");
            return;
        }
        if (paid > 0) _mismatch("a paying collect must emit FeesCollected");
    }

    /// @dev The Safe burns a random position. The event's paid amounts must equal
    ///      floor(owed x min(1, held / total)) per asset, with the holdings and the totals read
    ///      before the call (FR-9BRR, NFR-9BRW).
    function burn(uint256 idSeed) public {
        if (positionIds.length == 0) return;
        uint256 i = idSeed % positionIds.length;
        uint256 id = positionIds[i];
        uint256 usdcHeld = _usdcAvailable();
        uint256 usdcTotal = vault.totalUsdcOwed() + vault.totalFeesOwed();
        (uint256 yesHeld, uint256 noHeld) = _tokensHeldAfterMerge();
        uint256 yesTotal = vault.totalYesOwed();
        uint256 noTotal = vault.totalNoOwed();

        vm.recordLogs();
        vm.prank(lp);
        try vault.burnPosition(id) {
            completedBurns++;
            positionIds[i] = positionIds[positionIds.length - 1];
            positionIds.pop();
            _checkBurnedLog(vm.getRecordedLogs(), usdcHeld, usdcTotal, yesHeld, yesTotal, noHeld, noTotal);
        } catch (bytes memory reason) {
            _recordExitRevert(reason);
        }
    }

    /// @dev Merges two distinct positions that share a range and a mint tick, when such a pair
    ///      exists. No try/catch: with equal ranges and mint ticks no documented rejection is
    ///      reachable, so a revert fails the run.
    function merge(uint256 seedA, uint256 seedB) public {
        if (vault.phase() == 3) return;
        uint256 count = positionIds.length;
        if (count < 2) return;
        uint256 a = positionIds[seedA % count];
        (, int24 lowerA, int24 upperA, int24 mintA,,,) = vault.positions(a);
        for (uint256 i = 0; i < count; i++) {
            uint256 b = positionIds[(seedB % count + i) % count];
            if (b == a) continue;
            (, int24 lowerB, int24 upperB, int24 mintB,,,) = vault.positions(b);
            if (lowerB == lowerA && upperB == upperA && mintB == mintA) {
                uint256[] memory ids = new uint256[](2);
                ids[0] = a;
                ids[1] = b;
                vm.prank(operatorAddr);
                vault.mergePositions(ids);
                completedMerges++;
                return;
            }
        }
    }

    /// @dev Freezes the vault, one pick in ten, after the emergency-cancel timelock (FEAT-JXQO
    ///      FR-JXQP). No try/catch: after the warp nothing documented can reject the call.
    function freeze(uint256 seed) public {
        if (vault.phase() == 3 || seed % 10 != 0) return;
        vm.warp(block.timestamp + vault.emergencyCancelTimelock());
        vault.emergencyCancelAll();
        completedFreezes++;
    }

    /// @dev The USDC a payout may draw on: balance + pairs - totalEscrowed, floored at zero.
    function _usdcAvailable() internal view returns (uint256) {
        (uint256 yes, uint256 no) = _balances();
        uint256 pairs = yes < no ? yes : no;
        uint256 held = mockUsdc.balanceOf(address(vault)) + pairs;
        uint256 escrowed = vault.totalEscrowed();
        return held > escrowed ? held - escrowed : 0;
    }

    function _tokensHeldAfterMerge() internal view returns (uint256 yesHeld, uint256 noHeld) {
        (uint256 yes, uint256 no) = _balances();
        uint256 pairs = yes < no ? yes : no;
        yesHeld = yes - pairs;
        noHeld = no - pairs;
    }

    function _balances() internal view returns (uint256 yes, uint256 no) {
        yes = ctf.balanceOf(address(vault), vault.yesTokenId());
        no = ctf.balanceOf(address(vault), vault.noTokenId());
    }

    function _checkBurnedLog(
        Vm.Log[] memory logs,
        uint256 usdcHeld,
        uint256 usdcTotal,
        uint256 yesHeld,
        uint256 yesTotal,
        uint256 noHeld,
        uint256 noTotal
    ) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != PositionBurned.selector) continue;
            (
                uint256 usdcOwed,
                uint256 feesOwed,
                uint256 usdcPaid,
                uint256 tokenId,
                uint256 tokenOwed,
                uint256 tokenPaid
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            _checkLeg(usdcOwed + feesOwed, usdcPaid, usdcHeld, usdcTotal, "USDC");
            if (tokenId == vault.yesTokenId()) _checkLeg(tokenOwed, tokenPaid, yesHeld, yesTotal, "YES");
            else if (tokenId == vault.noTokenId()) _checkLeg(tokenOwed, tokenPaid, noHeld, noTotal, "NO");
            return;
        }
        _mismatch("a successful burn must emit PositionBurned");
    }

    /// @dev The definition of the ratio (FR-9BRM to FR-9BRR): paid == floor(owed x held / total)
    ///      when held < total, else paid == owed, and never above held.
    function _checkLeg(uint256 owed, uint256 paid, uint256 held, uint256 total, string memory asset) internal {
        uint256 expected = owed == 0 ? 0 : (held < total ? owed * held / total : owed);
        if (expected > held) expected = held;
        if (paid != expected) _mismatch(string.concat("a burn paid the wrong ", asset, " share"));
        if (paid > held) _mismatch(string.concat("a burn paid more ", asset, " than the vault held"));
        if (owed > 0 && held < total) cutPayouts++;
    }

    function _mismatch(string memory reason) internal {
        if (!payoutMismatch) {
            payoutMismatch = true;
            payoutMismatchReason = reason;
        }
    }

    function _recordExitRevert(bytes memory reason) internal {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
        if (undocumentedExitRevert == bytes4(0) && selector != LPVault.PositionNotFound.selector) {
            undocumentedExitRevert = selector;
        }
    }
}

/// @dev fail-on-revert makes any handler-level revert fail the run. The mint, the fee report,
///      the merge, and the freeze run with no try/catch on purpose; the move and the exits absorb
///      their documented rejections, so only an unexpected revert reaches here.
/// forge-config: default.invariant.fail-on-revert = true
contract SolvencyLedgerInvariantTest is StdInvariant, LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    SolvencyLedgerHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant ONE = 10_000;
    uint256 constant Q128 = 2 ** 128;

    struct Sums {
        uint256 usdc;
        uint256 yes;
        uint256 no;
        uint256 feesX128;
    }

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        // A floor of 1 keeps the first-mint check from rejecting any plant
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));
        vm.prank(operatorAddr);
        vault.updateTick(5000);

        handler = new SolvencyLedgerHandler(vault, mockUsdc, ctf, operatorAddr, exchangeAddr);
        targetContract(address(handler));

        // Prologue: one position of each side and a burn, so the afterInvariant guards hold by
        // construction and a harness whose action never works leaves its counter at zero
        handler.mint(5000, 5, 300e6, false);
        handler.mint(5100, 7, 123_456_789, false);
        handler.move(250);
        handler.notify(5e6);
        handler.fund(4);
        handler.drain(6);
        handler.burn(1);
    }

    // NFR-9BRX: the four scaled totals equal the sum of every live position's scaled claim at
    // currentTick and its scaled fee claim, exactly. The claim is summed per level here.
    function invariant_ledgerEqualsSumOfClaims() public view {
        Sums memory sums;
        uint256 count = vault.nextPositionId();
        for (uint256 i = 0; i < count; i++) {
            _addPosition(sums, i);
        }
        assertEq(vault.totalUsdcOwedScaled(), sums.usdc, "the USDC total must equal the sum of the scaled claims");
        assertEq(vault.totalYesOwedScaled(), sums.yes, "the YES total must equal the sum of the scaled claims");
        assertEq(vault.totalNoOwedScaled(), sums.no, "the NO total must equal the sum of the scaled claims");
        assertEq(vault.totalFeesOwedX128(), sums.feesX128, "the fee total must equal the sum of the scaled fee claims");
    }

    // FR-A2ZS: noSideLiquidity equals the in-range liquidity whose mint tick is at or below the
    // current tick.
    function invariant_noSideLiquidity() public view {
        int24 c = vault.currentTick();
        uint256 sum;
        uint256 count = vault.nextPositionId();
        for (uint256 i = 0; i < count; i++) {
            (address owner, int24 lo, int24 hi, int24 m, uint128 l,,) = vault.positions(i);
            if (owner == address(0)) continue;
            if (lo <= c && c < hi && m <= c) sum += l;
        }
        assertEq(vault.noSideLiquidity(), sum, "noSideLiquidity must equal the in-range NO-side liquidity");
    }

    // NFR-9BRW, FR-9BRR: no payout exceeded what the vault held, and every burn paid exactly
    // owed x min(1, held / total) per asset.
    function invariant_payoutsNeverExceedHeld() public view {
        assertFalse(handler.payoutMismatch(), handler.payoutMismatchReason());
    }

    // NFR-9BRT, NFR-9BRU: no move and no exit reverted for an undocumented reason.
    function invariant_ledgerRevertsOnlyForDocumentedReasons() public view {
        assertEq(handler.undocumentedMoveRevert(), bytes4(0), "updateTick reverted with an undocumented selector");
        assertEq(handler.undocumentedExitRevert(), bytes4(0), "an exit reverted with an undocumented selector");
    }

    /// @dev Every action ran at least once, so each invariant proved something. The setUp prologue
    ///      makes the counters nonzero when the action works, and its drain makes the first burn
    ///      a cut, so invariant 3 proves the ratio on a real shortfall in every run.
    function afterInvariant() public view {
        assertGt(handler.completedMoves(), 0, "the run must include a completed move");
        assertGt(handler.completedBurns(), 0, "the run must include a completed burn");
        assertGt(handler.completedBurns() + handler.completedCollects(), 1, "the run must include more than one exit");
        assertGt(handler.cutPayouts(), 0, "the run must include a payout at a ratio below 1");
    }

    /// @dev The test-side scaled claim, level by level (FR-7G4M): a YES level the price fell
    ///      through holds L tokens and L x (ONE - t) USDC-scaled, a NO level the price rose
    ///      through holds L tokens and L x t, and every other level L x ONE.
    function _claimScaled(int24 lo, int24 hi, int24 m, uint128 l)
        internal
        view
        returns (uint256 usdc, uint256 yes, uint256 no)
    {
        int24 c = vault.currentTick();
        for (int24 t = lo; t < hi; t++) {
            uint256 tt = uint256(int256(t));
            if (t < m && c <= t) {
                yes += l;
                usdc += l * (ONE - tt);
            } else if (t >= m && t < c) {
                no += l;
                usdc += l * tt;
            } else {
                usdc += l * ONE;
            }
        }
    }

    function _addPosition(Sums memory sums, uint256 i) internal view {
        (address owner, int24 lo, int24 hi, int24 m, uint128 l, uint256 last, uint256 tokensOwed) = vault.positions(i);
        if (owner == address(0) || l == 0) return;
        (uint256 u, uint256 y, uint256 n) = _claimScaled(lo, hi, m, l);
        sums.usdc += u;
        sums.yes += y;
        sums.no += n;
        uint256 inside = _feeGrowthInside(lo, hi);
        // unchecked: the same wraparound-cancelling delta the vault computes (ADR-8L1F)
        unchecked {
            sums.feesX128 += uint256(l) * (inside - last) + tokensOwed * Q128;
        }
    }

    /// @dev Mirrors LPVault._computeFeeGrowthInside through the public getters.
    function _feeGrowthInside(int24 lo, int24 hi) internal view returns (uint256) {
        int24 c = vault.currentTick();
        uint256 global = vault.feeGrowthGlobalX128();
        (,, uint256 outLo,) = vault.ticks(lo);
        (,, uint256 outHi,) = vault.ticks(hi);
        unchecked {
            uint256 below = c >= lo ? outLo : global - outLo;
            uint256 above = c < hi ? outHi : global - outHi;
            return global - below - above;
        }
    }
}
