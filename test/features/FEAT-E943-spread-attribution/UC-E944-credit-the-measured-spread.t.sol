// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-E943: Spread Attribution
// UC-E944: Credit the Measured Spread
// Integration tests for every scenario in this use case, against the real ConditionalTokens
// bytecode and the keeper's board bids: the measurement from the vault's own balances, the
// per-segment split inside one report, the round trip the public merge credits, the token-cover
// check, the carry-forward, the mint's credit-then-snapshot order, and the closing sweep.
// Covers: SC-E94H, SC-E94I, SC-E94J, SC-E94K, SC-E94L, SC-E94M, SC-E94N, SC-E94O

import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {KeeperFillFixture} from "../../fixtures/KeeperFillFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base for the spread-attribution scenarios. Deploys the factory and a vault on the real
// ConditionalTokens contract at tick 6000, with no donated USDC: every balance the vault holds
// arrives through a mint's escrow or through the keeper's fill, so the measurement is exercised
// against a state a real vault can reach.
// ──────────────────────────────────────────────
contract SpreadAttributionTestBase is LPVaultFixture, KeeperFillFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");
    address stranger = makeAddr("stranger");

    uint256 constant LP_A_PK = 0xA11CE;
    uint256 constant LP_B_PK = 0xB0B;
    address safeA;
    address safeB;

    int24 constant MINT_TICK = 6000;

    event SpreadCredited(uint256 amount, uint256 spreadGrowthGlobalX128);
    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);
    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        int24 mintTick,
        uint128 liquidity,
        uint256 usdcAmount,
        bytes32 intentId
    );
    event ResidueSwept(
        uint256 indexed positionId, address indexed owner, uint256 usdcResidue, uint256 yesResidue, uint256 noResidue
    );

    function setUp() public virtual {
        safeA = _safeOf(vm.addr(LP_A_PK));
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketIdOf(), int24(10), uint128(1)));

        _moveTick(MINT_TICK);
    }

    function marketIdOf() internal pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    function _mint(uint256 pk, int24 lower, int24 upper, uint256 amount, bytes32 intentId) internal returns (uint256) {
        return _escrowAndMint(vault, operatorAddr, pk, lower, upper, amount, intentId);
    }

    /// @dev The spread the vault has credited and not yet paid, in USDC units.
    function _spreadOwed() internal view returns (uint256) {
        return vault.totalSpreadOwed();
    }

    /// @dev One position's spread claim in USDC units, the formula the burn uses and the app
    ///      reproduces off-chain from the two public getters (FR-E94B, FR-E94Y).
    function _spreadClaim(uint256 positionId) internal view returns (uint256) {
        (, int24 lower, int24 upper,, uint128 liquidity, uint256 last) = vault.positions(positionId);
        (,,, uint256 lowerOutside) = vault.ticks(lower);
        (,,, uint256 upperOutside) = vault.ticks(upper);
        uint256 global = vault.spreadGrowthGlobalX128();
        int24 current = vault.currentTick();
        unchecked {
            uint256 below = current >= lower ? lowerOutside : global - lowerOutside;
            uint256 above = current < upper ? upperOutside : global - upperOutside;
            return (uint256(liquidity) * (global - below - above - last)) >> 128;
        }
    }

    function _vaultYes() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.yesTokenId());
    }

    function _vaultNo() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.noTokenId());
    }

    /// @dev The one SpreadCredited amount in `logs`, or a revert when there is none.
    function _creditedAmount(Vm.Log[] memory logs) internal view returns (uint256 amount, uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != SpreadCredited.selector) continue;
            (amount,) = abi.decode(logs[i].data, (uint256, uint256));
            count++;
        }
    }

    function _countCredits(Vm.Log[] memory logs) internal view returns (uint256 count) {
        (, count) = _creditedAmount(logs);
    }
}

// ──────────────────────────────────────────────
// SC-E94H: One report over one segment credits by liquidity, exactly
// What: A holds 0.3 tokens per level and B holds 0.2 over the same range [5500, 6500), both
//       minted at 6000. The keeper fills the fall to 5700 at 400 bps, which leaves 3,502,500
//       units of margin, and the Operator reports it. The credit splits 3 to 2.
// Why:  FR-E946: inside one in-range set every position placed the same liquidity on every
//       level, so a split by liquidity is exact whatever the fills' sizes were (NFR-E94D).
// ──────────────────────────────────────────────
contract OneSegmentCreditTest is SpreadAttributionTestBase {
    uint256 a;
    uint256 b;
    uint256 income;

    // The fills' margin over [5700, 6000) at 400 bps on 0.5 tokens per level
    uint256 constant MARGIN = 3_502_500;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        b = _mint(LP_B_PK, 5500, 6500, 200e6, keccak256("b"));
        income = _fillMove(vault, exchangeAddr, 6000, 5700, 400);
    }

    // SC-E94H: the fills leave exactly the board's margin, before any report
    function test_whenTheKeeperFillsAtASpreadThenTheVaultHoldsTheMargin() public view {
        assertEq(income, MARGIN, "the board's bids leave 3.5025 USDC on the 150 YES");
        assertEq(_vaultYes(), 150e6, "the fills bought 150 YES");
        assertEq(
            mockUsdc.balanceOf(address(vault)),
            500e6 - (87_742_500 - MARGIN),
            "the vault spent the bid, not the model price"
        );
    }

    // SC-E94H: the report credits the whole margin, once, to the one segment with liquidity
    function test_whenReportedThenTheMarginIsCreditedOnce() public {
        vm.recordLogs();
        _moveTick(5700);
        (uint256 amount, uint256 count) = _creditedAmount(vm.getRecordedLogs());

        assertEq(count, 1, "one credit, for the one segment that had liquidity");
        assertEq(amount, MARGIN - 1, "the whole margin less the unit the growth floor drops");
        assertEq(_spreadOwed(), MARGIN - 1, "the ledger owes the credited spread");
    }

    // SC-E94H: the split is 3 to 2, A's liquidity against B's
    function test_whenReportedThenTheSplitFollowsLiquidity() public {
        _moveTick(5700);

        uint256 claimA = _spreadClaim(a);
        uint256 claimB = _spreadClaim(b);
        assertApproxEqAbs(claimA, MARGIN * 3 / 5, 1, "A takes three fifths");
        assertApproxEqAbs(claimB, MARGIN * 2 / 5, 1, "B takes two fifths");
        // The total truncates once and each claim truncates on its own, so the sum of the two
        // floors can sit one unit below the total. The X128 ledger itself is exact.
        assertApproxEqAbs(claimA + claimB, _spreadOwed(), 1, "every credited unit belongs to a position");
    }

    // SC-E94H: a second report of the same tick credits nothing
    function test_whenTheTickDoesNotMoveThenNothingIsCredited() public {
        _moveTick(5700);
        uint256 owedBefore = _spreadOwed();

        vm.recordLogs();
        _moveTick(5700);

        assertEq(_countCredits(vm.getRecordedLogs()), 0, "the unchanged report reads no balance");
        assertEq(_spreadOwed(), owedBefore, "the ledger is unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-E94I: A report over several segments splits by model spend
// What: A holds 0.3 tokens per level over [5500, 6500) and B holds 0.2 over [5000, 6000), both
//       minted at 6000. The keeper fills the fall from 6000 to 5500 at 400 bps and from 5500 to
//       5000 at 600 bps, then the Operator reports 5000 in one call. The report weighs the two
//       segments by active x model spend.
// Why:  FR-E947: the vault sees one surplus at the end of the report, so it splits by what each
//       segment's levels were worth. NFR-E94D records the bounded error when the spread varies.
// ──────────────────────────────────────────────
contract MultiSegmentCreditTest is SpreadAttributionTestBase {
    uint256 a;
    uint256 b;
    uint256 income;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        b = _mint(LP_B_PK, 5000, 6000, 200e6, keccak256("b"));
    }

    /// @dev Both filled moves, with no report between them, so one later report must split them.
    function _fillBoth() internal {
        income = _fillMove(vault, exchangeAddr, 6000, 5500, 400);
        income += _fillMove(vault, exchangeAddr, 5500, 5000, 600);
    }

    // SC-E94I: the two segments' true margins
    function test_theTwoSegmentsCarryDifferentMargins() public {
        _fillBoth();
        assertEq(income, 5_737_500 + 3_144_800, "the two filled moves leave 8.8823 USDC");
    }

    // SC-E94I: one report credits both segments, by active x model spend
    function test_whenOneReportCrossesBothSegmentsThenTheSplitFollowsModelSpend() public {
        _fillBoth();
        vm.recordLogs();
        _moveTick(5000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countCredits(logs), 2, "one credit per segment with liquidity");

        // floor(8,882,300 x 14,373,750 / 19,623,250) and floor(8,882,300 x 5,249,500 / 19,623,250)
        uint256 claimA = _spreadClaim(a);
        uint256 claimB = _spreadClaim(b);
        assertApproxEqAbs(claimA, uint256(6_506_157) * 3 / 5, 1, "A takes three fifths of the first segment");
        assertApproxEqAbs(
            claimB, uint256(6_506_157) * 2 / 5 + 2_376_142, 2, "B takes the rest of the first and all of the second"
        );
        assertApproxEqAbs(claimA + claimB, income, 3, "every unit but the rounding dust is attributed");
    }

    // SC-E94I: reporting the same move in two calls credits each segment its own margin exactly
    function test_whenTheReportIsChunkedThenEachSegmentTakesItsOwnMargin() public {
        // The keeper reports at the initialized tick it crosses, so each report carries one
        // segment and each segment is credited its own margin exactly (NFR-E94D)
        _fillMove(vault, exchangeAddr, 6000, 5500, 400);
        _moveTick(5500);
        uint256 afterFirst = _spreadClaim(a);

        _fillMove(vault, exchangeAddr, 5500, 5000, 600);
        _moveTick(5000);

        assertApproxEqAbs(afterFirst, uint256(5_737_500) * 3 / 5, 1, "A takes its share of its own segment's margin");
        assertEq(_spreadClaim(a), afterFirst, "the second segment credits A nothing: it is out of range");
        assertApproxEqAbs(_spreadClaim(b), uint256(5_737_500) * 2 / 5 + 3_144_800, 2, "B takes both of its shares");
    }
}

// ──────────────────────────────────────────────
// SC-E94J: The public merge credits a round trip that ended where it began
// What: The keeper fills a fall from 6000 to 5900 and the rise back, both at 400 bps, with no
//       report between them, so the vault holds 30 YES, 30 NO, and 1.2 USDC of margin while the
//       reported tick never moved. mergeCompleteSets() credits, then merges.
// Why:  ADR-E94V: the unchanged-tick report reads no balance, so the keeper's merge call is the
//       moment the vault sees the trip's second leg as USDC.
// ──────────────────────────────────────────────
contract RoundTripMergeCreditTest is SpreadAttributionTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        _fillMove(vault, exchangeAddr, 6000, 5900, 400);
        _fillMove(vault, exchangeAddr, 5900, 6000, 400);
    }

    // SC-E94J: the round trip left a pair and the board's margin on it
    function test_theRoundTripLeavesAPairAndAMargin() public view {
        assertEq(_vaultYes(), 30e6, "30 YES from the fall");
        assertEq(_vaultNo(), 30e6, "30 NO from the rise");
        assertEq(mockUsdc.balanceOf(address(vault)), 271_200_000, "the vault spent 28.8 USDC on a pair worth 30");
        assertEq(vault.totalUsdcOwed(), 300e6, "the reported tick never moved, so the claim is all USDC");
    }

    // SC-E94J: the merge credits the margin to the liquidity in range, then merges
    function test_whenAnyWalletMergesThenTheRoundTripIsCredited() public {
        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 amount, uint256 count) = _creditedAmount(logs);
        assertEq(count, 1, "one credit");
        assertEq(amount, 1_200_000 - 1, "400 bps of the 30 tokens the trip turned over");
        assertApproxEqAbs(_spreadClaim(a), 1_200_000, 1, "the whole margin belongs to the one position in range");

        assertEq(_vaultYes(), 0, "the pair merged");
        assertEq(_vaultNo(), 0, "the pair merged");
        assertEq(mockUsdc.balanceOf(address(vault)), 301_200_000, "the pair became USDC");
        assertEq(mockUsdc.balanceOf(stranger), 0, "the caller receives nothing");
    }

    // SC-E94J: the credit runs before the merge, and a second call credits nothing
    function test_whenMergedTwiceThenOnlyTheFirstCredits() public {
        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 creditAt = type(uint256).max;
        uint256 mergeAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] == SpreadCredited.selector) creditAt = i;
            if (logs[i].topics[0] == CompleteSetsMerged.selector) mergeAt = i;
        }
        assertLt(creditAt, mergeAt, "the credit precedes the merge");

        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();
        (uint256 second,) = _creditedAmount(vm.getRecordedLogs());
        assertLe(second, 1, "the second call finds only the unit the first call's floor dropped");
    }

    // SC-E94J: the unchanged-tick report keeps its cost and credits nothing
    function test_whenTheTickIsReportedUnchangedThenNothingIsCredited() public {
        vm.recordLogs();
        _moveTick(6000);

        assertEq(vm.getRecordedLogs().length, 0, "the unchanged report reads no balance and writes no event");
        assertEq(_spreadOwed(), 0, "nothing credited");
    }
}

// ──────────────────────────────────────────────
// SC-E94K: A reported fill the vault never received is withheld
// What: The Operator reports a 40-level fall that no fill followed. The ledger books the move,
//       so the vault holds 7,175,400 USDC units above the principal, but its YES balance sits
//       below the 12,000,000 it now owes.
// Why:  FR-E948 and ADR-E94T: that USDC is unspent principal, not spread. Crediting it would
//       pay one LP with another's capital.
// ──────────────────────────────────────────────
contract TokenCoverCheckTest is SpreadAttributionTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
    }

    // SC-E94K: the report credits nothing while the YES balance is short
    function test_whenTheFillNeverArrivedThenNothingIsCredited() public {
        vm.recordLogs();
        _moveTick(5960);

        assertEq(_countCredits(vm.getRecordedLogs()), 0, "no credit while a token balance is short");
        assertEq(vault.totalYesOwed(), 12e6, "the ledger booked the band");
        assertEq(_vaultYes(), 0, "the vault never received the tokens");
        assertGt(mockUsdc.balanceOf(address(vault)), vault.totalUsdcOwed(), "the USDC looks like a surplus");
        assertEq(_spreadOwed(), 0, "and is not credited");
        assertEq(vault.spreadGrowthGlobalX128(), 0, "the global growth is untouched");
        assertEq(_spreadClaim(a), 0, "no position gains a claim");
    }

    // SC-E94K: once the fill lands, the same state credits the board's margin
    function test_whenTheFillArrivesThenTheCheckClears() public {
        _moveTick(5960);
        uint256 income = _fillMove(vault, exchangeAddr, 6000, 5960, 400);

        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();

        (uint256 amount,) = _creditedAmount(vm.getRecordedLogs());
        assertEq(amount, income - 1, "the board's margin, once both balances cover their totals");
    }
}

// ──────────────────────────────────────────────
// SC-E94L: A credit with nothing in range carries the surplus forward
// What: The price sits below A's range, so activeLiquidity is zero. A stranger sends 10 USDC to
//       the vault. The merge writes no growth. A later report that brings A back in range,
//       filled drift-free, credits the carried 10 USDC together with the rise's own margin.
// Why:  FR-E949: a surplus with nobody to credit stays measurable.
// ──────────────────────────────────────────────
contract CarryForwardTest is SpreadAttributionTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        _fillMove(vault, exchangeAddr, 6000, 5500, 400);
        _moveTick(5400);
        assertEq(vault.activeLiquidity(), 0, "precondition: the price left the range");
        mockUsdc.mint(address(vault), 10e6);
    }

    // SC-E94L: with nothing in range the merge writes no growth
    function test_whenNothingIsInRangeThenNoGrowthIsWritten() public {
        uint256 globalBefore = vault.spreadGrowthGlobalX128();
        uint256 owedBefore = _spreadOwed();

        vm.recordLogs();
        vm.prank(stranger);
        vault.mergeCompleteSets();

        assertEq(_countCredits(vm.getRecordedLogs()), 0, "nobody to credit");
        assertEq(vault.spreadGrowthGlobalX128(), globalBefore, "the global growth is untouched");
        assertEq(_spreadOwed(), owedBefore, "the ledger is untouched");
    }

    // SC-E94L: the next credit with liquidity takes the carried surplus
    function test_whenLiquidityReturnsThenTheCarriedSurplusIsCredited() public {
        vm.prank(stranger);
        vault.mergeCompleteSets();
        uint256 claimBefore = _spreadClaim(a);

        uint256 riseIncome = _fillMove(vault, exchangeAddr, 5400, 5600, 400);

        vm.recordLogs();
        _moveTick(5600);
        (uint256 amount,) = _creditedAmount(vm.getRecordedLogs());

        assertApproxEqAbs(amount, 10e6 + riseIncome, 1, "the carried donation and the rise's own margin");
        assertApproxEqAbs(_spreadClaim(a) - claimBefore, 10e6 + riseIncome, 1, "both reach the position that returned");
    }
}

// ──────────────────────────────────────────────
// SC-E94M: The mint credits the existing liquidity, then starts the new position at zero
// What: The round trip of SC-E94J is filled and unreported, so 1.2 USDC is pending. The Operator
//       mints B. The credit runs before B joins the in-range set, B's snapshot is taken after
//       both bounds are referenced, and the free pairs merge as the mint's one external call.
// Why:  FR-E94B: a position minted after a trade must never claim that trade's value, and the
//       order is unconditional on chain rather than a keeper obligation.
// ──────────────────────────────────────────────
contract MintCreditsFirstTest is SpreadAttributionTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        _fillMove(vault, exchangeAddr, 6000, 5900, 400);
        _fillMove(vault, exchangeAddr, 5900, 6000, 400);
    }

    // SC-E94M: the pending margin goes to A alone, and B starts at zero
    function test_whenMintedWhileASurplusIsPendingThenTheNewPositionClaimsNothing() public {
        vm.recordLogs();
        uint256 b = _mint(LP_B_PK, 5500, 6500, 200e6, keccak256("b"));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 amount, uint256 count) = _creditedAmount(logs);
        assertEq(count, 1, "the mint credits once");
        assertEq(amount, 1_200_000 - 1, "the whole round trip's margin");

        assertApproxEqAbs(_spreadClaim(a), 1_200_000, 1, "A holds the margin its own liquidity earned");
        assertEq(_spreadClaim(b), 0, "B starts at a zero spread claim");
        assertEq(vault.activeLiquidity(), 5e23, "B joined the in-range set after the credit");
    }

    // SC-E94M: the mint's one external call is the merge of the free pairs it counted
    function test_whenMintedThenTheFreePairsMergeAsTheOneExternalCall() public {
        vm.recordLogs();
        _mint(LP_B_PK, 5500, 6500, 200e6, keccak256("b"));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 creditAt = type(uint256).max;
        uint256 mergeAt = type(uint256).max;
        uint256 mintedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] == SpreadCredited.selector) creditAt = i;
            if (logs[i].topics[0] == CompleteSetsMerged.selector) mergeAt = i;
            if (logs[i].topics[0] == PositionMinted.selector) mintedAt = i;
        }
        assertLt(creditAt, mergeAt, "the credit precedes the merge");
        assertLt(mergeAt, mintedAt, "the merge precedes the mint event");

        assertEq(_vaultYes(), 0, "the pair merged");
        assertEq(_vaultNo(), 0, "the pair merged");
        assertEq(mockUsdc.balanceOf(address(vault)), 501_200_000, "the deposits plus the round trip's margin");
    }

    // SC-E94M: a later credit splits between the two, so B earns only from its own moment on
    function test_whenCreditedAfterTheMintThenBothShare() public {
        uint256 b = _mint(LP_B_PK, 5500, 6500, 200e6, keccak256("b"));
        uint256 claimABefore = _spreadClaim(a);

        uint256 income = _fillMove(vault, exchangeAddr, 6000, 5700, 400);
        _moveTick(5700);

        assertApproxEqAbs(_spreadClaim(a) - claimABefore, income * 3 / 5, 1, "A takes three fifths of the new margin");
        assertApproxEqAbs(_spreadClaim(b), income * 2 / 5, 1, "B takes two fifths, and nothing from before its mint");
    }
}

// ──────────────────────────────────────────────
// SC-E94N: A burn credits before it values its claim, and leaves nothing behind
// SC-E94O: The last live position takes the residue
// What: The round trip of SC-E94J is filled and unreported. The Safe burns. The burn credits the
//       pending 1.2 USDC with itself still in range, pays principal and spread in one transfer,
//       and deletes the record with its snapshot.
// Why:  ADR-E94W: an exit is final. A position that leaves while spread is unrealized, unmerged,
//       and uncredited would otherwise forfeit it.
// ──────────────────────────────────────────────
contract BurnCreditsFirstTest is SpreadAttributionTestBase {
    uint256 a;

    function setUp() public override {
        super.setUp();
        a = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a"));
        _fillMove(vault, exchangeAddr, 6000, 5900, 400);
        _fillMove(vault, exchangeAddr, 5900, 6000, 400);
    }

    // SC-E94N: the exiting position takes its own round trip's margin
    function test_whenBurnedWhileASurplusIsPendingThenTheExitTakesIt() public {
        vm.recordLogs();
        vm.prank(safeA);
        vault.burnPosition(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 amount, uint256 count) = _creditedAmount(logs);
        assertEq(count, 1, "the burn credits once, before it values the claim");
        assertEq(amount, 1_200_000 - 1, "the round trip's margin");

        assertEq(mockUsdc.balanceOf(safeA), 301_200_000, "the principal, the spread, and the dust, in one transfer");
        assertEq(ctf.balanceOf(safeA, vault.yesTokenId()), 0, "no token: the price sits at the mint tick");
    }

    // SC-E94N: the record and every total are empty, and a later credit cannot reach the id
    function test_whenBurnedThenNothingIsLeftBehind() public {
        vm.prank(safeA);
        vault.burnPosition(a);

        (address owner, int24 lower, int24 upper, int24 mintTick, uint128 liquidity, uint256 last) = vault.positions(a);
        assertEq(owner, address(0), "the record is deleted");
        assertEq(lower, int24(0), "the record is deleted");
        assertEq(upper, int24(0), "the record is deleted");
        assertEq(mintTick, int24(0), "the record is deleted");
        assertEq(liquidity, uint128(0), "the record is deleted");
        assertEq(last, uint256(0), "the spread snapshot leaves with the record");

        assertEq(vault.totalUsdcOwedScaled(), 0, "the USDC total is zero");
        assertEq(vault.totalYesOwedScaled(), 0, "the YES total is zero");
        assertEq(vault.totalNoOwedScaled(), 0, "the NO total is zero");
        assertEq(vault.totalSpreadOwedX128(), 0, "the spread total is zero");

        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "the vault holds exactly its escrow total");
        assertEq(_vaultYes(), 0, "no YES");
        assertEq(_vaultNo(), 0, "no NO");
    }

    // SC-E94O: this burn is the last live position's, so it sweeps what the credit left
    function test_whenTheLastPositionBurnsThenTheResidueIsSwept() public {
        vm.recordLogs();
        vm.prank(safeA);
        vault.burnPosition(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 sweeps;
        uint256 usdcResidue;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != ResidueSwept.selector) continue;
            sweeps++;
            (usdcResidue,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
        assertEq(sweeps, 1, "the last live position's burn sweeps");
        assertEq(usdcResidue, 1, "the dust the growth floor dropped, and nothing more");
    }

    // SC-E94Q: the relayed path pays exactly what the self-service path pays
    function test_whenRelayedThenTheAmountsAreIdentical() public {
        uint256 selfService = vm.snapshotState();
        vm.prank(safeA);
        vault.burnPosition(a);
        uint256 paidBySelf = mockUsdc.balanceOf(safeA);

        vm.revertToState(selfService);
        bytes memory sig = _signBurnIntent(address(vault), LP_A_PK, safeA, a, FAR_DEADLINE);
        vm.prank(operatorAddr);
        vault.burnPositionFor(safeA, a, FAR_DEADLINE, sig);

        assertEq(mockUsdc.balanceOf(safeA), paidBySelf, "both entry points pay the same amount");
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "the Operator receives nothing");
    }

    // SC-E94O: a record a position merge consumed has no claim, so it never triggers the sweep
    function test_whenARecordWasConsumedByAMergeThenItCannotSweep() public {
        uint256 second = _mint(LP_A_PK, 5500, 6500, 300e6, keccak256("a2"));
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        vm.expectRevert(LPVault.PositionNotFound.selector);
        vm.prank(safeA);
        vault.burnPosition(second);
    }
}
