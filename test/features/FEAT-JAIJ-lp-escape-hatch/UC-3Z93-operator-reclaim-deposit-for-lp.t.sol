// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-JAIJ: LP Escape Hatch
// UC-3Z93: Operator Reclaim Deposit for LP
// Integration tests for every scenario in this use case.
// Covers: SC-3Z9D, SC-3Z9F, SC-45IH, SC-3Z9G, SC-3Z9H, SC-3Z9I, SC-9OYF, SC-9OYG, SC-9OYH

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract with shared setup for all reclaimDepositFor scenarios.
// Deploys factory + vault and escrows one intent for the LP's Safe that the
// Operator never mints. The owner key then signs a ReclaimIntent — a type
// distinct from MintIntent — and the Operator relays it.
// ──────────────────────────────────────────────
contract RelayedReclaimTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    /// @dev The owner key's address and its Safe.
    address ownerKey;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 intentId = keccak256("escrowed-intent");
    uint256 escrowAmount = 600;

    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    function setUp() public virtual {
        ownerKey = vm.addr(LP_PK);
        lp = _safeOf(ownerKey);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        _fundSafe(mockUsdc, lp, address(vault), escrowAmount);
        _escrow(vault, operatorAddr, LP_PK, lp, int24(20), int24(80), escrowAmount, intentId, FAR_DEADLINE);
    }

    /// @dev The owner key's ReclaimIntent for the base escrow, with the far deadline.
    function _reclaimSig() internal view returns (bytes memory) {
        return _signReclaimIntent(address(vault), LP_PK, lp, intentId, FAR_DEADLINE);
    }

    /// @dev Relays the base reclaim as the Operator.
    function _relay() internal {
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, _reclaimSig());
    }

    /// @dev Reads the escrow's recorded Safe and amount.
    function _escrowOf(bytes32 id) internal view returns (address recorded, uint96 amount) {
        (recorded, amount,) = vault.pendingDeposits(id);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9D: Refund in one call
// What: The Operator relays the owner key's ReclaimIntent, and the vault
//       refunds the escrowed 600 to the Safe — never to msg.sender — in one
//       call, deletes the escrow, marks the intent used, and refreshes the
//       Operator silence timer.
// Why:  A voluntary cancellation gets the same gas-sponsored path as every
//       other action on the platform (decision C1), with the same
//       escrow-sourced refund as reclaimDeposit (FR-3ZVO).
// ──────────────────────────────────────────────
contract RelayedReclaimSuccessTest is RelayedReclaimTestBase {
    // SC-3Z9D: the Safe receives exactly the escrowed amount
    function test_refundsTheSafe() public {
        uint256 before_ = mockUsdc.balanceOf(lp);
        _relay();
        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its escrow");
    }

    // SC-3Z9D: the Operator, who paid the gas, receives nothing
    function test_paysNothingToTheCaller() public {
        _relay();
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "msg.sender receives nothing");
    }

    // SC-3Z9D: the escrow is deleted, totalEscrowed falls, and the intent is used
    function test_settlesTheRecord() public {
        _relay();

        (address recorded, uint96 amount) = _escrowOf(intentId);
        assertEq(recorded, address(0), "escrow should be deleted");
        assertEq(amount, 0, "escrow amount should be deleted");
        assertEq(vault.totalEscrowed(), 0, "totalEscrowed should fall to 0");
        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
    }

    // SC-3Z9D: DepositReclaimed emitted with the recorded Safe and amount
    function test_emitsDepositReclaimed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, escrowAmount);
        _relay();
    }

    // SC-3Z9D: a relayed reclaim is Operator work and refreshes the silence timer (FR-3ZVR)
    function test_refreshesOperatorSilenceTimer() public {
        vm.warp(block.timestamp + 1 days);
        _relay();
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "relayed reclaim should refresh the timer");
    }

    // SC-3Z9D: no position is created
    function test_createsNoPosition() public {
        _relay();
        assertEq(vault.nextPositionId(), 0, "no position should be created");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9F: Revert when nothing is escrowed for the intent
// What: A valid ReclaimIntent for an intentId that was never funded reverts
//       DepositNotEscrowed.
// Why:  The relayed path offers no way around the escrow requirement, so it
//       cannot drain other LPs' funds (FR-3ZVM).
// ──────────────────────────────────────────────
contract RelayedReclaimNothingEscrowedTest is RelayedReclaimTestBase {
    // SC-3Z9F: a signed reclaim over an unfunded intentId reverts
    function test_revertsWhenNothingEscrowed() public {
        bytes32 unknown = keccak256("never-escrowed");
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, lp, unknown, FAR_DEADLINE);
        uint256 timer = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.reclaimDepositFor(lp, unknown, FAR_DEADLINE, sig);

        assertEq(vault.lastOperatorActivityTimestamp(), timer, "a reverted relay is not proof of life");
    }
}

// ──────────────────────────────────────────────
// SC-45IH: Revert when the escrow belongs to a different Safe
// What: Safe B's owner key validly signs a ReclaimIntent naming B over A's
//       intentId; the relay reverts NotIntentOwner and A's escrow is untouched.
// Why:  The most security-critical check (FR-45IF): a compromised Operator
//       key with an attacker's signature still cannot move A's funds.
// ──────────────────────────────────────────────
contract RelayedReclaimForeignSafeTest is RelayedReclaimTestBase {
    // SC-45IH: B's valid signature over A's intentId reverts NotIntentOwner
    function test_revertsWhenEscrowBelongsToAnotherSafe() public {
        uint256 pkB = 0xB0B;
        address safeB = _safeOf(vm.addr(pkB));
        bytes memory sigB = _signReclaimIntent(address(vault), pkB, safeB, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDepositFor(safeB, intentId, FAR_DEADLINE, sigB);

        (address recorded, uint96 amount) = _escrowOf(intentId);
        assertEq(recorded, lp, "A's escrow still names A");
        assertEq(amount, escrowAmount, "A's escrow amount is untouched");
        assertFalse(vault.usedIntents(intentId), "A's intent stays unused");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9G: Revert when a mint authorization is replayed as a reclaim
// What: The Operator submits the owner key's MintIntent signature to
//       reclaimDepositFor; the vault recovers a signer against the
//       ReclaimIntent typehash, derives a different Safe, and reverts
//       InvalidSignature. The escrow stays mintable.
// Why:  A mint authorization must never double as a cancellation
//       (ADR-4029, FR-3ZVP).
// ──────────────────────────────────────────────
contract RelayedReclaimTypehashTest is RelayedReclaimTestBase {
    // SC-3Z9G: the MintIntent signature is rejected by reclaimDepositFor
    function test_mintSignatureIsRejectedAsReclaim() public {
        bytes memory mintSig =
            _signMintIntent(address(vault), LP_PK, lp, int24(20), int24(80), escrowAmount, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, mintSig);

        (address recorded,) = _escrowOf(intentId);
        assertEq(recorded, lp, "the escrow stays intact and mintable");
    }

    // FR-3ZVP: the ReclaimIntent signature is rejected by depositForIntent
    function test_reclaimSignatureIsRejectedAsDeposit() public {
        bytes32 fresh = keccak256("fresh");
        _fundSafe(mockUsdc, lp, address(vault), escrowAmount);
        bytes memory reclaimSig = _signReclaimIntent(address(vault), LP_PK, lp, fresh, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, int24(20), int24(80), escrowAmount, fresh, FAR_DEADLINE, reclaimSig);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9H: Revert on non-operator caller
// What: The Safe, its owner key, Admin, Oracle, and an arbitrary address all
//       get NotOperator on reclaimDepositFor, even with a valid ReclaimIntent.
// Why:  The relayed path is the Operator's; the Safe's own reclaimDeposit
//       (UC-JAIK) stays available (FR-3ZVQ).
// ──────────────────────────────────────────────
contract RelayedReclaimAccessControlTest is RelayedReclaimTestBase {
    function _relayAs(address caller) internal {
        bytes memory sig = _reclaimSig();
        vm.prank(caller);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, sig);
    }

    // SC-3Z9H: the Safe itself
    function test_revertsForTheSafe() public {
        _relayAs(lp);
    }

    // SC-3Z9H: the owner key
    function test_revertsForTheOwnerKey() public {
        _relayAs(ownerKey);
    }

    // SC-3Z9H: Admin
    function test_revertsForAdmin() public {
        _relayAs(admin);
    }

    // SC-3Z9H: Oracle
    function test_revertsForOracle() public {
        _relayAs(oracleAddr);
    }

    // SC-3Z9H: an arbitrary address
    function test_revertsForNobody() public {
        _relayAs(makeAddr("nobody"));
    }

    // SC-3Z9H: the Safe's own path stays open after a failed relay
    function test_directReclaimStillAvailable() public {
        _relayAs(makeAddr("nobody"));

        vm.prank(lp);
        vault.reclaimDeposit(intentId);
        assertEq(mockUsdc.balanceOf(lp), escrowAmount, "the Safe reclaims on its own");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9I: Revert when the intent has already been used
// What: After a mint, or after a reclaim through either path, a relayed
//       reclaim reverts IntentAlreadyUsed.
// Why:  One usedIntents namespace across the mint and both reclaims, so no
//       intent settles twice (ADR-JAIY).
// ──────────────────────────────────────────────
contract RelayedReclaimUsedIntentTest is RelayedReclaimTestBase {
    // SC-3Z9I: used by the mint
    function test_revertsAfterMint() public {
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), escrowAmount, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, _reclaimSig());
    }

    // SC-3Z9I: used by the direct reclaim
    function test_revertsAfterDirectReclaim() public {
        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, _reclaimSig());
    }

    // SC-3Z9I: used by a previous relayed reclaim
    function test_revertsAfterRelayedReclaim() public {
        _relay();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, intentId, FAR_DEADLINE, _reclaimSig());
    }
}

// ──────────────────────────────────────────────
// SC-9OYF: Revert after the deadline
// What: A relay at block.timestamp = T + 1 for a ReclaimIntent with deadline
//       T reverts IntentExpired; at T it succeeds. The Safe's own
//       reclaimDeposit has no deadline.
// Why:  Every LP-signed type carries a deadline (FR-9OYJ), and the deadline
//       is inclusive.
// ──────────────────────────────────────────────
contract RelayedReclaimDeadlineTest is RelayedReclaimTestBase {
    uint256 deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
    }

    // SC-9OYF: one second past the deadline reverts
    function test_revertsAfterDeadline() public {
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, lp, intentId, deadline);
        vm.warp(deadline + 1);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentExpired.selector);
        vault.reclaimDepositFor(lp, intentId, deadline, sig);
    }

    // SC-9OYF: exactly at the deadline succeeds
    function test_succeedsAtDeadline() public {
        bytes memory sig = _signReclaimIntent(address(vault), LP_PK, lp, intentId, deadline);
        vm.warp(deadline);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, intentId, deadline, sig);

        assertEq(mockUsdc.balanceOf(lp), escrowAmount, "the Safe should receive its escrow at the deadline");
    }

    // SC-9OYF: the Safe's own path has no deadline
    function test_directReclaimHasNoDeadline() public {
        vm.warp(deadline + 365 days);

        vm.prank(lp);
        vault.reclaimDeposit(intentId);

        assertEq(mockUsdc.balanceOf(lp), escrowAmount, "the direct reclaim never expires");
    }
}

// ──────────────────────────────────────────────
// SC-9OYG: Revert when the owner key derives a different Safe
// What: A key whose derived Safe is not S signs a ReclaimIntent naming S; a
//       signature names the signer's own address as lp; a high-s signature;
//       a v outside {27, 28}; a wrong length. All revert InvalidSignature.
// Why:  The same owner-key check as the deposit, through the shared
//       _verifySafeOwnerSignature and _recoverSigner (NFR-JAIX).
// ──────────────────────────────────────────────
contract RelayedReclaimSignatureTest is RelayedReclaimTestBase {
    function _expectInvalid(address named, bytes memory sig) internal {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(named, intentId, FAR_DEADLINE, sig);
    }

    // SC-9OYG: another key signing for Safe S reverts
    function test_revertsWhenKeyDerivesAnotherSafe() public {
        _expectInvalid(lp, _signReclaimIntent(address(vault), 0xB0B, lp, intentId, FAR_DEADLINE));
    }

    // SC-9OYG: naming the owner key's own address reverts
    function test_revertsWhenLpIsTheOwnerKeyItself() public {
        _expectInvalid(ownerKey, _signReclaimIntent(address(vault), LP_PK, ownerKey, intentId, FAR_DEADLINE));
    }

    // SC-9OYG: high-s reverts
    function test_revertsOnHighS() public {
        bytes32 structHash = keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, intentId, FAR_DEADLINE));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        _expectInvalid(lp, abi.encodePacked(r, bytes32(secp256k1n - uint256(s)), v == 27 ? uint8(28) : uint8(27)));
    }

    // SC-9OYG: v outside {27, 28} reverts
    function test_revertsOnInvalidV() public {
        bytes32 structHash = keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, intentId, FAR_DEADLINE));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), structHash));
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        _expectInvalid(lp, abi.encodePacked(r, s, uint8(29)));
    }

    // SC-9OYG: wrong length reverts
    function test_revertsOnWrongLength() public {
        _expectInvalid(lp, "");
    }
}

// ──────────────────────────────────────────────
// SC-9OYH: Works while paused, in WindDown, and after the freeze
// What: The relayed reclaim refunds the Safe while the vault is paused, after
//       startWindDown, and after emergencyCancelAll set phase 3.
// Why:  No phase check and no pause check on either reclaim path (FR-9OYO);
//       the Cancelled phase never locks a pending deposit (audit issue 6.7).
// ──────────────────────────────────────────────
contract RelayedReclaimInEveryPhaseTest is RelayedReclaimTestBase {
    function _assertRelayPays() internal {
        uint256 before_ = mockUsdc.balanceOf(lp);
        _relay();
        assertEq(mockUsdc.balanceOf(lp) - before_, escrowAmount, "the Safe should receive its escrow");
    }

    // SC-9OYH: paused
    function test_relaySucceedsWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();
        _assertRelayPays();
    }

    // SC-9OYH: WindDown
    function test_relaySucceedsInWindDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();
        _assertRelayPays();
    }

    // SC-9OYH: Cancelled
    function test_relaySucceedsAfterEmergencyCancel() public {
        uint256 holderPk = 0xB0B;
        _escrowAndMint(vault, operatorAddr, holderPk, int24(0), int24(100), 1000, keccak256("holder"));
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
        vm.prank(_safeOf(vm.addr(holderPk)));
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        _assertRelayPays();
    }
}
