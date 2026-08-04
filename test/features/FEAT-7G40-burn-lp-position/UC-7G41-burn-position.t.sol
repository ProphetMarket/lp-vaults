// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-7G41: Burn Position
// Integration tests for every scenario in this use case.
// Covers: SC-7G43, SC-7G44, SC-7G45, SC-7G46, SC-7G47, SC-7G48, SC-7G49, SC-7G4A, SC-7G4B

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock. transfer is needed because the burn's USDC leg goes
// through _safeTransfer (selector 0xa9059cbb).
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

/// @dev The receiver surface the ERC-1155 mock invokes on transfer.
interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Minimal but *real* ERC-1155: it tracks balances and fires the receiver hook on a
///      safe transfer to a contract, reverting unless the acknowledgement comes back. The
///      hook matters here — it is the reentrancy surface NFR-7G59 orders the burn around,
///      and a stub that skipped the callback would make that ordering untestable.
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
// Base fixture: full stack (factory + vault clone), one LP position on [200, 400]
// funded with 1000 USDC, and enough outcome-token inventory in the vault for the
// payout legs to actually move.
//
// Liquidity math, fixed by mintPositionFor: L = 1000 * 1e18 / (400 - 200) = 5e18.
// Principal reconstruction: P = 5e18 * 200 / 1e18 = 1000 USDC base units, exactly.
// ──────────────────────────────────────────────
contract BurnPositionTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    uint256 constant LP_B_PK = 0xB0B;
    address lp;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(1e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;
    uint256 constant Q128 = 2 ** 128;

    int24 constant TICK_LOWER = 200;
    int24 constant TICK_UPPER = 400;
    uint256 constant DEPOSIT = 1000;
    uint128 constant LIQUIDITY = 5e18;
    uint256 constant PRINCIPAL = 1000;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcAmount,
        uint256 outcomeTokenAmount,
        uint256 feesAmount
    );

    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    uint256 posId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        lpB = vm.addr(LP_B_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
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
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Outcome-token inventory. Nothing in src/ acquires these today — funding the
        // vault is the Operator's job off-chain, and the dual-asset withdrawal rewrite
        // owns the on-chain machinery (FEAT-7G40 Non-Goals).
        mockCt.mint(address(vault), yesTokenId, 1_000_000);
        mockCt.mint(address(vault), noTokenId, 1_000_000);

        posId = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-a"));
    }

    // ── helpers ───────────────────────────────

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

    function _mintPosition(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal returns (uint256) {
        bytes memory sig = _signMintIntent(pk, lpAddr, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tickLower, tickUpper, usdcAmount, intentId, sig);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lpAddr, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _moveTick(int24 newTick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(newTick);
    }

    /// @dev Fee revenue the Operator has actually funded, then announced.
    function _notifyFees(uint256 amount) internal {
        mockUsdc.mint(address(vault), amount);
        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    function _positionLiquidity(uint256 id) internal view returns (uint128 liquidity) {
        (,,, liquidity,,) = vault.positions(id);
    }

    function _positionOwner(uint256 id) internal view returns (address owner) {
        (owner,,,,,) = vault.positions(id);
    }

    function _tickBitSet(int24 tick) internal view returns (bool) {
        int16 wordPos = int16(tick >> 8);
        uint8 bitPos = uint8(uint24(tick) & 0xff);
        return (vault.tickBitmap(wordPos) >> bitPos) & 1 == 1;
    }

    function _assertPositionZeroed(uint256 id) internal view {
        (
            address owner,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInsideLast,
            uint256 tokensOwed
        ) = vault.positions(id);
        assertEq(owner, address(0), "owner not zeroed");
        assertEq(tickLower, int24(0), "tickLower not zeroed");
        assertEq(tickUpper, int24(0), "tickUpper not zeroed");
        assertEq(liquidity, uint128(0), "liquidity not zeroed");
        assertEq(feeGrowthInsideLast, uint256(0), "feeGrowthInsideLast not zeroed");
        assertEq(tokensOwed, uint256(0), "tokensOwed not zeroed");
    }
}

// ──────────────────────────────────────────────
// SC-7G43: Burn below range pays entirely in USDC
// What: With currentTick below tickLower, the position has converted nothing, so the
//       whole principal comes back as USDC and no outcome tokens move.
// Why:  This is the "nothing filled" corner of the dual-asset model. If it paid any
//       outcome tokens, an LP whose range the market never reached would be handed
//       inventory they never acquired.
// Example: range [200, 400], L = 5e18, currentTick = 150 → 1000 USDC, 0 tokens.
// ──────────────────────────────────────────────
contract BurnBelowRangeTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(150);
    }

    // SC-7G43: full principal returns as USDC
    function test_belowRangePaysFullPrincipalInUsdc() public {
        uint256 before = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp) - before, PRINCIPAL);
    }

    // SC-7G43: no outcome tokens are paid
    function test_belowRangePaysNoOutcomeTokens() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockCt.balanceOf(yesTokenId, lp), 0);
        assertEq(mockCt.balanceOf(noTokenId, lp), 0);
    }

    // SC-7G43: activeLiquidity is untouched because the position was never in range
    function test_belowRangeLeavesActiveLiquidityUnchanged() public {
        uint128 before = vault.activeLiquidity();

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.activeLiquidity(), before);
        assertEq(before, uint128(0));
    }

    // SC-7G43: the position record is zeroed and cannot be burned again
    function test_belowRangeZeroesPositionRecord() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        _assertPositionZeroed(posId);

        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(posId);
    }

    // SC-7G43: PositionBurned reports a USDC-only payout
    function test_belowRangeEmitsPositionBurned() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, PRINCIPAL, 0, 0);

        vm.prank(lp);
        vault.burnPosition(posId);
    }

    // SC-7G43: both boundary ticks give up the position's liquidity
    function test_belowRangeRemovesLiquidityFromBothTicks() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        (uint128 grossLower, int128 netLower,) = vault.ticks(TICK_LOWER);
        (uint128 grossUpper, int128 netUpper,) = vault.ticks(TICK_UPPER);
        assertEq(grossLower, uint128(0));
        assertEq(netLower, int128(0));
        assertEq(grossUpper, uint128(0));
        assertEq(netUpper, int128(0));
    }
}

// ──────────────────────────────────────────────
// SC-7G44: Burn above range pays entirely in outcome tokens
// What: With currentTick at or above tickUpper, every slot has converted, so the payout
//       is a complete set of outcome tokens and zero USDC principal.
// Why:  The vault must never sell on the LP's behalf (FR-7G4N) — auto-converting would
//       reintroduce a counterparty exactly when liquidity is thinnest.
// Example: currentTick = 450 → 0 USDC, 1000 YES + 1000 NO.
// ──────────────────────────────────────────────
contract BurnAboveRangeTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(450);
    }

    // SC-7G44: payout is a complete set sized to the full principal
    function test_aboveRangePaysCompleteSet() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockCt.balanceOf(yesTokenId, lp), PRINCIPAL);
        assertEq(mockCt.balanceOf(noTokenId, lp), PRINCIPAL);
    }

    // SC-7G44: no USDC principal is paid
    function test_aboveRangePaysNoUsdc() public {
        uint256 before = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp), before);
    }

    // SC-7G44: activeLiquidity is unchanged — the position was out of range at burn time
    function test_aboveRangeLeavesActiveLiquidityUnchanged() public {
        assertEq(vault.activeLiquidity(), uint128(0));

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.activeLiquidity(), uint128(0));
    }

    // SC-7G44: PositionBurned reports an outcome-token-only payout
    function test_aboveRangeEmitsPositionBurned() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, 0, PRINCIPAL, 0);

        vm.prank(lp);
        vault.burnPosition(posId);
    }

    // SC-7G44: exactly at tickUpper counts as above the range
    function test_atTickUpperPaysOutcomeTokensOnly() public {
        // Rebuild at the boundary rather than past it
        _moveTick(TICK_UPPER);

        uint256 beforeUsdc = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp), beforeUsdc);
        assertEq(mockCt.balanceOf(yesTokenId, lp), PRINCIPAL);
    }
}

// ──────────────────────────────────────────────
// SC-7G45: Burn in range pays a split of both assets
// What: With currentTick strictly inside the range, the LP receives USDC for the slots
//       above the tick and a complete set for the slots below it, and activeLiquidity
//       drops by exactly the position's liquidity.
// Why:  The split is the whole point of the dual-asset model — the payout is a function
//       of where the market sits, not of what was deposited.
// Example: currentTick = 300 in [200, 400] → 500 USDC + 500 YES + 500 NO.
// ──────────────────────────────────────────────
contract BurnInRangeTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G45: both legs are nonzero and split the principal evenly at the midpoint
    function test_inRangePaysBothAssets() public {
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 500);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
    }

    // SC-7G45: the two legs conserve the position's principal
    function test_inRangeConservesPrincipal() public {
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        uint256 usdcPaid = mockUsdc.balanceOf(lp) - beforeUsdc;
        uint256 setPaid = mockCt.balanceOf(yesTokenId, lp);
        assertEq(usdcPaid + setPaid, PRINCIPAL);
    }

    // SC-7G45: activeLiquidity decreases by exactly the burned liquidity
    function test_inRangeDecrementsActiveLiquidity() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.activeLiquidity(), uint128(0));
    }

    // SC-7G45: PositionBurned carries both asset amounts
    function test_inRangeEmitsPositionBurned() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, 500, 500, 0);

        vm.prank(lp);
        vault.burnPosition(posId);
    }

    // SC-7G45: the payout tracks currentTick, not the deposited amount
    function test_payoutCompositionFollowsTick() public {
        _moveTick(350);

        uint256 beforeUsdc = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.burnPosition(posId);

        // 50 of 200 slots unconverted -> 250 USDC, 750 of principal converted
        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 250);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 750);
    }
}

// ──────────────────────────────────────────────
// SC-7G46: Burn pays accrued fees alongside principal
// What: A single burn returns principal and every fee accrued since mint or last
//       collect; no separate collect call is needed, and none is possible afterwards.
// Why:  Closing a position must never strand its fees in the vault.
// Example: 1000 USDC of fees over 5e18 active liquidity, then burn in range.
// ──────────────────────────────────────────────
contract BurnWithFeesTest is BurnPositionTestBase {
    uint256 constant FEE_REVENUE = 1000;
    uint256 expectedFees;

    function setUp() public override {
        super.setUp();
        _moveTick(300);
        _notifyFees(FEE_REVENUE);

        // Mirror the contract's Q128 accounting exactly, including its downward
        // truncation: fees = L * (FEE_REVENUE * Q128 / L) / Q128.
        uint256 feeGrowth = FEE_REVENUE * Q128 / uint256(LIQUIDITY);
        expectedFees = uint256(LIQUIDITY) * feeGrowth / Q128;
    }

    // SC-7G46: fees ride out with the principal in one call
    function test_burnPaysFeesWithPrincipal() public {
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        // 500 USDC-side principal at tick 300, plus the accrued fees
        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 500 + expectedFees);
    }

    // SC-7G46: the fee leg is real, and within a dust unit of the revenue notified
    function test_accruedFeesAreSubstantiallyTheNotifiedRevenue() public view {
        assertGt(expectedFees, 0);
        assertLe(expectedFees, FEE_REVENUE);
        assertGe(expectedFees, FEE_REVENUE - 1);
    }

    // SC-7G46: PositionBurned reports the fee amount
    function test_burnEmitsFeeAmount() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, 500, 500, expectedFees);

        vm.prank(lp);
        vault.burnPosition(posId);
    }

    // SC-7G46: collect on a burned position reverts — the position is gone
    function test_collectAfterBurnReverts() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.collect(posId);
    }

    // SC-7G46: a burn after a collect pays only the principal — no double payment
    function test_collectThenBurnDoesNotPayFeesTwice() public {
        vm.prank(lp);
        vault.collect(posId);

        uint256 afterCollect = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp) - afterCollect, 500);
    }

    // SC-7G46: tokensOwed rolled up by a merge is paid out by the burn
    function test_burnPaysRolledUpTokensOwed() public {
        uint256 second = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-roll"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = posId;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        (,,,,, uint256 tokensOwed) = vault.positions(posId);
        assertGt(tokensOwed, 0);

        uint256 beforeUsdc = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.burnPosition(posId);

        // Survivor holds both positions' liquidity: 1000 USDC-side principal at tick 300
        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 1000 + tokensOwed);
    }
}

// ──────────────────────────────────────────────
// SC-7G47: Burning the last position at a tick deinitializes it
// What: A boundary tick whose liquidityGross reaches zero is deleted and its bitmap bit
//       cleared; a tick another position still references keeps its state.
// Why:  A set bit must mean "liquidity lives here". Leaving it set would make a later
//       updateTick cross a tick with nothing behind it.
// Example: LP A on [200, 400] and LP B on [200, 600]; burning A retires 400, keeps 200.
// ──────────────────────────────────────────────
contract BurnTickDeinitializationTest is BurnPositionTestBase {
    uint256 posB;
    uint128 constant LIQUIDITY_B = 2.5e18; // 1000 * 1e18 / (600 - 200)

    function setUp() public override {
        super.setUp();
        posB = _mintPosition(LP_B_PK, lpB, TICK_LOWER, int24(600), DEPOSIT, keccak256("mint-b"));

        // Give tick 200 a nonzero feeGrowthOutsideX128 to prove the burn preserves it:
        // move in range, distribute fees, then move back below the tick so crossing it
        // downward snapshots the accumulator.
        _moveTick(300);
        _notifyFees(1000);
        _moveTick(100);
    }

    // SC-7G47: the tick only this position referenced is deleted
    function test_lastPositionAtTickDeletesTickState() public {
        (uint128 grossBefore,,) = vault.ticks(TICK_UPPER);
        assertEq(grossBefore, LIQUIDITY);

        vm.prank(lp);
        vault.burnPosition(posId);

        (uint128 gross, int128 net, uint256 feeGrowthOutside) = vault.ticks(TICK_UPPER);
        assertEq(gross, uint128(0));
        assertEq(net, int128(0));
        assertEq(feeGrowthOutside, uint256(0));
    }

    // SC-7G47: its bitmap bit is cleared, so updateTick will skip it
    function test_lastPositionAtTickClearsBitmapBit() public {
        assertTrue(_tickBitSet(TICK_UPPER));

        vm.prank(lp);
        vault.burnPosition(posId);

        assertFalse(_tickBitSet(TICK_UPPER));
    }

    // SC-7G47: a tick another position still references survives intact
    function test_sharedTickSurvivesWithLiquidityRemoved() public {
        uint256 feeGrowthOutsideBefore;
        (,, feeGrowthOutsideBefore) = vault.ticks(TICK_LOWER);
        assertGt(feeGrowthOutsideBefore, 0);

        vm.prank(lp);
        vault.burnPosition(posId);

        (uint128 gross, int128 net, uint256 feeGrowthOutside) = vault.ticks(TICK_LOWER);
        assertEq(gross, LIQUIDITY_B, "only LP B's liquidity should remain");
        assertEq(net, int128(LIQUIDITY_B));
        assertEq(feeGrowthOutside, feeGrowthOutsideBefore, "shared tick's fee snapshot must survive");
        assertTrue(_tickBitSet(TICK_LOWER));
    }

    // SC-7G47: LP B's position is untouched and still burnable
    function test_otherPositionUnaffected() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(_positionLiquidity(posB), LIQUIDITY_B);

        vm.prank(lpB);
        vault.burnPosition(posB);

        _assertPositionZeroed(posB);
    }

    // SC-7G47: burning the last position of all clears both ticks
    function test_burningBothPositionsClearsAllTicks() public {
        vm.prank(lp);
        vault.burnPosition(posId);
        vm.prank(lpB);
        vault.burnPosition(posB);

        assertFalse(_tickBitSet(TICK_LOWER));
        assertFalse(_tickBitSet(TICK_UPPER));
        assertFalse(_tickBitSet(int24(600)));
    }
}

// ──────────────────────────────────────────────
// SC-7G48: Revert when the caller is not the position owner
// What: Only the recorded owner can burn. A third party is rejected even though the
//       payout would have gone to the owner anyway.
// Why:  This is timing control, not theft protection — payout composition depends on
//       currentTick at call time, so an outsider could force an exit into a split the
//       LP never chose.
// Example: LP B calls burnPosition on LP A's position.
// ──────────────────────────────────────────────
contract BurnOwnershipTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G48: a non-owner is rejected
    function test_nonOwnerCannotBurn() public {
        vm.prank(lpB);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(posId);
    }

    // SC-7G48: the operator cannot use the self-service path either
    function test_operatorCannotUseSelfServicePath() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(posId);
    }

    // SC-7G48: the rejected call moves nothing
    function test_rejectedBurnLeavesPositionIntact() public {
        uint256 vaultUsdcBefore = mockUsdc.balanceOf(address(vault));
        uint256 vaultYesBefore = mockCt.balanceOf(yesTokenId, address(vault));

        vm.prank(lpB);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(posId);

        assertEq(_positionLiquidity(posId), LIQUIDITY);
        assertEq(_positionOwner(posId), lp);
        assertEq(vault.activeLiquidity(), LIQUIDITY);
        assertEq(mockUsdc.balanceOf(address(vault)), vaultUsdcBefore);
        assertEq(mockCt.balanceOf(yesTokenId, address(vault)), vaultYesBefore);
    }

    // SC-7G48: the owner can still exit afterwards
    function test_ownerStillBurnsAfterRejectedAttempt() public {
        vm.prank(lpB);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(posId);

        vm.prank(lp);
        vault.burnPosition(posId);

        _assertPositionZeroed(posId);
    }
}

// ──────────────────────────────────────────────
// SC-7G49: Burn in WindDown phase succeeds identically to Active
// What: Wind-down closes new mints without closing exits. Payout, tick updates, and the
//       activeLiquidity delta match the same burn in Active.
// Why:  This is the burn half of FEAT-JGE7's exit-path guarantee, previously
//       unimplementable because no burn function existed.
// Example: oracle calls startWindDown, then the LP burns an in-range position.
// ──────────────────────────────────────────────
contract BurnDuringWindDownTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-7G49: the payout matches the Active-phase split exactly
    function test_windDownBurnPaysIdenticalSplit() public {
        assertEq(vault.phase(), uint8(2));
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 500);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
    }

    // SC-7G49: tick and liquidity accounting is unchanged by the phase
    function test_windDownBurnUpdatesTickStateIdentically() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.activeLiquidity(), uint128(0));
        (uint128 grossLower,,) = vault.ticks(TICK_LOWER);
        (uint128 grossUpper,,) = vault.ticks(TICK_UPPER);
        assertEq(grossLower, uint128(0));
        assertEq(grossUpper, uint128(0));
    }

    // SC-7G49: the vault stays in WindDown
    function test_windDownBurnDoesNotChangePhase() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.phase(), uint8(2));
    }

    // D6: a Cancelled vault has already distributed everything
    function test_burnRevertsAfterEmergencyCancel() public {
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(lp);
        vault.emergencyCancelAll();

        vm.prank(lp);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.burnPosition(posId);
    }
}

// ──────────────────────────────────────────────
// SC-7G4A: Burn succeeds with zero registered operators
// What: With every operator removed by the Admin, no emergency declared and no timelock
//       waited out, the owner still completes their exit in full.
// Why:  This is the concrete mechanism behind "LP capital is not trapped when the
//       Operator goes dark". Any change that gives this path an Operator dependency
//       voids the guarantee, and this test is what would catch it.
// Example: admin removes the only operator, then the LP burns.
// ──────────────────────────────────────────────
contract BurnWithoutOperatorsTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        // Position the tick while an operator still exists, then take them all away.
        _moveTick(300);
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
    }

    // SC-7G4A: the registry really is empty
    function test_noOperatorsRemain() public view {
        assertEq(vault.operators(operatorAddr), 0);
    }

    // SC-7G4A: the LP exits in full with no Operator participation
    function test_burnSucceedsWithNoOperators() public {
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp) - beforeUsdc, 500);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
        _assertPositionZeroed(posId);
    }

    // SC-7G4A: no emergency was declared — the vault is simply unattended
    function test_burnNeedsNoDeclaredEmergency() public {
        assertEq(vault.phase(), uint8(1));

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.phase(), uint8(1));
    }

    // SC-7G4A / FR-7G50: the self-service path is not an Operator heartbeat
    function test_burnDoesNotRefreshOperatorHeartbeat() public {
        uint256 before = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.lastOperatorActivityTimestamp(), before);
    }

    // SC-7G4A: a paused vault still lets the LP out
    function test_burnSucceedsWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();

        vm.prank(lp);
        vault.burnPosition(posId);

        _assertPositionZeroed(posId);
    }
}

// ──────────────────────────────────────────────
// SC-7G4B: Revert on a nonexistent or already-burned position
// What: An id that was never minted, one already burned, and one drained by a merge all
//       revert with PositionNotFound.
// Why:  A double burn must not drain a second payout, and because ids are never reused a
//       stale reference has to resolve to nothing rather than to someone else's position.
// Example: burnPosition(999), or burning the same id twice.
// ──────────────────────────────────────────────
contract BurnPositionNotFoundTest is BurnPositionTestBase {
    // SC-7G4B: never minted
    function test_neverMintedIdReverts() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(999);
    }

    // SC-7G4B: already burned
    function test_doubleBurnReverts() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(posId);
    }

    // SC-7G4B: a double burn cannot drain a second payout
    function test_doubleBurnPaysNothingTwice() public {
        vm.prank(lp);
        vault.burnPosition(posId);
        uint256 afterFirst = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(posId);

        assertEq(mockUsdc.balanceOf(lp), afterFirst);
    }

    // SC-7G4B: a position consumed by a merge has no liquidity left to burn
    function test_mergeConsumedPositionReverts() public {
        uint256 second = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-consumed"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = posId;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        vm.prank(lp);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(second);
    }

    // FR-7G4T: a burned id is never reassigned
    function test_burnedIdIsNeverReassigned() public {
        uint256 nextBefore = vault.nextPositionId();

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(vault.nextPositionId(), nextBefore, "burn must not rewind the counter");

        uint256 fresh = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-after-burn"));
        assertTrue(fresh != posId, "a burned id must never be reused");
        assertEq(fresh, nextBefore);
    }
}

// ──────────────────────────────────────────────
// Payout composition across the whole tick space (fuzz)
// What: For any currentTick, the split follows the three-branch rule and the two legs
//       conserve the position's principal to within one base unit of truncation dust.
// Why:  CLAUDE.md requires fuzz coverage on arithmetic-heavy code. The branch boundaries
//       (exactly at tickLower, exactly at tickUpper) are where an off-by-one would hide.
// Example: any tick in [-500, 900] against range [200, 400].
// ──────────────────────────────────────────────
contract BurnPayoutCompositionFuzzTest is BurnPositionTestBase {
    function testFuzz_payoutCompositionFollowsCurrentTick(int24 rawTick) public {
        int24 tick = int24(bound(int256(rawTick), -500, 900));
        if (tick != 0) _moveTick(tick);

        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.burnPosition(posId);

        uint256 usdcPaid = mockUsdc.balanceOf(lp) - beforeUsdc;
        uint256 setPaid = mockCt.balanceOf(yesTokenId, lp);

        // Both legs of the complete set are always the same size
        assertEq(setPaid, mockCt.balanceOf(noTokenId, lp), "YES and NO legs must match");

        if (tick < TICK_LOWER) {
            assertEq(usdcPaid, PRINCIPAL, "below range: full principal in USDC");
            assertEq(setPaid, 0, "below range: no outcome tokens");
        } else if (tick >= TICK_UPPER) {
            assertEq(usdcPaid, 0, "above range: no USDC principal");
            assertEq(setPaid, PRINCIPAL, "above range: full principal as a complete set");
        } else {
            uint256 expectedUsdc = uint256(LIQUIDITY) * uint256(int256(TICK_UPPER - tick)) / LIQUIDITY_PRECISION;
            uint256 expectedSet = uint256(LIQUIDITY) * uint256(int256(tick - TICK_LOWER)) / LIQUIDITY_PRECISION;
            assertEq(usdcPaid, expectedUsdc, "in range: USDC leg tracks the unconverted slots");
            assertEq(setPaid, expectedSet, "in range: outcome leg tracks the converted slots");
        }

        // Value conservation: the two legs sum to the principal, less at most one base
        // unit of downward truncation dust left behind in the vault.
        assertLe(usdcPaid + setPaid, PRINCIPAL, "payout must never exceed the principal");
        assertGe(usdcPaid + setPaid, PRINCIPAL - 1, "payout must not lose more than dust");
    }

    /// @dev Monotonicity: a higher tick never pays more USDC and never pays fewer outcome
    ///      tokens. Two positions in the same vault, burned at two different ticks.
    function testFuzz_payoutIsMonotonicInTick(int24 rawLow, int24 rawHigh) public {
        int24 lowTick = int24(bound(int256(rawLow), -500, 900));
        int24 highTick = int24(bound(int256(rawHigh), -500, 900));
        if (lowTick > highTick) (lowTick, highTick) = (highTick, lowTick);

        uint256 second = _mintPosition(LP_B_PK, lpB, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-mono"));

        if (lowTick != 0) _moveTick(lowTick);
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.burnPosition(posId);
        uint256 usdcAtLow = mockUsdc.balanceOf(lp) - beforeUsdc;
        uint256 setAtLow = mockCt.balanceOf(yesTokenId, lp);

        if (highTick != lowTick) _moveTick(highTick);
        uint256 beforeUsdcB = mockUsdc.balanceOf(lpB);
        vm.prank(lpB);
        vault.burnPosition(second);
        uint256 usdcAtHigh = mockUsdc.balanceOf(lpB) - beforeUsdcB;
        uint256 setAtHigh = mockCt.balanceOf(yesTokenId, lpB);

        assertLe(usdcAtHigh, usdcAtLow, "USDC leg must not grow as the tick rises");
        assertGe(setAtHigh, setAtLow, "outcome leg must not shrink as the tick rises");
    }
}

// ──────────────────────────────────────────────
// NFR-7G59: checks-effects-interactions against the ERC-1155 receive hook
// What: A position owner that re-enters burnPosition from onERC1155Received is rejected,
//       and finds no live position behind the guard either.
// Why:  The outcome-token payout hands control to the recipient mid-call. This is a live
//       reentrancy surface, not defense-in-depth.
// Example: an LP contract whose receive hook calls burnPosition again.
// ──────────────────────────────────────────────
contract ReentrantLp {
    /// @dev Slot 0 — the selector of whatever the re-entrant call reverted with. Read by
    ///      the test through vm.load, so this contract needs no constructor state and can
    ///      be etched over an address whose key signed the mint.
    bytes32 public caughtSelector;

    function onERC1155Received(address, address from, uint256, uint256, bytes calldata) external returns (bytes4) {
        // `from` is the vault: it is the account the tokens are leaving.
        try LPVault(from).burnPosition(0) {
            caughtSelector = bytes32("reentry succeeded");
        } catch (bytes memory err) {
            caughtSelector = bytes32(err);
        }
        return 0xf23a6e61;
    }
}

contract BurnReentrancyTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
        // The mint needed a real key behind `lp`; the reentrancy needs code there. Etch
        // after minting so both hold.
        vm.etch(lp, address(new ReentrantLp()).code);
    }

    // NFR-7G58: the guard rejects the re-entrant call
    function test_reentrantBurnIsRejected() public {
        assertEq(posId, 0, "the re-entrant helper burns id 0");

        vm.prank(lp);
        vault.burnPosition(posId);

        bytes32 caught = vm.load(lp, 0);
        assertEq(bytes4(caught), LPVault.Reentrancy.selector, "re-entrant burnPosition must revert with Reentrancy");
    }

    // NFR-7G59: the outer burn still completes, and completely
    function test_outerBurnCompletesDespiteReentrantHook() public {
        vm.prank(lp);
        vault.burnPosition(posId);

        _assertPositionZeroed(posId);
        assertEq(vault.activeLiquidity(), uint128(0));
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
    }
}
