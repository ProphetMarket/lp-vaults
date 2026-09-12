// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-K1MK: Pause and Unpause Vault
// Integration tests for every scenario in this use case.
// Covers: SC-K1ML, SC-K1MM, SC-K1MN, SC-K1MO, SC-K1MP

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for pauseTrading / unpauseTrading scenarios.
// Deploys factory + vault clone, mints one in-range position (so
// notifyFees has nonzero activeLiquidity), and provides helpers.
// ──────────────────────────────────────────────
contract PauseTradingTestBase is LPVaultFixture {
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

    event TradingPaused(address indexed caller);
    event TradingUnpaused(address indexed caller);

    uint256 positionId;

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // Mint one position: range [0, 100), 1000 USDC → liquidity = 10e18
        positionId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("setup-mint"));
    }

    function _pause() internal {
        vm.prank(admin);
        vault.pauseTrading();
    }
}

// ──────────────────────────────────────────────
// SC-K1ML: Admin pauses vault and gated functions revert
// What: When Admin calls pauseTrading(), paused becomes true and
//       TradingPaused is emitted. Subsequently, mintPositionFor,
//       notifyFees, updateTick, and mergePositions all revert with
//       TradingIsPaused.
// Why:  The circuit breaker must immediately halt all trading entry
//       points to contain damage from a bug or market anomaly.
// ──────────────────────────────────────────────
contract PauseTradingPauseAndGateTest is PauseTradingTestBase {
    // SC-K1ML: paused flag set to true
    function test_pausedFlagSetToTrue() public {
        assertEq(vault.paused(), false, "precondition: not paused");

        _pause();

        assertEq(vault.paused(), true, "paused should be true");
    }

    // SC-K1ML: TradingPaused event emitted with correct caller
    function test_emitsTradingPausedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit TradingPaused(admin);

        vm.prank(admin);
        vault.pauseTrading();
    }

    // SC-K1ML: mintPositionFor reverts while paused, even for an intent escrowed before the pause
    function test_mintPositionForRevertsWhilePaused() public {
        bytes32 intentId = keccak256("paused-mint");
        _fundSafe(mockUsdc, lp, address(vault), 100);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(0), int24(100), 100, intentId, FAR_DEADLINE);
        _pause();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 100, intentId, FAR_DEADLINE);
    }

    // SC-K1ML: notifyFees reverts while paused
    function test_notifyFeesRevertsWhilePaused() public {
        _pause();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.notifyFees(100);
    }

    // SC-K1ML: updateTick reverts while paused
    function test_updateTickRevertsWhilePaused() public {
        _pause();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.updateTick(int24(10));
    }

    // SC-K1ML: mergePositions reverts while paused
    function test_mergePositionsRevertsWhilePaused() public {
        // Mint a second position to make merge possible
        uint256 pos2 = _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 500, keccak256("mint-2"));

        _pause();

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = pos2;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mergePositions(ids);
    }
}

// ──────────────────────────────────────────────
// SC-K1MM: Unpause returns vault to normal
// What: After Admin calls unpauseTrading(), paused becomes false,
//       TradingUnpaused is emitted, and gated functions work again.
// Why:  The circuit breaker must be reversible so trading can resume
//       once the issue is resolved.
// ──────────────────────────────────────────────
contract PauseTradingUnpauseTest is PauseTradingTestBase {
    // SC-K1MM: paused flag set to false after unpause
    function test_pausedFlagSetToFalse() public {
        _pause();
        assertEq(vault.paused(), true, "precondition: paused");

        vm.prank(admin);
        vault.unpauseTrading();

        assertEq(vault.paused(), false, "paused should be false after unpause");
    }

    // SC-K1MM: TradingUnpaused event emitted with correct caller
    function test_emitsTradingUnpausedEvent() public {
        _pause();

        vm.expectEmit(true, false, false, false, address(vault));
        emit TradingUnpaused(admin);

        vm.prank(admin);
        vault.unpauseTrading();
    }

    // SC-K1MM: notifyFees succeeds after unpause
    function test_notifyFeesSucceedsAfterUnpause() public {
        _pause();

        // Verify it reverts while paused
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.notifyFees(100);

        // Unpause and verify it works
        vm.prank(admin);
        vault.unpauseTrading();

        uint256 feeGrowthBefore = vault.feeGrowthGlobalX128();
        vm.prank(operatorAddr);
        vault.notifyFees(100);
        assertGt(vault.feeGrowthGlobalX128(), feeGrowthBefore, "feeGrowth should increase after unpause");
    }
}

// ──────────────────────────────────────────────
// SC-K1MN: Revert if non-Admin calls
// What: pauseTrading and unpauseTrading revert with NotAdmin for
//       Operator, LP, and arbitrary addresses.
// Why:  Only Admins should be able to toggle the circuit breaker.
//       Compromise of the Operator must not unlock pause control.
// ──────────────────────────────────────────────
contract PauseTradingAccessControlTest is PauseTradingTestBase {
    // SC-K1MN: Operator calling pauseTrading reverts
    function test_operatorCannotPause() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.pauseTrading();
    }

    // SC-K1MN: LP calling pauseTrading reverts
    function test_lpCannotPause() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.pauseTrading();
    }

    // SC-K1MN: arbitrary address calling unpauseTrading reverts
    function test_arbitraryCannotUnpause() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.unpauseTrading();
    }
}

// ──────────────────────────────────────────────
// SC-K1MO: Collect works while paused
// What: While the vault is paused, LP can still call collect() to
//       withdraw accrued fees from their position.
// Why:  LP exit paths must never be blocked — capital should never
//       be trapped by the circuit breaker.
// Example: Distribute 500 USDC fees, pause, collect → LP receives fees.
// ──────────────────────────────────────────────
contract PauseTradingCollectTest is PauseTradingTestBase {
    // SC-K1MO: collect succeeds while paused
    function test_collectSucceedsWhilePaused() public {
        // Distribute fees so the position has something to collect
        vm.prank(operatorAddr);
        vault.notifyFees(500);

        // Fund vault with USDC for fee payout (notifyFees doesn't move USDC)
        mockUsdc.mint(address(vault), 500);

        _pause();

        // Collect should succeed despite pause
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(positionId);
        uint256 lpBalAfter = mockUsdc.balanceOf(lp);

        assertGt(lpBalAfter, lpBalBefore, "LP should receive fees while paused");
    }
}

// ──────────────────────────────────────────────
// SC-K1MP: ReclaimDeposit works while paused
// What: While the vault is paused, the Safe can still call reclaimDeposit()
//       to recover the USDC escrowed against an intent that was not minted,
//       in one call with no wait.
// Why:  LP exit paths must never be blocked by pause (FR-K1MI).
// ──────────────────────────────────────────────
contract PauseTradingReclaimTest is PauseTradingTestBase {
    bytes32 intentId = keccak256("reclaim-intent");
    uint256 reclaimAmount = 200;

    function setUp() public override {
        super.setUp();

        // Escrow an intent that the Operator never mints
        _fundSafe(mockUsdc, lp, address(vault), reclaimAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(0), int24(100), reclaimAmount, intentId, FAR_DEADLINE);
    }

    // SC-K1MP: reclaimDeposit succeeds while paused
    function test_reclaimDepositSucceedsWhilePaused() public {
        _pause();

        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(intentId);
        uint256 lpBalAfter = mockUsdc.balanceOf(lp);

        assertEq(lpBalAfter - lpBalBefore, reclaimAmount, "the Safe should receive the escrow while paused");
        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
        (address recorded,,) = vault.pendingDeposits(intentId);
        assertEq(recorded, address(0), "escrow should be deleted");
    }

    // FR-K1MI: reclaimDepositFor succeeds while paused
    function test_reclaimDepositForSucceedsWhilePaused() public {
        _pause();
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, lp, intentId, FAR_DEADLINE);

        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, sig);

        assertEq(mockUsdc.balanceOf(lp) - lpBalBefore, reclaimAmount, "the relayed reclaim should pay while paused");
    }

    // FR-K1MI, SC-K1ML: depositForIntent joins the trading entry points that revert while paused
    function test_depositForIntentRevertsWhilePaused() public {
        _pause();
        bytes32 fresh = keccak256("paused-deposit");
        _fundSafe(mockUsdc, lp, address(vault), 100);
        bytes memory sig = _signMintIntent(address(vault), LP_PK, lp, int24(0), int24(100), 100, fresh, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.depositForIntent(lp, int24(0), int24(100), 100, fresh, FAR_DEADLINE, sig);
    }
}

// ──────────────────────────────────────────────
// NFR-K1MJ: Pause independent of phase
// What: Pausing does not change the vault's phase, and unpausing
//       restores normal phase-gated behavior.
// Why:  Phase and pause are orthogonal controls — conflating them
//       would create edge cases where pause side-effects alter
//       the vault lifecycle.
// ──────────────────────────────────────────────
contract PauseTradingPhaseIndependenceTest is PauseTradingTestBase {
    // NFR-K1MJ: phase unchanged after pause/unpause cycle
    function test_phaseUnchangedAfterPauseUnpause() public {
        uint8 phaseBefore = vault.phase();

        _pause();
        assertEq(vault.phase(), phaseBefore, "phase unchanged after pause");

        vm.prank(admin);
        vault.unpauseTrading();
        assertEq(vault.phase(), phaseBefore, "phase unchanged after unpause");
    }
}
