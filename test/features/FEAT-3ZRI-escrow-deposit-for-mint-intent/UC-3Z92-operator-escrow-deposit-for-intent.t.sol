// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-3ZRI: Escrow Deposit for Mint Intent
// UC-3Z92: Operator Escrow Deposit for Intent
// Integration tests for every scenario in this use case.
// Covers: SC-3Z94, SC-45IB, SC-3Z95, SC-3Z96, SC-3Z97, SC-3Z98, SC-3Z99, SC-3Z9A, SC-3Z9B, SC-9OY9, SC-9OYA, SC-9OYB, SC-9OYC, SC-9OYD

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract with shared setup for all escrow scenarios.
// Deploys factory + vault, funds the LP's Safe, and signs intents with the
// Safe's owner key. The Safe has no code: vm.prank(safe) stands in for the
// relayed Safe transaction that approves the vault (decision C25).
// ──────────────────────────────────────────────
contract EscrowDepositTestBase is LPVaultFixture {
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

    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("intent-x");

    event DepositEscrowed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

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

        _fundSafe(mockUsdc, lp, address(vault), usdcAmount);
    }

    /// @dev Signs the base intent with the owner key, naming the Safe, with the far deadline.
    function _sig() internal view returns (bytes memory) {
        return _signMintIntent(address(vault), LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
    }

    /// @dev The base intent's struct hash, as the vault records it.
    function _structHash() internal view returns (bytes32) {
        return keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE));
    }

    /// @dev Escrows the base intent as the Operator.
    function _depositBase() internal {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());
    }

    /// @dev Reads the escrow entry.
    function _escrowOf(bytes32 id) internal view returns (address recorded, uint96 amount, bytes32 structHash) {
        (recorded, amount, structHash) = vault.pendingDeposits(id);
    }
}

// ──────────────────────────────────────────────
// SC-3Z94: Successful escrow of a signed mint intent
// What: The Operator escrows an intent the owner key signed for its Safe.
//       The vault records the Safe, 600, and the intent hash, adds 600 to
//       totalEscrowed, pulls 600 USDC from the Safe, refreshes the Operator
//       silence timer, and emits DepositEscrowed. No position, no tick, and
//       no usedIntents write.
// Why:  This is the one entry point for USDC into a position. Every dollar
//       the vault holds for an LP must have a recorded owner (ADR-3Z9Y).
// Example: Safe holds 600 and approved the vault; after the call the vault
//          holds 600, pendingDeposits[X] = (Safe, 600, hash).
// ──────────────────────────────────────────────
contract EscrowDepositSuccessTest is EscrowDepositTestBase {
    // SC-3Z94: the escrow entry holds the Safe, the amount, and the hash
    function test_recordsEscrowEntry() public {
        _depositBase();

        (address recorded, uint96 amount, bytes32 structHash) = _escrowOf(intentId);
        assertEq(recorded, lp, "escrow should record the Safe");
        assertEq(amount, usdcAmount, "escrow should record 600");
        assertEq(structHash, _structHash(), "escrow should record the intent hash");
    }

    // SC-3Z94: totalEscrowed increases by 600
    function test_increasesTotalEscrowed() public {
        _depositBase();
        assertEq(vault.totalEscrowed(), usdcAmount, "totalEscrowed should increase by 600");
    }

    // SC-3Z94: 600 USDC moves from the Safe to the vault
    function test_pullsUsdcFromSafe() public {
        _depositBase();

        assertEq(mockUsdc.balanceOf(lp), 0, "the Safe's 600 should be gone");
        assertEq(mockUsdc.balanceOf(address(vault)), usdcAmount, "the vault should hold 600");
    }

    // SC-3Z94: DepositEscrowed emitted with the Safe and the amount
    function test_emitsDepositEscrowed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositEscrowed(intentId, lp, usdcAmount);
        _depositBase();
    }

    // SC-3Z94: no position, no tick, no usedIntents write, no activeLiquidity change
    function test_createsNoPositionAndConsumesNoIntent() public {
        _depositBase();

        assertEq(vault.nextPositionId(), 0, "no position should be created");
        (uint128 gross,,,) = vault.ticks(tickLower);
        assertEq(gross, 0, "no tick should be touched");
        assertFalse(vault.usedIntents(intentId), "the intent is funded, not consumed");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should not change");
    }

    // SC-3Z94: a successful escrow refreshes the Operator silence timer (FR-3Z9S)
    function test_refreshesOperatorSilenceTimer() public {
        vm.warp(block.timestamp + 1 days);
        _depositBase();
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "escrow should refresh the silence timer");
    }

    // SC-3Z94: the escrowed intent is mintable and then refundable by nobody else
    function test_escrowIsMintable() public {
        _depositBase();

        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);

        (address owner,,,,,,) = vault.positions(posId);
        assertEq(owner, lp, "the position should belong to the Safe");
    }
}

// ──────────────────────────────────────────────
// SC-45IB: The escrow entry names its depositor and the intent hash
// What: pendingDeposits(X) holds Safe A, the amount, and keccak256 of the
//       MintIntent encoding; an intentId that was never escrowed reads back
//       a zero Safe.
// Why:  A valid signature does not prove who owns an intentId: any owner key
//       can sign over X naming its own Safe. The recorded Safe is what every
//       spending path checks (ADR-45IC), and the recorded hash binds the
//       terms for the mint (FR-3Z9W).
// ──────────────────────────────────────────────
contract EscrowEntryNamesDepositorTest is EscrowDepositTestBase {
    // SC-45IB: the entry's Safe is A, and the hash is the MintIntent hash with the deadline
    function test_entryNamesSafeAndHash() public {
        _depositBase();

        (address recorded,, bytes32 structHash) = _escrowOf(intentId);
        assertEq(recorded, lp, "the entry should name Safe A");
        assertEq(
            structHash,
            keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE)),
            "the entry should hold the MintIntent struct hash, deadline included"
        );
    }

    // SC-45IB: an intentId that was never escrowed reads back a zero Safe
    function test_unknownIntentReadsZeroSafe() public view {
        (address recorded, uint96 amount, bytes32 structHash) = _escrowOf(keccak256("never"));
        assertEq(recorded, address(0), "no escrow means a zero Safe");
        assertEq(amount, 0, "no escrow means a zero amount");
        assertEq(structHash, bytes32(0), "no escrow means a zero hash");
    }

    // SC-45IB: another owner key signing over the same intentId, naming its own Safe, gets its own
    // escrow only under a different intentId — the same intentId is blocked (SC-3Z95)
    function test_anotherSafeCannotTakeOverTheIntentId() public {
        _depositBase();

        uint256 pkB = 0xB0B;
        address safeB = _safeOf(vm.addr(pkB));
        _fundSafe(mockUsdc, safeB, address(vault), usdcAmount);
        bytes memory sigB =
            _signMintIntent(address(vault), pkB, safeB, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(safeB, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sigB);

        (address recorded,,) = _escrowOf(intentId);
        assertEq(recorded, lp, "the entry still names Safe A");
    }
}

// ──────────────────────────────────────────────
// SC-3Z95: Revert when the intent is already escrowed
// SC-3Z96: Revert when the intent has already been used
// What: A second deposit for an escrowed intentId reverts
//       DepositAlreadyEscrowed; a deposit for a used intentId reverts
//       IntentAlreadyUsed. No USDC moves either way.
// Why:  Never take the USDC twice for one intent (audit issue 6.2), and a
//       spent intent can never be funded again (ADR-JAIY).
// ──────────────────────────────────────────────
contract EscrowDuplicateAndUsedTest is EscrowDepositTestBase {
    // SC-3Z95: a second deposit for the same Safe reverts and the record is unchanged
    function test_revertsWhenAlreadyEscrowed() public {
        _depositBase();
        _fundSafe(mockUsdc, lp, address(vault), usdcAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());

        (, uint96 amount,) = _escrowOf(intentId);
        assertEq(amount, usdcAmount, "the record is unchanged");
        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "the second 600 stays in the Safe");
        assertEq(vault.totalEscrowed(), usdcAmount, "totalEscrowed counts one escrow");
    }

    // SC-3Z96: a deposit for an intentId the mint consumed reverts IntentAlreadyUsed
    function test_revertsWhenIntentUsedByMint() public {
        _depositBase();
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
        _fundSafe(mockUsdc, lp, address(vault), usdcAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());

        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }

    // SC-3Z96: a deposit for an intentId a reclaim consumed reverts IntentAlreadyUsed
    function test_revertsWhenIntentUsedByReclaim() public {
        _depositBase();
        vm.prank(lp);
        vault.reclaimDeposit(intentId);
        vm.prank(lp);
        mockUsdc.approve(address(vault), usdcAmount);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());

        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }
}

// ──────────────────────────────────────────────
// SC-3Z97: Revert on an owner key that does not derive the Safe
// What: A signature from a key whose derived Safe is not `lp`, an intent that
//       names the owner's own address as `lp`, a high-s signature, a v outside
//       {27, 28}, a wrong length, or a tampered field all revert
//       InvalidSignature, and no USDC moves.
// Why:  The Safe, not the signer, owns the deposit (decision C23). The
//       malleability rules are CLAUDE.md checklist item 5, applied once in
//       _recoverSigner.
// ──────────────────────────────────────────────
contract EscrowSignatureTest is EscrowDepositTestBase {
    function _expectInvalid(address named, bytes memory sig) internal {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(named, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }

    // SC-3Z97: a different owner key signing for Safe S reverts
    function test_revertsWhenKeyDerivesAnotherSafe() public {
        bytes memory sig =
            _signMintIntent(address(vault), 0xB0B, lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
        _expectInvalid(lp, sig);
    }

    // SC-3Z97: naming the owner key's own address as lp reverts — a Safe, never an EOA
    function test_revertsWhenLpIsTheOwnerKeyItself() public {
        bytes memory sig =
            _signMintIntent(address(vault), LP_PK, ownerKey, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(ownerKey, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
    }

    // SC-3Z97: a tampered field (the amount) reverts
    function test_revertsOnTamperedField() public {
        bytes memory sig =
            _signMintIntent(address(vault), LP_PK, lp, tickLower, tickUpper, usdcAmount - 1, intentId, FAR_DEADLINE);
        _expectInvalid(lp, sig);
    }

    // SC-3Z97: a high-s signature reverts
    function test_revertsOnHighS() public {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), _structHash()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(secp256k1n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        _expectInvalid(lp, abi.encodePacked(r, highS, flippedV));
    }

    // SC-3Z97: a v outside {27, 28} reverts
    function test_revertsOnInvalidV() public {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), _structHash()));
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        _expectInvalid(lp, abi.encodePacked(r, s, uint8(26)));
    }

    // SC-3Z97: a wrong length reverts
    function test_revertsOnWrongLength() public {
        _expectInvalid(lp, "");
        _expectInvalid(lp, hex"0102");
    }

    // SC-3Z97: a well-formed signature that recovers to address(0) reverts (r = 0 is not on the curve)
    function test_revertsOnZeroRecovery() public {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(vault)), _structHash()));
        (uint8 v,, bytes32 s) = vm.sign(LP_PK, digest);
        _expectInvalid(lp, abi.encodePacked(bytes32(0), s, v));
    }

    // SC-3Z97: a zero recovery reverts even when `lp` is the Safe that address(0) would derive.
    // _recoverSigner returns address(0) for every unusable signature (FEAT-C0DJ, ADR-C0YQ), so
    // the explicit zero check in _verifySafeOwnerSignature is what stops this pairing from
    // matching; the Safe comparison alone would let it through.
    function test_revertsOnZeroRecoveryNamingTheZeroDerivedSafe() public {
        address zeroSafe = _safeOf(address(0));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(zeroSafe, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, "");
    }
}

// ──────────────────────────────────────────────
// SC-3Z98: Revert on non-operator caller
// What: The Safe, its owner key, Admin, Oracle, and an arbitrary address all
//       get NotOperator, even with a valid signature.
// Why:  ADR-3Z9Z: the Operator chokepoint keeps an attacker from seeding a
//       position ahead of a real LP's deposit. A refusal leaves the USDC in
//       the Safe, so there is nothing to rescue.
// ──────────────────────────────────────────────
contract EscrowAccessControlTest is EscrowDepositTestBase {
    function _depositAs(address caller) internal {
        bytes memory sig = _sig();
        vm.prank(caller);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
    }

    // SC-3Z98: the Safe itself
    function test_revertsForTheSafe() public {
        _depositAs(lp);
    }

    // SC-3Z98: the owner key
    function test_revertsForTheOwnerKey() public {
        _depositAs(ownerKey);
    }

    // SC-3Z98: Admin
    function test_revertsForAdmin() public {
        _depositAs(admin);
    }

    // SC-3Z98: Oracle
    function test_revertsForOracle() public {
        _depositAs(oracleAddr);
    }

    // SC-3Z98: an arbitrary address
    function test_revertsForNobody() public {
        _depositAs(makeAddr("nobody"));
    }
}

// ──────────────────────────────────────────────
// SC-3Z99: Revert on zero amount
// SC-9OYA: Revert on an inverted, out-of-scale, or misaligned range
// What: usdcAmount == 0 reverts ZeroAmount; tickLower >= tickUpper, a tick
//       below 0, or a tick above 10000 reverts InvalidRange; a tick that is
//       not a multiple of tickSpacing reverts TickNotAligned. No escrow entry
//       is written.
// Why:  The vault never takes USDC it can only refund: a zero escrow could
//       never mint (FR-T7B5), and the mint always rejects a bad range
//       (FR-9OYL, one _requireValidRange shared with the mint).
// ──────────────────────────────────────────────
contract EscrowValidationTest is EscrowDepositTestBase {
    function _expect(bytes4 selector, int24 tl, int24 tu, uint256 amount) internal {
        bytes memory sig = _signMintIntent(address(vault), LP_PK, lp, tl, tu, amount, intentId, FAR_DEADLINE);
        vm.prank(operatorAddr);
        vm.expectRevert(selector);
        vault.depositForIntent(lp, tl, tu, amount, intentId, FAR_DEADLINE, sig);
        (address recorded,,) = _escrowOf(intentId);
        assertEq(recorded, address(0), "no escrow written");
        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }

    // SC-3Z99: zero amount
    function test_revertsOnZeroAmount() public {
        _expect(LPVault.ZeroAmount.selector, tickLower, tickUpper, 0);
    }

    // FR-45IA: an amount above uint96 reverts SafeCastOverflow instead of truncating the record
    function test_revertsWhenAmountExceedsUint96() public {
        uint256 tooLarge = uint256(type(uint96).max) + 1;
        _fundSafe(mockUsdc, lp, address(vault), tooLarge);
        bytes memory sig =
            _signMintIntent(address(vault), LP_PK, lp, tickLower, tickUpper, tooLarge, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.SafeCastOverflow.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, tooLarge, intentId, FAR_DEADLINE, sig);

        (address recorded,,) = _escrowOf(intentId);
        assertEq(recorded, address(0), "no escrow written");
    }

    // SC-9OYA: inverted range
    function test_revertsOnInvertedRange() public {
        _expect(LPVault.InvalidRange.selector, int24(80), int24(20), usdcAmount);
    }

    // SC-9OYA: equal ticks
    function test_revertsOnEqualTicks() public {
        _expect(LPVault.InvalidRange.selector, int24(50), int24(50), usdcAmount);
    }

    // SC-9OYA, FR-9OYL: a negative lower tick is outside the price scale
    function test_revertsWhenLowerTickIsBelowZero() public {
        _expect(LPVault.InvalidRange.selector, int24(-10), int24(20), usdcAmount);
    }

    // SC-9OYA, FR-9OYL: an upper tick above PRICE_TICK_ONE is outside the price scale
    function test_revertsWhenUpperTickIsAbovePriceOne() public {
        _expect(LPVault.InvalidRange.selector, int24(9990), int24(10010), usdcAmount);
    }

    // SC-9OYA: misaligned lower tick
    function test_revertsOnMisalignedLowerTick() public {
        _expect(LPVault.TickNotAligned.selector, int24(15), int24(80), usdcAmount);
    }

    // SC-9OYA: misaligned upper tick
    function test_revertsOnMisalignedUpperTick() public {
        _expect(LPVault.TickNotAligned.selector, int24(20), int24(75), usdcAmount);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9A: Revert when the vault is not Active
// What: A deposit into a WindDown or Cancelled vault reverts VaultNotActive,
//       and a deposit into a paused vault reverts TradingIsPaused.
// Why:  An escrow only funds a mint, and mints are Active-only and gated by
//       the pause. No new USDC enters a vault that cannot mint (FR-3Z9P).
// ──────────────────────────────────────────────
contract EscrowPhaseTest is EscrowDepositTestBase {
    function _expectPhaseRevert(bytes4 selector) internal {
        bytes memory sig = _sig();
        vm.prank(operatorAddr);
        vm.expectRevert(selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }

    // SC-3Z9A: WindDown
    function test_revertsInWindDown() public {
        vm.prank(oracleAddr);
        vault.startWindDown();
        _expectPhaseRevert(LPVault.VaultNotActive.selector);
    }

    // SC-3Z9A: Cancelled
    function test_revertsInCancelled() public {
        // A minted position by another Safe gives someone the right to cancel
        _escrowAndMint(vault, operatorAddr, 0xB0B, int24(0), int24(100), 1000, keccak256("holder"));
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vm.prank(_safeOf(vm.addr(0xB0B)));
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        _expectPhaseRevert(LPVault.VaultNotActive.selector);
    }

    // SC-3Z9A: paused
    function test_revertsWhilePaused() public {
        vm.prank(admin);
        vault.pauseTrading();
        _expectPhaseRevert(LPVault.TradingIsPaused.selector);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9B: Failed escrow leaves the Operator silence timer untouched
// What: A reverting deposit — duplicate escrow, zero amount — leaves
//       lastOperatorActivityTimestamp where it was.
// Why:  A failed call is not proof of life (FR-JXQS), so a stuck Operator
//       cannot hold off emergencyCancelAll by spamming reverting deposits.
// ──────────────────────────────────────────────
contract EscrowFailedCallHeartbeatTest is EscrowDepositTestBase {
    // SC-3Z9B: a duplicate escrow that reverts does not move the timer
    function test_duplicateEscrowLeavesTimerUntouched() public {
        _depositBase();
        uint256 timer = vault.lastOperatorActivityTimestamp();
        _fundSafe(mockUsdc, lp, address(vault), usdcAmount);

        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());

        assertEq(vault.lastOperatorActivityTimestamp(), timer, "a reverted deposit is not proof of life");
    }

    // SC-3Z9B: a zero-amount deposit that reverts does not move the timer
    function test_zeroAmountLeavesTimerUntouched() public {
        uint256 timer = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);
        bytes memory sig = _signMintIntent(address(vault), LP_PK, lp, tickLower, tickUpper, 0, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, 0, intentId, FAR_DEADLINE, sig);

        assertEq(vault.lastOperatorActivityTimestamp(), timer, "a reverted deposit is not proof of life");
    }
}

// ──────────────────────────────────────────────
// SC-9OY9: Revert after the deadline
// What: A deposit at block.timestamp = T + 1 for an intent with deadline T
//       reverts IntentExpired; the same deposit at T succeeds.
// Why:  Without a deadline a signed intent stays valid forever and an
//       Operator could escrow it months later (decision C23). The deadline is
//       inclusive and applies once, at the deposit (FR-9OYK).
// ──────────────────────────────────────────────
contract EscrowDeadlineTest is EscrowDepositTestBase {
    uint256 deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
    }

    function _sigWithDeadline() internal view returns (bytes memory) {
        return _signMintIntent(address(vault), LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId, deadline);
    }

    // SC-9OY9: one second past the deadline reverts
    function test_revertsAfterDeadline() public {
        bytes memory sig = _sigWithDeadline();
        vm.warp(deadline + 1);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentExpired.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, sig);

        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "no USDC moves");
    }

    // SC-9OY9: exactly at the deadline succeeds — the deadline is inclusive
    function test_succeedsAtDeadline() public {
        bytes memory sig = _sigWithDeadline();
        vm.warp(deadline);

        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, sig);

        (address recorded,,) = _escrowOf(intentId);
        assertEq(recorded, lp, "the escrow should be recorded at the deadline");
    }
}

// ──────────────────────────────────────────────
// SC-9OYB: The derived Safe matches the deployed Safe factory
// What: With the real Polygon and Amoy derivation inputs, the vault accepts
//       an intent naming the Safe that the live factories derive for the test
//       key, and rejects the same intent naming the owner's own address.
// Why:  Proves the CREATE2 formula against the deployed contracts without a
//       vendored artifact. Both expected Safe addresses were read from the
//       live factories' computeProxyAddress on 2026-09-12, and reproduce with
//       `cast` from the inputs in DEPLOYMENT.md.
// ──────────────────────────────────────────────
contract EscrowRealSafeVectorsTest is EscrowDepositTestBase {
    address constant POLYGON_SAFE_FACTORY = 0xD0d6655B69d5589402593a854836bbe5305ab09B;
    bytes32 constant POLYGON_PROXY_BYTECODE_HASH = 0x4b856c0ca50349cc4a9add5f9bfa9cb369b54f8b87f90023a3fb45b49eadec50;
    address constant POLYGON_SAFE_FOR_TEST_KEY = 0x511894A9736bdE6F848364A33e81F67cC183655E;

    address constant AMOY_SAFE_FACTORY = 0x0F95cE955dE28995F41f0A89B61aEa1c5e8F4c7a;
    bytes32 constant AMOY_PROXY_BYTECODE_HASH = 0x182112daed9969029a2a0edb10305e67a23eb3aa54543a1b8c7c08e9c8977c48;
    address constant AMOY_SAFE_FOR_TEST_KEY = 0x40953b353BFFa880AD4EF3A38f994625fD92aEf3;

    /// @dev The test key's address, as in the exploration and DEPLOYMENT.md.
    address constant TEST_KEY_ADDRESS = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

    /// @dev Builds a vault whose factory holds real derivation inputs.
    function _vaultWith(address safeFactory, bytes32 hash) internal returns (LPVault v) {
        LPVault impl = new LPVault();
        LPVaultFactory f = new LPVaultFactory(
            address(impl),
            address(mockUsdc),
            exchangeAddr,
            address(ctf),
            admin,
            oracleAddr,
            operatorAddr,
            safeFactory,
            hash
        );
        v = LPVault(_createVault(f, oracleAddr, keccak256(abi.encode(safeFactory)), vaultTickSpacing, minFirstLiq));
    }

    function _escrowOn(LPVault v, address named) internal {
        _fundSafe(mockUsdc, named, address(v), usdcAmount);
        bytes memory sig =
            _signMintIntent(address(v), LP_PK, named, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
        vm.prank(operatorAddr);
        v.depositForIntent(named, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
    }

    // SC-9OYB: the test key is the one the vectors were computed for
    function test_testKeyAddressMatchesVectors() public view {
        assertEq(ownerKey, TEST_KEY_ADDRESS, "0xA11CE should be the vectors' owner key");
    }

    // SC-9OYB: the fixture's formula reproduces both live Safe addresses
    function test_fixtureFormulaMatchesLiveFactories() public pure {
        assertEq(
            _deriveSafe(POLYGON_SAFE_FACTORY, POLYGON_PROXY_BYTECODE_HASH, TEST_KEY_ADDRESS),
            POLYGON_SAFE_FOR_TEST_KEY,
            "Polygon derivation should match computeProxyAddress"
        );
        assertEq(
            _deriveSafe(AMOY_SAFE_FACTORY, AMOY_PROXY_BYTECODE_HASH, TEST_KEY_ADDRESS),
            AMOY_SAFE_FOR_TEST_KEY,
            "Amoy derivation should match computeProxyAddress"
        );
    }

    // SC-9OYB: the Polygon vault accepts the live Safe
    function test_polygonVaultAcceptsTheLiveSafe() public {
        LPVault v = _vaultWith(POLYGON_SAFE_FACTORY, POLYGON_PROXY_BYTECODE_HASH);
        _escrowOn(v, POLYGON_SAFE_FOR_TEST_KEY);

        (address recorded,,) = v.pendingDeposits(intentId);
        assertEq(recorded, POLYGON_SAFE_FOR_TEST_KEY, "the Polygon vault should record the live Safe");
    }

    // SC-9OYB: the Polygon vault rejects the owner's own address
    function test_polygonVaultRejectsTheOwnerAddress() public {
        LPVault v = _vaultWith(POLYGON_SAFE_FACTORY, POLYGON_PROXY_BYTECODE_HASH);
        _fundSafe(mockUsdc, ownerKey, address(v), usdcAmount);
        bytes memory sig =
            _signMintIntent(address(v), LP_PK, ownerKey, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        v.depositForIntent(ownerKey, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
    }

    // SC-9OYB: the Amoy vault accepts the live Safe
    function test_amoyVaultAcceptsTheLiveSafe() public {
        LPVault v = _vaultWith(AMOY_SAFE_FACTORY, AMOY_PROXY_BYTECODE_HASH);
        _escrowOn(v, AMOY_SAFE_FOR_TEST_KEY);

        (address recorded,,) = v.pendingDeposits(intentId);
        assertEq(recorded, AMOY_SAFE_FOR_TEST_KEY, "the Amoy vault should record the live Safe");
    }

    // SC-9OYB: a Polygon Safe is not accepted on the Amoy vault — the inputs differ per chain
    function test_amoyVaultRejectsThePolygonSafe() public {
        LPVault v = _vaultWith(AMOY_SAFE_FACTORY, AMOY_PROXY_BYTECODE_HASH);
        _fundSafe(mockUsdc, POLYGON_SAFE_FOR_TEST_KEY, address(v), usdcAmount);
        bytes memory sig = _signMintIntent(
            address(v), LP_PK, POLYGON_SAFE_FOR_TEST_KEY, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE
        );

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        v.depositForIntent(POLYGON_SAFE_FOR_TEST_KEY, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, sig);
    }
}

// ──────────────────────────────────────────────
// SC-9OYC: A plain USDC transfer is not a deposit
// What: A Safe that transferred USDC to the vault directly, with a signed
//       intent but no depositForIntent, cannot mint and cannot reclaim: both
//       revert DepositNotEscrowed, and totalEscrowed stays 0.
// Why:  Decision C25: a plain transfer carries no record of who paid, which
//       is the cause of audit issues 6.1 and 6.2. The vault never credits it.
// ──────────────────────────────────────────────
contract EscrowPlainTransferTest is EscrowDepositTestBase {
    function setUp() public override {
        super.setUp();
        // The Safe sends its 600 straight to the vault instead of through the Operator
        vm.prank(lp);
        mockUsdc.transfer(address(vault), usdcAmount);
        assertEq(mockUsdc.balanceOf(address(vault)), usdcAmount, "precondition: the vault holds the plain transfer");
    }

    // SC-9OYC: the mint reverts DepositNotEscrowed
    function test_mintRevertsForPlainTransfer() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
    }

    // SC-9OYC: the reclaim reverts DepositNotEscrowed
    function test_reclaimRevertsForPlainTransfer() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.reclaimDeposit(intentId);
    }

    // SC-9OYC: totalEscrowed stays 0
    function test_totalEscrowedIsZero() public view {
        assertEq(vault.totalEscrowed(), 0, "a plain transfer is never escrowed");
    }
}

// ──────────────────────────────────────────────
// SC-9OYD: Revert when the Safe allowance is missing
// What: A Safe that holds the USDC but approved less than the amount makes
//       the pull fail with TransferFailed, and no escrow entry is written.
// Why:  Checks-effects-interactions leaves no record behind a failed pull
//       (NFR-3Z9U). An escrow entry without USDC would be a claim on other
//       LPs' funds.
// ──────────────────────────────────────────────
contract EscrowAllowanceTest is EscrowDepositTestBase {
    // SC-9OYD: a short allowance reverts TransferFailed and writes nothing
    function test_revertsWhenAllowanceIsShort() public {
        vm.prank(lp);
        mockUsdc.approve(address(vault), usdcAmount - 1);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TransferFailed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE, _sig());

        (address recorded,,) = _escrowOf(intentId);
        assertEq(recorded, address(0), "no escrow written");
        assertEq(vault.totalEscrowed(), 0, "totalEscrowed unchanged");
        assertEq(mockUsdc.balanceOf(lp), usdcAmount, "the Safe keeps its USDC");
    }
}
