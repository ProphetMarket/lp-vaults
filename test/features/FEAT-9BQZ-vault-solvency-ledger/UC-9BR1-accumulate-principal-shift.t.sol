// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR1: Accumulate Principal Shift
// Integration tests for every scenario in this use case.
// Covers: SC-9BS8, SC-9BS9, SC-9BSA, SC-9BSB (T-005), FR-9BRI, FR-9BRJ, FR-9BRK, FR-9BRL
//
// Every expected amount here is derived by hand from the split model _owedAmounts uses:
// a position's principal is spread evenly across the ticks in its range, so at any tick T
// inside [lower, upper) it is owed `liquidity * (upper - T) / 1e18` in USDC and
// `liquidity * (T - lower) / 1e18` as a complete set (that many YES AND that many NO).
// Every position in this file is sized so `usdcAmount` divides its range width exactly,
// which makes `liquidity * span / 1e18` land on a whole number and lets each assertion
// pin an exact figure rather than a tolerance.
//
// The vault-wide shift for one traversed span is that same formula against the liquidity
// active across the span: `activeLiquidity * span / 1e18`. Every test therefore asserts
// the totals both as an exact figure AND against the summed per-position split at the new
// tick, because those are two independent derivations of the same number.

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock — balanceOf, approve, transferFrom. Matches the updateTick
// suite's mock: no position here is ever burned, so no transfer path is exercised.
// ──────────────────────────────────────────────
contract MockERC20ForShift {
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

contract MockConditionalTokensForShift is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// Shared setup: a factory, one Active vault at currentTick 0, and a funded LP.
// Positions are NOT minted here — each scenario lays out its own initialized ticks,
// because the whole subject of this use case is which spans a move traverses.
// ──────────────────────────────────────────────
contract PrincipalShiftTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20ForShift mockUsdc;
    MockConditionalTokensForShift mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20ForShift();
        mockCt = new MockConditionalTokensForShift();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault =
            LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq, conditionId, yesTokenId, noTokenId));

        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Escrows and mints one position, which is what initializes its boundary ticks.
    function _mint(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        bytes memory sig = _signMintIntent(tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _signMintIntent(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault))
        );
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _updateTick(int24 newTick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(newTick);
    }

    /// @dev Asserts the three principal totals hold exactly these amounts. The outcome leg
    ///      is a complete set, so YES and NO are always credited and debited together.
    function _assertPrincipal(uint256 usdcOwed, uint256 outcomeOwed, string memory reason) internal view {
        assertEq(vault.totalUsdcOwed(), usdcOwed, reason);
        assertEq(vault.totalYesOwed(), outcomeOwed, reason);
        assertEq(vault.totalNoOwed(), outcomeOwed, reason);
    }
}

// ──────────────────────────────────────────────
// SC-9BS8: Price move crossing several initialized ticks accumulates each segment
// ──────────────────────────────────────────────
contract MultiCrossingShiftTest is PrincipalShiftTestBase {
    // Three positions with deliberately different liquidity, so each traversed span has
    // its own active-liquidity figure and a single vault-wide multiplication cannot
    // reproduce the right answer:
    //
    //   WIDE   [-100, 100)  2000 USDC over 200 ticks -> liquidity 10e18  (in range at 0)
    //   MID    [  20,  60)   800 USDC over  40 ticks -> liquidity 20e18
    //   UPPER  [  40,  80)   400 USDC over  40 ticks -> liquidity 10e18
    //
    // Initialized ticks: -100, 20, 40, 60, 80, 100. currentTick 0, activeLiquidity 10e18.
    function setUp() public override {
        super.setUp();
        _mint(int24(-100), int24(100), 2000, keccak256("wide"));
        _mint(int24(20), int24(60), 800, keccak256("mid"));
        _mint(int24(40), int24(80), 400, keccak256("upper"));
    }

    // SC-9BS8, FR-9BRI, FR-9BRJ, FR-9BRL: an upward move to 70 crosses 20, 40 and 60 and
    // then runs 10 further ticks. Each span is measured against the liquidity active
    // across it:
    //
    //   [ 0, 20] @ 10e18 -> 200      (WIDE only)
    //   [20, 40] @ 30e18 -> 600      (WIDE + MID, after crossing 20)
    //   [40, 60] @ 40e18 -> 800      (WIDE + MID + UPPER, after crossing 40)
    //   [60, 70] @ 20e18 -> 200      (WIDE + UPPER, after crossing 60 retires MID)
    //                       -----
    //                       1800
    //
    // A single multiplication against the liquidity active at the END of the move would
    // give 20e18 * 70 / 1e18 = 1400, and against the liquidity at the START 700. Pinning
    // 1800 is what separates per-segment accumulation from either shortcut.
    function test_when_a_move_crosses_several_initialized_ticks_then_every_span_contributes_its_own_shift() public {
        // At tick 0 only WIDE is split: 100 ticks of it are still USDC and 100 have
        // converted. MID and UPPER sit entirely above the price, so they are all USDC.
        _assertPrincipal(2200, 1000, "precondition: 1000 (WIDE) + 800 (MID) + 400 (UPPER) USDC, 1000 converted");

        _updateTick(int24(70));

        // Summed per-position split at tick 70, the independent derivation of the same
        // figures: WIDE owes 300 USDC / 1700 outcome, MID is now entirely above its range
        // so 0 / 800, UPPER is split at 100 / 300.
        _assertPrincipal(400, 2800, "each traversed span shifted against its own active liquidity");
    }

    // SC-9BS8, FR-9BRL: a price move converts principal, it never creates or destroys it.
    // The decrease in the origin total must equal the increase in the destination total,
    // which is the property that lets a later burn find its obligation wherever the
    // traversal left it.
    function test_when_a_move_crosses_several_initialized_ticks_then_no_principal_is_created_or_destroyed() public {
        uint256 usdcBefore = vault.totalUsdcOwed();
        uint256 outcomeBefore = vault.totalYesOwed();

        _updateTick(int24(70));

        assertEq(usdcBefore - vault.totalUsdcOwed(), 1800, "USDC principal fell by the accumulated shift");
        assertEq(vault.totalYesOwed() - outcomeBefore, 1800, "the YES leg rose by exactly that shift");
        assertEq(vault.totalNoOwed() - outcomeBefore, 1800, "and so did the NO leg -- the two move as a set");
    }
}

contract DescendingMultiCrossingShiftTest is PrincipalShiftTestBase {
    // The mirror image of the layout above, reflected through tick 0:
    //
    //   WIDE      [-100, 100)  2000 USDC over 200 ticks -> liquidity 10e18  (in range at 0)
    //   LOWER-MID [ -60, -20)   800 USDC over  40 ticks -> liquidity 20e18
    //   LOWER     [ -80, -40)   400 USDC over  40 ticks -> liquidity 10e18
    //
    // Initialized ticks: -100, -80, -60, -40, -20, 100.
    function setUp() public override {
        super.setUp();
        _mint(int24(-100), int24(100), 2000, keccak256("wide"));
        _mint(int24(-60), int24(-20), 800, keccak256("lower-mid"));
        _mint(int24(-80), int24(-40), 400, keccak256("lower"));
    }

    // SC-9BS8, FR-9BRI, FR-9BRJ, FR-9BRL: the same move run downward. This is not symmetry
    // for its own sake — updateTick's left-moving branch advances its search cursor to
    // `next - 1` to avoid re-finding the tick it just crossed, so a segment boundary read
    // from that cursor would be one tick short on every crossing. That mistake accumulates
    // 1710 here instead of 1800, which is why the assertion pins the amount.
    //
    //   [-20,   0] @ 10e18 -> 200    (WIDE only)
    //   [-40, -20] @ 30e18 -> 600    (WIDE + LOWER-MID, after crossing -20)
    //   [-60, -40] @ 40e18 -> 800    (WIDE + LOWER-MID + LOWER, after crossing -40)
    //   [-70, -60] @ 20e18 -> 200    (WIDE + LOWER, after crossing -60 retires LOWER-MID)
    //                                -----
    //                                 1800
    function test_when_a_move_descends_across_several_initialized_ticks_then_principal_converts_back_to_usdc() public {
        // At tick 0 the two lower positions sit entirely below the price, so their
        // principal has fully converted; only WIDE is split.
        _assertPrincipal(1000, 2200, "precondition: 1000 USDC from WIDE, 1000 + 800 + 400 converted");

        _updateTick(int24(-70));

        // Summed per-position split at tick -70: WIDE 1700 / 300, LOWER-MID entirely
        // below its range so 800 / 0, LOWER split at 300 / 100.
        _assertPrincipal(2800, 400, "each descended span converted back against its own active liquidity");
    }

    // SC-9BS8, FR-9BRL: conservation holds in the descending direction too — the outcome
    // legs fall by exactly what the USDC total gains.
    function test_when_a_move_descends_then_no_principal_is_created_or_destroyed() public {
        uint256 usdcBefore = vault.totalUsdcOwed();
        uint256 outcomeBefore = vault.totalYesOwed();

        _updateTick(int24(-70));

        assertEq(vault.totalUsdcOwed() - usdcBefore, 1800, "USDC principal rose by the accumulated shift");
        assertEq(outcomeBefore - vault.totalYesOwed(), 1800, "the YES leg fell by exactly that shift");
        assertEq(outcomeBefore - vault.totalNoOwed(), 1800, "and so did the NO leg -- the two move as a set");
    }
}

// ──────────────────────────────────────────────
// SC-9BS9: Price move crossing zero initialized ticks still accumulates
// ──────────────────────────────────────────────
contract ZeroCrossingShiftTest is PrincipalShiftTestBase {
    // One position spanning the whole neighbourhood, so the only initialized ticks are
    // -100 and 100 and any move between them crosses nothing.
    //
    //   WIDE [-100, 100)  2000 USDC over 200 ticks -> liquidity 10e18
    function setUp() public override {
        super.setUp();
        _mint(int24(-100), int24(100), 2000, keccak256("wide"));
    }

    // SC-9BS9, FR-9BRK: a move from 0 to 30 finds no tick to cross, yet it redistributes
    // the principal of every position spanning the gap exactly as a longer move would.
    // Treating "crossed nothing" as "changed nothing" would silently understate the
    // conversion by 10e18 * 30 / 1e18 = 300.
    function test_when_a_move_crosses_no_initialized_tick_then_the_traversed_span_still_shifts() public {
        _assertPrincipal(1000, 1000, "precondition: WIDE is split evenly at tick 0");

        // The crossing count in the event is the direct evidence that nothing was crossed,
        // so the shift below cannot be attributed to a crossing.
        vm.expectEmit(true, true, false, true);
        emit TickUpdated(int24(0), int24(30), 0);
        _updateTick(int24(30));

        // Per-position split at tick 30: 70 ticks still USDC, 130 converted.
        _assertPrincipal(700, 1300, "the single traversed span shifted 300 even with no crossing");

        // Nothing was crossed, so the liquidity the span was measured against is also the
        // liquidity the vault still holds active.
        assertEq(vault.activeLiquidity(), 10e18, "no crossing means no liquidityNet was applied");
    }

    // SC-9BS9, FR-9BRK: the shift a gap contributes does not depend on it being reached in
    // one call. Two 15-tick hops inside the gap must leave the ledger exactly where the
    // single 30-tick move left it, which is what "matches what the same span would have
    // contributed had it been part of a longer move" means in practice.
    function test_when_a_gap_is_traversed_in_two_hops_then_the_ledger_lands_where_one_hop_would() public {
        _updateTick(int24(15));
        _assertPrincipal(850, 1150, "the first hop shifts half the span");

        _updateTick(int24(30));
        _assertPrincipal(700, 1300, "two hops leave the totals where a single 30-tick move would");
    }
}

// ──────────────────────────────────────────────
// SC-9BSA: New tick off an initialized tick leaves a nonzero trailing segment
// ──────────────────────────────────────────────
contract TrailingSegmentShiftTest is PrincipalShiftTestBase {
    //   WIDE [-100, 100)  2000 USDC over 200 ticks -> liquidity 10e18
    //   MID  [  20,  60)   800 USDC over  40 ticks -> liquidity 20e18
    //
    // Initialized ticks: -100, 20, 60, 100. currentTick 0, activeLiquidity 10e18.
    function setUp() public override {
        super.setUp();
        _mint(int24(-100), int24(100), 2000, keccak256("wide"));
        _mint(int24(20), int24(60), 800, keccak256("mid"));
    }

    // SC-9BSA, FR-9BRJ: 45 is not an initialized tick, so the crossing loop stops at 20
    // and 25 ticks of travel remain unaccounted for until the trailing segment is
    // accumulated after the loop exits.
    //
    //   [ 0, 20] @ 10e18 -> 200      crossed
    //   [20, 45] @ 30e18 -> 750      trailing
    //                       ----
    //                        950
    //
    // Accumulating only inside the loop would record 200 and leave 750 — the larger of the
    // two — on the floor. Most moves land off an initialized tick, so that is the common
    // case rather than an edge case.
    function test_when_the_new_tick_misses_every_initialized_tick_then_the_trailing_span_still_shifts() public {
        _assertPrincipal(1800, 1000, "precondition: 1000 (WIDE) + 800 (MID) USDC, 1000 converted");

        _updateTick(int24(45));

        // Per-position split at tick 45: WIDE 550 / 1450, MID 300 / 500.
        _assertPrincipal(850, 1950, "the crossed span and the trailing span both contributed");
    }

    // SC-9BSA, FR-9BRJ: the complement — a move landing exactly on an initialized tick
    // leaves nothing trailing. Pinning this stops the trailing accumulation from being
    // written as an unconditional extra span, which would double-count the last crossing.
    //
    //   [ 0, 20] @ 10e18 -> 200      crossed, and nothing remains after it
    function test_when_the_new_tick_lands_on_an_initialized_tick_then_no_trailing_span_is_added() public {
        _updateTick(int24(20));

        // Per-position split at tick 20: WIDE 800 / 1200, MID entirely above the price so
        // still 800 / 0.
        _assertPrincipal(1600, 1200, "only the crossed span shifted; the trailing span is empty");
    }
}

// ──────────────────────────────────────────────
// SC-9BSB: Each segment is accumulated before its tick's liquidity change is applied
// ──────────────────────────────────────────────
contract SegmentOrderingShiftTest is PrincipalShiftTestBase {
    // The liquidity on either side of tick 40 differs by an order of magnitude, which is
    // what makes the ordering observable in the totals rather than in the dust:
    //
    //   WIDE  [-100, 100)  2000 USDC over 200 ticks -> liquidity  10e18  (in range at 0)
    //   HEAVY [  40,  80)  4000 USDC over  40 ticks -> liquidity 100e18
    function setUp() public override {
        super.setUp();
        _mint(int24(-100), int24(100), 2000, keccak256("wide"));
        _mint(int24(40), int24(80), 4000, keccak256("heavy"));
    }

    // SC-9BSB, FR-9BRI: HEAVY does not exist below tick 40, so the 40 ticks of travel
    // that precede it must be measured against 10e18 — the activeLiquidity in force
    // across that span — and only then may the tick's +100e18 liquidityNet be applied.
    //
    //   correct:   [ 0, 40] @  10e18 ->  400   then cross 40
    //              [40, 60] @ 110e18 -> 2200
    //                                   ----
    //                                   2600
    //
    //   reversed:  cross 40 first, then [0, 40] @ 110e18 -> 4400 + 2200 = 6600
    //
    // The reversed order reverts nothing and emits nothing unusual; the totals simply
    // drift by 4000 from what the vault owes. That is why this asserts an amount and not
    // a direction.
    function test_when_a_span_ends_at_a_heavy_tick_then_it_is_measured_before_that_tick_is_crossed() public {
        _assertPrincipal(5000, 1000, "precondition: 1000 (WIDE) + 4000 (HEAVY) USDC, 1000 converted");

        _updateTick(int24(60));

        // Summed per-position split at tick 60: WIDE 400 / 1600, HEAVY 2000 / 2000.
        _assertPrincipal(2400, 3600, "the pre-crossing span used 10e18, not the post-crossing 110e18");
    }

    // SC-9BSB, FR-9BRI: the tick's liquidity change is still applied — accumulating first
    // must not swallow the crossing. The span after tick 40 is the one that proves it,
    // and activeLiquidity is the direct read.
    function test_when_a_heavy_tick_is_crossed_then_its_liquidity_change_is_applied_to_the_next_span() public {
        _updateTick(int24(60));

        assertEq(vault.activeLiquidity(), 110e18, "crossing 40 brought HEAVY's liquidity into range");

        // A further 10 ticks now shift against the full 110e18: 110e18 * 10 / 1e18 = 1100.
        _updateTick(int24(70));

        // Per-position split at tick 70: WIDE 300 / 1700, HEAVY 1000 / 3000.
        _assertPrincipal(1300, 4700, "the span after the crossing was measured against 110e18");
    }
}
