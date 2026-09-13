// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-U079: Collect Fees on a Position
// UC-BMF8: Operator Collect Fees for LP
// Integration tests for every scenario in this use case: the relayed collect over the owner
// key's CollectIntent, its parity with the self-service path, and its rejections.
// Covers: SC-BMFG, SC-BMFH, SC-BMFI, SC-BMFJ, SC-BMFK, SC-BMFL, SC-BMFM, SC-BMG6

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for relayed collect scenarios.
// Deploys the factory and a vault, mints an in-range position for the Safe ([0, 100) with
// 1000 USDC, liquidity 10e18, positionId 0), and distributes 500 USDC of fees. The owner
// key signs a CollectIntent naming its Safe, and the Operator relays it.
// ──────────────────────────────────────────────
contract OperatorCollectTestBase is LPVaultFixture {
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

    uint128 constant LIQUIDITY = 10e18;
    uint256 constant Q128 = 2 ** 128;

    uint256 positionId;

    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

    function setUp() public virtual {
        safe = _safeOf(vm.addr(LP_PK));
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(10e18)));

        positionId = _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("setup"));
        _notifyFees(vault, operatorAddr, 500);
    }

    /// @dev What a collect would pay now: the fees since the snapshot plus tokensOwed.
    function _owed() internal view returns (uint256) {
        (,,,,, uint256 snapshot, uint256 tokensOwed) = vault.positions(positionId);
        return uint256(LIQUIDITY) * (vault.feeGrowthGlobalX128() - snapshot) / Q128 + tokensOwed;
    }

    function _sig(uint256 nonce) internal view returns (bytes memory) {
        return _signCollectIntent(address(vault), LP_PK, safe, positionId, nonce, FAR_DEADLINE);
    }

    function _relay(uint256 nonce, bytes memory sig) internal {
        vm.prank(operatorAddr);
        vault.collectFor(safe, positionId, nonce, FAR_DEADLINE, sig);
    }

    function _expectRevertOnRelay(bytes4 selector, uint256 nonce, bytes memory sig) internal {
        vm.prank(operatorAddr);
        vm.expectRevert(selector);
        vault.collectFor(safe, positionId, nonce, FAR_DEADLINE, sig);
    }
}

// ──────────────────────────────────────────────
// SC-BMFG: Operator collect pays the LP its fees, never the caller
// ──────────────────────────────────────────────
contract OperatorCollectPaysLpTest is OperatorCollectTestBase {
    // SC-BMFG: the Safe receives the fees, the Operator nothing, and the heartbeat refreshes
    function test_whenRelayedThenSafeReceivesFeesAndOperatorNothing() public {
        uint256 owed = _owed();
        assertGt(owed, 0, "precondition: fees accrued");
        uint256 operatorBefore = mockUsdc.balanceOf(operatorAddr);
        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesCollected(positionId, safe, owed);
        _relay(1, _sig(1));

        assertEq(mockUsdc.balanceOf(safe), owed, "the Safe receives the fees");
        assertEq(mockUsdc.balanceOf(operatorAddr), operatorBefore, "the Operator receives nothing");
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "the relayed collect is Operator activity");
    }

    // SC-BMFG: the struct hash is recorded and the snapshot advances
    function test_whenRelayedThenAuthorizationRecordedAndSnapshotAdvances() public {
        bytes32 structHash = keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, safe, positionId, 1, FAR_DEADLINE));

        _relay(1, _sig(1));

        assertTrue(vault.usedCollectAuthorizations(structHash), "the struct hash is consumed");
        (,,,,, uint256 snapshot, uint256 tokensOwed) = vault.positions(positionId);
        assertEq(snapshot, vault.feeGrowthGlobalX128(), "the snapshot advanced");
        assertEq(tokensOwed, 0, "nothing left to pay");
    }

    // FR-BMF9: the relayed collect pays what the self-service collect would
    function test_whenRelayedThenAmountMatchesSelfService() public {
        uint256 owed = _owed();

        _relay(1, _sig(1));
        uint256 relayed = mockUsdc.balanceOf(safe);

        // A second position for Safe B, in the same state, collected directly
        uint256 twin = _escrowAndMint(vault, operatorAddr, LP_B_PK, int24(0), int24(100), 1000, keccak256("twin"));
        _notifyFees(vault, operatorAddr, 1000);
        (,,,,, uint256 snapshotB,) = vault.positions(twin);
        uint256 owedB = uint256(LIQUIDITY) * (vault.feeGrowthGlobalX128() - snapshotB) / Q128;
        vm.prank(safeB);
        vault.collect(twin);

        assertEq(relayed, owed, "the relayed amount is the owed amount");
        assertEq(mockUsdc.balanceOf(safeB), owedB, "the self-service amount is the owed amount");
    }
}

// ──────────────────────────────────────────────
// SC-BMFH: A second collect with a new nonce pays only the new fees
// ──────────────────────────────────────────────
contract OperatorCollectSecondNonceTest is OperatorCollectTestBase {
    // SC-BMFH: nonce 2 pays F2, not F1 + F2
    function test_whenNewNonceThenPaysOnlyNewFees() public {
        _relay(1, _sig(1));
        uint256 first = mockUsdc.balanceOf(safe);

        _notifyFees(vault, operatorAddr, 300);
        uint256 second = _owed();
        assertGt(second, 0, "precondition: new fees accrued");

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesCollected(positionId, safe, second);
        _relay(2, _sig(2));

        assertEq(mockUsdc.balanceOf(safe), first + second, "the second collect pays only the new fees");
        bytes32 h1 = keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, safe, positionId, 1, FAR_DEADLINE));
        bytes32 h2 = keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, safe, positionId, 2, FAR_DEADLINE));
        assertTrue(vault.usedCollectAuthorizations(h1) && vault.usedCollectAuthorizations(h2), "both consumed");
    }
}

// ──────────────────────────────────────────────
// SC-BMFI: Revert when the nonce is replayed
// ──────────────────────────────────────────────
contract OperatorCollectReplayTest is OperatorCollectTestBase {
    // SC-BMFI: the replay reverts IntentAlreadyUsed, and the new fees stay collectible
    function test_whenNonceReplayedThenRevertsAndFeesStayCollectible() public {
        bytes memory sig = _sig(1);
        _relay(1, sig);
        _notifyFees(vault, operatorAddr, 300);
        uint256 balanceBefore = mockUsdc.balanceOf(safe);
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 hours);

        _expectRevertOnRelay(LPVault.IntentAlreadyUsed.selector, 1, sig);

        assertEq(mockUsdc.balanceOf(safe), balanceBefore, "nothing paid on the replay");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a revert refreshes nothing");
        _relay(2, _sig(2));
        assertGt(mockUsdc.balanceOf(safe), balanceBefore, "the new fees pay with a new nonce");
    }
}

// ──────────────────────────────────────────────
// SC-BMFJ: Revert when the deadline passed
// ──────────────────────────────────────────────
contract OperatorCollectDeadlineTest is OperatorCollectTestBase {
    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
    }

    // SC-BMFJ: one second past the deadline reverts
    function test_whenDeadlinePassedThenRevertsIntentExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signCollectIntent(address(vault), LP_PK, safe, positionId, 1, deadline);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentExpired.selector);
        vault.collectFor(safe, positionId, 1, deadline, sig);
    }

    // SC-BMFJ: the deadline is inclusive
    function test_whenDeadlineIsNowThenSucceeds() public {
        uint256 deadline = block.timestamp;
        uint256 owed = _owed();
        bytes memory sig = _signCollectIntent(address(vault), LP_PK, safe, positionId, 1, deadline);

        vm.prank(operatorAddr);
        vault.collectFor(safe, positionId, 1, deadline, sig);

        assertEq(mockUsdc.balanceOf(safe), owed, "a deadline equal to now is accepted");
    }
}

// ──────────────────────────────────────────────
// SC-BMFK: Revert when the signature does not derive lp
// ──────────────────────────────────────────────
contract OperatorCollectSignatureRejectionTest is OperatorCollectTestBase {
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _digest() internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, safe, positionId, 1, FAR_DEADLINE));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), structHash));
    }

    // SC-BMFK: case A — another owner key naming this Safe
    function test_whenAnotherKeySignsThenReverts() public {
        bytes memory sig = _signCollectIntent(address(vault), LP_B_PK, safe, positionId, 1, FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, sig);
    }

    // SC-BMFK: case B — an empty signature
    function test_whenSignatureIsEmptyThenReverts() public {
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, "");
    }

    // SC-BMFK: case B — 64 bytes
    function test_whenSignatureHas64BytesThenReverts() public {
        bytes memory sig = _sig(1);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, short);
    }

    // SC-BMFK: case B — a high s value
    function test_whenSignatureHasHighSThenReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, _digest());
        bytes32 highS = bytes32(SECP256K1N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, abi.encodePacked(r, highS, flippedV));
    }

    // SC-BMFK: case B — v outside {27, 28}
    function test_whenSignatureHasBadVThenReverts() public {
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, _digest());
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, abi.encodePacked(r, s, uint8(29)));
    }
}

// ──────────────────────────────────────────────
// SC-BMFL: Revert when lp is not the owner
// ──────────────────────────────────────────────
contract OperatorCollectWrongOwnerTest is OperatorCollectTestBase {
    // SC-BMFL: Safe B's valid CollectIntent for A's position reverts NotPositionOwner
    function test_whenLpIsNotTheOwnerThenReverts() public {
        bytes memory sig = _signCollectIntent(address(vault), LP_B_PK, safeB, positionId, 1, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.collectFor(safeB, positionId, 1, FAR_DEADLINE, sig);

        assertEq(mockUsdc.balanceOf(safeB), 0, "nothing paid");
        assertEq(mockUsdc.balanceOf(safe), 0, "nothing paid");
    }

    // FR-BMFA: a valid CollectIntent for a position that does not exist reverts PositionNotFound
    function test_whenPositionDoesNotExistThenReverts() public {
        bytes memory sig = _signCollectIntent(address(vault), LP_PK, safe, 999, 1, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.collectFor(safe, 999, 1, FAR_DEADLINE, sig);
    }
}

// ──────────────────────────────────────────────
// SC-BMFM: Revert on a non-Operator caller
// ──────────────────────────────────────────────
contract OperatorCollectNonOperatorTest is OperatorCollectTestBase {
    function _expectNotOperator(address caller) internal {
        bytes memory sig = _sig(1);
        vm.prank(caller);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.collectFor(safe, positionId, 1, FAR_DEADLINE, sig);
    }

    // SC-BMFM: an arbitrary address, the Admin, and the Oracle
    function test_whenNonOperatorCallsThenReverts() public {
        _expectNotOperator(makeAddr("nobody"));
        _expectNotOperator(admin);
        _expectNotOperator(oracleAddr);
    }

    // SC-BMFM: the Safe's own collect stays available
    function test_whenRejectedThenSelfServiceCollectWorks() public {
        _expectNotOperator(safe);
        uint256 owed = _owed();

        vm.prank(safe);
        vault.collect(positionId);

        assertEq(mockUsdc.balanceOf(safe), owed, "the self-service path stays open");
    }
}

// ──────────────────────────────────────────────
// SC-BMG6: Revert when a mint, reclaim, or burn authorization is reused as a collect
// ──────────────────────────────────────────────
contract OperatorCollectCrossTypeTest is OperatorCollectTestBase {
    // SC-BMG6: a MintIntent signature is not a collect
    function test_whenMintIntentReusedThenReverts() public {
        bytes memory sig =
            _signMintIntent(address(vault), LP_PK, safe, int24(0), int24(100), 1000, keccak256("setup"), FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, sig);
    }

    // SC-BMG6: a ReclaimIntent signature is not a collect
    function test_whenReclaimIntentReusedThenReverts() public {
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, safe, keccak256("setup"), FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, sig);
    }

    // SC-BMG6: a BurnIntent signature is not a collect
    function test_whenBurnIntentReusedThenReverts() public {
        bytes memory sig = _signBurnIntent(address(vault), LP_PK, safe, positionId, FAR_DEADLINE);
        _expectRevertOnRelay(LPVault.InvalidSignature.selector, 1, sig);
    }

    // SC-BMG6: a CollectIntent signature is rejected by the relayed burn
    function test_whenCollectIntentReusedAsBurnThenReverts() public {
        bytes memory sig = _sig(1);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(safe, positionId, FAR_DEADLINE, sig);
    }
}
