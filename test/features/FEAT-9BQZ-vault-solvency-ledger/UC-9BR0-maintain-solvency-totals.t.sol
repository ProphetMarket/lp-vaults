// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR0: Maintain Solvency Totals
// Integration tests for every scenario in this use case.
// Covers: SC-9BS3, SC-9BS4 (T-001 — escrow), SC-9BS0, SC-9BS1 (T-002 — principal),
// FR-9BRA/B/C (T-003 — fee entitlement), SC-9BS5, SC-9BS6 (T-004 — terminal + housekeeping)
//
// Three of UC-9BR0's nine scenarios are deliberately absent: SC-9BRZ (a tilted mint split),
// SC-9BS2 (a fee notification denominated in YES or NO), and SC-9BS7 (opposing tilts
// reported separately). All three need mintPositionFor / notifyFees signature changes owned
// by FEAT-T7AF and FEAT-TOGR, so no state reachable through this vault can drive them.
//
// Fees are USDC-only today: notifyFees takes a single uint256 and collect pays USDC, so
// totalFeesYesOwed and totalFeesNoOwed have no writer until FEAT-TOGR makes notification
// per-asset. They must still read zero, which _assertFeeTotalsUsdcOnly pins.

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// MockERC20 with transferFrom support, matching the escrow suite's mock.
// Balances matter here beyond the escrow itself: FR-9BRM's usdcRatio numerator
// is the vault's live USDC balance, so these tests assert the balance backing
// totalEscrowed alongside the total.
// ──────────────────────────────────────────────
contract MockERC20ForLedger {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
}

// Balance-tracking ERC-1155 stand-in, matching the burn suite's mock. Needed here
// because an in-range position's burn pays an outcome leg, and yesRatio / noRatio
// will read these balances as their numerators from T-006 onward.
contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[id][to] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        if (to.code.length > 0) {
            bytes4 ack = IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(ack == 0xf23a6e61, "ERC1155: receiver rejected");
        }
    }
}

// ──────────────────────────────────────────────
// Shared setup for every solvency-ledger scenario. Mirrors the escrow suite's
// harness so both read the same way; the ledger-specific parts are the helpers
// at the bottom that read the seven totals.
// ──────────────────────────────────────────────
contract SolvencyLedgerTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20ForLedger mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    uint256 constant LP_TWO_PK = 0xB0B;
    address lp;
    address lpTwo;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    // The canonical intent. Range width is 60 ticks against 600 USDC, so
    // liquidity = 600 * 1e18 / 60 = 10e18, exactly meeting minFirstLiq — the
    // first mint is accepted without the range having to be tuned per test.
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("ledger-intent-1");

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        lpTwo = vm.addr(LP_TWO_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20ForLedger();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault =
            LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq, conditionId, yesTokenId, noTokenId));

        // Fund both LPs and approve the vault.
        mockUsdc.mint(lp, 100_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        mockUsdc.mint(lpTwo, 100_000);
        vm.prank(lpTwo);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Move off the genesis timestamp so the reclaim timelock arithmetic
        // starts from a realistic point rather than zero.
        vm.warp(1_700_000_000);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signIntent(bytes32 typehash, uint256 pk, address lpAddr, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(typehash, lpAddr, tickLower, tickUpper, amount, id));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Escrows an intent as the Operator — the Given state for most scenarios here.
    function _escrow(uint256 pk, address lpAddr, uint256 amount, bytes32 id) internal {
        vm.prank(operatorAddr);
        vault.depositForIntent(
            lpAddr, tickLower, tickUpper, amount, id, _signIntent(MINT_INTENT_TYPEHASH, pk, lpAddr, amount, id)
        );
    }

    function _escrowCanonical() internal {
        _escrow(LP_PK, lp, usdcAmount, intentId);
    }

    /// @dev Mints the canonical intent, which must already be escrowed. Split from
    ///      _mintCanonical so a scenario can assert on the state between the two calls.
    function _mintEscrowed() internal returns (uint256) {
        vm.prank(operatorAddr);
        return vault.mintPositionFor(
            lp,
            tickLower,
            tickUpper,
            usdcAmount,
            intentId,
            _signIntent(MINT_INTENT_TYPEHASH, LP_PK, lp, usdcAmount, intentId)
        );
    }

    /// @dev Escrows and mints the canonical intent, returning the new positionId.
    ///      The Given state for every principal scenario.
    function _mintCanonical() internal returns (uint256) {
        _escrowCanonical();
        return _mintEscrowed();
    }

    /// @dev Escrows and mints a position over an arbitrary range, so a scenario can
    ///      straddle currentTick (which initializes to 0) when it needs the position
    ///      in range — notifyFees reverts against zero active liquidity.
    function _mintOver(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        returns (uint256)
    {
        bytes memory sig = _signIntentOver(MINT_INTENT_TYPEHASH, pk, lpAddr, tl, tu, amount, id);
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tl, tu, amount, id, sig);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lpAddr, tl, tu, amount, id, sig);
    }

    /// @dev Signing helper for ranges other than the canonical one.
    function _signIntentOver(
        bytes32 typehash,
        uint256 pk,
        address lpAddr,
        int24 tl,
        int24 tu,
        uint256 amount,
        bytes32 id
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(typehash, lpAddr, tl, tu, amount, id));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Asserts the three principal totals hold exactly these amounts.
    function _assertPrincipal(uint256 usdcOwed, uint256 yesOwed, uint256 noOwed, string memory reason) internal view {
        assertEq(vault.totalUsdcOwed(), usdcOwed, reason);
        assertEq(vault.totalYesOwed(), yesOwed, reason);
        assertEq(vault.totalNoOwed(), noOwed, reason);
    }

    /// @dev Asserts the three fee totals are still zero.
    function _assertFeeTotalsZero(string memory reason) internal view {
        _assertFeeTotalsUsdcOnly(0, reason);
    }

    /// @dev Asserts the USDC fee total holds `usdcFees` and that neither outcome-side fee
    ///      total was written. Fees are USDC-only until FEAT-TOGR makes notifyFees
    ///      per-asset, so a nonzero YES or NO fee total means a write hit the wrong slot.
    function _assertFeeTotalsUsdcOnly(uint256 usdcFees, string memory reason) internal view {
        assertEq(vault.totalFeesUsdcOwed(), usdcFees, reason);
        assertEq(vault.totalFeesYesOwed(), 0, reason);
        assertEq(vault.totalFeesNoOwed(), 0, reason);
    }

    /// @dev Mints an in-range position over [-40, 20) and notifies `feeAmount` of fees
    ///      against it, funding the vault first. notifyFees reverts against zero active
    ///      liquidity, so the position must straddle currentTick (which starts at 0).
    function _mintInRangeWithFees(uint256 feeAmount) internal returns (uint256 positionId) {
        positionId = _mintOver(LP_PK, lp, int24(-40), int24(20), usdcAmount, intentId);
        mockUsdc.mint(address(vault), feeAmount);
        vm.prank(operatorAddr);
        vault.notifyFees(feeAmount);
    }
}

// ──────────────────────────────────────────────
// Ledger state (FR-9BR3, FR-9BR4, FR-9BR6)
// ──────────────────────────────────────────────
contract SolvencyLedgerStateTest is SolvencyLedgerTestBase {
    // FR-9BR3, FR-9BR6: all seven totals exist and are readable as public views
    // without a transaction. A fresh vault owes nothing, so every one reads zero.
    // This is the baseline every other assertion in the file is measured against.
    function test_when_the_vault_is_fresh_then_every_ledger_total_reads_zero() public view {
        assertEq(vault.totalEscrowed(), 0, "fresh vault has no escrow");
        assertEq(vault.totalUsdcOwed(), 0, "fresh vault owes no USDC principal");
        assertEq(vault.totalYesOwed(), 0, "fresh vault owes no YES");
        assertEq(vault.totalNoOwed(), 0, "fresh vault owes no NO");
        assertEq(vault.totalFeesUsdcOwed(), 0, "fresh vault owes no USDC fees");
        assertEq(vault.totalFeesYesOwed(), 0, "fresh vault owes no YES fees");
        assertEq(vault.totalFeesNoOwed(), 0, "fresh vault owes no NO fees");
    }
}

// ──────────────────────────────────────────────
// SC-9BS3: Escrow deposit raises totalEscrowed and the consuming mint lowers it
// ──────────────────────────────────────────────
contract EscrowObligationTest is SolvencyLedgerTestBase {
    // SC-9BS3, FR-9BRD: the deposit raises the obligation in the same call that
    // pulls the USDC, so the obligation and the balance backing it enter together.
    // Asserting the balance alongside the total is the point — a total that moved
    // without the balance moving would be the exact drift the ledger exists to prevent.
    function test_when_a_deposit_is_escrowed_then_total_escrowed_rises_by_that_amount() public {
        assertEq(vault.totalEscrowed(), 0, "precondition: nothing escrowed yet");

        _escrowCanonical();

        assertEq(vault.totalEscrowed(), 600, "totalEscrowed equals the deposited amount");
        assertEq(mockUsdc.balanceOf(address(vault)), 600, "the vault holds the USDC backing it");
        _assertPrincipal(0, 0, 0, "a deposit creates no position, so no principal is owed yet");
        _assertFeeTotalsZero("a deposit creates no fee entitlement");
    }

    // SC-9BS3, FR-9BR3: totalEscrowed is a running total across intents, not a
    // record of the most recent deposit. Two LPs escrow different amounts and the
    // vault's obligation is their sum.
    function test_when_two_intents_are_escrowed_then_total_escrowed_accumulates_both() public {
        _escrowCanonical();
        _escrow(LP_TWO_PK, lpTwo, 900, keccak256("ledger-intent-2"));

        assertEq(vault.totalEscrowed(), 1500, "600 from the first intent plus 900 from the second");
        assertEq(mockUsdc.balanceOf(address(vault)), 1500, "the vault holds both deposits");
    }

    // SC-9BS3, FR-9BRE, FR-9BR8: the mint consumes the escrow, so the pending-refund
    // obligation is discharged — but nothing is forgiven. It changes form into a live
    // position claim, and both halves of that movement land in the same call. Asserting
    // them together is the point: a decrement without the matching increment would drop
    // an obligation the vault still owes.
    function test_when_a_mint_consumes_the_escrow_then_the_obligation_becomes_a_position_claim() public {
        _escrowCanonical();
        assertEq(vault.totalEscrowed(), 600, "precondition: the intent is funded");

        _mintEscrowed();

        assertEq(vault.totalEscrowed(), 0, "the consumed escrow is no longer a pending refund");
        _assertPrincipal(600, 0, 0, "the same 600 is now owed as position principal");
        assertEq(mockUsdc.balanceOf(address(vault)), 600, "the USDC stays in the vault, now backing a position");
    }

    // SC-9BS3: a mint consuming one intent leaves another LP's escrow untouched.
    // Guards against a decrement that zeroes the total rather than subtracting.
    function test_when_one_of_two_escrows_is_minted_then_the_other_remains_owed() public {
        _escrowCanonical();
        _escrow(LP_TWO_PK, lpTwo, 900, keccak256("ledger-intent-2"));

        _mintEscrowed();

        assertEq(vault.totalEscrowed(), 900, "only the minted intent's escrow is discharged");
    }
}

// ──────────────────────────────────────────────
// SC-9BS0: Burn decrements principal totals by the position's current split
// SC-9BS1: Fee collection leaves principal totals unchanged
// ──────────────────────────────────────────────
contract PrincipalObligationTest is SolvencyLedgerTestBase {
    // SC-9BS0, FR-9BR9: the burn discharges exactly what it paid out. currentTick
    // initializes to 0, below the canonical [20, 80] range, so the whole principal is
    // still USDC and none of it has converted — the split at burn time is all-USDC and
    // the totals return to where they started.
    function test_when_a_position_below_range_is_burned_then_principal_returns_to_zero() public {
        uint256 positionId = _mintCanonical();
        _assertPrincipal(600, 0, 0, "precondition: the position's principal is owed");

        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(positionId);

        _assertPrincipal(0, 0, 0, "the burned position's principal is no longer owed");
        assertEq(mockUsdc.balanceOf(lp) - lpBalanceBefore, 600, "the LP received exactly what was discharged");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault paid out everything it held for this position");
    }

    // SC-9BS0: burning one position leaves the other's claim standing. Guards against
    // a decrement that zeroes the totals rather than subtracting the burned share.
    function test_when_one_of_two_positions_is_burned_then_the_other_remains_owed() public {
        uint256 firstId = _mintCanonical();
        _mintOver(LP_TWO_PK, lpTwo, int24(20), int24(80), 900, keccak256("ledger-intent-2"));
        _assertPrincipal(1500, 0, 0, "precondition: both positions' principal is owed");

        vm.prank(lp);
        vault.burnPosition(firstId);

        _assertPrincipal(900, 0, 0, "only the burned position's principal is discharged");
    }

    // SC-9BS0, FR-9BR8: a position minted while currentTick already sits inside its
    // range is split from its first block — it owes outcome tokens immediately, with no
    // price movement at all. The ledger must record that split, not the deposit amount.
    //
    // Range [-40, 20) with currentTick == 0: liquidity is 600 * 1e18 / 60 = 10e18, so
    // the 20 ticks above the price stay USDC (10e18 * 20 / 1e18 = 200) and the 40 below
    // it have converted (10e18 * 40 / 1e18 = 400), paid as a complete set of each id.
    function test_when_a_position_is_minted_in_range_then_principal_records_the_split() public {
        _mintOver(LP_PK, lp, int24(-40), int24(20), usdcAmount, intentId);

        _assertPrincipal(200, 400, 400, "the starting split, not the 600 deposited");
    }

    // SC-9BS0: the discriminating case. This position's split differs from an all-USDC
    // reading, so a debit computed from anything other than the split at burn time
    // leaves a residue behind. Burning it must return every total to zero.
    function test_when_an_in_range_position_is_burned_then_every_principal_total_clears() public {
        uint256 positionId = _mintOver(LP_PK, lp, int24(-40), int24(20), usdcAmount, intentId);
        _assertPrincipal(200, 400, 400, "precondition: the position owes a split");

        // The vault must hold the outcome tokens it owes before it can pay them out.
        mockCt.mint(address(vault), yesTokenId, 400);
        mockCt.mint(address(vault), noTokenId, 400);

        vm.prank(lp);
        vault.burnPosition(positionId);

        _assertPrincipal(0, 0, 0, "the burn discharges all three legs, leaving no residue");
    }

    // FR-9BR8, NFR-9BRX: liquidity truncates when the deposit does not divide evenly by
    // the range width, so the principal reconstructed from it can sit just below the
    // deposit. Crediting the deposit would strand that remainder as a phantom obligation
    // that survives the position's own burn. 310 over 30 ticks reconstructs to 309.
    function test_when_a_mint_truncates_then_no_phantom_obligation_survives_the_burn() public {
        uint256 positionId = _mintOver(LP_PK, lp, int24(30), int24(60), 310, intentId);

        vm.prank(lp);
        vault.burnPosition(positionId);

        _assertPrincipal(0, 0, 0, "no residue survives a position that truncated at mint");
    }

    // SC-9BS1, FR-9BR7: a fee-only collect pays fees and leaves the position open, so
    // its principal claim is untouched. The position straddles currentTick (0) because
    // notifyFees reverts against zero active liquidity; that also makes this the case
    // where confusing the fee side for the principal side would be easiest.
    function test_when_a_fee_only_collect_runs_then_principal_totals_are_unchanged() public {
        uint256 positionId = _mintOver(LP_PK, lp, int24(-40), int24(20), usdcAmount, intentId);
        _assertPrincipal(200, 400, 400, "precondition: the in-range position's principal is owed");

        // Fund and notify fees so the position has something to collect.
        mockUsdc.mint(address(vault), 300);
        vm.prank(operatorAddr);
        vault.notifyFees(300);

        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.collect(positionId);

        assertGt(mockUsdc.balanceOf(lp), lpBalanceBefore, "the collect actually paid fees");
        _assertPrincipal(200, 400, 400, "collect pays fees only, so the principal claim stands");

        // The position survives with its liquidity and range intact, which is WHY its
        // principal claim is unchanged — the two assertions are one statement.
        (, int24 tl, int24 tu, uint128 liq,,) = vault.positions(positionId);
        assertEq(liq, 10e18, "the position keeps its liquidity");
        assertEq(tl, int24(-40), "the position keeps its lower tick");
        assertEq(tu, int24(20), "the position keeps its upper tick");
    }
}

// ──────────────────────────────────────────────
// Fee entitlement (FR-9BRA, FR-9BRB, FR-9BRC)
// ──────────────────────────────────────────────
contract FeeObligationTest is SolvencyLedgerTestBase {
    // FR-9BRA: notified fees become a recorded obligation. Only the USDC fee total moves,
    // because notifyFees takes a single amount and collect pays USDC — which asset a fee
    // arrives in becomes expressible only once FEAT-TOGR changes that signature.
    function test_when_fees_are_notified_then_the_usdc_fee_total_rises() public {
        _mintInRangeWithFees(300);

        _assertFeeTotalsUsdcOnly(300, "the notified fees are now owed to LPs");
    }

    // FR-9BRA: the fee total accumulates across notifications rather than recording only
    // the most recent one.
    function test_when_fees_are_notified_twice_then_the_fee_total_accumulates() public {
        _mintInRangeWithFees(300);

        mockUsdc.mint(address(vault), 450);
        vm.prank(operatorAddr);
        vault.notifyFees(450);

        _assertFeeTotalsUsdcOnly(750, "300 from the first notification plus 450 from the second");
    }

    // FR-9BRB: a collect discharges the fee obligation by what it actually transferred,
    // not by what was notified. With one LP holding all the active liquidity, the collect
    // recovers the whole notification apart from Q128 truncation dust.
    function test_when_a_position_collects_then_the_fee_total_falls_by_what_was_paid() public {
        uint256 positionId = _mintInRangeWithFees(300);

        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.collect(positionId);

        uint256 paid = mockUsdc.balanceOf(lp) - lpBalanceBefore;
        assertGt(paid, 0, "the collect paid something");
        _assertFeeTotalsUsdcOnly(300 - paid, "the total fell by exactly what the LP received");
    }

    // FR-9BRC: a burn pays principal and accrued fees in one call, so it must discharge
    // both obligations in that same call — no separate collect is needed to retire the
    // fee side.
    function test_when_a_position_is_burned_then_the_fee_total_falls_with_the_principal() public {
        uint256 positionId = _mintInRangeWithFees(300);
        _assertFeeTotalsUsdcOnly(300, "precondition: fees are owed");
        _assertPrincipal(200, 400, 400, "precondition: principal is owed");

        // The vault must hold the outcome tokens it owes before it can pay them out.
        mockCt.mint(address(vault), yesTokenId, 400);
        mockCt.mint(address(vault), noTokenId, 400);

        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(positionId);

        // The burn pays principal and fees in ONE USDC transfer, so the two legs have to
        // be separated to prove each ledger side was charged its own. Asserting only that
        // the fee total "fell" would pass if the principal leg were charged against the
        // fee ledger too, or if the two quantities were swapped — and the saturating floor
        // would hide the over-debit rather than reverting.
        uint256 usdcPaid = mockUsdc.balanceOf(lp) - lpBalanceBefore;
        uint256 feesPaid = usdcPaid - 200;

        _assertPrincipal(0, 0, 0, "the burn discharged the principal");
        _assertFeeTotalsUsdcOnly(300 - feesPaid, "the fee total fell by the fees paid, not by the principal leg too");
    }

    // FR-9BRA, FR-9BRB: each notification strands exactly one unit of Q128 truncation
    // dust, and repeated cycles accumulate it rather than compounding it.
    //
    // Both residues are pinned as absolute values, deliberately. Comparing the second
    // against the first would only assert linearity — and because both cycles are
    // identical, the residue after N cycles is N × (300 − debited) for ANY constant
    // debit, so every constant-offset bug satisfies a relative comparison. The
    // over-discharge case is worse still: the saturating floor collapses both readings
    // to zero, and 0 == 0 × 2 confirms nothing at all.
    //
    // Arithmetic: feeGrowth = floor(300·2^128 / 1e19) per notification, and the single
    // holder reclaims floor(feeGrowth · 1e19 / 2^128) = 299 of the 300. Both boundary
    // ticks carry feeGrowthOutsideX128 = 0 with currentTick inside the range, so the
    // second cycle sees exactly one more feeGrowth delta and reclaims 299 again.
    function test_when_notify_and_collect_repeats_then_dust_accrues_once_per_notification() public {
        uint256 positionId = _mintInRangeWithFees(300);

        vm.prank(lp);
        vault.collect(positionId);

        assertEq(vault.totalFeesUsdcOwed(), 1, "one cycle strands one unit of truncation dust");

        mockUsdc.mint(address(vault), 300);
        vm.prank(operatorAddr);
        vault.notifyFees(300);

        vm.prank(lp);
        vault.collect(positionId);

        assertEq(vault.totalFeesUsdcOwed(), 2, "two cycles strand two: the dust accumulates, it does not compound");
    }

    // FR-9BRA, FR-9BRB: the residue left after every LP has collected is Q128 truncation
    // dust and nothing more. That dust is genuinely still in the vault — notifyFees
    // required the Operator to deposit the full amount — so the balance and the total
    // retain it together and the ratio T-006 computes from them stays accurate. The
    // residue erring high is the conservative direction.
    function test_when_notified_fees_are_fully_collected_then_only_dust_remains() public {
        uint256 positionId = _mintInRangeWithFees(300);

        vm.prank(lp);
        vault.collect(positionId);

        // 300 USDC spread across 10e18 liquidity via mulDiv(amount, 2^128, liquidity)
        // loses at most one unit to downward truncation for the single holder.
        assertLe(vault.totalFeesUsdcOwed(), 1, "at most one unit of dust survives a full collect");
        assertLe(mockUsdc.balanceOf(address(vault)) - 600, 1, "and the vault still holds that dust");
    }
}

// ──────────────────────────────────────────────
// SC-9BS4: Reclaim refund lowers totalEscrowed
// ──────────────────────────────────────────────
contract ReclaimObligationTest is SolvencyLedgerTestBase {
    // SC-9BS4, FR-9BRF: the refund discharges the obligation by exactly what was
    // paid out, and the USDC leaves the vault alongside it.
    function test_when_an_escrow_is_reclaimed_then_total_escrowed_falls_by_the_refund() public {
        _escrowCanonical();

        // Phase 1 submits the reclaim and starts the timelock.
        vm.prank(lp);
        vault.reclaimDeposit(
            lp,
            tickLower,
            tickUpper,
            usdcAmount,
            intentId,
            _signIntent(MINT_INTENT_TYPEHASH, LP_PK, lp, usdcAmount, intentId)
        );

        vm.warp(block.timestamp + 24 hours + 1);

        // Phase 2 executes the refund.
        vm.prank(lp);
        vault.reclaimDeposit(
            lp,
            tickLower,
            tickUpper,
            usdcAmount,
            intentId,
            _signIntent(MINT_INTENT_TYPEHASH, LP_PK, lp, usdcAmount, intentId)
        );

        assertEq(vault.totalEscrowed(), 0, "the refunded escrow is no longer owed");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the USDC left the vault with the obligation");
    }

    // SC-9BS4, FR-9BRF: Phase 1 records a timestamp and returns without moving
    // money, so the obligation must survive it. A decrement placed in the shared
    // prologue rather than in Phase 2 would discharge the obligation while the
    // USDC is still sitting in the vault — understating what the vault owes for
    // the whole 24-hour timelock.
    function test_when_a_reclaim_is_only_submitted_then_total_escrowed_is_unchanged() public {
        _escrowCanonical();

        vm.prank(lp);
        vault.reclaimDeposit(
            lp,
            tickLower,
            tickUpper,
            usdcAmount,
            intentId,
            _signIntent(MINT_INTENT_TYPEHASH, LP_PK, lp, usdcAmount, intentId)
        );

        assertEq(vault.totalEscrowed(), 600, "Phase 1 moves no money, so the obligation stands");
        assertEq(mockUsdc.balanceOf(address(vault)), 600, "the USDC is still held");
    }

    // SC-9BS4, FR-9BRF: the Operator-relayed twin discharges the obligation
    // identically. Both reclaim paths pay the same refund, so both must decrement.
    function test_when_a_reclaim_is_relayed_by_the_operator_then_total_escrowed_falls() public {
        _escrowCanonical();

        bytes memory reclaimSig = _signIntent(RECLAIM_INTENT_TYPEHASH, LP_PK, lp, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        assertEq(vault.totalEscrowed(), 0, "the relayed refund discharges the obligation too");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the USDC went to the LP, not the relaying Operator");
    }
}

// ──────────────────────────────────────────────
// SC-9BS5: Emergency cancellation discharges every total it pays out
// SC-9BS6: Merge leaves every total unchanged
// ──────────────────────────────────────────────
contract TerminalAndHousekeepingTest is SolvencyLedgerTestBase {
    // SC-9BS5, FR-9BRG: an emergency cancellation pays out every live position's principal
    // and fees and enters the terminal state, so no total may be left claiming an
    // obligation it discharged. Without this the ledger reports a fully-drained vault as
    // still owing everything, and every ratio then reads as a total shortfall against an
    // empty balance — a drained vault made to look insolvent by its own bookkeeping.
    function test_when_the_vault_is_emergency_cancelled_then_discharged_totals_clear() public {
        uint256 positionId = _mintInRangeWithFees(300);
        _assertPrincipal(200, 400, 400, "precondition: principal is owed");
        _assertFeeTotalsUsdcOnly(300, "precondition: fees are owed");

        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);
        assertEq(mockUsdc.balanceOf(address(vault)), 900, "precondition: 600 principal plus 300 notified fees");

        // Wait out the operator-silence timelock, then let the position holder cancel.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(lp);
        vault.emergencyCancelAll();

        // Clearing the totals outright is only defensible BECAUSE the loop paid everything
        // out, so the payout has to be asserted here or the test cannot tell "cleared
        // because discharged" from "cleared regardless" — a cancellation that transferred
        // nothing at all would satisfy every other assertion below.
        //
        // This path reconstructs principal across the full range width and pays it all in
        // USDC: 10e18 liquidity × 60 ticks / 1e18 = 600, plus 299 of the 300 notified fees
        // after Q128 truncation, so the LP receives 899 and one unit of dust stays behind.
        assertEq(mockUsdc.balanceOf(lp) - lpBalanceBefore, 899, "the LP was paid principal plus accrued fees");
        assertEq(mockUsdc.balanceOf(address(vault)), 1, "the vault kept only the unclaimable fee dust");

        _assertPrincipal(0, 0, 0, "no principal survives a cancellation that paid it out");
        _assertFeeTotalsUsdcOnly(0, "no fee entitlement survives it either");
        assertEq(vault.phase(), 3, "the vault is in its terminal state");

        // The position was consumed, so nothing can claim against it again.
        (,,, uint128 liq,,) = vault.positions(positionId);
        assertEq(liq, 0, "the position holds no liquidity after cancellation");
    }

    // SC-9BS5, FR-9BRG: escrow is the one obligation a cancellation does NOT discharge.
    // emergencyCancelAll never touches pendingDeposits, and reclaimDeposit reverts
    // VaultCancelled once phase == 3, so an escrowed-but-unminted deposit is stranded with
    // no path out. totalEscrowed must keep reporting it — that is the ledger doing its job,
    // surfacing an obligation the vault cannot settle rather than quietly forgiving it.
    function test_when_the_vault_is_cancelled_then_unminted_escrow_is_still_reported_owed() public {
        _mintInRangeWithFees(300);

        // A second LP funds an intent that never gets minted.
        bytes32 strandedId = keccak256("ledger-intent-2");
        _escrow(LP_TWO_PK, lpTwo, 900, strandedId);
        assertEq(vault.totalEscrowed(), 900, "precondition: the second LP's deposit is escrowed");

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(lp);
        vault.emergencyCancelAll();

        assertEq(vault.totalEscrowed(), 900, "the cancellation paid no escrow refund, so it still stands");

        // Confirm the stranding is real rather than assumed: the escrow's own depositor
        // cannot recover it once the vault is cancelled.
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vm.prank(lpTwo);
        vault.reclaimDeposit(
            lpTwo,
            tickLower,
            tickUpper,
            900,
            strandedId,
            _signIntent(MINT_INTENT_TYPEHASH, LP_TWO_PK, lpTwo, 900, strandedId)
        );
    }

    // SC-9BS6, FR-9BRH: a merge preserves total liquidity and the tick range and moves no
    // assets — uncollected fees roll into the survivor's record rather than being paid — so
    // the vault's obligations are unchanged in both composition and amount.
    //
    // Asserted explicitly because "a position disappeared, so the ledger must move" is
    // exactly the wrong inference a later change would make. This test is what stops it.
    function test_when_positions_are_merged_then_every_total_is_unchanged() public {
        // Two positions, same owner and same range, so they are mergeable.
        uint256 first = _mintOver(LP_PK, lp, int24(-40), int24(20), usdcAmount, intentId);
        uint256 second = _mintOver(LP_PK, lp, int24(-40), int24(20), 900, keccak256("ledger-intent-2"));

        mockUsdc.mint(address(vault), 300);
        vm.prank(operatorAddr);
        vault.notifyFees(300);

        // Pin the Given state to its computed values rather than only to itself, so this
        // test stays meaningful if the mint-credit path ever regresses toward zero.
        // 600 USDC gives liquidity 10e18 and 900 gives 15e18, both over [-40, 20) at tick
        // 0: USDC legs 200 + 300 = 500, outcome legs 400 + 600 = 1000 on each side.
        _assertPrincipal(500, 1000, 1000, "precondition: both positions' principal is owed");
        _assertFeeTotalsUsdcOnly(300, "precondition: the notified fees are owed");
        assertEq(vault.totalEscrowed(), 0, "precondition: both intents were consumed by their mints");

        uint256 usdcOwedBefore = vault.totalUsdcOwed();
        uint256 yesOwedBefore = vault.totalYesOwed();
        uint256 noOwedBefore = vault.totalNoOwed();
        uint256 feesBefore = vault.totalFeesUsdcOwed();
        uint256 escrowedBefore = vault.totalEscrowed();

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        assertEq(vault.totalUsdcOwed(), usdcOwedBefore, "merge moves no USDC principal");
        assertEq(vault.totalYesOwed(), yesOwedBefore, "merge moves no YES principal");
        assertEq(vault.totalNoOwed(), noOwedBefore, "merge moves no NO principal");
        assertEq(vault.totalEscrowed(), escrowedBefore, "merge touches no escrow");
        _assertFeeTotalsUsdcOnly(feesBefore, "merge pays no fees, it rolls them into the survivor");

        // The merge really did happen — otherwise every assertion above is vacuous.
        (,,, uint128 survivorLiq,,) = vault.positions(first);
        (,,, uint128 consumedLiq,,) = vault.positions(second);
        assertEq(consumedLiq, 0, "the consumed position was emptied");
        assertEq(survivorLiq, 25e18, "and its liquidity moved to the survivor");
    }

    // SC-9BS6, NFR-9BRX: the merge tolerance, pinned at both bounds.
    //
    // A position's principal is never stored — it is reconstructed from its truncated
    // `liquidity`. Merging collapses N of those downward truncations into one, so the
    // survivor's reconstructed claim can exceed the credits recorded for the positions it
    // consumed, while FR-9BRH (correctly) forbids the merge from writing the ledger.
    //
    // The fixture must NOT divide evenly by the range width or the effect is invisible:
    // the sibling merge test above uses 600 and 900 over 60 ticks, both exact. Here two
    // 100-USDC positions over [-40, 20) each give liquidity 100·1e18/60 =
    // 1666666666666666666, crediting 33 USDC and 66 of each outcome token; the merged
    // survivor holds 3333333333333333332 and claims 66 and 133 — one unit per outcome leg
    // the ledger was never told about.
    //
    // The bystander is load-bearing twice over: a 100-USDC position yields ~1.67e18
    // liquidity, below minimumFirstLiquidity (10e18), so it cannot be the vault's first
    // mint; and its own claim is what the drift ends up understating.
    function test_when_a_merged_position_is_burned_then_the_totals_understate_by_one_unit_per_leg() public {
        _seedToleranceFixture();

        uint256 firstSmall = 1;
        uint256 secondSmall = 2;

        uint256[] memory ids = new uint256[](2);
        ids[0] = firstSmall;
        ids[1] = secondSmall;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        // FR-9BRH holds: the merge itself moved nothing.
        _assertPrincipal(2066, 4132, 4132, "the merge left every total untouched");

        // The survivor now claims 133 of each outcome token against 132 ever credited.
        mockCt.mint(address(vault), yesTokenId, 133);
        mockCt.mint(address(vault), noTokenId, 133);

        vm.prank(lp);
        vault.burnPosition(firstSmall);

        assertEq(mockCt.balanceOf(yesTokenId, lp), 133, "the survivor was paid the floor-of-the-sum claim");
        assertEq(mockCt.balanceOf(noTokenId, lp), 133, "on both outcome legs");

        // Only the bystander's claim remains. Its true obligation is 2000 / 4000 / 4000;
        // the outcome legs read one short. Pinned as exact values rather than as an upper
        // bound so the test fails if the drift ever widens AND if it silently disappears —
        // an inequality would keep passing in the second case and stop describing the
        // convention this test exists to document.
        _assertPrincipal(2000, 3999, 3999, "one base unit understated per outcome leg, per position merged away");
    }

    // SC-9BS6, NFR-9BRX: the control. Identical positions, identical burns, no merge —
    // the totals land exactly on the bystander's true claim. This is what isolates the
    // discrepancy above to the merge rather than to the reconstruction generally, and it
    // is what makes "one unit" a measurement instead of an assumption.
    function test_when_the_same_positions_are_burned_without_merging_then_the_totals_are_exact() public {
        _seedToleranceFixture();

        // Each unmerged position claims exactly what it was credited: 33 and 66.
        mockCt.mint(address(vault), yesTokenId, 132);
        mockCt.mint(address(vault), noTokenId, 132);

        vm.prank(lp);
        vault.burnPosition(1);
        vm.prank(lp);
        vault.burnPosition(2);

        _assertPrincipal(2000, 4000, 4000, "burned separately, the totals match the bystander's true claim");
    }

    /// @dev Bystander (6000 USDC, minted first to clear minimumFirstLiquidity) plus two
    ///      100-USDC positions owned by `lp` over the same range, so the pair is mergeable.
    ///      Leaves the ledger at 2066 / 4132 / 4132 with position ids 0, 1, 2.
    function _seedToleranceFixture() internal {
        _mintOver(LP_TWO_PK, lpTwo, int24(-40), int24(20), 6000, keccak256("bystander"));
        _mintOver(LP_PK, lp, int24(-40), int24(20), 100, keccak256("small-a"));
        _mintOver(LP_PK, lp, int24(-40), int24(20), 100, keccak256("small-b"));

        _assertPrincipal(2066, 4132, 4132, "precondition: 2000/4000 bystander plus 33/66 twice");
    }
}
