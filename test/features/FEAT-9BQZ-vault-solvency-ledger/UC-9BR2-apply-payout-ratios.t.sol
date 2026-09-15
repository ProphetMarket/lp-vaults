// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR2: Apply Payout Ratios
// Integration tests for every scenario in this use case.
// Covers: SC-9BSC, SC-9BSD, SC-9BSE, SC-9BSF, SC-9BSG, SC-COEU, SC-CYSB, SC-CYSC, SC-DFDY

import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {KeeperFillFixture} from "../../fixtures/KeeperFillFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for the ratio scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, reports tick 6000,
// and mints the worked example of decision C26 on demand: 300 USDC over [5500, 6500), so
// liquidity = 3e23 and mintTick = 6000. A shortfall is made the way a fill makes one: the
// exchange's standing approval moves USDC out of the vault, and the token legs are funded
// short. USDC and every outcome token have six decimals.
// ──────────────────────────────────────────────
contract PayoutRatioTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address safe;
    uint256 constant LP_B_PK = 0xB0B;
    address safeB;

    int24 constant LOWER = 5500;
    int24 constant UPPER = 6500;
    int24 constant MINT_TICK = 6000;
    uint256 constant PRINCIPAL = 300e6;
    uint128 constant LIQUIDITY = 3e23;

    // The claim at 5700 (SC-7G44): 90 YES and the USDC the band did not spend
    uint256 constant FELL_USDC = 247_354_500;
    uint256 constant BAND_TOKENS = 90e6;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 usdcPaid,
        uint256 spreadOwed,
        uint256 spreadPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );
    event OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount);
    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    function setUp() public virtual {
        safe = _safeOf(vm.addr(LP_PK));
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));

        _moveTick(MINT_TICK);
    }

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

    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    /// @dev Moves USDC out of the vault through the exchange's standing approval, as a fill
    ///      would (decision C8). This is how a test makes the vault short of USDC.
    function _drainThroughExchange(uint256 amount) internal {
        vm.prank(exchangeAddr);
        assertTrue(mockUsdc.transferFrom(address(vault), exchangeAddr, amount), "the fill should spend");
    }

    /// @dev Drains the vault to exactly `held` USDC above escrow.
    function _drainTo(uint256 held) internal {
        _drainThroughExchange(mockUsdc.balanceOf(address(vault)) - vault.totalEscrowed() - held);
    }

    function _yesOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.yesTokenId());
    }

    /// @dev Expects the burn's event with the given paid amounts, the owed ones being the
    ///      SC-7G44 claim.
    function _expectFellBurn(uint256 id, uint256 usdcPaid, uint256 yesPaid) internal {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(id, safe, FELL_USDC, usdcPaid, 0, 0, vault.yesTokenId(), BAND_TOKENS, yesPaid);
    }

    /// @dev Reports the result, winds the vault down, and has the Oracle redeem: the switch
    ///      (FEAT-6HBN UC-6HBP). The question ID of the vault's condition is the market ID.
    function _resolveAndRedeem(uint256 yesNumerator, uint256 noNumerator) internal {
        _resolve(bytes32(uint256(1)), _payouts(yesNumerator, noNumerator));
        vm.prank(oracleAddr);
        vault.startWindDown();
        vm.prank(oracleAddr);
        vault.redeemOutcomeTokens();
    }

    /// @dev Counts the logs of one event selector from one emitter in a recorded window.
    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == selector) n++;
        }
    }

    /// @dev The one PositionBurned log's usdcPaid + spreadPaid + tokenPaid, the USDC a resolved
    ///      burn sent in its single transfer (FR-CYS4, with the spread leg since R18).
    function _paidSum(Vm.Log[] memory logs) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != PositionBurned.selector) continue;
            (, uint256 usdcPaid,, uint256 spreadPaid,,, uint256 tokenPaid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            return usdcPaid + spreadPaid + tokenPaid;
        }
        revert("no PositionBurned log");
    }
}

// ──────────────────────────────────────────────
// SC-CYSB: Three burns after the switch receive the same ratio
// What: Three positions of the worked example at 5700 (742,063,500 USDC units and 270 YES
//       owed), the vault holding 270 YES and its USDC drained to half of what it owes
//       (371,031,750), the result [1, 0] reported and redeemed. held = 371,031,750 +
//       270,000,000 = 641,031,750 and owed = 742,063,500 + 270,000,000 = 1,012,063,500, so
//       each burn pays floor(337,354,500 x 641,031,750 / 1,012,063,500) = 213,677,250 in one
//       transfer, and the third leaves the vault at totalEscrowed.
// Why:  After the switch every asset is USDC, and one pooled ratio is what pro-rata means
//       (FR-CYS5, ADR-9BSH). The ratio stays the same because every burn debits the full
//       owed amount.
// ──────────────────────────────────────────────
contract ThreeBurnsAfterSwitchTest is PayoutRatioTestBase {
    uint256 a;
    uint256 b;
    uint256 c;
    uint256 constant EACH = 213_677_250;

    function setUp() public override {
        super.setUp();
        a = _mintExample(keccak256("a"));
        b = _mintExample(keccak256("b"));
        c = _mintExample(keccak256("c"));
        _moveTick(5700);
        _fundVault(270e6, 0);
        _drainTo(3 * FELL_USDC / 2);
        _resolveAndRedeem(1, 0);
        assertEq(mockUsdc.balanceOf(address(vault)), 641_031_750, "precondition: held after the redemption");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed(), 1_012_063_500, "precondition: the pooled owed total");
    }

    // SC-CYSB: each burn pays 213,677,250 in one transfer, the same ratio each time
    function test_whenShortOfUsdcAfterTheSwitchThenThreeBurnsPayTheSamePooledShare() public {
        vm.recordLogs();
        _burn(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_paidSum(logs), EACH, "first burn: the pooled share");
        assertEq(mockUsdc.balanceOf(safe), EACH, "one transfer of the pooled share");
        assertEq(_countLogs(logs, address(ctf), TransferSingle.selector), 0, "no token leg");
        assertEq(_countLogs(logs, address(vault), OutcomeTokensRedeemed.selector), 0, "the Oracle redeemed first");

        vm.recordLogs();
        _burn(b);
        assertEq(_paidSum(vm.getRecordedLogs()), EACH, "second burn: the same share");

        vm.recordLogs();
        _burn(c);
        assertEq(_paidSum(vm.getRecordedLogs()), EACH, "third burn: the same share");

        assertEq(mockUsdc.balanceOf(safe), 3 * EACH, "three equal shares");
        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "the vault holds the escrow total");
        assertEq(vault.totalUsdcOwed(), 0, "the USDC total is empty");
        assertEq(vault.totalYesOwed(), 0, "the YES total is empty");
    }

    // SC-CYSB: the two legs are one prorated sum, so usdcPaid + tokenPaid never exceeds held
    function test_theTwoLegsAreOneProratedSum() public {
        vm.recordLogs();
        _burn(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 usdcPaid;
        uint256 tokenPaid;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != PositionBurned.selector) continue;
            (, usdcPaid,,,,, tokenPaid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        }
        // floor(247,354,500 x 641,031,750 / 1,012,063,500) = 156,672,650; the token leg is the rest
        assertEq(usdcPaid, uint256(FELL_USDC) * 641_031_750 / 1_012_063_500, "usdcPaid is the prorated principal");
        assertEq(tokenPaid, EACH - usdcPaid, "tokenPaid is the rest of the prorated sum");
    }
}

// ──────────────────────────────────────────────
// SC-CYSC: A payout after the switch redeems late tokens first
// What: One position at 5700, the Oracle redeemed after [1, 0], then 5 YES and 5 NO arrive.
//       The burn redeems them for 5 USDC (OutcomeTokensRedeemed(safe, 5e6, 5e6, 5e6)), then
//       pays 337,354,500, and the vault keeps the 5 USDC and holds no token.
// Why:  The Oracle's call is a one-time switch, not a step the vault depends on for
//       solvency; every payout settles first (ADR-6HCK).
// ──────────────────────────────────────────────
contract LateTokensRedeemedByPayoutTest is PayoutRatioTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        // The USDC the band's fills spent, so the vault holds exactly the claim before the switch
        _drainThroughExchange(PRINCIPAL - FELL_USDC);
        _resolveAndRedeem(1, 0);
        _fundVault(5e6, 5e6);
    }

    // SC-CYSC: the redemption event, then the burn. Since R18 the late tokens' USDC is above
    // what the ledger owes, so the burn's own credit attributes it to the only liquidity in range
    // and the Safe receives it as a spread leg (FEAT-E943 FR-E945). The growth floor drops one
    // unit, which the closing sweep pays back in the same burn.
    function test_burnRedeemsTheLateTokensFirst() public {
        uint256 credited = 5e6 - 1;

        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(safe, 5e6, 5e6, 5e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(
            positionId, safe, FELL_USDC, FELL_USDC, credited, credited, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS
        );

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + BAND_TOKENS + 5e6, "the claim plus the late tokens' USDC");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault keeps nothing above escrow");
        assertEq(_yesOf(address(vault)), 0, "no YES left");
        assertEq(ctf.balanceOf(address(vault), vault.noTokenId()), 0, "no NO left");
        assertEq(_countLogs(logs, address(vault), CompleteSetsMerged.selector), 0, "no merge after the switch");
    }
}

// ──────────────────────────────────────────────
// SC-9BSC: A covered vault pays every claim in full
// What: The vault at 5700 holds 500 YES and 1,300 USDC against one claim of 247.3545 USDC
//       plus 90 YES; both ratios read 1 and the burn pays the whole claim, leaving the
//       surplus in the vault.
// Why:  FR-9BRP: a holding at or above the total is a ratio of exactly 1, and a surplus is
//       never a bonus.
// ──────────────────────────────────────────────
contract CoveredVaultTest is PayoutRatioTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _moveTick(5700);
        _fundVault(500e6, 0);
        mockUsdc.mint(address(vault), 1_000e6);
    }

    // The USDC the vault holds above what it owes, which the burn's own credit attributes to the
    // only liquidity in range. The growth is stored per unit of liquidity and floored, so the
    // position's claim reads one unit below the measurement; the closing sweep pays that unit
    // back in the same burn (FEAT-E943 FR-E946, FR-E94C).
    uint256 constant SURPLUS = 1_300e6 - FELL_USDC;
    uint256 constant CREDITED = SURPLUS - 1;

    // SC-9BSC: the whole claim, and the credited spread beside it
    function test_whenTheVaultCoversTheClaimThenTheBurnPaysInFull() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(
            positionId, safe, FELL_USDC, FELL_USDC, CREDITED, CREDITED, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS
        );
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 1_300e6, "the claim's USDC plus the credited spread");
        assertEq(_yesOf(safe), 500e6, "the claim's YES plus the swept residue");
    }

    // SC-9BSC: the surplus is attributed, not kept. It reaches this LP as owed spread, and the
    // closing sweep takes what the credit could not attribute, because this is the last live
    // position (FEAT-E943 FR-E94C). A surplus is still never a bonus through the ratio, which
    // stays capped at 1 (FR-9BRP).
    function test_whenTheVaultCoversTheClaimThenTheSurplusIsAttributed() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 swept;
        uint256 yesSwept;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ResidueSwept.selector) continue;
            (swept, yesSwept,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
        assertEq(swept, 1, "the sweep carries the one unit the growth floor dropped");
        assertEq(yesSwept, 500e6 - BAND_TOKENS, "the sweep carries the YES no claim was owed");

        assertEq(_yesOf(address(vault)), 0, "the vault keeps no YES");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault keeps nothing above escrow");
        assertEq(vault.totalUsdcOwedScaled(), 0, "the ledger settled the claim");
        assertEq(vault.totalYesOwedScaled(), 0, "the ledger settled the claim");
        assertEq(vault.totalSpreadOwedX128(), 0, "the ledger settled the spread");
    }

    event ResidueSwept(
        uint256 indexed positionId, address indexed owner, uint256 usdcResidue, uint256 yesResidue, uint256 noResidue
    );
}

// ──────────────────────────────────────────────
// SC-9BSD: Three burns in a row each receive the same ratio
// What: Three positions of the worked example, the vault at 5700, 270 YES owed and
//       742,063,500 USDC units owed. Case A: 150 YES held, every USDC held; each burn pays
//       50 YES (90 x 150 / 270) and its full USDC, and after the third the vault holds no
//       YES and owes none. Case B: 270 YES held, the USDC drained to half; each burn pays
//       123,677,250 USDC and all 90 YES, and after the third the USDC is exactly spent.
// Why:  FR-9BRR: every burn debits the full owed amount, so the ratio stays 5/9 (150/270,
//       then 100/180, then 50/90) and no burn gains by coming first.
// ──────────────────────────────────────────────
contract ThreeBurnsSameRatioTest is PayoutRatioTestBase {
    uint256 a;
    uint256 b;
    uint256 c;

    function setUp() public override {
        super.setUp();
        a = _mintExample(keccak256("a"));
        b = _mintExample(keccak256("b"));
        c = _mintExample(keccak256("c"));
        _moveTick(5700);
        assertEq(vault.totalYesOwed(), 270e6, "precondition: 270 YES owed");
        assertEq(vault.totalUsdcOwed(), 3 * FELL_USDC, "precondition: 742.0635 USDC owed");
    }

    // SC-9BSD: case A — short of YES, each burn pays 5/9 of its band
    function test_whenShortOfYesThenThreeBurnsPayTheSameShare() public {
        _fundVault(150e6, 0);
        // The fills that bought the 150 YES spent the USDC the three claims no longer name, so
        // the vault holds exactly what it owes and nothing is creditable as spread (FEAT-E943)
        _drainThroughExchange(3 * PRINCIPAL - 3 * FELL_USDC);

        _expectFellBurn(a, FELL_USDC, 50e6);
        _burn(a);
        assertEq(_yesOf(safe), 50e6, "first burn: 90 x 150 / 270");
        assertEq(vault.totalYesOwed(), 180e6, "debited by the full 90");
        assertEq(_yesOf(address(vault)), 100e6, "100 held against 180 owed, the same 5/9");

        _expectFellBurn(b, FELL_USDC, 50e6);
        _burn(b);
        assertEq(_yesOf(safe), 100e6, "second burn: the same 50");

        _expectFellBurn(c, FELL_USDC, 50e6);
        _burn(c);
        assertEq(_yesOf(safe), 150e6, "third burn: the same 50");
        assertEq(_yesOf(address(vault)), 0, "nothing left");
        assertEq(vault.totalYesOwed(), 0, "the ledger is empty");
        assertEq(mockUsdc.balanceOf(safe), 3 * FELL_USDC, "USDC was never short");
    }

    // SC-9BSD: case B — short of USDC by half, each burn pays half its USDC and all its YES
    function test_whenShortOfUsdcThenThreeBurnsPayTheSameShare() public {
        _fundVault(270e6, 0);
        uint256 owed = 3 * FELL_USDC;
        _drainTo(owed / 2);
        assertEq(vault.totalUsdcOwed(), owed, "precondition: the USDC total");

        _expectFellBurn(a, FELL_USDC / 2, BAND_TOKENS);
        _burn(a);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC / 2, "first burn: half");

        _expectFellBurn(b, FELL_USDC / 2, BAND_TOKENS);
        _burn(b);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "second burn: the same half");

        _expectFellBurn(c, FELL_USDC / 2, BAND_TOKENS);
        _burn(c);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + FELL_USDC / 2, "third burn: the same half");
        assertEq(_yesOf(safe), 270e6, "YES was never short");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the USDC is exactly spent");
        assertEq(vault.totalUsdcOwed(), 0, "the ledger is empty");
    }
}

// ──────────────────────────────────────────────
// SC-9BSE: Escrowed USDC never pays a burn
// What: Another Safe escrowed 500 USDC the Operator never minted, and the vault's balance was
//       drained below totalEscrowed; the burn of a USDC-only claim pays zero, does not revert,
//       settles the claim, and the later reclaim pays the recorded 500.
// Why:  Decision C7: escrowed USDC is senior, so it is neither in the numerator nor cut.
// ──────────────────────────────────────────────
contract EscrowSeniorTest is PayoutRatioTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _fundSafe(mockUsdc, safeB, address(vault), 500e6);
        _escrow(vault, operatorAddr, LP_B_PK, safeB, LOWER, UPPER, 500e6, keccak256("escrow-b"), FAR_DEADLINE);
        _drainThroughExchange(400e6);
        assertLt(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "precondition: below escrow");
    }

    // SC-9BSE: the burn pays zero USDC and settles
    function test_whenBelowEscrowThenTheBurnPaysZeroAndSettles() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, 0, 0, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 0, "nothing paid");
        assertEq(vault.totalUsdcOwed(), 0, "the claim settled");
        assertEq(vault.totalEscrowed(), 500e6, "the escrow is untouched");
    }

    // SC-9BSE: the reclaim pays the recorded amount, with no ratio
    function test_whenBelowEscrowThenTheReclaimPaysTheRecordedAmount() public {
        _burn(positionId);
        // The vault holds 400 USDC against the 500 escrowed; the burn took nothing
        mockUsdc.mint(address(vault), 100e6);

        vm.prank(safeB);
        vault.reclaimDeposit(keccak256("escrow-b"));

        assertEq(mockUsdc.balanceOf(safeB), 500e6, "the recorded 500 USDC, no ratio applied");
    }
}

// ──────────────────────────────────────────────
// SC-9BSF: A shortfall in one asset does not cut the others
// What: Two positions at 5700, 180 YES and 494,709,000 USDC units owed; the vault holds 90
//       YES and every USDC it owes. The first burn pays 45 YES and its full USDC.
// Why:  FR-9BRQ: the three ratios are independent.
// ──────────────────────────────────────────────
contract IndependentRatiosTest is PayoutRatioTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mintExample(keccak256("a"));
        _mintExample(keccak256("b"));
        _moveTick(5700);
        _fundVault(90e6, 0);
    }

    // SC-9BSF: only the YES leg is cut
    function test_whenShortOfYesOnlyThenOnlyTheYesLegIsCut() public {
        _expectFellBurn(a, FELL_USDC, 45e6);
        _burn(a);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "USDC in full");
        assertEq(_yesOf(safe), 45e6, "90 x 90 / 180");
    }
}

// ──────────────────────────────────────────────
// SC-9BSG: A position devalued by the price alone is paid in full
// What: The vault at 5700 holds exactly 90 YES and 247.3545 USDC above escrow; the burn pays
//       the whole claim although it is worth less than the 300 USDC deposited.
// Why:  ADR-9BSJ: the ledger owes token counts, so impermanent loss is not a shortfall.
// ──────────────────────────────────────────────
contract PriceOnlyDevaluationTest is PayoutRatioTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        _drainTo(FELL_USDC);
    }

    // SC-9BSG: both ratios read 1
    function test_whenOnlyThePriceMovedThenTheBurnPaysInFull() public {
        _expectFellBurn(positionId, FELL_USDC, BAND_TOKENS);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the whole USDC leg");
        assertEq(_yesOf(safe), BAND_TOKENS, "the whole YES leg");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault held exactly the claim");
    }
}

// ──────────────────────────────────────────────
// SC-COEU: A burn debits the full owed amount when it pays less
// What: The SC-BMF2 case: 200 USDC and 60 YES held against 247.3545 USDC and 90 YES owed;
//       the burn pays 200 and 60, the event shows paid < owed, and both totals read zero.
// Why:  FR-9BRR: no phantom claim lowers the next claimant's ratio.
// ──────────────────────────────────────────────
contract FullDebitOnShortPayoutTest is PayoutRatioTestBase {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _moveTick(5700);
        _fundVault(60e6, 0);
        _drainTo(200e6);
    }

    // SC-COEU: the event shows the cut and the totals fall by owed
    function test_whenTheBurnPaysLessThenTheTotalsFallByTheOwedAmounts() public {
        _expectFellBurn(positionId, 200e6, 60e6);
        _burn(positionId);

        assertEq(vault.totalUsdcOwed(), 0, "247,354,500 debited, not 200,000,000");
        assertEq(vault.totalYesOwed(), 0, "90 debited, not 60");
        assertEq(vault.totalUsdcOwedScaled(), 0, "no phantom USDC claim");
        assertEq(vault.totalYesOwedScaled(), 0, "no phantom YES claim");
    }
}

// ──────────────────────────────────────────────
// SC-DFDY: Drift-free fills conserve value across claims on both sides of the price, before
//          and after the switch
// What: Four positions minted at different ticks on both sides of the price, each after the
//       move that precedes it: [5500, 6500) with 300 USDC at 6000, [5500, 6500) with 300 at
//       5500, [5000, 6000) with 250 at 5700, and [6000, 7000) with 400 at 6300. The moves
//       6000 → 5500 → 5700 → 6300 → 5800, each filled by the keeper at the board's bid, at a
//       spread of 0 and of 2,000 bps. Run A burns every position before the switch; run B
//       reports [1, 0], the Oracle winds down and redeems, then every position burns. In
//       every run every PositionBurned reports paid == owed on every leg, the spread leg
//       included, the Safes together receive their deposits plus the summed spread income,
//       and the vault ends with 0 YES, 0 NO, and exactly totalEscrowed.
// Why:  Finding CV-02 of audits/code-validation-round-1.md: no test modeled the keeper, so a
//       merge rule that was wrong for the claim model (CV-01) passed every test. Since R18 the
//       spread income is asserted as paid, not held: the credit turns it into an obligation the
//       ledger carries (FEAT-E943), and the closing sweep leaves nothing behind, so the income
//       decision (O1b) is answered on chain. On the source before R14 run A failed at both
//       spreads: the merge took every pair, the last burns paid a cut token leg, and the vault
//       kept USDC above the spread income. On the source before R18 both runs fail at 2,000
//       bps: the income stays in the vault after the last burn instead of reaching the Safes.
// ──────────────────────────────────────────────
contract DriftFreeConservationTest is PayoutRatioTestBase, KeeperFillFixture {
    uint256[] ids;

    /// @dev The spread every burn paid, summed across a run (FEAT-E943 NFR-E94E).
    uint256 spreadOut;

    /// @dev The residue the last live position's burn swept, beyond its own claim.
    uint256 usdcResidue;

    /// @dev The USDC the ledger owed the four claims, read just before the first burn.
    uint256 claimsBefore;

    event ResidueSwept(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcResidueAmount,
        uint256 yesResidue,
        uint256 noResidue
    );

    /// @dev The mints and the filled moves of the scenario, from the vault at 6000. Returns the
    ///      spread income the fills left in the vault.
    function _mintsAndFills(uint32 spreadBps) internal returns (uint256 income) {
        ids.push(_escrowAndMint(vault, operatorAddr, LP_PK, 5500, 6500, 300e6, keccak256("p0")));
        _moveTick(5500);
        income += _fillMove(vault, exchangeAddr, 6000, 5500, spreadBps);
        ids.push(_escrowAndMint(vault, operatorAddr, LP_PK, 5500, 6500, 300e6, keccak256("p1")));
        _moveTick(5700);
        income += _fillMove(vault, exchangeAddr, 5500, 5700, spreadBps);
        ids.push(_escrowAndMint(vault, operatorAddr, LP_PK, 5000, 6000, 250e6, keccak256("p2")));
        _moveTick(6300);
        income += _fillMove(vault, exchangeAddr, 5700, 6300, spreadBps);
        ids.push(_escrowAndMint(vault, operatorAddr, LP_PK, 6000, 7000, 400e6, keccak256("p3")));
        _moveTick(5800);
        income += _fillMove(vault, exchangeAddr, 6300, 5800, spreadBps);
    }

    /// @dev Burns every position, checks every leg of every PositionBurned against its owed
    ///      amount, and returns the sum of the CompleteSetsMerged amounts. After the switch the
    ///      token leg's owed amount is its USDC at the payout [1, 0]: the YES count, or 0 for NO.
    function _burnAllInFull(bool afterSwitch) internal returns (uint256 merged) {
        vm.recordLogs();
        for (uint256 i = 0; i < ids.length; i++) {
            _burn(ids[i]);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CompleteSetsMerged.selector) merged += abi.decode(logs[i].data, (uint256));
            if (logs[i].topics[0] == ResidueSwept.selector) {
                (uint256 u, uint256 y, uint256 n) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                usdcResidue = u;
                assertEq(y, 0, "the sweep leaves no YES behind");
                assertEq(n, 0, "the sweep leaves no NO behind");
            }
            if (logs[i].topics[0] != PositionBurned.selector) continue;
            burns++;
            (
                uint256 usdcOwed,
                uint256 usdcPaid,
                uint256 spreadOwed,
                uint256 spreadPaid,
                uint256 tokenId,
                uint256 tokenOwed,
                uint256 tokenPaid
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(usdcPaid, usdcOwed, "the USDC leg is paid in full");
            assertEq(spreadPaid, spreadOwed, "the spread leg is paid in full");
            spreadOut += spreadPaid;
            uint256 tokenExpected = afterSwitch ? (tokenId == vault.yesTokenId() ? tokenOwed : 0) : tokenOwed;
            assertEq(tokenPaid, tokenExpected, "the token leg is paid in full");
        }
        assertEq(burns, ids.length, "every position burned");
    }

    function _run(uint32 spreadBps, bool afterSwitch) internal {
        uint256 income = _mintsAndFills(spreadBps);
        if (spreadBps == 0) assertEq(income, 0, "no spread income at a spread of 0");
        else assertGt(income, 0, "the board's bids leave spread income");

        // Under drift-free fills the tokens above the owed totals are the round-trip pairs
        uint256 freeYes = _yesOf(address(vault)) - vault.totalYesOwed();
        uint256 freeNo = ctf.balanceOf(address(vault), vault.noTokenId()) - vault.totalNoOwed();
        assertEq(freeYes, freeNo, "the excess of each token is the round-trip pairs");
        assertGt(freeYes, 0, "the path leaves round-trip pairs to merge");

        if (afterSwitch) _resolveAndRedeem(1, 0);

        // After the switch the token legs are USDC too, at the reported payout [1, 0], so the
        // YES the ledger owes is part of what the Safes receive
        claimsBefore = vault.totalUsdcOwed() + (afterSwitch ? vault.totalYesOwed() : 0);
        uint256 safeBefore = mockUsdc.balanceOf(safe);

        uint256 merged = _burnAllInFull(afterSwitch);

        assertEq(merged, afterSwitch ? 0 : freeYes, "the burns merge exactly the round-trip pairs");
        assertEq(_yesOf(address(vault)), 0, "the vault ends with no YES");
        assertEq(ctf.balanceOf(address(vault), vault.noTokenId()), 0, "the vault ends with no NO");

        // R18: the income reaches the Safes instead of staying in the vault (FEAT-E943)
        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "the vault keeps nothing above escrow");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed() + vault.totalNoOwed(), 0, "every principal total is zero");
        assertEq(vault.totalSpreadOwedX128(), 0, "the spread total is zero");

        // Every unit the fills left reaches a Safe, as a spread leg or as the closing sweep's
        // residue. The two together are the income exactly, because the sweep takes whatever the
        // credits could not attribute (FEAT-E943 FR-E94C).
        assertEq(spreadOut + usdcResidue, income, "every unit of spread income reaches a Safe");
        if (spreadBps == 0) {
            assertEq(usdcResidue, 0, "no residue at a spread of 0");
        } else {
            assertGt(spreadOut, 0, "the Safes are paid a spread leg at 2,000 bps");
            assertLt(usdcResidue, 3, "the residue is dust under drift-free fills");
        }

        // The Safes together receive every USDC the vault held above escrow, which is the sum of
        // what the ledger owed them and the income the fills left
        assertEq(
            mockUsdc.balanceOf(safe) - safeBefore, claimsBefore + income, "the Safes receive the claims plus the income"
        );
    }

    // SC-DFDY: run A at a spread of 0, every burn in full and nothing above escrow
    function test_whenFillsAreDriftFreeAtNoSpreadThenEveryBurnPaysInFullBeforeTheSwitch() public {
        _run(0, false);
    }

    // SC-DFDY: run A at 2,000 bps, every burn in full and exactly the spread income above escrow
    function test_whenFillsAreDriftFreeAtASpreadThenEveryBurnPaysInFullBeforeTheSwitch() public {
        _run(2000, false);
    }

    // SC-DFDY: run B at a spread of 0, after the Oracle's redemption
    function test_whenFillsAreDriftFreeAtNoSpreadThenEveryBurnPaysInFullAfterTheSwitch() public {
        _run(0, true);
    }

    // SC-DFDY: run B at 2,000 bps, after the Oracle's redemption
    function test_whenFillsAreDriftFreeAtASpreadThenEveryBurnPaysInFullAfterTheSwitch() public {
        _run(2000, true);
    }
}
