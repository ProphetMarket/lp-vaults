// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-7G40: Burn LP Position
// UC-7G41: Burn Position
// Integration tests for every scenario in this use case, against the real ConditionalTokens
// bytecode: the claim model of decision C26, the merge-first rule, the pay-what-is-there rule
// (decision O2), and the tick deinitialization that closes audit issue 6.15.
// Covers: SC-7G43, SC-7G44, SC-7G45, SC-7G46, SC-7G47, SC-7G48, SC-7G49, SC-7G4A, SC-7G4B,
//         SC-BMF1, SC-BMF2, SC-BMF3

import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for burn scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, reports tick
// 6000, and mints the worked example of decision C26: 300 USDC over [5500, 6500), so
// liquidity = 300e6 * 1e18 / 1000 = 3e23 and mintTick = 6000. USDC has six decimals in
// every amount below.
// ──────────────────────────────────────────────
contract BurnPositionTestBase is LPVaultFixture {
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

    bytes32 marketId = bytes32(uint256(1));

    // The worked example
    int24 constant LOWER = 5500;
    int24 constant UPPER = 6500;
    int24 constant MINT_TICK = 6000;
    uint256 constant PRINCIPAL = 300e6;
    uint128 constant LIQUIDITY = 3e23;
    // The vault at 5700: the YES band [5700, 6000), 90 YES, and the USDC the band did not spend
    uint256 constant FELL_USDC = 247_354_500;
    // The vault at 6300: the NO band [6000, 6300), 90 NO
    uint256 constant ROSE_USDC = 265_345_500;
    // An outcome token has USDC's six decimals: 90 tokens are 90e6 units, worth 90 USDC at par
    uint256 constant BAND_TOKENS = 90e6;
    uint256 constant Q128 = 2 ** 128;

    uint256 positionId;

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
    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public virtual {
        safe = _safeOf(vm.addr(LP_PK));
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1)));

        _moveTick(MINT_TICK);
        positionId = _mintExample(LP_PK, keccak256("example"));
    }

    /// @dev Mints the worked example for the owner key `pk`.
    function _mintExample(uint256 pk, bytes32 intentId) internal returns (uint256) {
        return _escrowAndMint(vault, operatorAddr, pk, LOWER, UPPER, PRINCIPAL, intentId);
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    /// @dev Gives the vault outcome tokens, as the keeper's fills would.
    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    /// @dev Moves USDC out of the vault through the exchange's standing approval, as a fill
    ///      would (decision C8). This is how a test makes the vault short.
    function _drainThroughExchange(uint256 amount) internal {
        vm.prank(exchangeAddr);
        mockUsdc.transferFrom(address(vault), exchangeAddr, amount);
    }

    function _yesOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.yesTokenId());
    }

    function _noOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.noTokenId());
    }

    function _burn(uint256 id) internal {
        vm.prank(safe);
        vault.burnPosition(id);
    }

    function _bitIsSet(int24 tick) internal view returns (bool) {
        int16 wordPos = int16(tick >> 8);
        uint8 bitPos = uint8(uint24(tick) & 0xff);
        return (vault.tickBitmap(wordPos) >> bitPos) & 1 == 1;
    }

    function _assertDeleted(uint256 id) internal view {
        (address owner, int24 tl, int24 tu, int24 mt, uint128 liq, uint256 snap, uint256 owed) = vault.positions(id);
        assertEq(owner, address(0), "owner should be zero");
        assertEq(tl, 0, "tickLower should be zero");
        assertEq(tu, 0, "tickUpper should be zero");
        assertEq(mt, 0, "mintTick should be zero");
        assertEq(liq, 0, "liquidity should be zero");
        assertEq(snap, 0, "snapshot should be zero");
        assertEq(owed, 0, "tokensOwed should be zero");
    }

    /// @dev The one PositionBurned log of a burn, decoded.
    function _burnedLog(Vm.Log[] memory logs)
        internal
        pure
        returns (
            uint256 usdcOwed,
            uint256 feesOwed,
            uint256 usdcPaid,
            uint256 tokenId,
            uint256 tokenOwed,
            uint256 tokenPaid
        )
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PositionBurned.selector) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            }
        }
        revert("a burn must emit PositionBurned");
    }
}

// ──────────────────────────────────────────────
// SC-7G43: Burn at the mint tick pays the whole principal in USDC
// What: With the vault at the mint tick, the burn pays 300 USDC, no token, deletes the
//       record, removes the liquidity from both ticks and from activeLiquidity, and
//       leaves the heartbeat alone.
// Why:  No level was crossed, so every level still holds its USDC. This is the base
//       case of the claim model and the parity anchor for the relayed path.
// ──────────────────────────────────────────────
contract BurnAtMintTickTest is BurnPositionTestBase {
    // SC-7G43: the Safe receives exactly 300 USDC and no token
    function test_whenAtMintTickThenSafeReceivesWholePrincipal() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe should receive 300 USDC");
        assertEq(_yesOf(safe), 0, "no YES");
        assertEq(_noOf(safe), 0, "no NO");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault paid everything it held");
    }

    // SC-7G43: PositionBurned carries the exact amounts, with tokenId zero
    function test_whenAtMintTickThenEventCarriesUsdcOnly() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, PRINCIPAL, 0, 0, 0);

        _burn(positionId);
    }

    // SC-7G43: the record is deleted and cannot be burned or collected again
    function test_whenBurnedThenRecordIsDeleted() public {
        _burn(positionId);

        _assertDeleted(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.collect(positionId);
    }

    // SC-7G43: both ticks lose the liquidity, and activeLiquidity falls by it
    function test_whenBurnedThenTicksAndActiveLiquidityFall() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY, "precondition: in range");

        _burn(positionId);

        (uint128 gLower, int128 nLower,) = vault.ticks(LOWER);
        (uint128 gUpper, int128 nUpper,) = vault.ticks(UPPER);
        assertEq(gLower, 0, "tick 5500 liquidityGross");
        assertEq(nLower, 0, "tick 5500 liquidityNet");
        assertEq(gUpper, 0, "tick 6500 liquidityGross");
        assertEq(nUpper, 0, "tick 6500 liquidityNet");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should fall by the position's liquidity");
    }

    // SC-7G43: the self-service burn never refreshes the heartbeat
    function test_whenBurnedThenHeartbeatIsUnchanged() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 3 days);

        _burn(positionId);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "burnPosition must not touch the heartbeat");
    }

    // SC-7G43: no ERC-1155 transfer and no merge when the vault holds no token
    function test_whenAtMintTickThenNoTokenTransferAndNoMerge() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != TransferSingle.selector, "no ERC-1155 transfer");
            assertTrue(logs[i].topics[0] != CompleteSetsMerged.selector, "no merge");
        }
    }

    // FR-7G4T: the burned id is never reassigned
    function test_whenBurnedThenIdIsRetired() public {
        _burn(positionId);

        uint256 nextId = _mintExample(LP_B_PK, keccak256("after-burn"));
        assertEq(nextId, positionId + 1, "a later mint draws the next id, never the burned one");
    }
}

// ──────────────────────────────────────────────
// SC-7G44: Burn after the price fell pays USDC plus YES
// What: The vault moved to 5700, so the YES band is [5700, 6000): 90 YES, and
//       3e23 * (1000 * 10000 - 1,754,850) / 1e22 = 247,354,500 USDC units.
// Why:  Below the mint tick a level bought YES at its own price when the price fell
//       through it. The vault spent 52.6455 USDC on 90 YES, an average of 0.585.
// ──────────────────────────────────────────────
contract BurnAfterPriceFellTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
    }

    // SC-7G44: the Safe receives 247.3545 USDC and 90 YES
    function test_whenPriceFellThenSafeReceivesUsdcPlusYes() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the USDC leg");
        assertEq(_yesOf(safe), BAND_TOKENS, "the YES leg");
        assertEq(_noOf(safe), 0, "no NO");
    }

    // SC-7G44: PositionBurned names the YES token and the exact amounts
    function test_whenPriceFellThenEventNamesYes() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, 0, FELL_USDC, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);

        _burn(positionId);
    }

    // NFR-7G59: the ERC-1155 transfer is the last external call, after the USDC transfer
    function test_whenPriceFellThenTokenTransferIsLast() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 usdcAt = type(uint256).max;
        uint256 tokenAt = type(uint256).max;
        uint256 burnedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Transfer.selector && logs[i].emitter == address(mockUsdc)) usdcAt = i;
            if (logs[i].topics[0] == TransferSingle.selector) tokenAt = i;
            if (logs[i].topics[0] == PositionBurned.selector) burnedAt = i;
        }
        assertLt(usdcAt, tokenAt, "USDC before the token");
        assertLt(tokenAt, burnedAt, "the token before the event");
    }

    // FR-7G4N: no call reaches the exchange
    function test_whenPriceFellThenExchangeIsNeverCalled() public {
        uint256 exchangeBefore = mockUsdc.balanceOf(exchangeAddr);
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(exchangeAddr), exchangeBefore, "the exchange is not part of a burn");
        assertEq(exchangeAddr.code.length, 0, "the exchange stub has no code, so any call would revert");
    }
}

// ──────────────────────────────────────────────
// SC-7G45: Burn after the price rose pays USDC plus NO
// What: The vault moved to 6300, so the NO band is [6000, 6300): 90 NO, and
//       3e23 * (700 * 10000 + 1,844,850) / 1e22 = 265,345,500 USDC units.
// Why:  At or above the mint tick a level bought NO at one minus its price when the
//       price rose through it. The vault spent 34.6545 USDC on 90 NO, an average NO
//       price of 0.38505.
// ──────────────────────────────────────────────
contract BurnAfterPriceRoseTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(6300);
        _fundVault(0, BAND_TOKENS);
    }

    // SC-7G45: the Safe receives 265.3455 USDC and 90 NO
    function test_whenPriceRoseThenSafeReceivesUsdcPlusNo() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), ROSE_USDC, "the USDC leg");
        assertEq(_noOf(safe), BAND_TOKENS, "the NO leg");
        assertEq(_yesOf(safe), 0, "no YES");
    }

    // SC-7G45: PositionBurned names the NO token and the exact amounts
    function test_whenPriceRoseThenEventNamesNo() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, ROSE_USDC, 0, ROSE_USDC, vault.noTokenId(), BAND_TOKENS, BAND_TOKENS);

        _burn(positionId);
    }

    // FR-7G4Q: at 6300 the position is in range, so activeLiquidity falls
    function test_whenPriceRoseThenActiveLiquidityFalls() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY, "precondition: in range at 6300");
        _burn(positionId);
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should fall by the position's liquidity");
    }
}

// ──────────────────────────────────────────────
// SC-7G46: Burn pays accrued fees with the USDC leg
// What: With F in fees notified since the mint, the burn pays 300 USDC plus F in one
//       transfer, PositionBurned.feesOwed == F, and no FeesCollected is emitted.
// Why:  Closing a position must strand no fee, and one transfer costs less than two.
// ──────────────────────────────────────────────
contract BurnPaysFeesTest is BurnPositionTestBase {
    uint256 constant FEES = 500e6;

    function setUp() public override {
        super.setUp();
        _notifyFees(vault, operatorAddr, FEES);
    }

    /// @dev What collect would pay: liquidity * feeGrowthInside / Q128, with the Q128
    ///      truncation dust the accumulator leaves (one unit here).
    function _expectedFees() internal view returns (uint256) {
        return uint256(LIQUIDITY) * vault.feeGrowthGlobalX128() / Q128;
    }

    // SC-7G46: the Safe receives the principal plus the fees in one call
    function test_whenFeesAccruedThenBurnPaysThemWithPrincipal() public {
        uint256 fees = _expectedFees();
        assertEq(fees, FEES - 1, "precondition: the accumulator truncates one unit of dust");

        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL + fees, "principal plus fees");
    }

    // SC-7G46: feesOwed carries F, and usdcPaid carries the sum
    function test_whenFeesAccruedThenEventCarriesFees() public {
        uint256 fees = _expectedFees();

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, fees, PRINCIPAL + fees, 0, 0, 0);

        _burn(positionId);
    }

    // SC-7G46: one USDC transfer, no FeesCollected
    function test_whenFeesAccruedThenOneTransferAndNoFeesCollected() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transfers = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Transfer.selector && logs[i].emitter == address(mockUsdc)) transfers++;
            assertTrue(logs[i].topics[0] != FeesCollected.selector, "no FeesCollected on a burn");
        }
        assertEq(transfers, 1, "one USDC transfer covers the principal and the fees");
    }

    // SC-7G46: a later collect reverts, because the position is gone
    function test_whenBurnedThenCollectReverts() public {
        _burn(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.collect(positionId);
    }
}

// ──────────────────────────────────────────────
// SC-7G47: Burning the last position at a tick deinitializes it
// What: Safe B holds [5500, 6000), so tick 5500 stays referenced and tick 6500 is
//       referenced only by the example. After the burn, ticks[6500] reads zero and its
//       bitmap bit is clear; ticks[5500] keeps its record and its bit. A later move from
//       6400 to 6600 crosses nothing.
// Why:  Audit issue 6.15: a set bit must mean liquidityGross > 0, or updateTick would
//       cross a tick with no liquidity behind it.
// ──────────────────────────────────────────────
contract BurnDeinitializesTickTest is BurnPositionTestBase {
    uint256 positionB;

    function setUp() public override {
        super.setUp();
        positionB = _escrowAndMint(vault, operatorAddr, LP_B_PK, LOWER, MINT_TICK, 100e6, keccak256("b"));
        assertTrue(_bitIsSet(UPPER), "precondition: tick 6500 is set");
        assertTrue(_bitIsSet(LOWER), "precondition: tick 5500 is set");
    }

    // SC-7G47: tick 6500 is deleted and its bit cleared
    function test_whenLastReferenceBurnsThenTickIsDeinitialized() public {
        _burn(positionId);

        (uint128 gross, int128 net, uint256 outside) = vault.ticks(UPPER);
        assertEq(gross, 0, "tick 6500 liquidityGross");
        assertEq(net, 0, "tick 6500 liquidityNet");
        assertEq(outside, 0, "tick 6500 feeGrowthOutside");
        assertFalse(_bitIsSet(UPPER), "tick 6500 bit must be clear");
    }

    // SC-7G47: tick 5500 keeps its bit, its net, and its feeGrowthOutside
    function test_whenAnotherReferenceRemainsThenTickIsPreserved() public {
        (uint128 grossBefore, int128 netBefore, uint256 outsideBefore) = vault.ticks(LOWER);

        _burn(positionId);

        (uint128 gross, int128 net, uint256 outside) = vault.ticks(LOWER);
        assertEq(gross, grossBefore - LIQUIDITY, "tick 5500 liquidityGross decreased by the example's liquidity");
        assertEq(net, netBefore - int128(LIQUIDITY), "tick 5500 liquidityNet decreased by the example's liquidity");
        assertEq(outside, outsideBefore, "tick 5500 feeGrowthOutside preserved");
        assertTrue(_bitIsSet(LOWER), "tick 5500 bit must stay set");
    }

    // SC-7G47: a later updateTick across 6500 crosses nothing
    function test_whenTickIsDeinitializedThenLaterMoveCrossesNothing() public {
        _moveTick(6400);
        _burn(positionId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(6400), int24(6600), 0);
        _moveTick(6600);
    }
}

// ──────────────────────────────────────────────
// SC-7G48: Revert when the caller is not the owner
// What: Safe B, the Operator, and the Admin each revert NotPositionOwner on Safe A's
//       position, which stays live.
// Why:  Timing control (ADR-7G5I): the claim depends on currentTick at call time.
// ──────────────────────────────────────────────
contract BurnNonOwnerTest is BurnPositionTestBase {
    function _expectNotOwner(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(positionId);
    }

    // SC-7G48: another Safe cannot burn it
    function test_whenAnotherSafeCallsThenReverts() public {
        _expectNotOwner(safeB);
    }

    // SC-7G48: the Operator cannot burn it directly
    function test_whenOperatorCallsThenReverts() public {
        _expectNotOwner(operatorAddr);
    }

    // SC-7G48: the Admin cannot burn it
    function test_whenAdminCallsThenReverts() public {
        _expectNotOwner(admin);
    }

    // SC-7G48: the position stays live and the owner can still burn it
    function test_whenRejectedThenPositionStaysLive() public {
        _expectNotOwner(safeB);

        (,,,, uint128 liq,,) = vault.positions(positionId);
        assertEq(liq, LIQUIDITY, "the position stays live");
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the owner still exits in full");
    }
}

// ──────────────────────────────────────────────
// SC-7G49: Burn in WindDown and in Cancelled succeeds identically to Active
// What: Case A: after startWindDown the burn pays the SC-7G43 amounts and the phase stays
//       WindDown. Case B: after a real emergencyCancelAll the burn reverts PositionNotFound,
//       because at this step the cancel zeroes every position.
// Why:  Decisions C5 and C9: no phase gates the exit. R10 turns case B into a payout.
// ──────────────────────────────────────────────
contract BurnPhaseTest is BurnPositionTestBase {
    // SC-7G49: case A — the same amounts in WindDown
    function test_whenWindDownThenBurnPaysAsInActive() public {
        vm.prank(oracleAddr);
        vault.startWindDown();

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, PRINCIPAL, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC in WindDown");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity falls as in Active");
        assertEq(vault.phase(), 2, "phase stays WindDown");
    }

    // SC-7G49: case A — the burn works while paused
    function test_whenPausedThenBurnSucceeds() public {
        vm.prank(admin);
        vault.pauseTrading();

        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC while paused");
    }

    // SC-7G49: case B — after the cancel the position is zeroed, so the burn reverts PositionNotFound
    function test_whenCancelledThenBurnRevertsPositionNotFound() public {
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
        vm.prank(safe);
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(positionId);
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-7G4A: Burn succeeds with zero registered operators
// What: The Admin removes the only Operator; the Safe still burns and receives 300 USDC.
// Why:  FR-7G4Z, NFR-7G5B: the escape hatch reads no Operator state.
// ──────────────────────────────────────────────
contract BurnWithNoOperatorTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
        assertEq(vault.operators(operatorAddr), 0, "precondition: no operator");
    }

    // SC-7G4A: the burn pays in full with no Operator
    function test_whenNoOperatorThenBurnPays() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC");
        _assertDeleted(positionId);
    }

    // SC-7G4A: no heartbeat write
    function test_whenNoOperatorThenHeartbeatUnchanged() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 10 days);

        _burn(positionId);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "no heartbeat write");
    }
}

// ──────────────────────────────────────────────
// SC-7G4B: Revert on a nonexistent, burned, or merged-away position
// What: A never-minted id, a burned id, and a position that mergePositions consumed each
//       revert PositionNotFound.
// Why:  A consumed position's liquidity already moved to a survivor; burning it would
//       touch the ticks by zero and could clear a bit the survivor needs.
// ──────────────────────────────────────────────
contract BurnNotFoundTest is BurnPositionTestBase {
    // SC-7G4B: case A — never minted
    function test_whenNeverMintedThenReverts() public {
        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(999);
    }

    // SC-7G4B: case B — already burned
    function test_whenAlreadyBurnedThenReverts() public {
        _burn(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(positionId);
    }

    // SC-7G4B: case C — consumed by a merge, so the owner is set and the liquidity is zero
    function test_whenMergedAwayThenReverts() public {
        uint256 second = _mintExample(LP_PK, keccak256("second"));
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);
        (address owner,,,, uint128 liq,,) = vault.positions(second);
        assertEq(owner, safe, "precondition: the consumed record keeps its owner");
        assertEq(liq, 0, "precondition: the consumed record has zero liquidity");

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(second);

        // The survivor still burns for both principals, and the ticks stay consistent
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), 2 * PRINCIPAL, "the survivor pays both principals");
        assertFalse(_bitIsSet(UPPER), "the last reference cleared the bit");
    }
}

// ──────────────────────────────────────────────
// SC-BMF1: Burn merges the vault's pairs first
// What: The vault holds 50 YES and 50 NO. The burn merges them, then pays 300 USDC, so the
//       vault's USDC falls by 250 net and both token balances read zero.
//       CompleteSetsMerged(safe, 50) precedes PositionBurned in the log.
// Why:  Decision C26: a pair is worth exactly 1 USDC, and a payout turns it into USDC first.
// ──────────────────────────────────────────────
contract BurnMergesFirstTest is BurnPositionTestBase {
    uint256 constant PAIRS = 50e6;

    function setUp() public override {
        super.setUp();
        _fundVault(PAIRS, PAIRS);
    }

    // SC-BMF1: the pairs are gone and the vault's USDC fell by 250 net
    function test_whenVaultHoldsPairsThenBurnMergesThem() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        _burn(positionId);

        assertEq(_yesOf(address(vault)), 0, "no YES after the merge");
        assertEq(_noOf(address(vault)), 0, "no NO after the merge");
        assertEq(vaultBefore - mockUsdc.balanceOf(address(vault)), PRINCIPAL - PAIRS, "300 out, 50 in");
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC");
    }

    // SC-BMF1: CompleteSetsMerged(safe, 50) precedes PositionBurned
    function test_whenVaultHoldsPairsThenMergeLogPrecedesBurnLog() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 mergedAt = type(uint256).max;
        uint256 burnedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CompleteSetsMerged.selector) {
                mergedAt = i;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), safe, "the caller is the Safe");
                assertEq(abi.decode(logs[i].data, (uint256)), PAIRS, "50 pairs merged");
            }
            if (logs[i].topics[0] == PositionBurned.selector) burnedAt = i;
        }
        assertLt(mergedAt, burnedAt, "the merge precedes the burn event");
    }
}

// ──────────────────────────────────────────────
// SC-BMF2: Burn pays what the vault holds when it is short
// What: Case A: the claim is 247.3545 USDC plus 90 YES, the vault holds 200 USDC and 60
//       YES; the burn pays 200 and 60, emits owed and paid, and deletes the record.
//       Case B: the vault's USDC balance is below totalEscrowed; the burn pays zero USDC
//       and does not revert. Case C: a vault richer than the claim pays the claim exactly.
// Why:  Decisions C6, C7, and O2. A checked subtraction would revert every exit once a
//       fill took the balance below the escrow total.
// Setup: the exchange's standing approval moves USDC out of the vault, as a fill would.
// ──────────────────────────────────────────────
contract BurnShortVaultTest is BurnPositionTestBase {
    // SC-BMF2: case A — short in USDC and in the token, per asset
    function test_whenVaultIsShortThenBurnPaysWhatItHolds() public {
        _moveTick(5700);
        _fundVault(60e6, 0);
        _drainThroughExchange(PRINCIPAL - 200e6);
        assertEq(mockUsdc.balanceOf(address(vault)), 200e6, "precondition: 200 USDC above escrow");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, 0, 200e6, vault.yesTokenId(), BAND_TOKENS, 60e6);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 200e6, "the USDC the vault held");
        assertEq(_yesOf(safe), 60e6, "the YES the vault held");
        _assertDeleted(positionId);
    }

    // SC-BMF2: case B — a balance below totalEscrowed pays zero USDC and does not revert
    function test_whenBalanceIsBelowEscrowThenBurnPaysZeroUsdc() public {
        // Safe B escrows 500 USDC that the Operator never mints
        _fundSafe(mockUsdc, safeB, address(vault), 500e6);
        _escrow(vault, operatorAddr, LP_B_PK, safeB, LOWER, UPPER, 500e6, keccak256("escrow-b"), FAR_DEADLINE);
        assertEq(vault.totalEscrowed(), 500e6, "precondition: escrow recorded");
        _drainThroughExchange(400e6);
        assertLt(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "precondition: below escrow");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, 0, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 0, "nothing to pay");
        assertEq(vault.totalEscrowed(), 500e6, "escrowed USDC never pays a burn");
        _assertDeleted(positionId);
    }

    // SC-BMF2: case C — a vault richer than the claim pays the claim exactly
    function test_whenVaultIsRichThenBurnPaysClaimExactly() public {
        _moveTick(5700);
        _fundVault(500e6, 0);
        mockUsdc.mint(address(vault), 1_000e6);

        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the claim's USDC, not more");
        assertEq(_yesOf(safe), BAND_TOKENS, "the claim's YES, not more");
        assertEq(_yesOf(address(vault)), 500e6 - BAND_TOKENS, "the vault keeps the rest");
    }

    // SC-BMF2: no USDC transfer when nothing is paid
    function test_whenNothingIsPaidThenNoUsdcTransfer() public {
        _fundSafe(mockUsdc, safeB, address(vault), 500e6);
        _escrow(vault, operatorAddr, LP_B_PK, safeB, LOWER, UPPER, 500e6, keccak256("escrow-b"), FAR_DEADLINE);
        _drainThroughExchange(400e6);

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(mockUsdc), "no USDC transfer");
        }
    }
}

// ──────────────────────────────────────────────
// SC-BMF3: Burn of a clamped mint tick pays NO for the levels the price rose through
// What: The Operator reported 5000 before the mint, so mintTick = 5500. After a move to
//       5800 the NO band is [5500, 5800): 90 NO and
//       3e23 * (700 * 10000 + 300 * (5500 + 5800 - 1) / 2) / 1e22 = 260,845,500 USDC units.
// Why:  A mint below its range has an empty YES side and a NO side that is the whole range.
// ──────────────────────────────────────────────
contract BurnClampedMintTickTest is BurnPositionTestBase {
    uint256 clamped;

    function setUp() public override {
        super.setUp();
        _burn(positionId);
        _moveTick(5000);
        clamped = _mintExample(LP_PK, keccak256("clamped"));
        (,,, int24 mintTick,,,) = vault.positions(clamped);
        assertEq(mintTick, LOWER, "precondition: the mint tick clamped to tickLower");
        _moveTick(5800);
        _fundVault(0, BAND_TOKENS);
    }

    // SC-BMF3: 260.8455 USDC plus 90 NO
    function test_whenMintTickClampedBelowThenRiseBuysNo() public {
        uint256 before = mockUsdc.balanceOf(safe);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(clamped, safe, 260_845_500, 0, 260_845_500, vault.noTokenId(), BAND_TOKENS, BAND_TOKENS);
        _burn(clamped);

        assertEq(mockUsdc.balanceOf(safe) - before, 260_845_500, "the USDC leg");
        assertEq(_noOf(safe), BAND_TOKENS, "the NO leg");
    }

    // FR-7G4M: a mint clamped above its range with the price still above pays USDC only
    function test_whenMintTickClampedAboveAndPriceStaysAboveThenUsdcOnly() public {
        _moveTick(7000);
        uint256 above = _mintExample(LP_PK, keccak256("above"));
        (,,, int24 mintTick,,,) = vault.positions(above);
        assertEq(mintTick, UPPER, "precondition: the mint tick clamped to tickUpper");
        uint256 before = mockUsdc.balanceOf(safe);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(above, safe, PRINCIPAL, 0, PRINCIPAL, 0, 0, 0);
        _burn(above);

        assertEq(mockUsdc.balanceOf(safe) - before, PRINCIPAL, "every level is still USDC");
    }
}

// ──────────────────────────────────────────────
// FR-7G4M: the closed-form claim equals a per-level loop
// What: For a random liquidity, range, reported tick before the mint (so the clamp cases
//       occur), and current tick, a real burn's PositionBurned carries usdcOwed and
//       tokenOwed equal to a loop that adds L tokens and L * (ONE - t) or L * t per band
//       level, summed exactly and divided once.
// Why:  The arithmetic series is the audited shape; the loop is the definition. The
//       product stays under 2^156, so neither needs _mulDiv.
// ──────────────────────────────────────────────
contract BurnClaimFuzzTest is BurnPositionTestBase {
    uint256 constant ONE = 10_000;
    uint256 constant P = 1e18;

    function setUp() public override {
        super.setUp();
        _burn(positionId);
    }

    function testFuzz_claimEqualsPerLevelLoop(
        uint256 usdcSeed,
        uint256 lowerSeed,
        uint256 widthSeed,
        int256 reportSeed,
        int256 currentSeed
    ) public {
        uint256 usdcAmount = bound(usdcSeed, 1e6, 1e12);
        int24 lower = int24(int256(bound(lowerSeed, 0, 990) * 10));
        int24 width = int24(int256(bound(widthSeed, 1, 100) * 10));
        if (lower + width > 10000) lower = 10000 - width;
        int24 upper = lower + width;
        // The reported tick can sit outside the range, so the mint tick clamps to a bound
        int24 report = int24(bound(reportSeed, int256(lower) - 500, int256(upper) + 500));
        int24 current = int24(bound(currentSeed, int256(lower) - 500, int256(upper) + 500));

        _moveTick(report);
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, lower, upper, usdcAmount, keccak256("fuzz"));
        (,,, int24 m, uint128 liquidity,,) = vault.positions(id);
        _moveTick(current);

        vm.recordLogs();
        _burn(id);
        (uint256 usdcOwed,,, uint256 tokenId, uint256 tokenOwed,) = _burnedLog(vm.getRecordedLogs());

        (uint256 loopUsdc, uint256 loopTokenId, uint256 loopTokens) = _loop(liquidity, lower, upper, m, current);
        assertEq(usdcOwed, loopUsdc, "the USDC leg must equal the per-level loop");
        assertEq(tokenId, loopTokenId, "the token id must match the band's side");
        assertEq(tokenOwed, loopTokens, "the token leg must equal the per-level loop");
    }

    /// @dev The definition of the claim, level by level: every level holds L USDC-units-per-P;
    ///      a YES level spent L * t / ONE of it, a NO level spent L * (ONE - t) / ONE. The sums
    ///      stay exact and divide once at the end.
    function _loop(uint128 liquidity, int24 lower, int24 upper, int24 m, int24 c)
        internal
        view
        returns (uint256 usdc, uint256 tokenId, uint256 tokens)
    {
        uint256 l = liquidity;
        uint256 usdcTimes = 0;
        uint256 tokenTimes = 0;
        for (int24 t = lower; t < upper; t++) {
            uint256 tick = uint256(int256(t));
            if (c < m && t >= c && t < m) {
                usdcTimes += l * (ONE - tick);
                tokenTimes += l;
                tokenId = vault.yesTokenId();
            } else if (c > m && t >= m && t < c) {
                usdcTimes += l * tick;
                tokenTimes += l;
                tokenId = vault.noTokenId();
            } else {
                usdcTimes += l * ONE;
            }
        }
        usdc = usdcTimes / (ONE * P);
        tokens = tokenTimes / P;
        if (tokens == 0 && tokenTimes == 0) tokenId = 0;
    }
}

// ──────────────────────────────────────────────
// NFR-7G58, NFR-7G59: a re-entering Safe meets the guard with the position already gone
// What: Code etched at the Safe's address re-enters the vault from onERC1155Received. Its
//       collect call reverts Reentrancy, and the burn completes with the full payout.
// Why:  A Safe owner can replace the Safe's fallback handler, so the ERC-1155 callback is a
//       live reentrancy surface, not defense in depth.
// ──────────────────────────────────────────────
contract ReentrantSafe {
    LPVault immutable vault;
    uint256 immutable target;
    bytes4 public recorded;

    constructor(LPVault vault_, uint256 target_) {
        vault = vault_;
        target = target_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try vault.collect(target) {
            recorded = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            recorded = bytes4(reason);
        }
        return 0xf23a6e61;
    }
}

contract BurnReentrancyTest is BurnPositionTestBase {
    uint256 other;

    function setUp() public override {
        super.setUp();
        other = _mintExample(LP_PK, keccak256("other"));
        _moveTick(5700);
        _fundVault(2 * BAND_TOKENS, 0);
    }

    // NFR-7G58: the re-entering collect reverts Reentrancy and the burn pays in full
    function test_whenSafeReentersThenGuardRejectsAndBurnCompletes() public {
        // The deployed instance's runtime code carries its immutables, so the copy at the
        // Safe's address re-enters the same vault for the same position.
        ReentrantSafe attacker = new ReentrantSafe(vault, other);
        vm.etch(safe, address(attacker).code);

        _burn(positionId);

        assertEq(ReentrantSafe(safe).recorded(), LPVault.Reentrancy.selector, "the re-entry meets the guard");
        assertEq(_yesOf(safe), BAND_TOKENS, "the burn still delivers the YES leg");
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the burn still delivers the USDC leg");
    }
}

// ──────────────────────────────────────────────
// NFR-7G5C: a burn with a merge, tick deinitialization, and both transfers stays under
//           250,000 gas against the mock USDC
// ──────────────────────────────────────────────
contract BurnGasTest is BurnPositionTestBase {
    // NFR-7G5C: measured cold, as R3 measured, so every slot starts cold as in a real transaction
    function test_burnWithMergeAndBothLegsStaysUnderBound() public {
        _moveTick(5700);
        _fundVault(BAND_TOKENS + 50e6, 50e6);
        vm.cool(address(vault));
        vm.cool(address(factory));
        vm.cool(address(mockUsdc));
        vm.cool(address(ctf));

        vm.prank(safe);
        uint256 before = gasleft();
        vault.burnPosition(positionId);
        uint256 used = before - gasleft();

        assertLt(used, 250_000, "the burn must stay under the NFR-7G5C bound");
    }
}
