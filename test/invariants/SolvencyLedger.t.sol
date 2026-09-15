// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-9BQZ: Vault Solvency Ledger (NFR-9BRX, the exact conservation invariant; NFR-9BRW)
// UC-9BR0: Maintain Solvency Totals, UC-9BR1: Accumulate Principal Shift, UC-9BR2: Apply Payout Ratios
// Invariants required by CLAUDE.md's Foundry conventions and by the ledger requirement of
// audit-solutions.md (FR-2J6D), for the ledger under mints, burns, collects, fee reports,
// merges, freezes, tick moves, a resolution, and the Oracle's redemption (the switch,
// FEAT-6HBN):
//   1. the four scaled totals equal the sum over every live position of its scaled claim
//      at currentTick and its scaled fee claim, exactly, with no tolerance (NFR-9BRX). The
//      claim is computed per level in this file, not from the vault's closed form, so a wrong
//      closed form is caught too. The switch changes no total, so the check does not change
//   2. noSideLiquidity == Σ liquidity over in-range positions whose mintTick <= currentTick
//   3. no burn or collect paid more of an asset than the vault held, and every burn paid
//      exactly floor(owed x min(1, held / total)) per asset before the switch, with held
//      counting the free pairs (the pairs above what the ledger owes in both tokens, read
//      before the call) as USDC and less them per token, and
//      floor((usdcOwed + feesOwed + tokenUsdc) x min(1, held / total)) as one USDC sum after
//      it (NFR-9BRW, FR-9BRR, FR-CYS5, FEAT-6HBN ADR-DFE2)
//   4. updateTick, the exits, and the redemption reverted only for a documented reason
// The handler's moves are clamped to [-300, 10300] and bounded to 700 ticks, so they cross
// nothing, end between ticks, cross mint ticks, and leave the price scale; its deposits
// rarely divide by the range width, so only a scaled ledger stays exact; it freezes the
// vault one pick in ten, after which the exits keep running; and it resolves the market one
// pick in three once two positions are live (wind-down, then the result), after which the
// Oracle redeems and the exits pay USDC at one ratio. Every expected value is read from the vault's own records, with no
// handler mirror beyond the free-pairs rule itself.
// Mutation checks of 2026-09-14: invariant 1 fails at once with the trailing segment
// removed, with the segment before a crossing removed, and with liquidityNet applied
// before the segment.
//
// A second harness, SolvencyConservationInvariantTest, drives DriftFreeLedgerHandler: no
// donation and no drain, every range inside the board's quotable band [100, 9900], deposits
// that divide by the width so every level holds whole tokens, and every successful move
// filled by the keeper at a spread of 2,000 bps through KeeperFillFixture, with the spread
// income summed in a ghost variable (finding CV-02 of audits/code-validation-round-1.md,
// UC-9BR2 SC-DFDY). Its invariants: the USDC above escrow plus the free pairs covers the
// USDC and fee totals and each token balance covers its total, so every ratio is 1; and no
// burn or collect was cut. Its closing check burns every position and asserts zero tokens
// and USDC above escrow between the spread income and that plus one unit per completed
// mint, move, burn, fee report, collect, redemption, and consumed merge position: the fee
// dust a report and a collect leave (x mod 2^128), the dust a merge debits (FR-9BRH), the
// per-side floors of a redemption and of a resolved burn, and the per-move floor of the
// keeper's spend. Mutation check of 2026-09-14: invariant_holdingsCoverTotals fails with
// _freePairs restored to min(yes, no).

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "../fixtures/LPVaultFixture.sol";
import {KeeperFillFixture} from "../fixtures/KeeperFillFixture.sol";
import {ITestConditionalTokens} from "../fixtures/ConditionalTokensFixture.sol";
import {MockERC20} from "../fixtures/MockERC20.sol";

/// @dev The test contract prepared the condition, so it is the condition's oracle on the
///      ConditionalTokens contract and the only address that can report; the handler asks it to.
interface IResultReporter {
    function reportPayouts(uint256[] calldata payouts) external;
}

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
    address public oracleAddr;
    address public exchangeAddr;
    IResultReporter public reporter;

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The one Safe that owns every position, so any two same-range positions can merge.
    address public lp;

    uint256 internal intentNonce;
    uint256[] internal positionIds;

    uint256 public completedMints;
    uint256 public completedMoves;
    uint256 public completedNotifies;
    uint256 public completedBurns;
    uint256 public completedCollects;
    uint256 public completedMerges;
    uint256 public completedFreezes;
    uint256 public completedResolutions;
    uint256 public completedRedemptions;
    /// @dev How many payouts ran after the switch, so invariant 3 proved the pooled ratio too.
    uint256 public resolvedPayouts;
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
        address oracleAddr_,
        address exchangeAddr_
    ) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        ctf = ctf_;
        // The fixture's token funding reads the collateral the vault's condition was split against
        collateralOf[vault_.conditionId()] = address(mockUsdc_);
        operatorAddr = operatorAddr_;
        oracleAddr = oracleAddr_;
        exchangeAddr = exchangeAddr_;
        reporter = IResultReporter(msg.sender);
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
        // A mint reverts VaultNotActive in WindDown and Cancelled
        if (vault.phase() != 1) return;
        int24 tickLower;
        int24 tickUpper;
        if (copyRange && positionIds.length > 0) {
            (, int24 lo, int24 hi,, uint128 liq,,) = vault.positions(positionIds[widthSeed % positionIds.length]);
            if (liq > 0) {
                tickLower = lo;
                tickUpper = hi;
            }
        }
        if (tickUpper == 0) (tickLower, tickUpper) = _range(lowerSeed, widthSeed);
        uint256 usdcAmount = _deposit(usdcSeed, tickLower, tickUpper);
        bytes32 intentId = keccak256(abi.encode("ledger-mint", intentNonce++));
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, tickLower, tickUpper, usdcAmount, intentId);
        positionIds.push(id);
        completedMints++;
    }

    /// @dev A range near the current tick, up to 600 ticks wide, anywhere on the scale.
    function _range(int256 lowerSeed, uint256 widthSeed)
        internal
        view
        virtual
        returns (int24 tickLower, int24 tickUpper)
    {
        int256 c = int256(vault.currentTick());
        int256 lo = bound(lowerSeed, c - 600, c + 600);
        if (lo < 0) lo = 0;
        if (lo > 9000) lo = 9000;
        tickLower = int24(lo / 10 * 10);
        tickUpper = tickLower + int24(uint24(bound(widthSeed, 1, 60) * 10));
        if (tickUpper > 10000) tickUpper = 10000;
    }

    /// @dev A deposit that rarely divides by the width, so only a scaled ledger stays exact.
    function _deposit(uint256 usdcSeed, int24, int24) internal pure virtual returns (uint256) {
        return bound(usdcSeed, 1e6, 1_000_003e6);
    }

    /// @dev Moves the tick by at most 700 ticks, clamped to [-300, 10300] so the price leaves
    ///      the scale on both sides. TooManyTicksCrossed is the one documented rejection.
    function move(int256 moveSeed) public virtual {
        // A move reverts VaultNotActive in WindDown and Cancelled
        if (vault.phase() != 1) return;
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
        completedNotifies++;
    }

    /// @dev Moves USDC out of the vault through the exchange's standing approval, as a fill
    ///      would (decision C8), one pick in six, so some payouts meet a USDC shortfall.
    function drain(uint256 seed) public virtual {
        if (seed % 6 != 0) return;
        uint256 balance = mockUsdc.balanceOf(address(vault));
        uint256 escrowed = vault.totalEscrowed();
        if (balance <= escrowed) return;
        uint256 amount = bound(seed, 1, balance - escrowed);
        vm.prank(exchangeAddr);
        assertTrue(mockUsdc.transferFrom(address(vault), exchangeAddr, amount), "the drain should spend");
    }

    /// @dev Gives the vault outcome tokens, as the keeper's fills would, one pick in four, so a
    ///      token leg meets a ratio between 0 and 1 and not only 0.
    function fund(uint256 seed) public virtual {
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
        (uint256 usdcHeld, uint256 usdcTotal, bool resolved) = _usdcRatioSides();
        uint256 before = mockUsdc.balanceOf(lp);
        vm.recordLogs();
        vm.prank(lp);
        try vault.collect(id) {
            completedCollects++;
            if (resolved) resolvedPayouts++;
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
        (uint256 usdcHeld, uint256 usdcTotal, bool resolved) = _usdcRatioSides();
        (uint256 yesHeld, uint256 noHeld) = _tokensHeldAfterMerge();
        uint256 yesTotal = vault.totalYesOwed();
        uint256 noTotal = vault.totalNoOwed();

        vm.recordLogs();
        vm.prank(lp);
        try vault.burnPosition(id) {
            completedBurns++;
            positionIds[i] = positionIds[positionIds.length - 1];
            positionIds.pop();
            if (resolved) {
                resolvedPayouts++;
                _checkResolvedBurnedLog(vm.getRecordedLogs(), usdcHeld, usdcTotal);
            } else {
                _checkBurnedLog(vm.getRecordedLogs(), usdcHeld, usdcTotal, yesHeld, yesTotal, noHeld, noTotal);
            }
        } catch (bytes memory reason) {
            _recordExitRevert(reason);
        }
    }

    /// @dev Resolves the market once per run, one pick in three once two positions are live,
    ///      so the switch lands mid-run and the exits after it have claims to pay (one pick in
    ///      eight landed near the end of a 50-call run and left one run in six with a payout
    ///      after the switch, measured on 2026-09-14): the Oracle winds the vault down
    ///      when it is Active (the redemption reverts while Active, and a frozen vault needs no
    ///      wind-down), then the condition's oracle, the test contract, reports [1, 0], [0, 1],
    ///      or [1, 1] by seed, the three vectors Prophet's Resolution.sol allows. No try/catch:
    ///      nothing documented can reject either call.
    function resolve(uint256 seed) public {
        if (completedResolutions > 0 || seed % 3 != 0 || positionIds.length < 2) return;
        if (vault.phase() == 1) {
            vm.prank(oracleAddr);
            vault.startWindDown();
        }
        uint256 which = (seed / 8) % 3;
        uint256[] memory payouts = which == 0 ? _payouts(1, 0) : which == 1 ? _payouts(0, 1) : _payouts(1, 1);
        reporter.reportPayouts(payouts);
        completedResolutions++;
    }

    /// @dev The Oracle's redemption, the switch. MarketNotResolved (no result yet) and
    ///      VaultStillActive are its documented rejections; any other selector fails the run.
    function redeem(uint256) public {
        vm.prank(oracleAddr);
        try vault.redeemOutcomeTokens() {
            completedRedemptions++;
        } catch (bytes memory reason) {
            bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0xffffffff);
            if (
                undocumentedExitRevert == bytes4(0) && selector != LPVault.MarketNotResolved.selector
                    && selector != LPVault.VaultStillActive.selector
            ) {
                undocumentedExitRevert = selector;
            }
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

    /// @dev The two sides of the USDC ratio (FR-9BRM before the switch, FR-CYS5 after it): held
    ///      is the balance plus the USDC the settlement produces (the free pairs, or every token
    ///      at the stored payout) less totalEscrowed, floored at zero; total is the principal and
    ///      the fees owed, plus the token totals at the stored payout after the switch.
    function _usdcRatioSides() internal view returns (uint256 held, uint256 total, bool resolved) {
        (uint256 yes, uint256 no) = _balances();
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        resolved = (numYes | numNo) != 0;
        uint256 incoming = resolved ? _atPayout(yes, no) : _freePairs(yes, no);
        uint256 balance = mockUsdc.balanceOf(address(vault)) + incoming;
        uint256 escrowed = vault.totalEscrowed();
        held = balance > escrowed ? balance - escrowed : 0;
        total = vault.totalUsdcOwed() + vault.totalFeesOwed();
        if (resolved) total += _atPayout(vault.totalYesOwed(), vault.totalNoOwed());
    }

    /// @dev What `yes` YES and `no` NO redeem for at the stored payout, each side rounded down,
    ///      as the ConditionalTokens contract pays.
    function _atPayout(uint256 yes, uint256 no) internal view returns (uint256) {
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        uint256 den = uint256(numYes) + uint256(numNo);
        return yes * numYes / den + no * numNo / den;
    }

    /// @dev After the switch a burn pays one USDC sum: usdcPaid + tokenPaid must equal
    ///      floor((usdcOwed + feesOwed + tokenUsdc) x min(1, held / total)), never above held,
    ///      with the token leg valued at the stored payout (FR-CYS4, FR-CYS5).
    function _checkResolvedBurnedLog(Vm.Log[] memory logs, uint256 usdcHeld, uint256 usdcTotal) internal {
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
            uint256 tokenUsdc = tokenId == vault.yesTokenId()
                ? _atPayout(tokenOwed, 0)
                : (tokenId == vault.noTokenId() ? _atPayout(0, tokenOwed) : 0);
            _checkLeg(usdcOwed + feesOwed + tokenUsdc, usdcPaid + tokenPaid, usdcHeld, usdcTotal, "USDC (resolved)");
            // A redemption burns tokens, which is a TransferSingle to the zero address; a
            // transfer to any other address is the token leg the switch forbids
            for (uint256 j = 0; j < logs.length; j++) {
                if (
                    logs[j].emitter == address(ctf) && logs[j].topics[0] == TransferSingle.selector
                        && logs[j].topics[3] != bytes32(0)
                ) {
                    _mismatch("a resolved burn made an ERC-1155 transfer");
                }
            }
            return;
        }
        _mismatch("a successful burn must emit PositionBurned");
    }

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    /// @dev What each token balance holds after the merge of the free pairs, the token ratios'
    ///      numerators (FR-9BRN, FR-9BRO), with the owed totals read before the call.
    function _tokensHeldAfterMerge() internal view returns (uint256 yesHeld, uint256 noHeld) {
        (uint256 yes, uint256 no) = _balances();
        uint256 pairs = _freePairs(yes, no);
        yesHeld = yes - pairs;
        noHeld = no - pairs;
    }

    /// @dev The free-pairs rule (FEAT-6HBN ADR-DFE2), the one handler mirror: min(yes - min(yes,
    ///      totalYesOwed()), no - min(no, totalNoOwed())), with the totals read before the call,
    ///      so the exiting position's own band never counts as free.
    function _freePairs(uint256 yes, uint256 no) internal view returns (uint256) {
        uint256 yesOwed = vault.totalYesOwed();
        uint256 noOwed = vault.totalNoOwed();
        uint256 freeYes = yes > yesOwed ? yes - yesOwed : 0;
        uint256 freeNo = no > noOwed ? no - noOwed : 0;
        return freeYes < freeNo ? freeYes : freeNo;
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

// ──────────────────────────────────────────────
// Drift-free handler: the base handler without a donation or a drain, with every range inside
// the board's quotable band and whole tokens per level, and with every successful move filled
// by the keeper at a spread of 2,000 bps (SC-DFDY). The base handler keeps its wider bounds and
// its drift actions, because ledger exactness under drift is its job; this one proves value
// conservation, which needs the vault to hold exactly what the fills bring.
// ──────────────────────────────────────────────
contract DriftFreeLedgerHandler is SolvencyLedgerHandler, KeeperFillFixture {
    /// @dev The board's spread on every fill, in bps.
    uint32 internal constant SPREAD_BPS = 2000;

    /// @dev The spread income every fill left in the vault: the model price less the bid,
    ///      summed over every token bought, floored once per move.
    uint256 public spreadIncome;

    constructor(
        LPVault vault_,
        MockERC20 mockUsdc_,
        ITestConditionalTokens ctf_,
        address operatorAddr_,
        address oracleAddr_,
        address exchangeAddr_
    ) SolvencyLedgerHandler(vault_, mockUsdc_, ctf_, operatorAddr_, oracleAddr_, exchangeAddr_) {}

    /// @dev No donation: every token the vault holds arrived through a fill.
    function fund(uint256) public override {}

    /// @dev No drain: every USDC that left the vault was a fill's spend.
    function drain(uint256) public override {}

    /// @dev A range inside [100, 9900], where the board quotes every level, so a bid is never
    ///      above the model price.
    function _range(int256 lowerSeed, uint256 widthSeed)
        internal
        view
        override
        returns (int24 tickLower, int24 tickUpper)
    {
        int256 c = int256(vault.currentTick());
        int256 lo = bound(lowerSeed, c - 600, c + 600);
        if (lo < 100) lo = 100;
        if (lo > 9300) lo = 9300;
        tickLower = int24(lo / 10 * 10);
        tickUpper = tickLower + int24(uint24(bound(widthSeed, 1, 60) * 10));
        if (tickUpper > 9900) tickUpper = 9900;
    }

    /// @dev A deposit that is a multiple of the width, so every level holds a whole number of
    ///      token units and only the USDC spend rounds, once per move.
    function _deposit(uint256 usdcSeed, int24 tickLower, int24 tickUpper) internal pure override returns (uint256) {
        uint256 width = uint256(int256(tickUpper - tickLower));
        return bound(usdcSeed, 1e4, 1e9) * width;
    }

    /// @dev The keeper merges on sight before it posts the next ladder, then the move runs, and
    ///      every level the move crossed is filled at the board's bid. The merge first keeps the
    ///      vault's USDC at or above the next spend: a level filled twice in the same direction
    ///      holds its USDC as a pair until a merge. The base updateTick succeeds if and only if
    ///      the tick changed, so the fill follows exactly the successful moves.
    function move(int256 moveSeed) public override {
        vault.mergeCompleteSets();
        int24 from = vault.currentTick();
        super.move(moveSeed);
        int24 to = vault.currentTick();
        if (to != from) spreadIncome += _fillMove(vault, exchangeAddr, from, to, SPREAD_BPS);
    }

    /// @dev The two sides of the USDC ratio, for the coverage invariant.
    function usdcSides() external view returns (uint256 held, uint256 total, bool resolved) {
        return _usdcRatioSides();
    }

    /// @dev Burns every live position through the checked burn, from the last to the first, and
    ///      drops the records a merge consumed, which no longer burn (PositionNotFound).
    function burnAll() external {
        for (uint256 i = positionIds.length; i > 0; i--) {
            (,,,, uint128 liquidity,,) = vault.positions(positionIds[i - 1]);
            if (liquidity == 0) {
                positionIds[i - 1] = positionIds[positionIds.length - 1];
                positionIds.pop();
                continue;
            }
            burn(i - 1);
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

        handler = new SolvencyLedgerHandler(vault, mockUsdc, ctf, operatorAddr, oracleAddr, exchangeAddr);
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

    /// @dev Reports the result of the vault's condition, whose question ID is the market ID. Only
    ///      the handler may call it: this contract prepared the condition, so it is the oracle on
    ///      the ConditionalTokens contract, and the fuzzer must not report on its own.
    function reportPayouts(uint256[] calldata payouts) external {
        require(msg.sender == address(handler), "only the handler reports");
        _resolve(bytes32(uint256(1)), payouts);
    }

    // NFR-9BRT, NFR-9BRU: no move, no exit, and no redemption reverted for an undocumented reason.
    function invariant_ledgerRevertsOnlyForDocumentedReasons() public view {
        assertEq(handler.undocumentedMoveRevert(), bytes4(0), "updateTick reverted with an undocumented selector");
        assertEq(
            handler.undocumentedExitRevert(),
            bytes4(0),
            "an exit or the redemption reverted with an undocumented selector"
        );
    }

    /// @dev Every action ran at least once, so each invariant proved something. The setUp prologue
    ///      makes the counters nonzero when the action works, and its drain makes the first burn
    ///      a cut, so invariant 3 proves the ratio on a real shortfall in every run. No guard for
    ///      the switch: the resolution is one pick in eight and a per-run guard would fail about
    ///      one run in a thousand; the deterministic tests of UC-6HBP, UC-7G41, UC-9BR2, and
    ///      UC-U07A prove the transition, and this harness proves the invariants hold across it.
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

/// @dev The conservation harness of finding CV-02 (SC-DFDY). fail-on-revert, as above: a fill
///      that cannot spend, a mint outside the band, or an undocumented revert fails the run.
/// forge-config: default.invariant.fail-on-revert = true
contract SolvencyConservationInvariantTest is StdInvariant, LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    DriftFreeLedgerHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));
        vm.prank(operatorAddr);
        vault.updateTick(5000);

        handler = new DriftFreeLedgerHandler(vault, mockUsdc, ctf, operatorAddr, oracleAddr, exchangeAddr);
        targetContract(address(handler));

        // The closing burn is the test's, not the fuzzer's, and the two drift actions do nothing
        // here, so the run's calls go to the actions that move value
        bytes4[] memory excluded = new bytes4[](3);
        excluded[0] = DriftFreeLedgerHandler.burnAll.selector;
        excluded[1] = DriftFreeLedgerHandler.fund.selector;
        excluded[2] = DriftFreeLedgerHandler.drain.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));

        // Prologue, as the ledger harness runs it without the donation and the drain: two
        // positions, a filled move, a fee report, and a burn
        handler.mint(5000, 5, 300e6, false);
        handler.mint(5100, 7, 123_456_789, false);
        handler.move(250);
        handler.notify(5e6);
        handler.burn(1);
    }

    // SC-DFDY, FR-9BRM to FR-9BRO: under drift-free fills the USDC above escrow plus the free
    // pairs covers the USDC and fee totals, and each token balance covers its total, so every
    // ratio is 1 on every call.
    function invariant_holdingsCoverTotals() public view {
        (uint256 held, uint256 total, bool resolved) = handler.usdcSides();
        assertGe(held, total, "the USDC above escrow plus the free pairs must cover the USDC and fee totals");
        if (!resolved) {
            assertGe(
                ctf.balanceOf(address(vault), vault.yesTokenId()), vault.totalYesOwed(), "YES must cover its total"
            );
            assertGe(ctf.balanceOf(address(vault), vault.noTokenId()), vault.totalNoOwed(), "NO must cover its total");
        }
    }

    // SC-DFDY, FR-9BRR: every burn and every collect paid its owed amount in full, and no payout
    // mismatched the ratio.
    function invariant_burnsPayInFull() public view {
        assertFalse(handler.payoutMismatch(), handler.payoutMismatchReason());
        assertEq(handler.cutPayouts(), 0, "no burn or collect was cut under drift-free fills");
    }

    /// @dev Reports the result of the vault's condition; only the handler may call it, as in the
    ///      ledger harness.
    function reportPayouts(uint256[] calldata payouts) external {
        require(msg.sender == address(handler), "only the handler reports");
        _resolve(bytes32(uint256(1)), payouts);
    }

    /// @dev The closing check: every position burns, the vault holds no token, and the USDC
    ///      above escrow is the spread income plus at most the dust the roundings leave, one unit
    ///      per completed mint, move, burn, fee report, collect, redemption, and consumed merge
    ///      position (see the file header). A run with no completed move or burn proves nothing,
    ///      so both counters must be above zero.
    function afterInvariant() public {
        assertGt(handler.completedMoves(), 0, "the run must include a completed move");
        assertGt(handler.completedBurns(), 0, "the run must include a completed burn");

        handler.burnAll();

        assertEq(ctf.balanceOf(address(vault), vault.yesTokenId()), 0, "no YES after every burn");
        assertEq(ctf.balanceOf(address(vault), vault.noTokenId()), 0, "no NO after every burn");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed() + vault.totalNoOwed(), 0, "every total is zero");

        uint256 above = mockUsdc.balanceOf(address(vault)) - vault.totalEscrowed();
        uint256 income = handler.spreadIncome();
        uint256 residueBound = handler.completedMints() + handler.completedMoves() + handler.completedBurns()
            + handler.completedNotifies() + handler.completedCollects() + handler.completedRedemptions()
            + handler.completedMerges();
        assertGe(above, income, "the vault keeps at least the spread income");
        assertLe(above, income + residueBound, "the vault keeps at most the spread income plus the rounding dust");
    }
}
