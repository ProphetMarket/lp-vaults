// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-3Z92: Operator Escrow Deposit for Intent
// Integration tests for every scenario in this use case.
// Covers: SC-3Z94, SC-45IB, SC-3Z95, SC-3Z96, SC-3Z97, SC-3Z98, SC-3Z99, SC-3Z9A, SC-3Z9B

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// MockERC20 with transferFrom support for escrow tests.
// Tracks balances and allowances so tests can assert on USDC movement
// between the LP's wallet and the vault.
// ──────────────────────────────────────────────
contract MockERC20ForEscrow {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockConditionalTokens {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// Base test contract with shared setup for all escrow scenarios.
// Deploys factory, creates vault, funds the LP, and provides the EIP-712
// signing helper. depositForIntent verifies the SAME MintIntent struct that
// mintPositionFor verifies — the LP signs once and that one signature
// authorizes both the escrow and the later mint.
// ──────────────────────────────────────────────
contract EscrowDepositTestBase is Test {
    using stdStorage for StdStorage;

    LPVaultFactory factory;
    LPVault vault;
    MockERC20ForEscrow mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");
    address stranger = makeAddr("stranger");

    uint256 constant LP_PK = 0xA11CE;
    uint256 constant IMPOSTOR_PK = 0xB0B;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    // The canonical intent used across scenarios: a well-formed range that
    // mintPositionFor would accept, so nothing but the escrow rules is under test.
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("escrow-intent-1");

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event DepositEscrowed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20ForEscrow();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        // Fund the LP and approve the vault. This is the LP's only on-chain
        // action on the deposit path — the Operator does the rest.
        mockUsdc.mint(lp, 100_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Move off the genesis timestamp so heartbeat assertions compare against
        // a value that is distinguishable from the zero default.
        vm.warp(1_700_000_000);
    }

    /// @dev Computes the EIP-712 domain separator for the vault.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    /// @dev Signs a MintIntent struct with the given private key.
    function _signMintIntent(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tl, tu, amount, id));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs the canonical intent declared on this base contract.
    function _signCanonical(uint256 pk) internal view returns (bytes memory) {
        return _signMintIntent(pk, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    /// @dev Escrows the canonical intent as the Operator. Used by scenarios that
    ///      need a pre-existing escrow entry as their Given state.
    function _escrowCanonical() internal {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    /// @dev Marks an intentId as consumed without routing through mintPositionFor
    ///      or reclaimDeposit, neither of which exists in its escrow-aware form yet
    ///      (T-002 and T-003). Writing the mapping directly reproduces exactly the
    ///      state those paths leave behind: usedIntents set, no escrow entry.
    function _markIntentUsed(bytes32 id) internal {
        stdstore.target(address(vault)).sig("usedIntents(bytes32)").with_key(id).checked_write(true);
    }

    /// @dev Asserts the escrow at `id` records exactly this depositor and amount.
    ///      Both halves matter: the amount alone is not a claim, because anyone can
    ///      produce a valid signature over any intentId.
    function _assertEscrow(bytes32 id, address expectedLp, uint96 expectedAmount, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, expectedLp, reason);
        assertEq(escrowAmount, expectedAmount, reason);
    }

    /// @dev Asserts no escrow exists at `id`. The sentinel is the zero lp address.
    function _assertNoEscrow(bytes32 id, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, address(0), reason);
        assertEq(escrowAmount, 0, reason);
    }

    /// @dev Sets the vault's phase via direct storage manipulation.
    ///      phase is a uint8 at slot 5, byte offset 17 (bits 136-143), packed with
    ///      minimumFirstLiquidity (bytes 0-15) and _initialized (byte 16).
    function _setPhase(uint8 p) internal {
        bytes32 slot = bytes32(uint256(5));
        bytes32 current = vm.load(address(vault), slot);
        bytes32 mask = ~bytes32(uint256(0xFF) << 136);
        bytes32 updated = (current & mask) | bytes32(uint256(p) << 136);
        vm.store(address(vault), slot, updated);
    }
}

// ──────────────────────────────────────────────
// SC-3Z94: Successful escrow of a signed mint intent
// What: The Operator submits the LP's signed MintIntent. The vault verifies the
//       signature, pulls the USDC out of the LP's wallet, and records it under
//       that exact intentId in pendingDeposits.
// Why:  This is the funding step the whole escrow model rests on. Until it runs,
//       nothing has been pulled from the LP; after it runs, exactly one intent
//       can claim those funds — either mintPositionFor consumes them into a
//       position, or a reclaim path refunds them. Never both, never neither.
// Example: LP signs [20, 80] for 600 USDC. After the call the LP is down 600,
//          the vault is up 600, and pendingDeposits[intentId] == 600.
// ──────────────────────────────────────────────
contract EscrowDepositSuccessTest is EscrowDepositTestBase {
    // SC-3Z94: the escrowed amount is recorded against the intentId
    function test_escrowIsRecordedAgainstTheIntentId() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        _assertEscrow(intentId, lp, 600, "escrow should record the depositing LP and the intent's usdcAmount");
    }

    // SC-3Z94: USDC moves from the LP's wallet into the vault
    function test_usdcMovesFromLpWalletIntoTheVault() public {
        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBalanceBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(mockUsdc.balanceOf(lp), lpBalanceBefore - 600, "LP balance should decrease by usdcAmount");
        assertEq(
            mockUsdc.balanceOf(address(vault)), vaultBalanceBefore + 600, "vault balance should increase by usdcAmount"
        );
    }

    // SC-3Z94: DepositEscrowed is emitted with the intent's identifying fields
    function test_depositEscrowedEventIsEmitted() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositEscrowed(intentId, lp, 600);

        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z94: the intent is funded, not consumed — usedIntents stays clear so
    //          mintPositionFor can still claim it
    function test_intentIsNotMarkedUsedByEscrowing() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertFalse(vault.usedIntents(intentId), "escrowing funds an intent, it does not consume it");
    }

    // SC-3Z94: no position or liquidity state is touched — escrow is purely custodial
    function test_noPositionOrLiquidityStateIsTouched() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(vault.nextPositionId(), 0, "no position should be created by an escrow");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should be untouched by an escrow");
        (uint128 grossLower,,) = vault.ticks(tickLower);
        (uint128 grossUpper,,) = vault.ticks(tickUpper);
        assertEq(grossLower, 0, "tickLower should not be initialized by an escrow");
        assertEq(grossUpper, 0, "tickUpper should not be initialized by an escrow");
    }

    // SC-3Z94: a successful escrow is proof the Operator is alive
    function test_successfulEscrowRefreshesTheSilenceTimer() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            block.timestamp,
            "a successful Operator call should refresh the emergency-cancel silence timer"
        );
    }
}

// ──────────────────────────────────────────────
// SC-45IB: The escrow entry names its depositor
// What: The escrow records WHO deposited, not just how much, and that recorded
//       depositor is what every consuming path checks.
// Why:  An intentId is not bound to an LP by the signature scheme.
//       _verifyMintIntent recovers a signer and compares it to a caller-supplied
//       `lp` argument, so anyone can produce a signature that verifies over any
//       intentId by signing with their own key and naming their own address.
//       If the escrow held only an amount, nothing would distinguish the LP who
//       actually funded an intent from a stranger presenting a self-signed intent
//       over the same intentId — and since intentIds are published in the
//       DepositEscrowed log, that is an unprivileged drain via reclaimDeposit.
// Example: Alice funds intentId X. Mallory signs her own intent over X. The
//          escrow still reads (Alice, 600), and Mallory's submission is turned
//          away by the escrow guard — NOT by signature verification, which she
//          passes. That distinction is the whole point of this scenario.
// ──────────────────────────────────────────────
contract EscrowDepositRecordsDepositorTest is EscrowDepositTestBase {
    // SC-45IB: the escrow names the LP who funded it
    function test_escrowRecordsTheDepositingLp() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        _assertEscrow(intentId, lp, 600, "escrow should name its depositor");
    }

    // SC-45IB: a foreign LP's signature over the same intentId verifies successfully,
    //          which is exactly why the recorded depositor is load-bearing
    function test_foreignSignatureOverTheSameIntentIdPassesVerification() public {
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        // Mallory signs her OWN intent, naming herself, over Alice's intentId.
        address mallory = vm.addr(IMPOSTOR_PK);
        bytes memory mallorySig = _signMintIntent(IMPOSTOR_PK, mallory, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        // The escrow guard rejects this, NOT the signature guard. depositForIntent
        // verifies the signature (line order: signature check, then escrow check),
        // so a DepositAlreadyEscrowed revert proves Mallory's signature was accepted
        // as valid for Alice's intentId. Nothing but the recorded `lp` distinguishes
        // them, which is what SC-45IE, SC-45IG, and SC-45IH go on to enforce on the
        // paths that actually move money.
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(mallory, tickLower, tickUpper, usdcAmount, intentId, mallorySig);

        _assertEscrow(intentId, lp, 600, "the escrow must still belong to its original depositor");
    }
}

// ──────────────────────────────────────────────
// SC-3Z95: Revert when the intent is already escrowed
// What: A second depositForIntent for an intentId that already carries escrow
//       reverts, leaving the original escrow untouched.
// Why:  This is the guard that stops the LP being charged twice. Without it a
//       retried or duplicated Operator call would pull a second 600 from the LP
//       while pendingDeposits could only ever account for one of them, orphaning
//       the other — the exact failure the escrow model exists to eliminate.
// Example: escrow 600 against intent X, then submit the identical signed intent
//          again. Second call reverts; pendingDeposits[X] is still 600 and the
//          LP has been debited exactly once.
// ──────────────────────────────────────────────
contract EscrowDepositAlreadyEscrowedTest is EscrowDepositTestBase {
    function setUp() public override {
        super.setUp();
        _escrowCanonical();
    }

    // SC-3Z95: a duplicate escrow for the same intentId reverts
    function test_duplicateEscrowReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z95: the LP is debited exactly once across both calls
    function test_lpIsNotChargedTwice() public {
        uint256 lpBalanceAfterFirstEscrow = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(mockUsdc.balanceOf(lp), lpBalanceAfterFirstEscrow, "the failed second escrow must not pull more USDC");
        _assertEscrow(intentId, lp, 600, "the original escrow must survive the rejected duplicate");
    }

    // SC-3Z95: a second, DIFFERENT LP cannot straddle an intentId already funded.
    //          The guard keys on the recorded depositor, so it catches this even
    //          though the second submission carries a perfectly valid signature.
    function test_aDifferentLpCannotEscrowOverAnExistingIntent() public {
        address mallory = vm.addr(IMPOSTOR_PK);
        mockUsdc.mint(mallory, 100_000);
        vm.prank(mallory);
        mockUsdc.approve(address(vault), type(uint256).max);
        uint256 malloryBalanceBefore = mockUsdc.balanceOf(mallory);

        bytes memory mallorySig = _signMintIntent(IMPOSTOR_PK, mallory, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(mallory, tickLower, tickUpper, usdcAmount, intentId, mallorySig);

        assertEq(mockUsdc.balanceOf(mallory), malloryBalanceBefore, "the rejected call must not pull Mallory's USDC");
        _assertEscrow(intentId, lp, 600, "the escrow must still belong to the original depositor");
    }
}

// ──────────────────────────────────────────────
// SC-3Z96: Revert when the intent has already been used
// What: An intentId already consumed — by a mint or by a completed reclaim —
//       cannot be re-funded.
// Why:  A spent intent has already had its outcome: the LP either holds the
//       position it funded or has been refunded. Re-escrowing it would pull a
//       second deposit for an intent whose lifecycle is over, with no path left
//       to mint or reclaim it.
// Example: intent X was minted (usedIntents[X] == true, escrow already deleted).
//          Escrowing X again reverts rather than silently pulling 600 more.
// ──────────────────────────────────────────────
contract EscrowDepositIntentAlreadyUsedTest is EscrowDepositTestBase {
    function setUp() public override {
        super.setUp();
        _markIntentUsed(intentId);
    }

    // SC-3Z96: escrowing a spent intentId reverts
    function test_escrowingAUsedIntentReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z96: no USDC is pulled for a spent intent
    function test_noUsdcIsPulledForASpentIntent() public {
        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(mockUsdc.balanceOf(lp), lpBalanceBefore, "a spent intent must not pull a second deposit");
        _assertNoEscrow(intentId, "no escrow should be recorded for a spent intent");
    }
}

// ──────────────────────────────────────────────
// SC-3Z97: Revert on invalid LP signature
// What: An intent whose signature does not recover to the named LP is rejected.
// Why:  The signature is the only thing standing between an Operator and an
//       arbitrary LP's approved USDC allowance. Without this check, the Operator
//       chokepoint would become a license to drain any wallet that had ever
//       approved the vault.
// Example: an impostor key signs an intent naming the real LP as the depositor.
//          Recovery returns the impostor's address, not the LP's, so the call
//          reverts and the LP's allowance is never touched.
// ──────────────────────────────────────────────
contract EscrowDepositInvalidSignatureTest is EscrowDepositTestBase {
    // SC-3Z97: a signature from a key other than the named LP's reverts
    function test_signatureFromAnotherKeyReverts() public {
        bytes memory impostorSig = _signCanonical(IMPOSTOR_PK);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, impostorSig);
    }

    // SC-3Z97: a signature over different fields than those submitted reverts
    function test_tamperedFieldsReverts() public {
        // The LP genuinely signed for 600; the Operator submits the same signature
        // alongside an inflated 900.
        bytes memory sigFor600 = _signCanonical(LP_PK);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, 900, intentId, sigFor600);
    }

    // SC-3Z97: no USDC is pulled when the signature fails
    function test_noUsdcIsPulledOnInvalidSignature() public {
        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(IMPOSTOR_PK));

        assertEq(mockUsdc.balanceOf(lp), lpBalanceBefore, "an unsigned intent must never move the LP's USDC");
        _assertNoEscrow(intentId, "no escrow should be recorded on signature failure");
    }
}

// ──────────────────────────────────────────────
// SC-3Z98: Revert on non-operator caller
// What: A caller outside the operator registry cannot escrow, even holding a
//       genuinely valid LP signature.
// Why:  The Operator chokepoint exists to stop an attacker seeding a position
//       ahead of a real LP's deposit to skew tick-initialization and fee-growth
//       state in their own favour. A valid LP signature proves the LP consented
//       to the deposit; it says nothing about who may sequence it.
// Example: the LP themselves holds their own valid signature and calls
//          depositForIntent directly. It reverts — deposit has no direct-LP twin.
// ──────────────────────────────────────────────
contract EscrowDepositNotOperatorTest is EscrowDepositTestBase {
    // SC-3Z98: an arbitrary address holding a valid signature cannot escrow
    function test_strangerWithValidSignatureCannotEscrow() public {
        vm.prank(stranger);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z98: the LP cannot escrow their own deposit — there is no direct-LP path
    function test_lpCannotEscrowTheirOwnDeposit() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z98: the Admin holds registry authority, not transactional authority
    function test_adminCannotEscrow() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }
}

// ──────────────────────────────────────────────
// SC-3Z99: Revert on zero amount
// What: An intent for 0 USDC is rejected.
// Why:  A zero-value escrow could never be minted, because minting rejects a zero
//       usdcAmount (FR-T7B5). It could only ever be unwound through the 24-hour
//       reclaim timelock, so rejecting it up front keeps every entry in the
//       mapping spendable. (The "nothing escrowed" sentinel is the entry's zero
//       lp address, not its amount — see SC-45IB.)
// Example: LP signs an intent for 0. The call reverts, so intentId X stays
//          genuinely fundable rather than holding an unspendable entry.
// ──────────────────────────────────────────────
contract EscrowDepositZeroAmountTest is EscrowDepositTestBase {
    // SC-3Z99: a zero-amount intent reverts
    function test_zeroAmountReverts() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 0, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, 0, intentId, sig);
    }

    // SC-3Z99 / FR-45IA: an amount beyond the escrow field's range reverts rather
    // than truncating. uint96 holds ~7.9e28 base units (~7.9e22 USDC at 6 decimals),
    // far above total supply, so this is unreachable in practice — but a silent
    // truncation would record an escrow smaller than the USDC actually collected,
    // which is a fund-loss bug, so the cast reverts instead.
    function test_amountBeyondTheEscrowFieldRangeReverts() public {
        uint256 tooLarge = uint256(type(uint96).max) + 1;
        mockUsdc.mint(lp, tooLarge);
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, tooLarge, intentId);
        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.SafeCastOverflow.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, tooLarge, intentId, sig);

        assertEq(mockUsdc.balanceOf(lp), lpBalanceBefore, "an out-of-range amount must not pull the LP's USDC");
        _assertNoEscrow(intentId, "no escrow should be recorded when the amount does not fit");
    }

    // SC-3Z99: the zero sentinel stays unambiguous, so the duplicate guard holds
    function test_zeroSentinelRemainsUnambiguous() public {
        bytes memory zeroSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 0, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, 0, intentId, zeroSig);

        _assertNoEscrow(intentId, "a rejected zero escrow leaves the sentinel meaning 'never funded'");

        // Because the sentinel still reads as absent, a genuine escrow for the
        // same intentId is still possible — and is then protected by SC-3Z95.
        _escrowCanonical();
        _assertEscrow(intentId, lp, 600, "a real escrow can still fund an intent a zero attempt touched");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9A: Revert when the vault is not Active
// What: Escrow is rejected once the vault leaves the Active phase.
// Why:  Escrow exists only to fund a mint, and mints are Active-only. Accepting
//       a deposit into a wound-down or cancelled vault would pull the LP's USDC
//       into a vault that can never mint it into a position, stranding the funds
//       until the reclaim timelock elapses.
// Example: the Oracle winds the vault down (phase 2). The Operator's otherwise
//          valid escrow call reverts and the LP's USDC stays in their wallet.
// ──────────────────────────────────────────────
contract EscrowDepositVaultNotActiveTest is EscrowDepositTestBase {
    // SC-3Z9A: escrow reverts in WindDown
    function test_escrowRevertsInWindDown() public {
        _setPhase(2);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z9A: escrow reverts in the terminal Cancelled phase
    function test_escrowRevertsWhenCancelled() public {
        _setPhase(3);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));
    }

    // SC-3Z9A: no USDC enters a vault that can no longer mint
    function test_noUsdcEntersANonActiveVault() public {
        _setPhase(2);
        uint256 lpBalanceBefore = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(mockUsdc.balanceOf(lp), lpBalanceBefore, "a non-active vault must not pull the LP's USDC");
        _assertNoEscrow(intentId, "no escrow should be recorded in a non-active vault");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9B: Failed escrow leaves the Operator silence timer untouched
// What: A reverting depositForIntent does not refresh lastOperatorActivityTimestamp.
// Why:  The silence timer is what lets any position holder trigger
//       emergencyCancelAll after a prolonged Operator outage. If a failed call
//       counted as proof of life, a stuck or malicious Operator could hold the
//       timelock off indefinitely by spamming calls it knows will revert.
// Example: the timer sits at T. The Operator submits a duplicate escrow, which
//          reverts. The timer is still T, so the countdown keeps running.
// ──────────────────────────────────────────────
contract EscrowDepositHeartbeatOnFailureTest is EscrowDepositTestBase {
    function setUp() public override {
        super.setUp();
        _escrowCanonical();
    }

    // SC-3Z9B: a rejected duplicate escrow does not advance the timer
    function test_revertedDuplicateEscrowDoesNotAdvanceTheTimer() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 3 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositAlreadyEscrowed.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, _signCanonical(LP_PK));

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a failed call is not proof the Operator is alive");
    }

    // SC-3Z9B: a rejected zero-amount escrow does not advance the timer either
    function test_revertedZeroAmountEscrowDoesNotAdvanceTheTimer() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 3 days);

        bytes32 freshIntent = keccak256("escrow-intent-zero");
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 0, freshIntent);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, 0, freshIntent, sig);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a failed call is not proof the Operator is alive");
    }
}
