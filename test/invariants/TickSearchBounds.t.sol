// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TVS1: Update Current Tick — invariant coverage for the target-bounded tick search.
// Covers: NFR-5IDG
//
// Pins the property that updateTick's bitmap scan costs what the Operator's own
// price move costs, and never more, no matter where LPs have initialized ticks.
//
// Why this file exists separately from test/invariants/FeeGrowthAccounting.t.sol:
// that suite's handler bounds every tick to [-2000, 2000] and wraps its updateTick
// call as `try vault.updateTick(newTick) {} catch {}`. Both choices are right for
// its own subject — fee-growth arithmetic, where a rejected action is a legitimate
// outcome worth tolerating — but together they make it structurally blind to the
// bug this file guards: it can never reach an extreme bitmap word, and it reads an
// arithmetic panic as an ordinary rejection. The handler below tolerates only the
// four rejections updateTick actually documents, and treats everything else as a
// failure to be surfaced.

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {CTFPositionIds} from "../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock — balanceOf, approve, transferFrom.
// ──────────────────────────────────────────────
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
}

contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// Handler: mints positions anywhere in int24 — including against both extreme
// bitmap words — and walks the tick in bounded steps, recording what it sees.
// ──────────────────────────────────────────────
contract TickSearchBoundsHandler is Test {
    LPVault public vault;
    MockERC20 public mockUsdc;

    address public operatorAddr;
    address public lp;
    uint256 public lpPk;

    int24 public constant TICK_SPACING = 10;

    /// @dev Outermost ticks that are both inside int24 and aligned to TICK_SPACING.
    ///      A position here initializes bits in bitmap word 32767 (== type(int16).max)
    ///      or word -32768 (== type(int16).min) — the two words a bounded search must
    ///      be able to stop against, and that an unbounded one walks toward.
    int24 public constant HIGHEST_ALIGNED_TICK = 8388600;
    int24 public constant LOWEST_ALIGNED_TICK = -8388600;

    /// @dev Widest single move the handler makes. NFR-5IDG promises that scan cost
    ///      tracks the Operator's move, not third-party tick placement — it does not
    ///      promise an arbitrarily large jump is cheap. Capping the move is what makes
    ///      the gas assertion below a statement about the bound rather than about the
    ///      distance travelled.
    int24 public constant MAX_MOVE = 2000;

    /// @dev Gas ceiling for a move that crosses nothing at all — pure scan cost.
    ///      A target-bounded scan reads a handful of bitmap words. An unbounded one
    ///      walks toward whichever extreme word an LP has planted a tick in, up to
    ///      32768 cold words at 2100 gas each — roughly 79,000,000, as measured
    ///      against the pre-fix code. The ceiling sits far above the former and two
    ///      orders of magnitude below the latter.
    uint256 public constant ZERO_CROSSING_GAS_CEILING = 200_000;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 constant TICK_UPDATED_SIG = keccak256("TickUpdated(int24,int24,uint256)");

    // ── Observations the invariants read ──

    /// @dev Set the first time updateTick reverts with anything other than one of its
    ///      four documented rejections. An arithmetic panic (0x4e487b71) lands here.
    ///      Recorded rather than asserted inline so the finding survives to the
    ///      invariant check regardless of the suite's fail_on_revert setting.
    bytes4 public unexpectedRevertSelector;

    /// @dev Highest gas seen on an updateTick call that crossed zero ticks.
    uint256 public maxZeroCrossingGas;

    /// @dev Tick the run was at when maxZeroCrossingGas was observed, and the target
    ///      it was moving to — reported in the failure message so a regression names
    ///      the coordinates that triggered it rather than just a number.
    int24 public worstFrom;
    int24 public worstTo;

    uint256 public updateTickSuccesses;
    uint256 public zeroCrossingMoves;

    // ── Position ledger, mirrored so the invariants can recompute from scratch ──

    struct MintedPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    MintedPosition[] public mintedPositions;
    int24[] public referencedTicks;
    mapping(int24 => bool) public tickAlreadyReferenced;

    uint256 intentNonce;

    constructor(LPVault _vault, MockERC20 _mockUsdc, address _operatorAddr, uint256 _lpPk) {
        vault = _vault;
        mockUsdc = _mockUsdc;
        operatorAddr = _operatorAddr;
        lpPk = _lpPk;
        lp = vm.addr(_lpPk);
    }

    function mintedPositionCount() external view returns (uint256) {
        return mintedPositions.length;
    }

    function referencedTickCount() external view returns (uint256) {
        return referencedTicks.length;
    }

    // ──────────────────────────────────────────────
    // Action: plant a position, either near the current tick or against an extreme.
    //
    // The "near" mode produces real crossings, so the tick-state invariants have
    // something to check. The "extreme" mode is the adversarial one: it is exactly
    // the move available to any LP, since a mint intent may name any aligned range,
    // and it is what an unbounded search would then chase on every later call.
    // ──────────────────────────────────────────────
    function mintPosition(uint256 placementSeed, uint256 widthSeed, uint256 usdcSeed, bool nearCurrentTick) public {
        int24 width = int24(int256(bound(widthSeed, 1, 50))) * TICK_SPACING;
        int24 tickLower;

        if (nearCurrentTick) {
            int24 current = vault.currentTick();
            int256 lo = int256(current) - 3000;
            int256 hi = int256(current) + 3000;
            // Keep the whole range inside int24 even at the edges of the walk.
            if (lo < int256(LOWEST_ALIGNED_TICK)) lo = int256(LOWEST_ALIGNED_TICK);
            if (hi > int256(HIGHEST_ALIGNED_TICK) - int256(width)) hi = int256(HIGHEST_ALIGNED_TICK) - int256(width);
            if (lo > hi) lo = hi;
            tickLower = int24(bound(int256(placementSeed), lo, hi));
        } else {
            // Hug one extreme or the other, so bitmap words 32767 and -32768 both
            // get populated across a run.
            bool high = placementSeed % 2 == 0;
            tickLower = high
                ? int24(
                    bound(
                        int256(placementSeed),
                        int256(HIGHEST_ALIGNED_TICK) - 2000 - int256(width),
                        int256(HIGHEST_ALIGNED_TICK) - int256(width)
                    )
                )
                : int24(bound(int256(placementSeed), int256(LOWEST_ALIGNED_TICK), int256(LOWEST_ALIGNED_TICK) + 2000));
        }

        // Align both bounds. Solidity truncates toward zero, so this stays a multiple
        // of TICK_SPACING on both sides of zero.
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = tickLower + width;
        if (tickUpper > HIGHEST_ALIGNED_TICK) return;

        uint256 usdcAmount = bound(usdcSeed, 1, 1_000_000);

        bytes32 intentId = keccak256(abi.encode("tick-search-mint", intentNonce++));
        bytes memory sig = _sign(tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        try vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig) {}
        catch {
            return;
        }

        vm.prank(operatorAddr);
        try vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig) returns (uint256 id) {
            (,,, uint128 liquidity,,) = vault.positions(id);
            mintedPositions.push(MintedPosition(tickLower, tickUpper, liquidity));
            _rememberTick(tickLower);
            _rememberTick(tickUpper);
        } catch {
            // A rejected mint is a legitimate outcome for arbitrary input (a zero
            // liquidity weight on a wide range, for instance). Mint rejection is
            // FEAT-T7AF's subject, not this file's.
        }
    }

    // ──────────────────────────────────────────────
    // Action: move the tick a bounded distance and account for what it cost.
    //
    // Unlike the fee-growth handler, this deliberately does NOT swallow every
    // revert. Only updateTick's four documented rejections are tolerated; anything
    // else — an arithmetic panic above all — is recorded for the invariant to fail on.
    // ──────────────────────────────────────────────
    function moveTick(int256 moveSeed) public {
        int24 from = vault.currentTick();
        int256 move = bound(moveSeed, -int256(MAX_MOVE), int256(MAX_MOVE));
        if (move == 0) return;

        int256 targetWide = int256(from) + move;
        if (targetWide > int256(type(int24).max)) targetWide = int256(type(int24).max);
        if (targetWide < int256(type(int24).min)) targetWide = int256(type(int24).min);
        int24 target = int24(targetWide);
        if (target == from) return;

        vm.recordLogs();

        vm.prank(operatorAddr);
        uint256 gasBefore = gasleft();
        try vault.updateTick(target) {
            uint256 gasUsed = gasBefore - gasleft();
            updateTickSuccesses++;

            // Only a move that crossed nothing is a clean measurement of scan cost;
            // crossings are bounded separately by MAX_TICK_CROSSINGS and legitimately
            // dominate the bill when they happen.
            if (_ticksCrossedFromLogs() == 0) {
                zeroCrossingMoves++;
                if (gasUsed > maxZeroCrossingGas) {
                    maxZeroCrossingGas = gasUsed;
                    worstFrom = from;
                    worstTo = target;
                }
            }
        } catch (bytes memory err) {
            if (!_isDocumentedRejection(err) && unexpectedRevertSelector == bytes4(0)) {
                unexpectedRevertSelector = _selectorOf(err);
            }
        }
    }

    /// @dev The four rejections updateTick's API surface documents. Everything else
    ///      — including Panic(uint256) — is a defect this suite exists to catch.
    function _isDocumentedRejection(bytes memory err) internal pure returns (bool) {
        bytes4 sel = _selectorOf(err);
        return sel == LPVault.NotOperator.selector || sel == LPVault.VaultNotActive.selector
            || sel == LPVault.SameTick.selector || sel == LPVault.TooManyTicksCrossed.selector;
    }

    function _selectorOf(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0xffffffff);
        assembly {
            sel := mload(add(err, 32))
        }
    }

    /// @dev Reads ticksCrossed out of the TickUpdated event the call just emitted.
    ///      oldTick and newTick are indexed, so ticksCrossed is the whole data word.
    function _ticksCrossedFromLogs() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TICK_UPDATED_SIG) {
                return abi.decode(logs[i].data, (uint256));
            }
        }
        // No event found means no successful update to measure; treat as "crossed
        // something" so it is never counted as a clean zero-crossing sample.
        return type(uint256).max;
    }

    function _rememberTick(int24 tick) internal {
        if (!tickAlreadyReferenced[tick]) {
            tickAlreadyReferenced[tick] = true;
            referencedTicks.push(tick);
        }
    }

    function _sign(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 domainSep =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lpPk, digest);
        return abi.encodePacked(r, s, v);
    }
}

// ──────────────────────────────────────────────
// NFR-5IDG: updateTick's cost follows the Operator's reported move, and the search
// terminates cleanly, across arbitrary interleavings of mint and tick movement with
// positions planted against both extreme bitmap words.
// ──────────────────────────────────────────────
contract TickSearchBoundsInvariantTest is StdInvariant, Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;
    TickSearchBoundsHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        // minimumFirstLiquidity of 1 keeps the first-mint floor out of the way —
        // that floor is FEAT-REPZ's subject, and a rejected first mint would just
        // starve this suite of positions.
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(
                keccak256("tick-search-bounds"), int24(10), uint128(1), conditionId, yesTokenId, noTokenId
            )
        );

        address lp = vm.addr(LP_PK);
        mockUsdc.mint(lp, type(uint128).max);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        handler = new TickSearchBoundsHandler(vault, mockUsdc, operatorAddr, LP_PK);
        targetContract(address(handler));
    }

    // NFR-5IDG: the search reports "not found" and lets the call finish; it never
    // reverts with an arithmetic panic. This is the assertion the pre-fix code fails
    // — its unguarded `wordPos++` overflowed int16 on reaching the highest word — and
    // the one the existing fee-growth suite's blanket `catch {}` could not have made.
    function invariant_updateTickOnlyRevertsForDocumentedReasons() public view {
        assertEq(
            handler.unexpectedRevertSelector(),
            bytes4(0),
            "updateTick reverted with an undocumented error (0x4e487b71 is an arithmetic panic)"
        );
    }

    // NFR-5IDG: a move that crosses nothing costs a scan of a few bitmap words,
    // regardless of how many ticks LPs have planted at the extremes by that point.
    function invariant_zeroCrossingMoveCostStaysBounded() public view {
        assertLt(
            handler.maxZeroCrossingGas(),
            handler.ZERO_CROSSING_GAS_CEILING(),
            "a crossing-free updateTick scanned far past its target tick"
        );
    }

    // NFR-5IDG is a claim about cost, so the ceiling above is only meaningful if a run
    // actually produced crossing-free moves to measure — otherwise a run in which every
    // move happened to revert would satisfy it vacuously. This is a post-run check
    // rather than an invariant: it is legitimately false at setUp, before any action
    // has run, which is exactly when an invariant is first evaluated.
    function afterInvariant() external view {
        assertGt(handler.zeroCrossingMoves(), 0, "no crossing-free moves were observed: the gas bound proved nothing");
    }

    // Re-verification of the tick-crossing invariant this repo's CLAUDE.md requires,
    // now against the bounded search: activeLiquidity is the summed liquidity of
    // exactly those positions whose range contains the current tick. A search that
    // skipped a legitimate crossing — the failure mode an over-tight bound would
    // introduce — desynchronizes this without reverting anything.
    function invariant_activeLiquidityMatchesInRangePositions() public view {
        int24 current = vault.currentTick();
        uint256 count = handler.mintedPositionCount();
        uint256 expected;

        for (uint256 i = 0; i < count; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity) = handler.mintedPositions(i);
            if (tickLower <= current && current < tickUpper) {
                expected += liquidity;
            }
        }

        assertEq(uint256(vault.activeLiquidity()), expected, "activeLiquidity diverged from the in-range positions");
    }

    // Tick bookkeeping is unaffected by how the next tick is located: a tick's
    // liquidityGross is still the total liquidity of every position referencing it.
    // Crossing never touches liquidityGross, so this holding after arbitrary movement
    // is what shows the bounded search changed only which words are read.
    function invariant_liquidityGrossMatchesPositionsReferencingTick() public view {
        uint256 tickCount = handler.referencedTickCount();
        uint256 positionCount = handler.mintedPositionCount();

        for (uint256 t = 0; t < tickCount; t++) {
            int24 tick = handler.referencedTicks(t);
            uint256 expected;

            for (uint256 i = 0; i < positionCount; i++) {
                (int24 tickLower, int24 tickUpper, uint128 liquidity) = handler.mintedPositions(i);
                if (tickLower == tick || tickUpper == tick) {
                    expected += liquidity;
                }
            }

            (uint128 liquidityGross,,) = vault.ticks(tick);
            assertEq(uint256(liquidityGross), expected, "liquidityGross diverged from the positions referencing it");
        }
    }
}
