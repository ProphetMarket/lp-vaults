// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JGEE: Start Wind Down
// Integration tests for every scenario in this use case.
// Covers: SC-JGEF, SC-JGEG, SC-JGEH, SC-JGEI, SC-JGEJ, SC-JGEK

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for wind-down scenarios.
// Deploys factory + vault clone and mints an in-range position for the LP.
// ──────────────────────────────────────────────
contract StartWindDownTestBase is LPVaultFixture {
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
    uint128 minFirstLiq = uint128(10e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;

    // Events declared for expectEmit
    event VaultWindDownStarted(bytes32 indexed marketId);
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

    // Position minted in setUp for exit-path tests
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

        // Mint a position: range [0, 100) with 1000 USDC, so there is an
        // existing position for exit-path tests.
        positionId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("setup-mint"));
    }

    /// @dev Transitions the vault to WindDown using the real startWindDown() function.
    function _windDownVault() internal {
        vm.prank(oracleAddr);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEF: Successful wind-down transition
// What: When the Oracle calls startWindDown() on an Active vault, the phase
//       transitions from Active (1) to WindDown (2) and a VaultWindDownStarted
//       event is emitted with the vault's marketId.
// Why:  This is the core lifecycle transition — the only mechanism by which a
//       vault stops accepting new positions when its underlying market resolves.
// ──────────────────────────────────────────────
contract SuccessfulWindDownTest is StartWindDownTestBase {
    // SC-JGEF: phase transitions from Active to WindDown
    function test_phaseChangesToWindDown() public {
        assertEq(vault.phase(), 1, "precondition: vault should be Active");

        vm.prank(oracleAddr);
        vault.startWindDown();

        assertEq(vault.phase(), 2, "phase should be WindDown after startWindDown");
    }

    // SC-JGEF: VaultWindDownStarted event emitted with correct marketId
    function test_emitsVaultWindDownStartedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit VaultWindDownStarted(marketId);

        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-JGEF: no other state is modified (positions, ticks unchanged)
    function test_noSideEffectsOnPositionState() public {
        // Snapshot position state before wind-down
        (address ownerBefore, int24 tlBefore, int24 tuBefore,, uint128 liqBefore,) = vault.positions(positionId);
        uint128 activeLiqBefore = vault.activeLiquidity();
        int24 currentTickBefore = vault.currentTick();

        vm.prank(oracleAddr);
        vault.startWindDown();

        // Verify nothing changed except phase
        (address ownerAfter, int24 tlAfter, int24 tuAfter,, uint128 liqAfter,) = vault.positions(positionId);
        assertEq(ownerAfter, ownerBefore, "owner unchanged");
        assertEq(tlAfter, tlBefore, "tickLower unchanged");
        assertEq(tuAfter, tuBefore, "tickUpper unchanged");
        assertEq(liqAfter, liqBefore, "liquidity unchanged");
        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity unchanged");
        assertEq(vault.currentTick(), currentTickBefore, "currentTick unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-JGEG: Revert when phase is not Active (idempotency)
// What: A second startWindDown() call reverts because the vault is already
//       in WindDown phase. This proves the transition is idempotent-safe.
// Why:  Prevents accidental double-calls from corrupting state or emitting
//       duplicate events.
// ──────────────────────────────────────────────
contract RevertWhenNotActiveTest is StartWindDownTestBase {
    function setUp() public override {
        super.setUp();
        // First wind-down — puts vault in WindDown phase
        _windDownVault();
    }

    // SC-JGEG: second call reverts with VaultNotActive
    function test_revertsOnSecondCall() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEH: Revert when non-Oracle calls
// What: Only the Oracle can transition the vault. Operator, LP, Admin, and
//       arbitrary addresses all revert with NotOracle.
// Why:  startWindDown is a lifecycle operation — compromise of the Operator
//       key must not allow an attacker to freeze minting across all vaults.
// ──────────────────────────────────────────────
contract RevertWhenNonOracleCallsTest is StartWindDownTestBase {
    // SC-JGEH: operator reverts
    function test_revertsWhenOperatorCalls() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: LP reverts
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: arbitrary address reverts
    function test_revertsWhenArbitraryAddressCalls() public {
        address arbitrary = makeAddr("arbitrary");
        vm.prank(arbitrary);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: admin reverts (admin is registry-only, cannot call vault lifecycle functions)
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEI: depositForIntent reverts in WindDown
// SC-JGEJ: mintPositionFor reverts in WindDown
// What: After startWindDown(), depositForIntent reverts with VaultNotActive
//       and records no escrow, and mintPositionFor reverts with VaultNotActive
//       even for an intent that was escrowed before the wind-down. No position
//       is created and the intentId is not consumed, so the Safe can reclaim it.
// Why:  WindDown means the market has resolved — new capital entering a
//       resolved market would be trapped with no purpose (FR-JGEB).
// ──────────────────────────────────────────────
contract MintRevertsInWindDownTest is StartWindDownTestBase {
    bytes32 intentId = keccak256("wind-down-mint");

    function setUp() public override {
        super.setUp();
        // Escrow before the wind-down, so the mint is what the phase blocks
        _fundSafe(mockUsdc, lp, address(vault), 500);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(0), int24(100), 500, intentId, FAR_DEADLINE);
        _windDownVault();
    }

    // SC-JGEI: depositForIntent reverts with VaultNotActive and records nothing
    function test_depositForIntentRevertsInWindDown() public {
        bytes32 fresh = keccak256("wind-down-deposit");
        _fundSafe(mockUsdc, lp, address(vault), 500);
        bytes memory sig = _signMintIntent(address(vault), LP_PK, lp, int24(0), int24(100), 500, fresh, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.depositForIntent(lp, int24(0), int24(100), 500, fresh, FAR_DEADLINE, sig);

        (address recorded,,) = vault.pendingDeposits(fresh);
        assertEq(recorded, address(0), "no escrow should be recorded in WindDown");
        assertEq(mockUsdc.balanceOf(lp), 500, "no USDC should move");
    }

    // SC-JGEJ: mintPositionFor reverts with VaultNotActive
    function test_mintPositionForRevertsInWindDown() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, FAR_DEADLINE);
    }

    // SC-JGEJ: no position created (nextPositionId unchanged)
    function test_nextPositionIdUnchangedAfterRevert() public {
        uint256 nextIdBefore = vault.nextPositionId();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, FAR_DEADLINE);

        assertEq(vault.nextPositionId(), nextIdBefore, "nextPositionId should not change");
    }

    // SC-JGEJ: intentId not consumed
    function test_intentIdNotConsumedAfterRevert() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, FAR_DEADLINE);

        assertEq(vault.usedIntents(intentId), false, "intentId should not be marked as used");
    }
}

// ──────────────────────────────────────────────
// SC-JGEK: Exit paths succeed in WindDown
// What: After startWindDown(), burnPosition removes the position's liquidity
//       from both ticks, deletes the record, merges the free pairs, and pays
//       the Safe the claim's USDC plus its one outcome token, the same amounts
//       as in Active. The position sits at its mint tick, so the claim is USDC
//       only and the vault holds no pair to merge.
// Why:  Capital must never be stranded. The wind-down only prevents new mints;
//       all exit paths remain open so LPs can withdraw.
// ──────────────────────────────────────────────
contract ExitPathsSucceedInWindDownTest is StartWindDownTestBase {
    function setUp() public override {
        super.setUp();
        _windDownVault();
    }

    // SC-JGEK, FR-JGEC: the burn pays the claim's USDC plus its one outcome token and deletes the position
    function test_whenWoundDownThenBurnPaysTheClaimAndDeletesThePosition() public {
        (,,,, uint128 liquidity,) = vault.positions(positionId);
        assertEq(vault.activeLiquidity(), liquidity, "precondition: the position is in range at its mint tick");
        uint256 before_ = mockUsdc.balanceOf(lp);
        uint256 yesBefore = ctf.balanceOf(lp, vault.yesTokenId());
        uint256 noBefore = ctf.balanceOf(lp, vault.noTokenId());

        // 1000 USDC over [0, 100) at its mint tick: every level is still USDC, so the token leg
        // is empty. These are the amounts the same burn pays in Active (FEAT-7G40 SC-7G49).
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, lp, 1000, 1000, 0, 0, 0, 0, 0);
        vm.prank(lp);
        vault.burnPosition(positionId);

        assertEq(mockUsdc.balanceOf(lp) - before_, 1000, "the Safe receives the whole principal");
        assertEq(ctf.balanceOf(lp, vault.yesTokenId()), yesBefore, "no YES token is owed at the mint tick");
        assertEq(ctf.balanceOf(lp, vault.noTokenId()), noBefore, "no NO token is owed at the mint tick");
        (address owner,,,, uint128 liqAfter,) = vault.positions(positionId);
        assertEq(owner, address(0), "the position record is deleted");
        assertEq(liqAfter, 0, "the position record is deleted");
        (uint128 gLower,,,) = vault.ticks(int24(0));
        (uint128 gUpper,,,) = vault.ticks(int24(100));
        assertEq(gLower, 0, "tick 0 lost the liquidity");
        assertEq(gUpper, 0, "tick 100 lost the liquidity");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity fell by the position's liquidity");
        assertEq(vault.phase(), 2, "phase should still be WindDown");
    }
}

// ──────────────────────────────────────────────
// SC-JGEK (reclaim side): both reclaim paths succeed in WindDown
// What: An escrow made before the wind-down is refundable by the Safe's own
//       reclaimDeposit and by the Operator's reclaimDepositFor after
//       startWindDown().
// Why:  FR-JGEC: exit paths keep the Active behavior in WindDown.
// ──────────────────────────────────────────────
contract ReclaimPathsInWindDownTest is StartWindDownTestBase {
    bytes32 escrowIntent = keccak256("wind-down-escrow");
    uint256 escrowAmount = 500;

    function setUp() public override {
        super.setUp();
        _fundSafe(mockUsdc, lp, address(vault), escrowAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(0), int24(100), escrowAmount, escrowIntent, FAR_DEADLINE);
        _windDownVault();
    }

    // SC-JGEK: reclaimDeposit(intentId) succeeds in WindDown
    function test_reclaimDepositSucceedsInWindDown() public {
        uint256 before_ = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.reclaimDeposit(escrowIntent);

        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its escrow in WindDown");
    }

    // SC-JGEK: reclaimDepositFor succeeds in WindDown
    function test_reclaimDepositForSucceedsInWindDown() public {
        uint256 before_ = mockUsdc.balanceOf(lp);
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, lp, escrowIntent, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, escrowIntent, FAR_DEADLINE, sig);

        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the relayed reclaim should pay the Safe in WindDown");
    }
}
