// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-3Z93: Operator Reclaim Deposit for LP
// Integration tests for every scenario in this use case.
// Covers: SC-3Z9C, SC-3Z9D, SC-3Z9E, SC-3Z9F, SC-45IH, SC-3Z9G, SC-3Z9H, SC-3Z9I

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// MockERC20 with transfer and transferFrom support.
// transferFrom backs depositForIntent (LP→vault); transfer backs the refund
// (vault→LP), so tests can assert who actually ends up with the money.
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

contract MockConditionalTokens {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// ReentrantERC20: malicious ERC-20 that re-enters the vault during the Phase 2
// transfer. The callback is wrapped in a low-level call so the outer transfer
// still succeeds when the reentrant attempt reverts, letting the test observe
// both outcomes.
// ──────────────────────────────────────────────
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentrantCalldata;
    bool public reentrancyAttempted;
    bool public reentrancyReverted;
    // The reentrant call's revert data. Captured because "it reverted" is not
    // enough: several guards can reject the callback, and only one of them is
    // the reentrancy guard under test.
    bytes public reentrantReturndata;

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

    function setReentrancyTarget(address _target, bytes calldata _calldata) external {
        target = _target;
        reentrantCalldata = _calldata;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        if (!reentrancyAttempted && target != address(0)) {
            reentrancyAttempted = true;
            (bool success, bytes memory returndata) = target.call(reentrantCalldata);
            reentrancyReverted = !success;
            reentrantReturndata = returndata;
        }

        return true;
    }
}

// ──────────────────────────────────────────────
// Base test contract for the Operator-relayed reclaim path.
//
// The distinguishing feature of this use case is the SIGNATURE, not the
// mechanics: reclaimDepositFor accepts a ReclaimIntent, a struct with its own
// EIP-712 typehash, deliberately NOT interchangeable with the MintIntent that
// authorizes the escrow and the mint. Both signing helpers live here so the
// domain-separation tests can sign one struct and submit it where the other
// is expected.
// ──────────────────────────────────────────────
contract ReclaimDepositForTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address exchangeAddr = makeAddr("exchange");
    address operatorAddr = makeAddr("operator");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    // A second LP who funds nothing under the intent under test. SC-45IH drives
    // the vault with this party's genuinely-valid signature.
    uint256 constant LP_B_PK = 0xB0B;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    // The canonical intent used across scenarios.
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("relayed-reclaim-1");

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event ReclaimSubmitted(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);
    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        lpB = vm.addr(LP_B_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Move off the genesis timestamp so heartbeat assertions compare against a
        // value distinguishable from the zero default.
        vm.warp(1_700_000_000);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    /// @dev Signs an EIP-712 struct of the given typehash. Both MintIntent and
    ///      ReclaimIntent carry identical fields — only the typehash differs, which
    ///      is exactly what makes them non-interchangeable.
    function _sign(uint256 pk, bytes32 typehash, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(typehash, lpAddr, tl, tu, amount, id));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMint(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, MINT_INTENT_TYPEHASH, lpAddr, tl, tu, amount, id);
    }

    function _signReclaim(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, RECLAIM_INTENT_TYPEHASH, lpAddr, tl, tu, amount, id);
    }

    /// @dev Escrows a deposit as the Operator. The escrow is always authorized by a
    ///      MintIntent — a ReclaimIntent must never be able to fund one.
    function _escrow(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id) internal {
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tl, tu, amount, id, _signMint(pk, lpAddr, tl, tu, amount, id));
    }

    /// @dev Escrows the canonical intent for the canonical LP.
    function _escrowCanonical() internal {
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    /// @dev Relays a reclaim authorization as the Operator.
    function _relay(bytes memory sig) internal {
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _assertEscrow(bytes32 id, address expectedLp, uint96 expectedAmount, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, expectedLp, reason);
        assertEq(escrowAmount, expectedAmount, reason);
    }

    function _assertNoEscrow(bytes32 id, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, address(0), reason);
        assertEq(escrowAmount, 0, reason);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9C: Phase 1 records the reclaim submission
// What: The Operator relays the LP's signed ReclaimIntent. The vault records
//       intentTimestamps[intentId], emits ReclaimSubmitted, refreshes the
//       Operator silence timer, and moves no USDC.
// Why:  Phase 1 starts the RECLAIM_TIMELOCK clock. The escrow stays intact
//       through the window, so the Operator can still mint the position if the
//       LP changes their mind — the cancellation is not final until Phase 2.
// ──────────────────────────────────────────────
contract RelayedReclaimPhase1Test is ReclaimDepositForTestBase {
    function setUp() public override {
        super.setUp();
        _escrowCanonical();
    }

    // SC-3Z9C: Phase 1 records the submission timestamp
    function test_phase1RecordsTimestamp() public {
        assertEq(vault.intentTimestamps(intentId), 0, "no submission should be recorded yet");

        _relay(_signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId));

        assertEq(vault.intentTimestamps(intentId), block.timestamp, "Phase 1 should record block.timestamp");
    }

    // SC-3Z9C: Phase 1 emits ReclaimSubmitted
    function test_phase1EmitsReclaimSubmitted() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit ReclaimSubmitted(intentId, lp, usdcAmount);

        _relay(_signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId));
    }

    // SC-3Z9C: no USDC moves and the escrow is untouched, so a mint is still possible
    function test_phase1MovesNoFundsAndLeavesEscrowIntact() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 lpBefore = mockUsdc.balanceOf(lp);

        _relay(_signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId));

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be unchanged after Phase 1");
        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance must be unchanged after Phase 1");
        _assertEscrow(intentId, lp, uint96(usdcAmount), "the escrow must survive Phase 1");
        assertFalse(vault.usedIntents(intentId), "Phase 1 must not consume the intentId");
    }

    // SC-3Z9C: the relayed path IS an Operator action, so it refreshes the timer
    function test_phase1RefreshesOperatorSilenceTimer() public {
        vm.warp(block.timestamp + 1 days);

        _relay(_signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId));

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            block.timestamp,
            "a successful relayed reclaim is proof the Operator is alive"
        );
    }
}

// ──────────────────────────────────────────────
// SC-3Z9D: Phase 2 refunds the LP after the timelock
// What: After RECLAIM_TIMELOCK elapses, the Operator relays again. The vault
//       marks the intent used, deletes the escrow, and pays the escrowed amount
//       to the LP — never to the caller.
// Why:  This is the gas-sponsored twin of the escape hatch: the Operator pays
//       the gas and receives nothing. FR-3ZVO requires observable outcomes
//       identical to the LP's own reclaimDeposit.
// Example: LP escrowed 600. Operator relays Phase 1, waits 24h+1, relays again.
//          LP is up 600; the Operator's own balance has not moved.
// ──────────────────────────────────────────────
contract RelayedReclaimPhase2Test is ReclaimDepositForTestBase {
    bytes reclaimSig;

    function setUp() public override {
        super.setUp();
        _escrowCanonical();

        reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        _relay(reclaimSig);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // SC-3Z9D: the LP receives the escrowed amount
    function test_phase2PaysTheLp() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        _relay(reclaimSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "the LP should receive the escrowed amount");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore - usdcAmount, "the vault should pay out exactly that");
    }

    // SC-3Z9D: the Operator pays gas and receives nothing — funds never go to msg.sender
    function test_phase2PaysNothingToTheCaller() public {
        uint256 operatorBefore = mockUsdc.balanceOf(operatorAddr);

        _relay(reclaimSig);

        assertEq(mockUsdc.balanceOf(operatorAddr), operatorBefore, "the relaying Operator must receive nothing");
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "the Operator holds no USDC at any point");
    }

    // SC-3Z9D: the intent is consumed and the escrow cleared
    function test_phase2ConsumesIntentAndEscrow() public {
        _relay(reclaimSig);

        assertTrue(vault.usedIntents(intentId), "the intentId should be permanently marked used");
        _assertNoEscrow(intentId, "the escrow should be deleted");
    }

    // SC-3Z9D: DepositReclaimed is emitted with the escrowed amount
    function test_phase2EmitsDepositReclaimed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, usdcAmount);

        _relay(reclaimSig);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9D: the refund is the ESCROWED amount, not what the authorization claims
// What: The LP escrows 600, then signs a ReclaimIntent over the same intentId
//       claiming 50,000. The Operator relays it. The LP gets exactly 600.
// Why:  FR-3ZVO requires the relayed path to apply the same escrow-sourced
//       refund as reclaimDeposit. A relayed path that trusted the caller-supplied
//       usdcAmount would reopen the vault drain through a second door — and the
//       claim here is sized within the vault's balance, so an over-payment would
//       succeed and take another LP's escrow rather than harmlessly reverting.
// ──────────────────────────────────────────────
contract RelayedReclaimRefundIsEscrowSourcedTest is ReclaimDepositForTestBase {
    uint256 inflatedClaim = 50_000;
    bytes32 otherIntentId = keccak256("another-lps-escrow");
    bytes inflatedSig;

    function setUp() public override {
        super.setUp();

        _escrowCanonical();
        // A second LP's escrow gives an over-payment something to steal.
        _escrow(LP_B_PK, lpB, tickLower, tickUpper, inflatedClaim, otherIntentId);

        inflatedSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, inflatedClaim, intentId);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // SC-3Z9D: the payout is the escrowed 600, not the claimed 50,000
    function test_refundEqualsEscrowedAmount() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "the LP must receive exactly the escrowed 600");
        _assertEscrow(otherIntentId, lpB, uint96(inflatedClaim), "the other LP's escrow must be untouched");
    }

    // SC-3Z9D: DepositReclaimed reports the escrowed amount, so an indexer is never
    // told a larger sum left the vault than actually did
    function test_depositReclaimedReportsTheEscrowedAmount() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, usdcAmount);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);
    }

    // SC-3Z9C: and Phase 1 likewise reports the escrowed amount, so the pending
    // refund shown to an LP is the number Phase 2 will actually pay
    function test_reclaimSubmittedReportsTheEscrowedAmount() public {
        // A fresh intent so this test drives Phase 1 itself rather than reusing setUp's.
        bytes32 freshId = keccak256("relayed-phase1-inflated");
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, freshId);
        bytes memory sig = _signReclaim(LP_PK, lp, tickLower, tickUpper, inflatedClaim, freshId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ReclaimSubmitted(freshId, lp, usdcAmount);

        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, inflatedClaim, freshId, sig);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9E: Revert before the timelock elapses
// What: Relaying Phase 2 before RECLAIM_TIMELOCK has elapsed reverts with
//       TimelockNotElapsed.
// Why:  The Operator cannot shortcut the same waiting period the LP faces.
//       Gas sponsorship buys convenience, not privilege.
// ──────────────────────────────────────────────
contract RelayedReclaimTimelockTest is ReclaimDepositForTestBase {
    bytes reclaimSig;

    function setUp() public override {
        super.setUp();
        _escrowCanonical();

        reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        _relay(reclaimSig);

        // One second short of the timelock
        vm.warp(block.timestamp + 24 hours - 1);
    }

    // SC-3Z9E: an early Phase 2 reverts
    function test_revertsBeforeTimelockElapses() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9E: nothing moves and the silence timer is not refreshed by the failure
    function test_earlyAttemptChangesNothing() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "no USDC may move");
        _assertEscrow(intentId, lp, uint96(usdcAmount), "the escrow must survive");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted call is not proof of life");
    }

    // SC-3Z9D, SC-3Z9E: the boundary itself succeeds. ARCHITECTURE states the
    // invariant as `elapsed >= RECLAIM_TIMELOCK`, so exactly-at-the-timelock must
    // pay out. Pinning it catches an off-by-one that would strand the LP an extra
    // block — the kind of error a `+1 second` margin in every other test hides.
    function test_succeedsExactlyAtTheTimelockBoundary() public {
        // setUp left us one second short; step forward to elapsed == RECLAIM_TIMELOCK.
        vm.warp(block.timestamp + 1);

        uint256 lpBefore = mockUsdc.balanceOf(lp);
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "the refund must land exactly at the timelock");
        assertTrue(vault.usedIntents(intentId), "the intent should be settled");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9F: Revert when nothing is escrowed for the intent
// What: A ReclaimIntent for an intentId that was never funded is refused with
//       NothingToReclaim, however large the amount it claims.
// Why:  FR-3ZVM applies to both reclaim paths. The relayed path must offer no
//       way around the escrow requirement, or it becomes an alternate route to
//       draining other LPs' funds.
// ──────────────────────────────────────────────
contract RelayedReclaimNothingEscrowedTest is ReclaimDepositForTestBase {
    bytes32 unfundedIntentId = keccak256("never-funded");
    uint256 claimedAmount = 1_000_000;

    function setUp() public override {
        super.setUp();
        // A real escrow exists under a DIFFERENT intentId, so the vault holds funds.
        _escrowCanonical();
    }

    // SC-3Z9F: an unfunded intent is refused
    function test_revertsWhenNothingEscrowed() public {
        bytes memory sig = _signReclaim(LP_PK, lp, tickLower, tickUpper, claimedAmount, unfundedIntentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NothingToReclaim.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, claimedAmount, unfundedIntentId, sig);
    }

    // SC-3Z9F: the clock never starts and no USDC leaves the vault
    function test_unfundedIntentStartsNoClockAndMovesNoFunds() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        bytes memory sig = _signReclaim(LP_PK, lp, tickLower, tickUpper, claimedAmount, unfundedIntentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NothingToReclaim.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, claimedAmount, unfundedIntentId, sig);

        assertEq(vault.intentTimestamps(unfundedIntentId), 0, "an unfunded intent must not start the timelock");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be untouched");
    }
}

// ──────────────────────────────────────────────
// SC-45IH: Revert when the escrow belongs to a different LP
// What: LP A funded intentId X. LP B validly signs a ReclaimIntent naming
//       themselves over X, and the Operator submits it — by mistake or in
//       collusion. It reverts with NotIntentOwner.
// Why:  The relayed path grants the Operator no ability to redirect one LP's
//       deposit to another. Even a compromised Operator key combined with an
//       attacker's genuine signature cannot move A's funds, because ownership
//       is settled by the escrow record and not by who signed (FR-45IF).
// ──────────────────────────────────────────────
contract RelayedReclaimForeignEscrowTest is ReclaimDepositForTestBase {
    function setUp() public override {
        super.setUp();
        // LP A funds the intent.
        _escrowCanonical();
    }

    // SC-45IH: B's genuine ReclaimIntent over A's intentId is refused
    function test_revertsWhenAuthorizationIsFromNonDepositor() public {
        bytes memory sigB = _signReclaim(LP_B_PK, lpB, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDepositFor(lpB, tickLower, tickUpper, usdcAmount, intentId, sigB);
    }

    // SC-45IH: A's escrow is intact and A remains able to reclaim it
    function test_depositorsEscrowSurvivesAndRemainsReclaimable() public {
        bytes memory sigB = _signReclaim(LP_B_PK, lpB, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDepositFor(lpB, tickLower, tickUpper, usdcAmount, intentId, sigB);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "A's escrow must be intact");
        assertFalse(vault.usedIntents(intentId), "A must not be locked out");
        assertEq(vault.intentTimestamps(intentId), 0, "B must not start the clock against A's intentId");

        // A's own relayed reclaim still completes.
        bytes memory sigA = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        _relay(sigA);
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 lpBefore = mockUsdc.balanceOf(lp);
        _relay(sigA);
        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "A must still recover their deposit");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9G: Revert when a mint authorization is replayed as a reclaim
// What: The Operator holds only the LP's original MintIntent signature — the
//       one that authorized the escrow. Submitting it to reclaimDepositFor
//       reverts with InvalidSignature, and the escrow remains mintable.
// Why:  ADR-4029. If a reclaim reused the MintIntent typehash, the single
//       signature an LP produces to fund a position would double as
//       authorization to cancel it, letting an Operator holding that signature
//       unilaterally reverse the LP's intent. Cancelling must require the LP to
//       have signed a reclaim specifically.
// Example: the same five field values, signed under a different typehash,
//          produce a different digest and therefore recover a different address.
// ──────────────────────────────────────────────
contract RelayedReclaimTypehashSeparationTest is ReclaimDepositForTestBase {
    function setUp() public override {
        super.setUp();
        _escrowCanonical();
    }

    // SC-3Z9G: a MintIntent signature is not a reclaim authorization
    function test_mintIntentSignatureIsRejected() public {
        // The exact signature that authorized the escrow, replayed as a reclaim.
        bytes memory mintSig = _signMint(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);
    }

    // SC-3Z9G: the escrow is left intact and still mintable after the rejection
    function test_escrowRemainsIntactAndMintable() public {
        bytes memory mintSig = _signMint(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "the escrow must be intact");
        assertEq(vault.intentTimestamps(intentId), 0, "no reclaim clock may start");

        // The position the LP actually authorized can still be minted.
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);
        (address owner,,,,,) = vault.positions(posId);
        assertEq(owner, lp, "the LP's intent must remain mintable");
    }

    // SC-3Z9G, NFR-JAIX: a malleable (high-s) reclaim signature is rejected.
    // Without this an attacker could derive a second valid signature from an
    // observed one, per CLAUDE.md rule 5.
    function test_revertsOnHighSReclaimSignature() public {
        bytes32 structHash =
            keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);

        // Flip s into the upper half of the curve order and flip v to match
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleableSig =
            abi.encodePacked(r, bytes32(secp256k1n - uint256(s)), v == 27 ? uint8(28) : uint8(27));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, malleableSig);
    }

    // SC-3Z9G, NFR-JAIX: a v value outside {27, 28} is rejected
    function test_revertsOnInvalidVReclaimSignature() public {
        bytes32 structHash =
            keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);

        bytes memory badVSig = abi.encodePacked(r, s, uint8(26));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, badVSig);
    }

    // SC-3Z9G: a signature of the wrong length is rejected before any recovery
    function test_revertsOnMalformedSignature() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, "");
    }

    // SC-3Z9G: a ReclaimIntent signed by someone other than the named LP is rejected
    function test_revertsWhenReclaimSignerIsNotTheNamedLp() public {
        // LP B signs, but the call names LP A
        bytes memory sigB = _signReclaim(LP_B_PK, lpB, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, sigB);
    }

    // SC-3Z9G (converse): a ReclaimIntent signature cannot fund an escrow or mint,
    // so the separation holds in both directions per FR-3ZVP
    function test_reclaimIntentSignatureIsRejectedByTheDepositAndMintPaths() public {
        bytes32 freshId = keccak256("reclaim-sig-cannot-deposit");
        bytes memory reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, freshId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, freshId, reclaimSig);

        // And it cannot mint the already-escrowed canonical intent either.
        bytes memory reclaimSigCanonical = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSigCanonical);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9H: Revert on non-operator caller
// What: reclaimDepositFor is Operator-gated. Any other caller — including the
//       LP themselves, the Admin, and the Oracle — gets NotOperator, even
//       holding a genuinely valid authorization past the timelock.
// Why:  FR-3ZVQ. This is the convenience path, not an exit guarantee. The LP's
//       own permissionless reclaimDeposit (UC-JAIK) remains available and is
//       unaffected by this gate — which the last test here proves.
// ──────────────────────────────────────────────
contract RelayedReclaimAccessControlTest is ReclaimDepositForTestBase {
    bytes reclaimSig;

    function setUp() public override {
        super.setUp();
        _escrowCanonical();
        reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-3Z9H: the LP cannot use the relayed path directly
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9H: the Admin cannot either — Admin is registry-only
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9H: nor the Oracle — Operator and Oracle are separate accounts
    function test_revertsWhenOracleCalls() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9H: nor an arbitrary address
    function test_revertsWhenStrangerCalls() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9H: the LP's own permissionless path is unaffected by this gate
    function test_lpsOwnReclaimPathStillWorks() public {
        bytes memory mintSig = _signMint(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 lpBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "the escape hatch must remain open to the LP");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9I: Revert when the intent has already been used
// What: An intentId already consumed — by a mint, by a completed reclaimDeposit,
//       or by a completed reclaimDepositFor — is refused with IntentAlreadyUsed.
// Why:  ADR-JAIY. The two reclaim entry points and the mint path share one
//       usedIntents namespace, so no intent can be settled twice by mixing paths.
// ──────────────────────────────────────────────
contract RelayedReclaimIntentAlreadyUsedTest is ReclaimDepositForTestBase {
    // SC-3Z9I: an intent consumed by mintPositionFor cannot be reclaimed
    function test_revertsAfterMint() public {
        _escrowCanonical();

        bytes memory mintSig = _signMint(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);

        bytes memory reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9I: an intent already settled through the relayed path cannot be replayed
    function test_revertsAfterCompletedRelayedReclaim() public {
        _escrowCanonical();

        bytes memory reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        _relay(reclaimSig);
        vm.warp(block.timestamp + 24 hours + 1);
        _relay(reclaimSig);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }

    // SC-3Z9I: the two entry points share one namespace — an intent settled through
    // the LP's own path cannot then be settled again through the relayed one
    function test_revertsAfterCompletedPermissionlessReclaim() public {
        _escrowCanonical();

        bytes memory mintSig = _signMint(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);

        bytes memory reclaimSig = _signReclaim(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);
    }
}

// ──────────────────────────────────────────────
// NFR-JAIW: nonReentrant modifier on reclaimDepositFor
// What: A malicious ERC-20 that calls back into reclaimDepositFor during the
//       Phase 2 payout is blocked by the nonReentrant guard.
// Why:  NFR-JAIW names BOTH entry points. Without the guard, a callback during
//       _safeTransfer could re-enter before the state settles and drain the
//       vault across several payouts in one transaction. The relayed path is
//       Operator-gated, but a compromised Operator key plus a malicious token
//       is exactly the pairing the guard has to survive.
// ──────────────────────────────────────────────
contract RelayedReclaimReentrancyTest is Test {
    LPVaultFactory factory;
    LPVault vault;
    ReentrantERC20 reentrantUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address exchangeAddr = makeAddr("exchange");
    address operatorAddr = makeAddr("operator");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        reentrantUsdc = new ReentrantERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(reentrantUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        reentrantUsdc.mint(lp, 2000);
        vm.prank(lp);
        reentrantUsdc.approve(address(vault), type(uint256).max);

        // Register the malicious token as an Operator. Without this, the reentrant
        // callback (whose msg.sender is the token) is rejected by onlyOperator before
        // nonReentrant is ever reached, and the test would pass with the guard removed.
        // This is also the threat model the guard exists for: a compromised Operator
        // key combined with a malicious token.
        vm.prank(admin);
        factory.addOperator(address(reentrantUsdc));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _sign(uint256 pk, bytes32 typehash, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(typehash, lpAddr, tl, tu, amount, id));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // NFR-JAIW: reentrant call during the Phase 2 payout is blocked
    function test_reentrancyDuringPhase2PayoutIsBlocked() public {
        int24 tickLower = int24(20);
        int24 tickUpper = int24(80);
        uint256 usdcAmount = 1000;
        bytes32 intentId = keccak256("relayed-reentrant");

        bytes memory mintSig = _sign(LP_PK, MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory reclaimSig = _sign(LP_PK, RECLAIM_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, mintSig);

        // Phase 1
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        // Arm the token to re-enter on the payout transfer
        reentrantUsdc.setReentrancyTarget(
            address(vault),
            abi.encodeWithSelector(
                LPVault.reclaimDepositFor.selector, lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig
            )
        );

        uint256 lpBefore = reentrantUsdc.balanceOf(lp);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(operatorAddr);
        vault.reclaimDepositFor(lp, tickLower, tickUpper, usdcAmount, intentId, reclaimSig);

        assertTrue(reentrantUsdc.reentrancyAttempted(), "reentrancy should have been attempted");
        assertTrue(reentrantUsdc.reentrancyReverted(), "the reentrant call must revert");
        // Assert on the revert REASON, not merely that it reverted. Checks-effects
        // ordering already sets usedIntents before the transfer, so a vault with no
        // reentrancy guard would still reject the callback — with IntentAlreadyUsed.
        // Only Reentrancy proves the guard itself fired.
        assertEq(
            bytes4(reentrantUsdc.reentrantReturndata()),
            LPVault.Reentrancy.selector,
            "the callback must be stopped by the reentrancy guard specifically"
        );
        assertEq(reentrantUsdc.balanceOf(lp), lpBefore + usdcAmount, "the LP is paid exactly once");
    }
}
