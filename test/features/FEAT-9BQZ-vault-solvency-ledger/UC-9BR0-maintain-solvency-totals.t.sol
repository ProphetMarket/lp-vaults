// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR0: Maintain Solvency Totals
// Integration tests for every scenario in this use case.
// Covers: SC-9BRZ, SC-9BS0, SC-9BS6, SC-9BS7, SC-COEO, SC-COEP

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for the ledger scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, reports tick 6000,
// and mints the worked example of decision C26 on demand: 300 USDC over [5500, 6500), so
// liquidity = 3e23 and mintTick = 6000. The scaled units: USDC in units x 1e22, tokens in
// units x 1e18. USDC and every outcome token have six decimals.
// ──────────────────────────────────────────────
contract SolvencyLedgerTestBase is LPVaultFixture {
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
    uint128 constant LIQUIDITY = 3e23;
    uint256 constant USDC_SCALE = 1e22;
    uint256 constant TOKEN_SCALE = 1e18;

    // The claim at 5700: the YES band [5700, 6000), 90 YES, and the USDC the band did not spend
    uint256 constant FELL_USDC = 247_354_500;
    uint256 constant BAND_TOKENS = 90e6;
    // The same claim in the scaled units
    uint256 constant MINT_USDC_SCALED = uint256(LIQUIDITY) * 1000 * 10_000;
    uint256 constant FELL_USDC_SCALED = uint256(LIQUIDITY) * 8_245_150;
    uint256 constant FELL_YES_SCALED = uint256(LIQUIDITY) * 300;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 usdcPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );
    event PositionsMerged(uint256[] positionIds, uint256 survivorId);
    event EmergencyCancelExecuted(address indexed caller);

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
    }

    /// @dev Mints the worked example for the owner key `pk`.
    function _mintExample(bytes32 intentId) internal returns (uint256) {
        return _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, UPPER, PRINCIPAL, intentId);
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    function _burn(uint256 id) internal {
        vm.prank(safe);
        vault.burnPosition(id);
    }

    /// @dev Gives the vault outcome tokens, as the keeper's fills would.
    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    /// @dev The three scaled totals, read in one place.
    function _scaledTotals() internal view returns (uint256 usdc, uint256 yes, uint256 no) {
        usdc = vault.totalUsdcOwedScaled();
        yes = vault.totalYesOwedScaled();
        no = vault.totalNoOwedScaled();
    }

    function _assertPrincipalTotalsZero() internal view {
        assertEq(vault.totalUsdcOwedScaled(), 0, "the USDC total must be zero");
        assertEq(vault.totalYesOwedScaled(), 0, "the YES total must be zero");
        assertEq(vault.totalNoOwedScaled(), 0, "the NO total must be zero");
    }
}

// ──────────────────────────────────────────────
// SC-9BRZ: Mint credits the USDC total by the whole deposit
// What: A mint of 300 USDC over [5500, 6500) at 6000 raises the USDC total by 3e23 x 1000 x
//       10000 and nothing else, and the in-range position enters on the NO side.
// Why:  The clamped mint tick leaves the band empty at the mint (FR-9BR8), so a mint's claim
//       is USDC only, and the scaled unit is the claim before its division (FR-9BR4).
// ──────────────────────────────────────────────
contract LedgerMintCreditTest is SolvencyLedgerTestBase {
    // SC-9BRZ: the USDC total rises by the whole deposit, in the scaled unit
    function test_whenMintedThenUsdcTotalHoldsTheWholeDeposit() public {
        _mintExample(keccak256("a"));

        assertEq(vault.totalUsdcOwedScaled(), MINT_USDC_SCALED, "the scaled USDC total");
        assertEq(vault.totalUsdcOwed(), PRINCIPAL, "the truncated USDC total");
    }

    // SC-9BRZ: no token total moves
    function test_whenMintedThenTokenTotalsStayZero() public {
        _mintExample(keccak256("a"));

        assertEq(vault.totalYesOwed(), 0, "no YES at the mint");
        assertEq(vault.totalNoOwed(), 0, "no NO at the mint");
    }

    // SC-9BRZ: an in-range mint enters on the NO side
    function test_whenMintedInRangeThenNoSideLiquidityRises() public {
        _mintExample(keccak256("a"));

        assertEq(vault.noSideLiquidity(), LIQUIDITY, "mintTick == currentTick puts the position on the NO side");
    }
}

// ──────────────────────────────────────────────
// SC-9BS0: Burn debits the totals by the claim at the current tick
// What: With the vault at 5700 the burn lowers the USDC total by the scaled 247.3545 USDC and
//       the YES total by the scaled 90 YES, exactly what PositionBurned reports as owed.
// Why:  The debit is the claim at burn time, computed once from the same _claim the payout
//       truncates (FR-9BR9).
// ──────────────────────────────────────────────
contract LedgerBurnDebitTest is SolvencyLedgerTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        assertEq(vault.totalUsdcOwed(), FELL_USDC, "precondition: the USDC total after the move");
        assertEq(vault.totalYesOwed(), BAND_TOKENS, "precondition: the YES total after the move");
    }

    // SC-9BS0: the totals fall by the claim the event reports
    function test_whenBurnedThenTotalsFallByTheOwedAmounts() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);
        _burn(positionId);

        _assertPrincipalTotalsZero();
    }

    // SC-9BS0: the scaled debit is the scaled claim
    function test_whenBurnedThenScaledTotalsFallByTheScaledClaim() public {
        (uint256 usdcBefore, uint256 yesBefore,) = _scaledTotals();
        assertEq(usdcBefore, FELL_USDC_SCALED, "precondition: the scaled USDC total");
        assertEq(yesBefore, FELL_YES_SCALED, "precondition: the scaled YES total");

        _burn(positionId);

        assertEq(usdcBefore - vault.totalUsdcOwedScaled(), FELL_USDC_SCALED, "the USDC debit");
        assertEq(yesBefore - vault.totalYesOwedScaled(), FELL_YES_SCALED, "the YES debit");
    }

    // SC-9BS0: a position on the YES side of its mint tick leaves noSideLiquidity alone
    function test_whenBurnedOnTheYesSideThenNoSideLiquidityIsUnchanged() public {
        assertEq(vault.noSideLiquidity(), 0, "precondition: the move to 5700 crossed the mint tick");
        _burn(positionId);
        assertEq(vault.noSideLiquidity(), 0, "nothing on the NO side to remove");
    }
}

// ──────────────────────────────────────────────
// SC-9BS6: A merge leaves every total unchanged
// What: Two positions of the same Safe over the same range and mint tick, 300 and 200 USDC;
//       the merge sums the liquidity into the survivor and writes no total.
// Why:  FR-9BRH: the claim is linear in liquidity and both positions share the range and the
//       mint tick, so the principal is conserved without a write.
// ──────────────────────────────────────────────
contract LedgerMergeTest is SolvencyLedgerTestBase {
    uint256 survivor;
    uint256 consumed;

    function setUp() public override {
        super.setUp();
        survivor = _mintExample(keccak256("a"));
        consumed = _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, UPPER, 200e6, keccak256("b"));
    }

    function _merge() internal returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = survivor;
        ids[1] = consumed;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);
    }

    // SC-9BS6: the three totals read identically before and after
    function test_whenMergedThenNoTotalIsWritten() public {
        (uint256 usdcBefore, uint256 yesBefore, uint256 noBefore) = _scaledTotals();

        uint256[] memory ids = _merge();

        (uint256 usdcAfter, uint256 yesAfter, uint256 noAfter) = _scaledTotals();
        assertEq(usdcAfter, usdcBefore, "USDC total");
        assertEq(yesAfter, yesBefore, "YES total");
        assertEq(noAfter, noBefore, "NO total");
        assertEq(ids[0], survivor, "the first id survives");
    }
}

// ──────────────────────────────────────────────
// SC-9BS7: Opposing bands are reported separately, never netted
// What: A position minted at 6000 holds YES after a fall to 5700, and a position minted at
//       5500 (the Operator reported 5000 before it) holds NO at 5700; the two totals read 90
//       and 60 in full.
// Why:  FR-9BR5: a signed net would cancel the two and hide that the vault can pay neither.
// ──────────────────────────────────────────────
contract LedgerOpposingBandsTest is SolvencyLedgerTestBase {
    function setUp() public override {
        super.setUp();
        // Position B is minted below its range, so its mint tick clamps to 5500
        _moveTick(5000);
        _mintExample(keccak256("b"));
        // Position A is minted at 6000
        _moveTick(MINT_TICK);
        _mintExample(keccak256("a"));
        _moveTick(5700);
    }

    // SC-9BS7: each total reports its own band
    function test_whenBandsOpposeThenEachTotalReportsItsOwn() public view {
        assertEq(vault.totalYesOwed(), BAND_TOKENS, "A's YES band [5700, 6000)");
        assertEq(vault.totalNoOwed(), 60e6, "B's NO band [5500, 5700)");
        assertEq(vault.totalUsdcOwed(), FELL_USDC + 273_597_000, "the two USDC claims");
    }
}

// ──────────────────────────────────────────────
// SC-COEO: A mint and its burn cancel exactly with a deposit that does not divide by the width
// What: 123,456,789 units over 1,000 ticks, two moves, and a burn leave every scaled total at
//       zero, exactly.
// Why:  FR-9BR4: a ledger held in truncated units would drift by up to one unit per booking.
// ──────────────────────────────────────────────
contract LedgerExactCancelTest is SolvencyLedgerTestBase {
    // SC-COEO: the scaled totals return to their start
    function test_whenMintedMovedAndBurnedThenScaledTotalsReturnToZero() public {
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, UPPER, 123_456_789, keccak256("odd"));

        _moveTick(5713);
        assertTrue(vault.totalUsdcOwedScaled() % USDC_SCALE != 0, "precondition: the scaled total is not a whole unit");
        _moveTick(6120);
        _burn(id);

        _assertPrincipalTotalsZero();
    }
}

// ──────────────────────────────────────────────
// SC-COEP: The freeze leaves every total unchanged
// What: After the Operator's silence, any address freezes the vault; the three scaled totals
//       and noSideLiquidity read as before, and a burn afterwards debits them as in Active.
// Why:  FEAT-JXQO FR-JXQP: the freeze writes phase and nothing else (decision C9).
// ──────────────────────────────────────────────
contract LedgerFreezeTest is SolvencyLedgerTestBase {
    uint256 positionA;

    function setUp() public override {
        super.setUp();
        // B sits out of range at 6000 with a NO band; A is in range on the NO side
        _moveTick(5800);
        _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, MINT_TICK, PRINCIPAL, keccak256("b"));
        _moveTick(MINT_TICK);
        positionA = _mintExample(keccak256("a"));
    }

    function _freeze() internal {
        vm.warp(block.timestamp + vault.emergencyCancelTimelock());
        vm.expectEmit(true, false, false, true, address(vault));
        emit EmergencyCancelExecuted(address(0xF00D));
        vm.prank(address(0xF00D));
        vault.emergencyCancelAll();
    }

    // SC-COEP: no total and no counter moves
    function test_whenFrozenThenTotalsAndNoSideLiquidityAreUnchanged() public {
        (uint256 usdcBefore, uint256 yesBefore, uint256 noBefore) = _scaledTotals();
        uint128 noSideBefore = vault.noSideLiquidity();
        assertTrue(usdcBefore > 0 && noBefore > 0 && noSideBefore > 0, "precondition: nonzero state");

        _freeze();

        (uint256 usdcAfter, uint256 yesAfter, uint256 noAfter) = _scaledTotals();
        assertEq(vault.phase(), 3, "frozen");
        assertEq(usdcAfter, usdcBefore, "USDC total");
        assertEq(yesAfter, yesBefore, "YES total");
        assertEq(noAfter, noBefore, "NO total");
        assertEq(vault.noSideLiquidity(), noSideBefore, "noSideLiquidity");
    }

    // SC-COEP: a burn after the freeze debits the totals as in Active
    function test_whenFrozenThenBurnDebitsTheTotals() public {
        _freeze();
        uint256 usdcBefore = vault.totalUsdcOwedScaled();

        _burn(positionA);

        assertEq(usdcBefore - vault.totalUsdcOwedScaled(), MINT_USDC_SCALED, "A's claim at its mint tick");
        assertEq(vault.noSideLiquidity(), 0, "A left the NO side");
    }
}
