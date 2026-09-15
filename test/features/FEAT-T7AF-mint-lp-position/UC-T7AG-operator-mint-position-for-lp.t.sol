// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-T7AG: Operator Mint Position for LP
// Integration tests for every scenario in this use case.
// Covers: SC-T7AH, SC-T7AI, SC-T7AJ, SC-AFPN, SC-T7AK, SC-T7AL, SC-T7AM, SC-T7AN, SC-T7AO, SC-AFPM, SC-T7AP, SC-3Z9J, SC-45IE, SC-3Z9K, SC-T7AR, SC-3XU5, SC-3XU6

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {VaultStorage} from "../../fixtures/VaultStorage.sol";

// ──────────────────────────────────────────────
// Base test contract with shared setup for all mint scenarios.
// Deploys factory, creates vault, and escrows intents for the LP's Safe. The mint
// consumes an escrow: it verifies no signature and moves no USDC (FEAT-3ZRI did both).
// ──────────────────────────────────────────────
contract MintPositionTestBase is LPVaultFixture {
    using stdStorage for StdStorage;

    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The LP's Safe: the recorded depositor and the position owner.
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;

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

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));
    }

    /// @dev Funds the Safe and escrows an intent for it with the far deadline.
    function _escrowIntent(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        _fundSafe(mockUsdc, lp, address(vault), usdcAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
    }

    /// @dev Mints an escrowed intent as the Operator.
    function _mint(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal returns (uint256) {
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
    }

    /// @dev Sets the vault's currentTick via storage manipulation (no updateTick yet).
    function _setCurrentTick(int24 tick) internal {
        VaultStorage.setCurrentTick(stdstore, address(vault), tick);
    }
}

// ──────────────────────────────────────────────
// SC-T7AH: Successful in-range mint with fresh ticks
// What: When the Operator mints an escrowed intent for a range that spans the
//       current tick (in-range), the vault consumes the escrow, creates the
//       position owned by the Safe, initializes both bound ticks with their
//       liquidity, adds liquidity to activeLiquidity, moves no USDC, and
//       emits PositionMinted. This is the primary happy path.
// Why:  This scenario exercises the complete mint flow end-to-end: the escrow
//       checks, tick initialization, active liquidity update, and the escrow
//       deletion. It's the most common case in production.
// Example: vault at currentTick=50, escrow of 600 for [20, 80]. Tick 20 and
//          tick 80 initialize with the position's liquidity.
//          liquidity = 600 * 1e18 / 60 = 10e18.
// ──────────────────────────────────────────────
contract MintPositionInRangeSuccessTest is MintPositionTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("intent-1");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
        _escrowIntent(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-T7AH: position record has correct owner (the Safe), ticks, and liquidity
    function test_positionRecordIsCorrect() public {
        uint256 posId = _mint(tickLower, tickUpper, usdcAmount, intentId);

        (address owner, int24 tl, int24 tu, int24 mintTick, uint128 liq) = vault.positions(posId);
        assertEq(owner, lp, "position owner should be the LP's Safe");
        assertEq(tl, tickLower, "tickLower should match");
        assertEq(tu, tickUpper, "tickUpper should match");
        assertEq(mintTick, int24(50), "mintTick should be currentTick, which is inside the range");
        // liquidity = 600 * 1e18 / (80 - 20) = 10e18
        assertEq(liq, uint128(10e18), "liquidity should be usdcAmount * PRECISION / rangeWidth");
    }

    // SC-T7AH: tick 20 initialized: liquidityGross and liquidityNet updated
    function test_lowerTickInitializedCorrectly() public {
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        (uint128 liqGross, int128 liqNet,) = vault.ticks(tickLower);
        assertEq(liqGross, uint128(10e18), "tick 20 liquidityGross should equal position liquidity");
        assertEq(liqNet, int128(int256(uint256(10e18))), "tick 20 liquidityNet should be positive");
    }

    // SC-T7AH: tick 80 initialized: liquidityGross and liquidityNet updated
    function test_upperTickInitializedCorrectly() public {
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        (uint128 liqGross, int128 liqNet,) = vault.ticks(tickUpper);
        assertEq(liqGross, uint128(10e18), "tick 80 liquidityGross should equal position liquidity");
        assertEq(liqNet, -int128(int256(uint256(10e18))), "tick 80 liquidityNet should be negative");
    }

    // SC-T7AH: activeLiquidity increased (position is in-range)
    function test_activeLiquidityIncreasedForInRangePosition() public {
        uint128 before_ = vault.activeLiquidity();
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        assertEq(vault.activeLiquidity(), before_ + uint128(10e18), "activeLiquidity should increase");
    }

    // SC-T7AH: the interior mint tick 50 is initialized as a crossable tick, the NO sub-range
    // [50, 80) is booked at 50 and at 80, and the in-range mint enters on the NO side
    // (FR-T7AV, FEAT-TVS0 ADR-COEW)
    function test_interiorMintTickIsInitializedAndTheNoSubRangeIsBooked() public {
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        (uint128 liqGross, int128 liqNet, int128 noNet) = vault.ticks(int24(50));
        assertEq(liqGross, uint128(10e18), "tick 50 liquidityGross counts the position");
        assertEq(liqNet, 0, "tick 50 liquidityNet is zero: no position bounds it");
        assertEq(noNet, int128(int256(uint256(10e18))), "tick 50 noLiquidityNet starts the NO sub-range");
        (,, int128 noNetUpper) = vault.ticks(tickUpper);
        assertEq(noNetUpper, -int128(int256(uint256(10e18))), "tick 80 noLiquidityNet ends the NO sub-range");
        assertEq((vault.tickBitmap(int16(0)) >> 50) & 1, 1, "tick 50's bitmap bit is set");
        assertEq(vault.noSideLiquidity(), uint128(10e18), "the mint enters on the NO side");
        assertEq(vault.totalUsdcOwedScaled(), uint256(10e18) * 60 * 10_000, "the ledger credits the deposit");
    }

    // SC-T7AH: the mint moves no USDC; the escrow already holds it
    function test_mintMovesNoUsdc() public {
        uint256 safeBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        assertEq(vaultBefore, usdcAmount, "precondition: the escrow put 600 USDC in the vault");

        _mint(tickLower, tickUpper, usdcAmount, intentId);

        assertEq(mockUsdc.balanceOf(lp), safeBefore, "the Safe's balance must not change at the mint");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "the vault's balance must not change at the mint");
    }

    // SC-T7AH: the escrow is consumed and totalEscrowed falls by 600
    function test_mintConsumesEscrow() public {
        assertEq(vault.totalEscrowed(), usdcAmount, "precondition: 600 escrowed");

        _mint(tickLower, tickUpper, usdcAmount, intentId);

        (address recorded, uint96 amount, bytes32 structHash) = vault.pendingDeposits(intentId);
        assertEq(recorded, address(0), "escrow entry should be deleted");
        assertEq(amount, 0, "escrow amount should be deleted");
        assertEq(structHash, bytes32(0), "escrow hash should be deleted");
        assertEq(vault.totalEscrowed(), 0, "totalEscrowed should fall by the escrowed amount");
    }

    // SC-T7AH: PositionMinted event emitted with the Safe as owner and the mint tick
    function test_emitsPositionMintedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionMinted(0, lp, tickLower, tickUpper, int24(50), uint128(10e18), usdcAmount, intentId);

        _mint(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-T7AH: intentId recorded as used
    function test_intentIdRecordedAsUsed() public {
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
    }

    // SC-T7AH: nextPositionId incremented
    function test_nextPositionIdIncremented() public {
        uint256 before_ = vault.nextPositionId();
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        assertEq(vault.nextPositionId(), before_ + 1, "nextPositionId should increment");
    }
}

// ──────────────────────────────────────────────
// SC-T7AI: Successful out-of-range mint (above current tick)
// What: When the LP's range is entirely above the current tick, the position
//       is created but activeLiquidity does NOT increase. Both ticks are
//       initialized with the position's liquidity.
// Why:  Out-of-range positions do not count in activeLiquidity until the
//       price moves into their range. Getting this wrong would misclassify
//       which positions are in range.
// ──────────────────────────────────────────────
contract MintPositionOutOfRangeTest is MintPositionTestBase {
    int24 tickLower = int24(60);
    int24 tickUpper = int24(90);
    uint256 usdcAmount = 300;
    bytes32 intentId = keccak256("intent-oor");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
        _escrowIntent(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-T7AI: activeLiquidity unchanged for out-of-range position
    function test_activeLiquidityUnchangedWhenOutOfRange() public {
        uint128 before_ = vault.activeLiquidity();
        _mint(tickLower, tickUpper, usdcAmount, intentId);

        assertEq(vault.activeLiquidity(), before_, "activeLiquidity should NOT change for out-of-range");
    }

    // SC-T7AI: position created for the Safe and the escrow consumed, with no USDC moved
    function test_positionCreatedAndEscrowConsumed() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 posId = _mint(tickLower, tickUpper, usdcAmount, intentId);

        (address owner,,,, uint128 liq) = vault.positions(posId);
        assertEq(owner, lp, "position owner should be the LP's Safe");
        // liquidity = 300 * 1e18 / 30 = 10e18
        assertEq(liq, uint128(10e18), "liquidity should be correct");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "no USDC should move at the mint");
        assertEq(vault.totalEscrowed(), 0, "totalEscrowed should fall by 300");
    }
}

// ──────────────────────────────────────────────
// SC-T7AJ: Second position on existing tick
// What: When a new position references a tick that already has liquidity
//       (from a prior mint), the tick stays initialized and only
//       liquidityGross/Net are accumulated.
// Why:  A shared tick must count every position that references it, so a
//       later burn of one position leaves the tick live for the other.
// ──────────────────────────────────────────────
contract MintPositionExistingTickTest is MintPositionTestBase {
    bytes32 intentId1 = keccak256("intent-first");
    bytes32 intentId2 = keccak256("intent-second");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));

        // First mint establishes tick 20 and tick 60
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(20), int24(60), 400, intentId1);
    }

    // SC-T7AJ: second position accumulates liquidityGross on shared tick
    function test_liquidityGrossAccumulatesOnExistingTick() public {
        (uint128 liqGrossBefore,,) = vault.ticks(int24(20));

        _escrowAndMint(vault, operatorAddr, LP_PK, int24(20), int24(80), 600, intentId2);

        // Second position liquidity: 600 * 1e18 / 60 = 10e18
        (uint128 liqGrossAfter,,) = vault.ticks(int24(20));
        assertEq(liqGrossAfter, liqGrossBefore + uint128(10e18), "liquidityGross should accumulate");
    }

    // SC-T7AJ: the second mint deletes its own escrow and leaves totalEscrowed at 0
    function test_secondMintConsumesItsEscrow() public {
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(20), int24(80), 600, intentId2);

        (address recorded,,) = vault.pendingDeposits(intentId2);
        assertEq(recorded, address(0), "second escrow should be deleted");
        assertEq(vault.totalEscrowed(), 0, "no escrow should remain");
    }
}

// ──────────────────────────────────────────────
// SC-AFPN: Mint tick clamps into the range when the price is outside it
// What: A position records currentTick as its mintTick when the price is
//       inside its range, tickLower when the price is below the range, and
//       tickUpper when the price is at or above it. The event carries the
//       same value as the record.
// Why:  FR-AFPO and ADR-AFPP: the claim model (decision C26) values a claim
//       from its mint tick, and the clamp gives two positions minted on the
//       same side of their range the same mint tick, so they can merge.
// Example: currentTick = 50. [60, 90) stores 60, [0, 30) stores 30,
//          [20, 80) stores 50.
// ──────────────────────────────────────────────
contract MintTickClampTest is MintPositionTestBase {
    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
    }

    function _mintTickOf(uint256 posId) internal view returns (int24 mintTick) {
        (,,, mintTick,) = vault.positions(posId);
    }

    // SC-AFPN: below the range, the mint tick clamps up to tickLower
    function test_whenPriceIsBelowTheRangeThenMintTickIsTickLower() public {
        uint256 posId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(60), int24(90), 300, keccak256("below"));
        assertEq(_mintTickOf(posId), int24(60), "mintTick should clamp up to tickLower");
    }

    // SC-AFPN: at or above the range, the mint tick clamps down to tickUpper
    function test_whenPriceIsAboveTheRangeThenMintTickIsTickUpper() public {
        uint256 posId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(30), 300, keccak256("above"));
        assertEq(_mintTickOf(posId), int24(30), "mintTick should clamp down to tickUpper");
    }

    // SC-AFPN: inside the range, the mint tick is currentTick, and only this position is in range
    function test_whenPriceIsInsideTheRangeThenMintTickIsCurrentTick() public {
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(60), int24(90), 300, keccak256("below"));
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(30), 300, keccak256("above"));
        uint256 posId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(20), int24(80), 600, keccak256("inside"));

        assertEq(_mintTickOf(posId), int24(50), "mintTick should be currentTick");
        (,,,, uint128 liquidity) = vault.positions(posId);
        assertEq(vault.activeLiquidity(), liquidity, "only the in-range position counts toward activeLiquidity");
    }

    // SC-AFPN: the event carries the clamped value the record stores
    function test_eventCarriesTheClampedMintTick() public {
        bytes32 intentId = keccak256("event-below");
        _escrowIntent(int24(60), int24(90), 300, intentId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionMinted(0, lp, int24(60), int24(90), int24(60), uint128(10e18), 300, intentId);
        _mint(int24(60), int24(90), 300, intentId);
    }
}

// ──────────────────────────────────────────────
// SC-T7AK: Inverted range revert
// SC-T7AL: Misaligned tick revert
// SC-T7AM: Non-active vault revert
// SC-T7AR: Zero amount revert
// What: Validation checks reject structurally invalid mint requests before
//       any state is touched. Each fires a distinct custom error, and each
//       fires before the escrow is read, so no escrow is needed to reach it.
// Why:  Early reverts protect the vault from recording positions with
//       impossible ranges, misaligned ticks, or zero liquidity. They also
//       prevent minting into a wound-down vault.
// ──────────────────────────────────────────────
contract MintPositionValidationTest is MintPositionTestBase {
    // SC-T7AK: tickLower >= tickUpper reverts with InvalidRange
    function test_revertsOnInvertedRange() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(80), int24(20), 600, keccak256("inv"), FAR_DEADLINE);
    }

    // SC-T7AK: tickLower == tickUpper reverts with InvalidRange
    function test_revertsOnEqualTicks() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(50), int24(50), 600, keccak256("eq"), FAR_DEADLINE);
    }

    // SC-T7AK, FR-T7B2: a negative lower tick is outside the price scale
    function test_revertsWhenLowerTickIsBelowZero() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(-10), int24(20), 600, keccak256("neg"), FAR_DEADLINE);
    }

    // SC-T7AK, FR-T7B2: an upper tick above PRICE_TICK_ONE is outside the price scale
    function test_revertsWhenUpperTickIsAbovePriceOne() public {
        assertEq(vault.PRICE_TICK_ONE(), int24(10000), "precondition: one tick is one basis point");
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(9990), int24(10010), 600, keccak256("over"), FAR_DEADLINE);
    }

    // SC-T7AL: tick not aligned to tickSpacing reverts with TickNotAligned
    function test_revertsOnMisalignedLowerTick() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TickNotAligned.selector);
        vault.mintPositionFor(lp, int24(15), int24(80), 600, keccak256("mis"), FAR_DEADLINE);
    }

    // SC-T7AL: misaligned upper tick also reverts
    function test_revertsOnMisalignedUpperTick() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TickNotAligned.selector);
        vault.mintPositionFor(lp, int24(20), int24(75), 600, keccak256("mis2"), FAR_DEADLINE);
    }

    // SC-T7AM: mint on a non-active vault reverts with VaultNotActive, even for an escrowed intent
    function test_revertsWhenVaultNotActive() public {
        bytes32 intentId = keccak256("wd");
        _escrowIntent(int24(20), int24(80), 600, intentId);

        // Move the vault to WindDown (phase 2) through the Oracle
        vm.prank(oracleAddr);
        vault.startWindDown();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, FAR_DEADLINE);
    }

    // SC-T7AR: usdcAmount == 0 reverts with ZeroAmount
    function test_revertsOnZeroAmount() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 0, keccak256("zero"), FAR_DEADLINE);
    }
}

// ──────────────────────────────────────────────
// SC-T7AN: Non-operator caller revert
// What: Only registered Operators can call mintPositionFor. All other
//       callers — the LP's Safe, Admin, Oracle, arbitrary addresses — get NotOperator.
// Why:  FR-RFS6 from FEAT-REPZ mandates operator-only position creation
//       to eliminate the first-LP inflation attack vector.
// ──────────────────────────────────────────────
contract MintPositionAccessControlTest is MintPositionTestBase {
    bytes32 intentId = keccak256("access");

    function setUp() public override {
        super.setUp();
        _escrowIntent(int24(20), int24(80), 600, intentId);
    }

    function _mintAs(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, FAR_DEADLINE);
    }

    // SC-T7AN: the LP's Safe calling directly reverts
    function test_revertsWhenLpCallsDirectly() public {
        _mintAs(lp);
    }

    // SC-T7AN: Admin calling reverts
    function test_revertsWhenAdminCalls() public {
        _mintAs(admin);
    }

    // SC-T7AN: Oracle calling reverts
    function test_revertsWhenOracleCalls() public {
        _mintAs(oracleAddr);
    }

    // SC-T7AN: arbitrary address calling reverts
    function test_revertsWhenNobodyCalls() public {
        _mintAs(makeAddr("nobody"));
    }
}

// ──────────────────────────────────────────────
// SC-T7AO: First mint below minimum liquidity
// SC-AFPM: Small mint succeeds after active liquidity returns to zero
// What: When nextPositionId == 0 and the computed liquidity from the mint
//       falls below minimumFirstLiquidity, the call reverts with
//       BelowMinimumFirstLiquidity, and the escrow stays in place. Once one
//       position exists the floor never applies again, even when the price
//       sits in a range with no position and activeLiquidity is zero.
// Why:  FR-RFS7 from FEAT-REPZ prevents a tiny first position from
//       manipulating the fee accumulator (the v3 analog of the ERC-4626
//       first-depositor inflation attack). Audit issue 6.9 (decision C15):
//       the old activeLiquidity == 0 condition re-applied the floor whenever
//       the price entered an empty range, which blocked small LPs.
// ──────────────────────────────────────────────
contract MintPositionFirstMintFloorTest is MintPositionTestBase {
    // SC-T7AO: first mint with liquidity below floor reverts, and the escrow survives for a reclaim
    function test_revertsWhenFirstMintBelowFloor() public {
        // minFirstLiq = 10e18. A mint of 1 USDC across [0, 10] gives
        // liquidity = 1 * 1e18 / 10 = 0.1e18 = 1e17, which is < 10e18.
        bytes32 intentId = keccak256("tiny");
        _escrowIntent(int24(0), int24(10), 1, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.BelowMinimumFirstLiquidity.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), 1, intentId, FAR_DEADLINE);

        (address recorded, uint96 amount,) = vault.pendingDeposits(intentId);
        assertEq(recorded, lp, "escrow should stay in place after the failed mint");
        assertEq(amount, 1, "escrow amount should be untouched");
    }

    // SC-T7AO: first mint with liquidity at exactly the floor succeeds
    function test_succeedsWhenFirstMintMeetsFloor() public {
        // minFirstLiq = 10e18. A mint of 100 USDC across [0, 10] gives
        // liquidity = 100 * 1e18 / 10 = 10e18, which == 10e18. Should succeed.
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(10), 100, keccak256("ok"));

        assertGt(vault.activeLiquidity(), 0, "activeLiquidity should be non-zero after first mint");
    }

    /// @dev One floor-sized position over [100, 200) at tick 150 (1000 USDC / 100 ticks = 10e18),
    ///      then a move to 250, where no position exists, so activeLiquidity returns to zero.
    function _mintFloorSizedThenLeaveEveryRange() internal {
        _setCurrentTick(int24(150));
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(100), int24(200), 1000, keccak256("floor-sized"));
        vm.prank(operatorAddr);
        vault.updateTick(int24(250));
        assertEq(vault.activeLiquidity(), 0, "the move out of every range must empty activeLiquidity");
    }

    // SC-AFPM: a 1-USDC mint over [0, 10) (liquidity 1e17 < 10e18) succeeds once a position exists
    function test_whenActiveLiquidityReturnsToZeroThenSmallMintSucceeds() public {
        _mintFloorSizedThenLeaveEveryRange();

        bytes32 intentId = keccak256("small-after-first");
        _escrowIntent(int24(0), int24(10), 1, intentId);
        uint256 posId = _mint(int24(0), int24(10), 1, intentId);

        (,,,, uint128 liquidity) = vault.positions(posId);
        assertEq(liquidity, uint128(1e17), "the small position must exist with its computed liquidity");
        assertEq(vault.activeLiquidity(), 0, "the small position is out of range, so activeLiquidity stays 0");
    }

    // FR-RFS7: the floor rejects a random small amount as the first mint, and accepts the same
    // amount once one position exists and the price has left every range
    function testFuzz_floorAppliesToTheFirstMintOnly(uint256 usdcAmount) public {
        // liquidity = usdcAmount * 1e18 / 10 < 10e18 for every amount in [1, 99]
        usdcAmount = bound(usdcAmount, 1, 99);
        bytes32 intentId = keccak256(abi.encode("fuzz-small", usdcAmount));
        _escrowIntent(int24(0), int24(10), usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.BelowMinimumFirstLiquidity.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), usdcAmount, intentId, FAR_DEADLINE);

        _mintFloorSizedThenLeaveEveryRange();

        // The failed mint left the escrow in place, so the same intent mints now
        uint256 posId = _mint(int24(0), int24(10), usdcAmount, intentId);
        (,,,, uint128 liquidity) = vault.positions(posId);
        assertEq(
            liquidity, uint128(usdcAmount * LIQUIDITY_PRECISION / 10), "the small mint must succeed after the first"
        );
    }
}

// ──────────────────────────────────────────────
// SC-T7AP: Duplicate intentId revert
// What: Reusing an intentId that was already consumed in a successful mint
//       reverts with IntentAlreadyUsed before the escrow is read. The
//       usedIntents mapping is write-once.
// Why:  Replay protection prevents the same intent from being executed
//       twice — the LP only authorized one mint per intentId.
// ──────────────────────────────────────────────
contract MintPositionReplayProtectionTest is MintPositionTestBase {
    bytes32 intentId = keccak256("replay-me");

    // SC-T7AP: second use of the same intentId reverts, and reports the replay, not the missing escrow
    function test_revertsOnDuplicateIntentId() public {
        // First use succeeds
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(10), 100, intentId);

        // Second use reverts
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), 100, intentId, FAR_DEADLINE);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9J: Revert when no deposit is escrowed for the intent
// SC-45IE: Revert when the escrow belongs to a different Safe
// SC-3Z9K: Revert when the recorded hash does not match the arguments
// What: The escrow record is the mint's only proof of deposit and of
//       ownership. No escrow → DepositNotEscrowed. Another Safe's escrow →
//       NotIntentOwner, before the hash compare. A changed range, amount, or
//       deadline → IntentMismatch.
// Why:  Audit NM-0986 issues 6.1 and 6.2: no position without recorded USDC,
//       and never a second pull. A valid signature never proves who owns an
//       intentId, and the mint checks no signature at all, so the recorded
//       Safe is the only ownership proof (FR-45ID). The recorded hash is what
//       binds the intent's terms (FR-3Z9W).
// ──────────────────────────────────────────────
contract MintPositionEscrowChecksTest is MintPositionTestBase {
    bytes32 intentId = keccak256("escrowed");

    function setUp() public override {
        super.setUp();
        _escrowIntent(int24(20), int24(80), 600, intentId);
    }

    // SC-3Z9J: no escrow for the intentId
    function test_revertsWhenNothingEscrowed() public {
        bytes32 unknown = keccak256("never-escrowed");
        uint256 nextBefore = vault.nextPositionId();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, unknown, FAR_DEADLINE);

        assertEq(vault.nextPositionId(), nextBefore, "no position created");
        assertFalse(vault.usedIntents(unknown), "usedIntents unchanged");
    }

    // SC-45IE: the escrow belongs to Safe A, and the Operator names Safe B
    function test_revertsWhenEscrowBelongsToAnotherSafe() public {
        address safeB = _safeOf(vm.addr(0xB0B));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.mintPositionFor(safeB, int24(20), int24(80), 600, intentId, FAR_DEADLINE);

        (address recorded, uint96 amount,) = vault.pendingDeposits(intentId);
        assertEq(recorded, lp, "A's escrow is untouched");
        assertEq(amount, 600, "A's escrow amount is untouched");
    }

    // SC-3Z9K: a different range reverts IntentMismatch
    function test_revertsOnDifferentRange() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentMismatch.selector);
        vault.mintPositionFor(lp, int24(20), int24(90), 600, intentId, FAR_DEADLINE);
    }

    // SC-3Z9K: a different amount reverts IntentMismatch
    function test_revertsOnDifferentAmount() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentMismatch.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 500, intentId, FAR_DEADLINE);
    }

    // SC-3Z9K: a different deadline reverts IntentMismatch
    function test_revertsOnDifferentDeadline() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentMismatch.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, FAR_DEADLINE - 1);
    }

    // SC-3Z9K: a mismatch leaves the escrow in place with its recorded terms
    function test_mismatchLeavesEscrowInPlace() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentMismatch.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 500, intentId, FAR_DEADLINE);

        (address recorded, uint96 amount,) = vault.pendingDeposits(intentId);
        assertEq(recorded, lp, "escrow should stay recorded for the Safe");
        assertEq(amount, 600, "escrow amount should be unchanged");
        assertEq(vault.totalEscrowed(), 600, "totalEscrowed should be unchanged");
    }

    // SC-3Z9K: the mint reads no clock: a deposit made near its deadline still mints after it
    function test_mintSucceedsAfterTheDeadlineHasPassed() public {
        bytes32 lateIntent = keccak256("near-deadline");
        uint256 deadline = block.timestamp + 10;
        _fundSafe(mockUsdc, lp, address(vault), 600);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(20), int24(80), 600, lateIntent, deadline);

        vm.warp(deadline + 1 days);

        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, int24(20), int24(80), 600, lateIntent, deadline);

        (address owner,,,,) = vault.positions(posId);
        assertEq(owner, lp, "the mint should succeed after the deposit's deadline passed");
    }
}

// ──────────────────────────────────────────────
// SC-3XU5, SC-3XU6: Minting feeds the Operator silence timer
// What: A successful mintPositionFor refreshes lastOperatorActivityTimestamp;
//       a mint that reverts leaves it exactly where it was.
// Why:  Processing LP deposits is real Operator work and should count as proof
//       of life against the emergency-cancel timelock (FEAT-JXQO, FR-JXQS).
//       A failed call must not count — otherwise a broken Operator could prove
//       liveness by failing repeatedly.
// Example: warp a day forward, mint succeeds → timer == block.timestamp;
//          replay the same intentId → reverts, timer unchanged.
// ──────────────────────────────────────────────
contract MintRefreshesOperatorSilenceTimerTest is MintPositionTestBase {
    // SC-3XU5: a successful mint advances the timer to the current block
    function test_successfulMintRefreshesSilenceTimer() public {
        bytes32 intentId = keccak256("mint-refreshes-timer");
        _escrowIntent(int24(20), int24(80), 600, intentId);

        // Move well past vault creation so a stale timer would be obvious
        vm.warp(block.timestamp + 1 days);

        _mint(int24(20), int24(80), 600, intentId);

        assertEq(
            vault.lastOperatorActivityTimestamp(), block.timestamp, "a successful mint should refresh the silence timer"
        );
    }

    // SC-3XU6: a mint rejected for a duplicate intentId leaves the timer alone
    function test_revertedMintOnDuplicateIntentLeavesSilenceTimerUntouched() public {
        bytes32 intentId = keccak256("mint-duplicate-intent");
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(20), int24(80), 600, intentId);

        uint256 timerAfterFirstMint = vault.lastOperatorActivityTimestamp();

        // Time passes, then the same intent is replayed and rejected
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, FAR_DEADLINE);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            timerAfterFirstMint,
            "a reverted mint must not count as proof of life"
        );
    }

    // SC-3XU6: the same holds for a mint rejected on range validation
    function test_revertedMintOnInvertedRangeLeavesSilenceTimerUntouched() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(80), int24(20), 600, keccak256("mint-inverted-range"), FAR_DEADLINE);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted mint must not count as proof of life");
    }
}
