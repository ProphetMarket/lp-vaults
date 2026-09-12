// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-K1M8: Merge Same-Range Positions
// Integration tests for every scenario in this use case.
// Covers: SC-K1M9, SC-K1MA, SC-K1MB, SC-K1MC

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {ConditionalTokensFixture} from "../../fixtures/ConditionalTokensFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {VaultStorage} from "../../fixtures/VaultStorage.sol";

// ──────────────────────────────────────────────
// Base test contract for mergePositions scenarios.
// Deploys the full stack (factory + vault clone), mints two in-range positions
// owned by the same LP on the same tick range [0, 100), and provides helpers.
// ──────────────────────────────────────────────
contract MergePositionsTestBase is ConditionalTokensFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(1e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;
    uint256 constant Q128 = 2 ** 128;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event PositionsMerged(uint256[] positionIds, uint256 survivorId);

    // Position IDs assigned during setUp
    uint256 posA;
    uint256 posB;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Mint position A: range [0, 100), 500 USDC → liquidity = 5e18
        bytes memory sigA = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, keccak256("mint-a"));
        vm.prank(operatorAddr);
        posA = vault.mintPositionFor(lp, int24(0), int24(100), 500, keccak256("mint-a"), sigA);

        // Mint position B: range [0, 100), 500 USDC → liquidity = 5e18
        bytes memory sigB = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, keccak256("mint-b"));
        vm.prank(operatorAddr);
        posB = vault.mintPositionFor(lp, int24(0), int24(100), 500, keccak256("mint-b"), sigB);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildIds(uint256 id0, uint256 id1) internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        return ids;
    }
}

// ──────────────────────────────────────────────
// SC-K1M9: Successful merge of two same-range positions
// What: When Operator calls mergePositions with two positions that share the
//       same owner, tickLower, and tickUpper, the survivor (first ID) ends up
//       with the summed liquidity, the consumed position is zeroed, the
//       PositionsMerged event is emitted, and tick liquidityGross is unchanged.
// Why:  This is the core happy path. The liquidity sum must be exact — any
//       error would break fee distribution proportionality.
// Example: posA=5e18 liq, posB=5e18 liq → survivor=10e18 liq, consumed=0.
// ──────────────────────────────────────────────
contract MergePositionsSuccessTest is MergePositionsTestBase {
    // SC-K1M9: survivor liquidity equals sum of both positions
    function test_survivorLiquidityEqualsSumOfBoth() public {
        // Both positions: 500 USDC on [0, 100) → each has 5e18 liquidity
        (,,, uint128 liqA,,) = vault.positions(posA);
        (,,, uint128 liqB,,) = vault.positions(posB);
        uint128 expectedLiq = liqA + liqB;

        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        (,,, uint128 survivorLiq,,) = vault.positions(posA);
        assertEq(survivorLiq, expectedLiq, "survivor liquidity should equal sum");
        assertEq(survivorLiq, 10e18, "survivor liquidity should be 10e18");
    }

    // SC-K1M9: consumed position has zero liquidity after merge
    function test_consumedPositionLiquidityIsZero() public {
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        (,,, uint128 consumedLiq,,) = vault.positions(posB);
        assertEq(consumedLiq, 0, "consumed position liquidity should be zero");
    }

    // SC-K1M9: PositionsMerged event emitted with correct IDs
    function test_emitsPositionsMergedEvent() public {
        uint256[] memory ids = _buildIds(posA, posB);

        vm.expectEmit(false, false, false, true, address(vault));
        emit PositionsMerged(ids, posA);

        vm.prank(operatorAddr);
        vault.mergePositions(ids);
    }

    // SC-K1M9: tick liquidityGross unchanged after merge
    function test_tickLiquidityGrossUnchanged() public {
        // Record tick state before merge
        (uint128 grossLowerBefore,,) = vault.ticks(int24(0));
        (uint128 grossUpperBefore,,) = vault.ticks(int24(100));

        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        // Tick state must be identical — total liquidity on the range hasn't changed
        (uint128 grossLowerAfter,,) = vault.ticks(int24(0));
        (uint128 grossUpperAfter,,) = vault.ticks(int24(100));
        assertEq(grossLowerAfter, grossLowerBefore, "tickLower liquidityGross unchanged");
        assertEq(grossUpperAfter, grossUpperBefore, "tickUpper liquidityGross unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-K1MA: Revert on mismatched ranges
// What: When Operator calls mergePositions with two positions that have
//       different tick ranges, the call reverts with RangeMismatch.
// Why:  Merging positions with different ranges would corrupt the tick state
//       since the liquidity distribution is range-dependent.
// Example: posA=[0,100), posC=[0,200) → revert.
// ──────────────────────────────────────────────
contract MergePositionsRangeMismatchTest is MergePositionsTestBase {
    uint256 posC;

    function setUp() public override {
        super.setUp();

        // Mint position C with a different upper tick: range [0, 200)
        mockUsdc.mint(lp, 1_000_000);
        bytes memory sigC = _signMintIntent(LP_PK, lp, int24(0), int24(200), 500, keccak256("mint-c"));
        vm.prank(operatorAddr);
        posC = vault.mintPositionFor(lp, int24(0), int24(200), 500, keccak256("mint-c"), sigC);
    }

    // SC-K1MA: reverts with RangeMismatch when tick ranges differ
    function test_revertsWithRangeMismatch() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.RangeMismatch.selector);
        vault.mergePositions(_buildIds(posA, posC));
    }

    // SC-K1MA: no state change on revert (positions unchanged)
    function test_noStateChangeOnMismatch() public {
        (,,, uint128 liqABefore,,) = vault.positions(posA);
        (,,, uint128 liqCBefore,,) = vault.positions(posC);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.RangeMismatch.selector);
        vault.mergePositions(_buildIds(posA, posC));

        (,,, uint128 liqAAfter,,) = vault.positions(posA);
        (,,, uint128 liqCAfter,,) = vault.positions(posC);
        assertEq(liqAAfter, liqABefore, "posA liquidity unchanged after revert");
        assertEq(liqCAfter, liqCBefore, "posC liquidity unchanged after revert");
    }
}

// ──────────────────────────────────────────────
// SC-K1MB: Revert on empty or single-item input
// What: When Operator calls mergePositions with an empty array or a single
//       position ID, the call reverts with InsufficientPositions.
// Why:  Merging requires at least two positions. A single-element merge is a
//       no-op that wastes gas; an empty-array merge is always a caller bug.
// ──────────────────────────────────────────────
contract MergePositionsInsufficientInputTest is MergePositionsTestBase {
    // SC-K1MB: reverts on empty array
    function test_revertsOnEmptyArray() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InsufficientPositions.selector);
        vault.mergePositions(ids);
    }

    // SC-K1MB: reverts on single element
    function test_revertsOnSingleElement() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = posA;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InsufficientPositions.selector);
        vault.mergePositions(ids);
    }
}

// ──────────────────────────────────────────────
// SC-K1MC: Fee accounting preserved after merge
// What: When two positions have accrued different fees and are merged, the
//       survivor's tokensOwed includes both positions' uncollected fees,
//       feeGrowthInsideLastX128 is set to the current value, and a subsequent
//       collect returns the correct total with no loss or double-counting.
// Why:  Fee preservation is the hardest invariant of merge. If the
//       feeGrowthInsideLastX128 snapshot is stale or the tokensOwed rollup
//       is wrong, LPs lose money or claim phantom fees.
// Example: posA accrued 600 USDC fees (sole position during first notifyFees),
//          posB accrued 200 USDC fees (joined before second notifyFees) →
//          survivor tokensOwed includes 800+200=1000 total, collect returns 1000.
// ──────────────────────────────────────────────
contract MergePositionsFeeAccountingTest is MergePositionsTestBase {
    // Override setUp to create asymmetric fee accrual.
    // 1. Mint posA → sole position, receives all of first notifyFees(600)
    // 2. Mint posB → activeLiquidity doubles, second notifyFees(400) split equally
    // Result: posA accrued ~800, posB accrued ~200
    function setUp() public override {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Mint posA: 500 USDC on [0, 100) → liq = 5e18, activeLiquidity = 5e18
        bytes memory sigA = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, keccak256("mint-a"));
        vm.prank(operatorAddr);
        posA = vault.mintPositionFor(lp, int24(0), int24(100), 500, keccak256("mint-a"), sigA);

        // Distribute 600 USDC fees while posA is the only in-range position
        vm.prank(operatorAddr);
        vault.notifyFees(600);

        // Mint posB: 500 USDC on [0, 100) → liq = 5e18, activeLiquidity = 10e18
        bytes memory sigB = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, keccak256("mint-b"));
        vm.prank(operatorAddr);
        posB = vault.mintPositionFor(lp, int24(0), int24(100), 500, keccak256("mint-b"), sigB);

        // Distribute 400 USDC fees split between posA and posB (200 each)
        vm.prank(operatorAddr);
        vault.notifyFees(400);
    }

    // SC-K1MC: survivor tokensOwed includes both positions' uncollected fees
    function test_survivorTokensOwedIncludesBothFees() public {
        // Compute expected uncollected fees for each position using reference math.
        // posA: sole recipient of 600, half of 400 → ~800.
        // posB: half of 400 → ~200.
        (,,, uint128 liqA, uint256 feeGrowthLastA, uint256 owedA) = vault.positions(posA);
        (,,, uint128 liqB, uint256 feeGrowthLastB, uint256 owedB) = vault.positions(posB);

        // feeGrowthInside for [0, 100) equals feeGrowthGlobal (both ticks below currentTick=0)
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();

        // Uncollected fees = liquidity * (feeGrowthInside - feeGrowthInsideLast) / Q128
        uint256 feesA = uint256(liqA) * (feeGrowthGlobal - feeGrowthLastA) / Q128;
        uint256 feesB = uint256(liqB) * (feeGrowthGlobal - feeGrowthLastB) / Q128;
        uint256 expectedOwed = owedA + feesA + owedB + feesB;

        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        (,,,,, uint256 survivorOwed) = vault.positions(posA);
        assertEq(survivorOwed, expectedOwed, "survivor tokensOwed should include both positions' fees");
        assertGt(survivorOwed, 0, "survivor should have nonzero owed fees");
    }

    // SC-K1MC: survivor feeGrowthInsideLastX128 equals current feeGrowthInside
    function test_survivorFeeGrowthInsideLastEqualsCurrentValue() public {
        // Current feeGrowthInside for [0, 100) should equal feeGrowthGlobal
        // (both tick bounds at or below currentTick=0)
        uint256 expectedFeeGrowthInside = vault.feeGrowthGlobalX128();

        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        (,,,, uint256 survivorFeeGrowthLast,) = vault.positions(posA);
        assertEq(
            survivorFeeGrowthLast, expectedFeeGrowthInside, "survivor feeGrowthInsideLast should equal current value"
        );
    }

    // SC-K1MC: collect after merge returns correct total (no loss, no double-counting)
    function test_collectAfterMergeReturnsCorrectTotal() public {
        // Compute expected total fees before merge
        (,,, uint128 liqA, uint256 feeGrowthLastA, uint256 owedA) = vault.positions(posA);
        (,,, uint128 liqB, uint256 feeGrowthLastB, uint256 owedB) = vault.positions(posB);
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        uint256 feesA = uint256(liqA) * (feeGrowthGlobal - feeGrowthLastA) / Q128;
        uint256 feesB = uint256(liqB) * (feeGrowthGlobal - feeGrowthLastB) / Q128;
        uint256 expectedTotal = owedA + feesA + owedB + feesB;

        // Merge positions
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        // Fund vault with enough USDC to pay out fees (notifyFees doesn't move USDC)
        mockUsdc.mint(address(vault), expectedTotal);

        // Collect as LP — should receive the full rolled-up fee amount
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(posA);
        uint256 lpBalAfter = mockUsdc.balanceOf(lp);

        assertEq(lpBalAfter - lpBalBefore, expectedTotal, "LP should receive the full rolled-up fee total");
        assertGt(expectedTotal, 0, "expected total should be nonzero");
    }
}

// ──────────────────────────────────────────────
// NFR-K1M7: Operator-only access control
// What: Only registered Operators can call mergePositions. Non-operator
//       callers (LP, Admin, arbitrary address) get NotOperator.
// Why:  Merge modifies position state. Unrestricted access would allow
//       anyone to merge another LP's positions without authorization.
// ──────────────────────────────────────────────
contract MergePositionsAccessControlTest is MergePositionsTestBase {
    // NFR-K1M7: LP calling mergePositions reverts with NotOperator
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mergePositions(_buildIds(posA, posB));
    }

    // NFR-K1M7: Admin calling mergePositions reverts with NotOperator
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mergePositions(_buildIds(posA, posB));
    }

    // NFR-K1M7: arbitrary address calling mergePositions reverts with NotOperator
    function test_revertsWhenArbitraryAddressCalls() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mergePositions(_buildIds(posA, posB));
    }
}

// ── Regression: fee-growth wraparound (audit NM-0986-Prophet) ──
//   Position merge succeeds and preserves fee accounting even when a
//   position's fee delta wraps mod 2^256
// ─────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────
// Base test contract for the mergePositions wraparound reproduction.
//
// See UC-JXQW's fee-growth-wraparound regression section for the full
// rationale: a position's feeGrowthInsideLastX128 snapshot can legitimately
// be a wrapped (mod-2^256) value produced by _computeFeeGrowthInside
// (fixed in T-001). mergePositions
// computes the SAME `fresh - snapshot` delta twice -- once for the survivor,
// once per consumed position -- and each computation independently
// underflows unless wrapped in unchecked. This test constructs the
// condition directly, with a storage write on the relevant position's
// feeGrowthInsideLastX128 slot, exercising the survivor and the consumed
// position in separate scenarios so both call sites are proven fixed.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundTestBase is ConditionalTokensFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(1e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        returns (uint256)
    {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _buildIds(uint256 id0, uint256 id1) internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        return ids;
    }

    /// @dev Overwrites positions[id].feeGrowthInsideLastX128 directly.
    function _setFeeGrowthInsideLast(uint256 id, uint256 value) internal {
        VaultStorage.setFeeGrowthInsideLast(stdstore, address(vault), id, value);
    }
}

// ──────────────────────────────────────────────
// FR-K1M6: merge succeeds and preserves fee accounting when the SURVIVOR's
// snapshot is a wrapped value
// What: the survivor's own uncollected-fees computation
//       (`survivorFees = liquidity * (fresh - snapshot) / Q128`) underflows
//       when survivor.feeGrowthInsideLastX128 is a wrapped (mod-2^256) value
//       -- the legitimate result _computeFeeGrowthInside can produce per
//       FR-U07H. Before the fix, this reverts the whole merge.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundSurvivorTest is MergePositionsWraparoundTestBase {
    event PositionsMerged(uint256[] positionIds, uint256 survivorId);

    uint256 posSurvivor;
    uint256 posConsumed;

    function setUp() public override {
        super.setUp();

        posSurvivor = _mintPosition(int24(0), int24(100), 500, keccak256("survivor"));
        posConsumed = _mintPosition(int24(0), int24(100), 500, keccak256("consumed"));

        _setFeeGrowthInsideLast(posSurvivor, type(uint256).max - 1000);
    }

    // FR-K1M6: merge succeeds instead of reverting on the survivor's wrapped snapshot.
    function test_mergeSucceedsDespiteSurvivorWrappedSnapshot() public {
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posSurvivor, posConsumed));

        (,,, uint128 survivorLiq,,) = vault.positions(posSurvivor);
        assertEq(survivorLiq, 10e18, "survivor liquidity should be the sum of both positions");
    }

    // FR-K1M6: consumed position is zeroed and PositionsMerged is emitted.
    function test_consumedPositionZeroedAndEventEmitted() public {
        uint256[] memory ids = _buildIds(posSurvivor, posConsumed);

        vm.expectEmit(false, false, false, true, address(vault));
        emit PositionsMerged(ids, posSurvivor);

        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        (,,, uint128 consumedLiq,,) = vault.positions(posConsumed);
        assertEq(consumedLiq, 0, "consumed position liquidity should be zeroed");
    }
}

// ──────────────────────────────────────────────
// FR-K1M6: merge succeeds and preserves fee accounting when a CONSUMED
// position's snapshot is a wrapped value
// What: the same underflow, but on the loop's per-consumed-position
//       computation (`consumedFees = liquidity * (fresh - snapshot) / Q128`)
//       instead of the survivor's own computation -- a distinct call site
//       in the same function.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundConsumedTest is MergePositionsWraparoundTestBase {
    uint256 posSurvivor;
    uint256 posConsumed;

    function setUp() public override {
        super.setUp();

        posSurvivor = _mintPosition(int24(0), int24(100), 500, keccak256("survivor"));
        posConsumed = _mintPosition(int24(0), int24(100), 500, keccak256("consumed"));

        _setFeeGrowthInsideLast(posConsumed, type(uint256).max - 1000);
    }

    // FR-K1M6: merge succeeds instead of reverting on the consumed position's
    // wrapped snapshot.
    function test_mergeSucceedsDespiteConsumedWrappedSnapshot() public {
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posSurvivor, posConsumed));

        (,,, uint128 survivorLiq,,) = vault.positions(posSurvivor);
        (,,, uint128 consumedLiq,,) = vault.positions(posConsumed);
        assertEq(survivorLiq, 10e18, "survivor liquidity should be the sum of both positions");
        assertEq(consumedLiq, 0, "consumed position liquidity should be zeroed");
    }
}

// ──────────────────────────────────────────────
// SC-3XUP, SC-3XUQ: Merging feeds the Operator silence timer
// What: A successful mergePositions refreshes lastOperatorActivityTimestamp;
//       a merge that reverts leaves it exactly where it was.
// Why:  Position housekeeping is real Operator work and should count as proof
//       of life against the emergency-cancel timelock (FEAT-JXQO, FR-JXQS).
//       A failed call must not count.
// Example: warp a day forward, merge posA+posB → timer == block.timestamp;
//          merge a single-item array → reverts, timer unchanged.
// ──────────────────────────────────────────────
contract MergeRefreshesOperatorSilenceTimerTest is MergePositionsTestBase {
    // SC-3XUP: a successful merge advances the timer to the current block
    function test_successfulMergeRefreshesSilenceTimer() public {
        // Move well past the setUp mints so a stale timer would be obvious
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posA, posB));

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            block.timestamp,
            "a successful merge should refresh the silence timer"
        );
    }

    // SC-3XUQ: a merge rejected for insufficient input leaves the timer alone
    function test_revertedMergeOnSingleItemInputLeavesSilenceTimerUntouched() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.warp(block.timestamp + 1 days);

        uint256[] memory single = new uint256[](1);
        single[0] = posA;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InsufficientPositions.selector);
        vault.mergePositions(single);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted merge must not count as proof of life");
    }
}
