// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-9BR2: Apply Payout Ratios
// Integration tests for every scenario in this use case.
// Covers: SC-9BSC, SC-9BSD, SC-9BSE, SC-9BSF, SC-9BSG, SC-COET, SC-COEU, SC-CYSB, SC-CYSC

import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
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
    uint256 constant Q128 = 2 ** 128;

    // The claim at 5700 (SC-7G44): 90 YES and the USDC the band did not spend
    uint256 constant FELL_USDC = 247_354_500;
    uint256 constant BAND_TOKENS = 90e6;

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
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amountOwed, uint256 amountPaid);
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
        mockUsdc.transferFrom(address(vault), exchangeAddr, amount);
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
    function _expectFellBurn(uint256 id, uint256 fees, uint256 usdcPaid, uint256 yesPaid) internal {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(id, safe, FELL_USDC, fees, usdcPaid, vault.yesTokenId(), BAND_TOKENS, yesPaid);
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

    /// @dev The one PositionBurned log's usdcPaid + tokenPaid, the USDC a resolved burn sent.
    function _paidSum(Vm.Log[] memory logs) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != PositionBurned.selector) continue;
            (,, uint256 usdcPaid,,, uint256 tokenPaid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            return usdcPaid + tokenPaid;
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
        assertEq(vault.totalFeesOwed(), 0, "the fee total is empty");
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
            (,, usdcPaid,,, tokenPaid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
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

    // SC-CYSC: the redemption event, then the burn; the vault keeps the 5 USDC and no token
    function test_burnRedeemsTheLateTokensFirst() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(safe, 5e6, 5e6, 5e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, 0, FELL_USDC, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + BAND_TOKENS, "the whole claim in USDC");
        assertEq(mockUsdc.balanceOf(address(vault)), 5e6, "the vault keeps the late tokens' USDC");
        assertEq(_yesOf(address(vault)), 0, "no YES left");
        assertEq(ctf.balanceOf(address(vault), vault.noTokenId()), 0, "no NO left");
        assertEq(_countLogs(logs, address(vault), CompleteSetsMerged.selector), 0, "no merge after the switch");
    }
}

// ──────────────────────────────────────────────
// SC-9BSC: A covered vault pays every claim in full
// What: The vault at 5700 holds 500 YES and 1,300 USDC against one claim of 247.3545 USDC
//       plus 90 YES and 9,999,999 units of fees; both ratios read 1 and the burn pays the
//       whole claim, leaving the surplus in the vault.
// Why:  FR-9BRP: a holding at or above the total is a ratio of exactly 1, and a surplus is
//       never a bonus.
// ──────────────────────────────────────────────
contract CoveredVaultTest is PayoutRatioTestBase {
    uint256 positionId;
    uint256 fees;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _notifyFees(vault, operatorAddr, 10e6);
        fees = 9_999_999;
        _moveTick(5700);
        _fundVault(500e6, 0);
        mockUsdc.mint(address(vault), 1_000e6);
    }

    // SC-9BSC: the whole claim and the whole fees
    function test_whenTheVaultCoversTheClaimThenTheBurnPaysInFull() public {
        _expectFellBurn(positionId, fees, FELL_USDC + fees, BAND_TOKENS);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + fees, "the claim's USDC plus the fees");
        assertEq(_yesOf(safe), BAND_TOKENS, "the claim's YES");
    }

    // SC-9BSC: the surplus stays
    function test_whenTheVaultCoversTheClaimThenTheSurplusStays() public {
        _burn(positionId);

        assertEq(_yesOf(address(vault)), 500e6 - BAND_TOKENS, "the vault keeps the YES it did not owe");
        assertEq(vault.totalUsdcOwedScaled(), 0, "the ledger settled the claim");
        assertEq(vault.totalYesOwedScaled(), 0, "the ledger settled the claim");
        assertEq(vault.totalFeesOwedX128(), 0, "the ledger settled the fees");
    }
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

        _expectFellBurn(a, 0, FELL_USDC, 50e6);
        _burn(a);
        assertEq(_yesOf(safe), 50e6, "first burn: 90 x 150 / 270");
        assertEq(vault.totalYesOwed(), 180e6, "debited by the full 90");
        assertEq(_yesOf(address(vault)), 100e6, "100 held against 180 owed, the same 5/9");

        _expectFellBurn(b, 0, FELL_USDC, 50e6);
        _burn(b);
        assertEq(_yesOf(safe), 100e6, "second burn: the same 50");

        _expectFellBurn(c, 0, FELL_USDC, 50e6);
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
        assertEq(vault.totalUsdcOwed() + vault.totalFeesOwed(), owed, "precondition: the USDC total");

        _expectFellBurn(a, 0, FELL_USDC / 2, BAND_TOKENS);
        _burn(a);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC / 2, "first burn: half");

        _expectFellBurn(b, 0, FELL_USDC / 2, BAND_TOKENS);
        _burn(b);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "second burn: the same half");

        _expectFellBurn(c, 0, FELL_USDC / 2, BAND_TOKENS);
        _burn(c);
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + FELL_USDC / 2, "third burn: the same half");
        assertEq(_yesOf(safe), 270e6, "YES was never short");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the USDC is exactly spent");
        assertEq(vault.totalUsdcOwed(), 0, "the ledger is empty");
    }
}

// ──────────────────────────────────────────────
// SC-9BSE: Escrowed USDC never pays a burn or a collect
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
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, 0, 0, 0, 0);
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
        _expectFellBurn(a, 0, FELL_USDC, 45e6);
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
        _expectFellBurn(positionId, 0, FELL_USDC, BAND_TOKENS);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the whole USDC leg");
        assertEq(_yesOf(safe), BAND_TOKENS, "the whole YES leg");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault held exactly the claim");
    }
}

// ──────────────────────────────────────────────
// SC-COET: A collect at a ratio pays its share, zeroes tokensOwed, and emits both amounts
// What: The in-range position is owed 9,999,999 units of fees and the vault holds above
//       escrow 40 percent of the principal and the fees it owes; the collect pays 40 percent
//       of the fees, sets tokensOwed to zero, debits the whole scaled claim, and emits both
//       amounts; a later collect owes only the fees that grew since.
// Why:  ADR-COEN: a cut is final, and the LP chose the moment.
// ──────────────────────────────────────────────
contract CollectAtRatioTest is PayoutRatioTestBase {
    uint256 positionId;
    uint256 owed;
    uint256 expectedPaid;

    function setUp() public override {
        super.setUp();
        positionId = _mintExample(keccak256("a"));
        _notifyFees(vault, operatorAddr, 10e6);
        owed = 9_999_999;
        uint256 total = vault.totalUsdcOwed() + vault.totalFeesOwed();
        uint256 held = total * 4 / 10;
        _drainTo(held);
        expectedPaid = owed * held / total;
    }

    // SC-COET: the share, the event, and the settled claim
    function test_whenTheVaultIsShortThenTheCollectPaysItsShareAndSettles() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesCollected(positionId, safe, owed, expectedPaid);
        vm.prank(safe);
        vault.collect(positionId);

        assertEq(mockUsdc.balanceOf(safe), expectedPaid, "40 percent of the fees owed");
        (,,,,,, uint256 tokensOwed) = vault.positions(positionId);
        assertEq(tokensOwed, 0, "nothing waits for a later collect");
        assertEq(vault.totalFeesOwedX128(), 0, "the ledger settled the whole scaled claim");
    }

    // SC-COET: the later collect owes only the new fees
    function test_whenCollectedAgainThenOnlyTheNewFeesAreOwed() public {
        vm.prank(safe);
        vault.collect(positionId);
        _notifyFees(vault, operatorAddr, 5e6);
        uint256 newOwed = 4_999_999;
        uint256 total = vault.totalUsdcOwed() + vault.totalFeesOwed();
        uint256 held = mockUsdc.balanceOf(address(vault));
        uint256 expectedPaid2 = held < total ? newOwed * held / total : newOwed;

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesCollected(positionId, safe, newOwed, expectedPaid2);
        vm.prank(safe);
        vault.collect(positionId);

        assertEq(mockUsdc.balanceOf(safe), expectedPaid + expectedPaid2, "the new fees at the ratio then in force");
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
        _expectFellBurn(positionId, 0, 200e6, 60e6);
        _burn(positionId);

        assertEq(vault.totalUsdcOwed(), 0, "247,354,500 debited, not 200,000,000");
        assertEq(vault.totalYesOwed(), 0, "90 debited, not 60");
        assertEq(vault.totalUsdcOwedScaled(), 0, "no phantom USDC claim");
        assertEq(vault.totalYesOwedScaled(), 0, "no phantom YES claim");
    }
}
