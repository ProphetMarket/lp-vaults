// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-7G40: Burn LP Position
// UC-7G42: Operator Burn Position for LP
// Integration tests for every scenario in this use case: the relayed burn over the owner
// key's BurnIntent, its parity with the self-service path, and its rejections.
// Covers: SC-7G4C, SC-7G4D, SC-7G4E, SC-7G4F, SC-7G4G, SC-7G4H, SC-7G4I, SC-7G4J, SC-7G4K,
//         SC-BMF4, SC-BMF5

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for relayed burn scenarios.
// The same worked example as the self-service file: 300 USDC over [5500, 6500) minted at
// tick 6000, liquidity 3e23. The owner key signs a BurnIntent naming its Safe, and the
// Operator relays it.
// ──────────────────────────────────────────────
contract OperatorBurnTestBase is LPVaultFixture {
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
    uint256 constant FELL_USDC = 247_354_500;
    uint256 constant ROSE_USDC = 265_345_500;
    uint256 constant BAND_TOKENS = 90e6;

    uint256 positionId;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 usdcPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );

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
        positionId = _escrowAndMint(vault, operatorAddr, LP_PK, LOWER, UPPER, PRINCIPAL, keccak256("example"));
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    function _yesOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.yesTokenId());
    }

    function _noOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.noTokenId());
    }

    /// @dev The owner key's BurnIntent for the example position, with the far deadline.
    function _sig() internal view returns (bytes memory) {
        return _signBurnIntent(address(vault), LP_PK, safe, positionId, FAR_DEADLINE);
    }

    /// @dev The Operator relays the example burn with the given signature.
    function _relay(bytes memory sig) internal {
        vm.prank(operatorAddr);
        vault.burnPositionFor(safe, positionId, FAR_DEADLINE, sig);
    }

    function _expectRevertOnRelay(bytes4 selector, bytes memory sig) internal {
        vm.prank(operatorAddr);
        vm.expectRevert(selector);
        vault.burnPositionFor(safe, positionId, FAR_DEADLINE, sig);
    }

    function _assertLive() internal view {
        (address owner,,,, uint128 liq) = vault.positions(positionId);
        assertEq(owner, safe, "the position keeps its owner");
        assertEq(liq, LIQUIDITY, "the position keeps its liquidity");
    }
}

// ──────────────────────────────────────────────
// SC-7G4C: Operator burn at the mint tick pays the LP the whole principal in USDC
// What: The relayed burn pays the Safe 300 USDC, the Operator receives nothing, the
//       authorization is recorded, and the heartbeat refreshes.
// Why:  Parity with SC-7G43 (ADR-7G5E): one body, two entry points.
// ──────────────────────────────────────────────
contract OperatorBurnAtMintTickTest is OperatorBurnTestBase {
    // SC-7G4C: the Safe receives 300 USDC, the Operator nothing
    function test_whenRelayedAtMintTickThenSafeReceivesPrincipal() public {
        uint256 operatorBefore = mockUsdc.balanceOf(operatorAddr);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0);
        _relay(_sig());

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC");
        assertEq(mockUsdc.balanceOf(operatorAddr), operatorBefore, "the Operator receives nothing");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity falls");
    }

    // SC-7G4C: the struct hash is recorded and the record is deleted
    function test_whenRelayedThenAuthorizationRecordedAndRecordDeleted() public {
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, safe, positionId, FAR_DEADLINE));
        assertFalse(vault.usedBurnAuthorizations(structHash), "precondition: unused");

        _relay(_sig());

        assertTrue(vault.usedBurnAuthorizations(structHash), "the struct hash is consumed");
        (address owner,,,, uint128 liq) = vault.positions(positionId);
        assertEq(owner, address(0), "the record is deleted");
        assertEq(liq, 0, "the record is deleted");
    }

    // FR-7G4L: the relayed burn and the self-service burn pay the same amounts for the same state
    function test_whenRelayedThenAmountsMatchSelfServiceTwin() public {
        uint256 twin = _escrowAndMint(vault, operatorAddr, LP_B_PK, LOWER, UPPER, PRINCIPAL, keccak256("twin"));

        _relay(_sig());
        vm.prank(safeB);
        vault.burnPosition(twin);

        assertEq(mockUsdc.balanceOf(safe), mockUsdc.balanceOf(safeB), "both paths pay the same USDC");
        (uint128 gLower,,) = vault.ticks(LOWER);
        assertEq(gLower, 0, "both paths removed their liquidity from the shared tick");
    }
}

// ──────────────────────────────────────────────
// SC-7G4D: Operator burn after the price fell pays the LP USDC plus YES, never the caller
// ──────────────────────────────────────────────
contract OperatorBurnAfterPriceFellTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
    }

    // SC-7G4D: 247.3545 USDC plus 90 YES to the Safe, nothing to the Operator
    function test_whenRelayedAfterFallThenSafeReceivesUsdcPlusYes() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);
        _relay(_sig());

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the USDC leg goes to the Safe");
        assertEq(_yesOf(safe), BAND_TOKENS, "the YES leg goes to the Safe");
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "no USDC to the caller");
        assertEq(_yesOf(operatorAddr), 0, "no YES to the caller");
    }
}

// ──────────────────────────────────────────────
// SC-7G4E: Operator burn after the price rose pays the LP USDC plus NO
// ──────────────────────────────────────────────
contract OperatorBurnAfterPriceRoseTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(6300);
        _fundVault(0, BAND_TOKENS);
    }

    // SC-7G4E: 265.3455 USDC plus 90 NO to the Safe
    function test_whenRelayedAfterRiseThenSafeReceivesUsdcPlusNo() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, ROSE_USDC, ROSE_USDC, vault.noTokenId(), BAND_TOKENS, BAND_TOKENS);
        _relay(_sig());

        assertEq(mockUsdc.balanceOf(safe), ROSE_USDC, "the USDC leg goes to the Safe");
        assertEq(_noOf(safe), BAND_TOKENS, "the NO leg goes to the Safe");
        assertEq(_noOf(operatorAddr), 0, "no NO to the caller");
    }
}

// ──────────────────────────────────────────────
// SC-7G4F: Revert when the burn authorization is missing
// SC-7G4G: Revert when the burn authorization is malformed
// What: An empty signature, a 64-byte one, a high-s one, a v outside {27, 28}, and a
//       valid signature from a key whose Safe is not `lp` each revert InvalidSignature,
//       and the position stays live.
// Why:  Operator authority alone never closes a position, and a malleable form would give
//       a replay a second encoding.
// ──────────────────────────────────────────────
contract OperatorBurnSignatureRejectionTest is OperatorBurnTestBase {
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _digest() internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, safe, positionId, FAR_DEADLINE));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), structHash));
    }

    // SC-7G4F: an empty signature
    function test_whenSignatureIsEmptyThenReverts() public {
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, "");
        _assertLive();
    }

    // SC-7G4G: case C — 64 bytes
    function test_whenSignatureHas64BytesThenReverts() public {
        bytes memory sig = _sig();
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, short);
        _assertLive();
    }

    // SC-7G4G: case A — a high s value
    function test_whenSignatureHasHighSThenReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, _digest());
        bytes32 highS = bytes32(SECP256K1N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, abi.encodePacked(r, highS, flippedV));
        _assertLive();
    }

    // SC-7G4G: case B — v outside {27, 28}
    function test_whenSignatureHasBadVThenReverts() public {
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, _digest());
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, abi.encodePacked(r, s, uint8(29)));
        _assertLive();
    }

    // SC-7G4G: case D — a key whose derived Safe is not lp
    function test_whenSignerIsNotTheSafesOwnerKeyThenReverts() public {
        bytes memory sig = _signBurnIntent(address(vault), LP_B_PK, safe, positionId, FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, sig);
        _assertLive();
    }

    // FR-7G53: a valid BurnIntent from Safe B for Safe A's position reverts NotPositionOwner
    function test_whenLpIsNotTheOwnerThenRevertsNotPositionOwner() public {
        bytes memory sig = _signBurnIntent(address(vault), LP_B_PK, safeB, positionId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPositionFor(safeB, positionId, FAR_DEADLINE, sig);
        _assertLive();
    }

    // SC-7G4G: no heartbeat write on a rejected relay
    function test_whenRejectedThenHeartbeatUnchanged() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        _expectRevertOnRelay(LPVault.InvalidSignature.selector, "");

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a revert refreshes nothing");
    }
}

// ──────────────────────────────────────────────
// SC-7G4H: Revert when a burn authorization is replayed
// What: A second submission of a consumed BurnIntent reverts IntentAlreadyUsed, before
//       the position check.
// Why:  ADR-85DM: a replay is distinguishable from a burn of a position that never existed.
// ──────────────────────────────────────────────
contract OperatorBurnReplayTest is OperatorBurnTestBase {
    // SC-7G4H: the replay reports IntentAlreadyUsed, not PositionNotFound
    function test_whenAuthorizationReplayedThenRevertsIntentAlreadyUsed() public {
        bytes memory sig = _sig();
        _relay(sig);

        _expectRevertOnRelay(LPVault.IntentAlreadyUsed.selector, sig);
    }

    // FR-7G55: a different deadline is a different authorization, and it meets the deleted record
    function test_whenNewDeadlineAfterBurnThenRevertsPositionNotFound() public {
        _relay(_sig());

        uint256 later = FAR_DEADLINE - 1;
        bytes memory sig = _signBurnIntent(address(vault), LP_PK, safe, positionId, later);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPositionFor(safe, positionId, later, sig);
    }
}

// ──────────────────────────────────────────────
// SC-7G4I: Revert when a mint or reclaim authorization is reused as a burn
// What: The owner key's MintIntent and ReclaimIntent signatures each recover to a key
//       whose Safe is not lp under the BurnIntent typehash, so the relay reverts
//       InvalidSignature. A BurnIntent is rejected by the other two paths.
// Why:  Three disjoint namespaces (ADR-7G5H).
// ──────────────────────────────────────────────
contract OperatorBurnCrossTypeTest is OperatorBurnTestBase {
    // SC-7G4I: a MintIntent signature is not a burn
    function test_whenMintIntentReusedThenReverts() public {
        bytes memory sig =
            _signMintIntent(address(vault), LP_PK, safe, LOWER, UPPER, PRINCIPAL, keccak256("example"), FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, sig);
        _assertLive();
    }

    // SC-7G4I: a ReclaimIntent signature is not a burn
    function test_whenReclaimIntentReusedThenReverts() public {
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, safe, keccak256("example"), FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, sig);
        _assertLive();
    }

    // SC-7G4I: a BurnIntent signature is rejected by the deposit and the relayed reclaim
    function test_whenBurnIntentReusedElsewhereThenEachPathReverts() public {
        bytes memory sig = _sig();
        bytes32 intentId = keccak256("example");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(safe, LOWER, UPPER, PRINCIPAL, keccak256("new"), FAR_DEADLINE, sig);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(safe, intentId, FAR_DEADLINE, sig);
    }
}

// ──────────────────────────────────────────────
// SC-7G4J: Revert on a non-Operator caller
// ──────────────────────────────────────────────
contract OperatorBurnNonOperatorTest is OperatorBurnTestBase {
    function _expectNotOperator(address caller) internal {
        bytes memory sig = _sig();
        vm.prank(caller);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(safe, positionId, FAR_DEADLINE, sig);
    }

    // SC-7G4J: an arbitrary address with a valid BurnIntent
    function test_whenArbitraryAddressCallsThenReverts() public {
        _expectNotOperator(makeAddr("nobody"));
        _assertLive();
    }

    // SC-7G4J: the Admin
    function test_whenAdminCallsThenReverts() public {
        _expectNotOperator(admin);
    }

    // SC-7G4J: the Oracle
    function test_whenOracleCallsThenReverts() public {
        _expectNotOperator(oracleAddr);
    }

    // SC-7G4J: the Safe itself cannot use the relayed path, and keeps burnPosition
    function test_whenSafeCallsRelayedPathThenRevertsButSelfServiceWorks() public {
        _expectNotOperator(safe);

        vm.prank(safe);
        vault.burnPosition(positionId);
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the self-service path stays open");
    }
}

// ──────────────────────────────────────────────
// SC-7G4K: Operator burn in WindDown succeeds identically to Active
// ──────────────────────────────────────────────
contract OperatorBurnInWindDownTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-7G4K: the same amounts, and the phase stays WindDown
    function test_whenWindDownThenRelayedBurnPaysAsInActive() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0);
        _relay(_sig());

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC in WindDown");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity falls as in Active");
        assertEq(vault.phase(), 2, "phase stays WindDown");
    }

    // FR-7G4V: the relayed burn works while paused
    function test_whenPausedThenRelayedBurnSucceeds() public {
        vm.prank(admin);
        vault.pauseTrading();

        _relay(_sig());
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC while paused");
    }
}

// ──────────────────────────────────────────────
// SC-BMF4: Revert when the deadline passed
// What: A BurnIntent with deadline = block.timestamp - 1 reverts IntentExpired, and the
//       same shape with deadline = block.timestamp succeeds.
// Why:  Decision C23: every LP type carries a deadline, inclusive.
// ──────────────────────────────────────────────
contract OperatorBurnDeadlineTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
    }

    // SC-BMF4: one second past the deadline reverts
    function test_whenDeadlinePassedThenRevertsIntentExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signBurnIntent(address(vault), LP_PK, safe, positionId, deadline);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentExpired.selector);
        vault.burnPositionFor(safe, positionId, deadline, sig);
        _assertLive();
    }

    // SC-BMF4: the deadline is inclusive
    function test_whenDeadlineIsNowThenSucceeds() public {
        uint256 deadline = block.timestamp;
        bytes memory sig = _signBurnIntent(address(vault), LP_PK, safe, positionId, deadline);

        vm.prank(operatorAddr);
        vault.burnPositionFor(safe, positionId, deadline, sig);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "a deadline equal to now is accepted");
    }
}

// ──────────────────────────────────────────────
// SC-BMF5: Operator burn refreshes the heartbeat
// ──────────────────────────────────────────────
contract OperatorBurnHeartbeatTest is OperatorBurnTestBase {
    // SC-BMF5: lastOperatorActivityTimestamp == block.timestamp after the relay
    function test_whenRelayedThenHeartbeatRefreshes() public {
        vm.warp(block.timestamp + 2 days);
        assertLt(vault.lastOperatorActivityTimestamp(), block.timestamp, "precondition: stale timer");

        _relay(_sig());

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "the relayed burn is Operator activity");
    }
}
