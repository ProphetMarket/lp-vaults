// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JAIK: Reclaim Deposit
// Integration tests for every scenario in this use case.
// Covers: SC-JAIL, SC-3Z9L, SC-45IG, SC-JAIM, SC-JAIN, SC-3ZA0, SC-JAIP

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// MockERC20 with transfer and transferFrom support for reclaim tests.
// Tracks balances and allowances so tests can assert on USDC movement
// in both directions: LP→vault (depositForIntent) and vault→LP (reclaim).
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

contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

// ──────────────────────────────────────────────
// ReentrantERC20: malicious ERC-20 that attempts to re-enter
// vault.reclaimDeposit during a transfer call. Used by NFR-JAIW
// reentrancy test. The callback is wrapped in a low-level call so
// the outer transfer succeeds even when the reentrant call reverts.
// ──────────────────────────────────────────────
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentrantCalldata;
    bool public reentrancyAttempted;
    bool public reentrancyReverted;
    // The reentrant call's revert data. Captured because "it reverted" is not
    // enough: with the guard removed the callback is still rejected — by the
    // msg.sender != lp gate — so only the revert reason distinguishes them.
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

        // Attempt reentrancy on the first transfer only
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
// Base test contract with shared setup for all reclaimDeposit scenarios.
// Deploys factory + vault, provides the EIP-712 signing helper, and escrows
// deposits through the real depositForIntent path so the refund the reclaim
// pays out is the one the vault actually collected.
//
// The Operator appears here only to escrow the deposit in the Given state.
// reclaimDeposit itself takes no operator signature and reads no operator
// registry state — that independence is the whole point of the escape hatch.
// ──────────────────────────────────────────────
contract ReclaimDepositTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    // An unrelated party who deposits nothing. SC-3Z9L and SC-45IG drive the
    // vault through this address to prove a signature is not a claim.
    uint256 constant ATTACKER_PK = 0xBAD;
    address attacker;

    uint256 constant OPERATOR_PK = 0xB0B;
    address operatorAddr;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event ReclaimSubmitted(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);
    event DepositReclaimed(bytes32 indexed intentId, address indexed lp, uint256 usdcAmount);

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        attacker = vm.addr(ATTACKER_PK);
        operatorAddr = vm.addr(OPERATOR_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault =
            LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq, conditionId, yesTokenId, noTokenId));

        // Fund both parties and approve the vault. The attacker is funded too, so
        // that "the attacker has no escrow" is a fact about the escrow ledger and
        // not an accident of them being broke.
        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        mockUsdc.mint(attacker, 1_000_000);
        vm.prank(attacker);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Computes the EIP-712 domain separator for the vault.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    /// @dev Signs a MintIntent struct with the given private key.
    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Escrows a deposit against `intentId` as the Operator, on behalf of the
    ///      LP who signs it. This is the only way USDC becomes attributable to an
    ///      intent, and therefore the only way a reclaim can ever pay out.
    function _escrow(uint256 pk, address lpAddr, int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
    {
        bytes memory sig = _signMintIntent(pk, lpAddr, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    /// @dev Executes Phase 1 of reclaimDeposit (records the submission timestamp).
    function _submitPhase1(
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes memory lpSig
    ) internal {
        vm.prank(lpAddr);
        vault.reclaimDeposit(lpAddr, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    /// @dev Asserts the escrow at `id` records exactly this depositor and amount.
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
}

// ──────────────────────────────────────────────
// SC-JAIL: Successful reclaim after timelock — Phase 1 (submission)
// What: The first call to reclaimDeposit with a valid, escrowed, unfulfilled
//       intentId records intentTimestamps[intentId] = block.timestamp, emits
//       ReclaimSubmitted, and does NOT transfer any USDC, touch the escrow,
//       or mark usedIntents.
// Why:  Phase 1 starts the RECLAIM_TIMELOCK countdown, giving the Operator
//       a final window to fulfill the intent before the LP can withdraw.
//       The two-phase pattern (ADR-JB78) keeps timelock enforcement
//       self-contained within FEAT-JAIJ.
// ──────────────────────────────────────────────
contract ReclaimPhase1SubmissionTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-phase1");

    function setUp() public override {
        super.setUp();
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-JAIL: Phase 1 records intentTimestamps to current block.timestamp
    function test_phase1RecordsTimestamp() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(
            vault.intentTimestamps(intentId), block.timestamp, "intentTimestamps should equal current block.timestamp"
        );
    }

    // SC-JAIL: Phase 1 emits ReclaimSubmitted event with correct params
    function test_phase1EmitsReclaimSubmitted() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ReclaimSubmitted(intentId, lp, usdcAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIL: Phase 1 does not transfer any USDC
    function test_phase1NoUsdcTransferred() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 lpBefore = mockUsdc.balanceOf(lp);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance should be unchanged after Phase 1");
        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance should be unchanged after Phase 1");
    }

    // SC-JAIL: Phase 1 leaves the escrow intact, so the Operator can still mint
    function test_phase1LeavesEscrowIntact() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "Phase 1 must not touch the escrow");
    }

    // SC-JAIL: Phase 1 does not mark usedIntents
    function test_phase1UsedIntentsRemainsFalse() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertFalse(vault.usedIntents(intentId), "usedIntents should remain false after Phase 1");
    }

    // SC-JAIL: only the LP named in the intent may call. A third party who has
    // merely obtained a copy of the LP's signature — they are published nowhere,
    // but signatures leak — cannot use it to force that LP's deposit into
    // cancellation. The escrow-owner check would still send the money to the
    // right place, so this gate is about who may START the process, not where
    // the funds go. FEAT-JAIJ names it in Actors; ARCHITECTURE pins it as
    // "LP only (msg.sender == lp)".
    function test_revertsWhenCallerIsNotTheNamedLp() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // The attacker submits the LP's own genuine intent, naming the LP.
        vm.prank(attacker);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(vault.intentTimestamps(intentId), 0, "a stranger must not start the LP's reclaim clock");
        _assertEscrow(intentId, lp, uint96(usdcAmount), "the escrow must be untouched");
    }

    // SC-JAIL: an LP self-service exit is not evidence the Operator is alive
    function test_phase1DoesNotRefreshOperatorSilenceTimer() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            timerBefore,
            "LP activity must not mask a dead Operator by refreshing the silence timer"
        );
    }
}

// ──────────────────────────────────────────────
// SC-JAIL: Successful reclaim after timelock — Phase 2 (execution)
// What: After RECLAIM_TIMELOCK elapses since Phase 1, the second call marks
//       usedIntents[intentId] = true, deletes the escrow, transfers the
//       ESCROWED amount from the vault to the LP, and emits DepositReclaimed.
// Why:  This is the LP escape hatch's primary happy path — proving an LP
//       can recover their USDC when the Operator fails to fulfill.
// Example: LP escrowed 1000 USDC, submitted Phase 1 at t=100,
//          RECLAIM_TIMELOCK = 86400. At t=86501 (past timelock),
//          Phase 2 succeeds: LP gets 1000 USDC back.
// ──────────────────────────────────────────────
contract ReclaimPhase2SuccessTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-phase2");

    bytes lpSig;

    function setUp() public override {
        super.setUp();
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1: submit reclaim request
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        // Warp past RECLAIM_TIMELOCK (24 hours + 1 second margin)
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // SC-JAIL: Phase 2 transfers the escrowed amount from vault to LP
    function test_phase2TransfersUsdcToLp() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "LP balance should increase by the escrowed amount");
        assertEq(
            mockUsdc.balanceOf(address(vault)), vaultBefore - usdcAmount, "vault balance should decrease by usdcAmount"
        );
    }

    // SC-JAIL: Phase 2 marks usedIntents as true
    function test_phase2MarksUsedIntents() public {
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertTrue(vault.usedIntents(intentId), "usedIntents should be true after Phase 2");
    }

    // SC-JAIL: Phase 2 deletes the escrow, so mint and reclaim are mutually exclusive
    function test_phase2DeletesTheEscrow() public {
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        _assertNoEscrow(intentId, "the refunded escrow entry must be cleared");
    }

    // SC-JAIL: Phase 2 emits DepositReclaimed event with correct params
    function test_phase2EmitsDepositReclaimed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, usdcAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIL: an LP self-service exit is not evidence the Operator is alive, so
    // the completed reclaim must leave the silence timer exactly where it was
    function test_phase2DoesNotRefreshOperatorSilenceTimer() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            timerBefore,
            "a completed reclaim must not refresh the silence timer and mask a dead Operator"
        );
    }
}

// ──────────────────────────────────────────────
// SC-JAIL: the refund is the ESCROWED amount, not the amount the intent claims
// What: The LP escrows 600 against intentId X, then drives the reclaim with a
//       second MintIntent over the same X claiming 50,000 — validly signed by
//       the LP themselves. Both phases succeed, and they receive exactly 600.
// Why:  This is the heart of the Critical finding this feature closes. FR-JAIQ
//       requires the refund amount and the recipient to be read from on-chain
//       escrow, "never from the caller-supplied usdcAmount". The signature check
//       cannot catch this: the LP genuinely signed the inflated intent, and it is
//       genuinely their own escrow, so `msg.sender == lp`, `_verifyMintIntent`,
//       and the recorded-depositor check all pass. Only sourcing the amount from
//       `pendingDeposits[X].amount` stops the vault paying out other LPs' funds.
// Example: the vault holds 600 (this LP's escrow) + 50,000 (another LP's). The
//          claim is sized so the vault CAN cover it — paying it out would succeed
//          and silently drain the other LP, rather than reverting on a shortfall.
//          The LP asks for 50,000 and gets 600.
// ──────────────────────────────────────────────
contract ReclaimRefundIsEscrowSourcedTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 escrowedAmount = 600;
    // Deliberately within the vault's balance: an over-payment here is a
    // successful theft, not a failed transfer.
    uint256 inflatedClaim = 50_000;
    bytes32 intentId = keccak256("escrow-600-claim-50k");
    bytes32 otherIntentId = keccak256("another-lps-escrow");

    // The intent the LP actually signs at reclaim time: same intentId, same range,
    // but an amount far above what they ever escrowed.
    bytes inflatedSig;

    function setUp() public override {
        super.setUp();

        // The LP escrows 600 — this is the only USDC attributable to intentId.
        _escrow(LP_PK, lp, tickLower, tickUpper, escrowedAmount, intentId);

        // A different LP escrows 50,000, so the vault has ample balance for an
        // over-payment to come out of. The guard, not an empty vault, is the defence.
        _escrow(ATTACKER_PK, attacker, tickLower, tickUpper, 50_000, otherIntentId);

        inflatedSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, inflatedClaim, intentId);

        // Phase 1 with the inflated intent, then warp past the timelock.
        _submitPhase1(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // SC-JAIL: Phase 1 also reports the escrowed amount, so an indexer never shows
    // a pending refund larger than the vault will pay
    function test_reclaimSubmittedReportsTheEscrowedAmount() public {
        // A fresh intent, so this test drives Phase 1 itself rather than reusing setUp's.
        bytes32 freshId = keccak256("phase1-inflated-claim");
        _escrow(LP_PK, lp, tickLower, tickUpper, escrowedAmount, freshId);
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, inflatedClaim, freshId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ReclaimSubmitted(freshId, lp, escrowedAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, inflatedClaim, freshId, sig);
    }

    // SC-JAIL: the LP receives exactly what they escrowed, not what they claimed
    function test_refundEqualsEscrowedAmountNotClaimedAmount() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + escrowedAmount, "the LP must receive exactly the escrowed 600");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore - escrowedAmount, "the vault must pay out only 600");
    }

    // SC-JAIL: the other LP's escrow is untouched by the inflated claim
    function test_otherLpsEscrowIsUntouched() public {
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);

        _assertEscrow(otherIntentId, attacker, uint96(50_000), "the other LP's escrow must be intact");
        assertGe(mockUsdc.balanceOf(address(vault)), 50_000, "the vault must still hold the other LP's escrow in full");
    }

    // SC-JAIL: the emitted event reports the escrowed amount, so off-chain
    // consumers cannot be misled about what was actually paid
    function test_depositReclaimedReportsTheEscrowedAmount() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, escrowedAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, inflatedClaim, intentId, inflatedSig);
    }
}

// ──────────────────────────────────────────────
// SC-3Z9L: Revert when nothing is escrowed for the intent
// What: A caller holding a validly self-signed intent for an enormous amount,
//       against an intentId that was never funded, is refused with
//       NothingToReclaim — even after waiting out the full timelock.
// Why:  This is the guard that stops a caller who deposited nothing from
//       draining the vault's general balance. Signing an intent for an
//       arbitrary amount grants no claim: only USDC actually escrowed under
//       that intentId can ever be paid out.
// Example: the attacker signs (attacker, 20, 80, 1_000_000, X) with their own
//          key. The vault holds far more than that from other LPs. They still
//          get nothing, because pendingDeposits[X] is empty.
// ──────────────────────────────────────────────
contract ReclaimNothingEscrowedTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 claimedAmount = 1_000_000;
    bytes32 unfundedIntentId = keccak256("never-funded");

    function setUp() public override {
        super.setUp();

        // The vault holds substantial USDC belonging to a real LP's escrow, so a
        // successful drain would have something to take.
        _escrow(LP_PK, lp, tickLower, tickUpper, 5000, keccak256("real-lp-escrow"));
    }

    // SC-3Z9L: Phase 1 is refused outright — the clock never even starts
    function test_revertsOnPhase1WhenNothingEscrowed() public {
        bytes memory sig = _signMintIntent(ATTACKER_PK, attacker, tickLower, tickUpper, claimedAmount, unfundedIntentId);

        vm.prank(attacker);
        vm.expectRevert(LPVault.NothingToReclaim.selector);
        vault.reclaimDeposit(attacker, tickLower, tickUpper, claimedAmount, unfundedIntentId, sig);

        assertEq(vault.intentTimestamps(unfundedIntentId), 0, "an unfunded intent must not start the timelock clock");
    }

    // SC-3Z9L: waiting out the timelock does not help, and no USDC leaves the vault
    function test_noUsdcLeavesTheVaultEvenAfterTheTimelock() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 attackerBefore = mockUsdc.balanceOf(attacker);

        bytes memory sig = _signMintIntent(ATTACKER_PK, attacker, tickLower, tickUpper, claimedAmount, unfundedIntentId);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(attacker);
        vm.expectRevert(LPVault.NothingToReclaim.selector);
        vault.reclaimDeposit(attacker, tickLower, tickUpper, claimedAmount, unfundedIntentId, sig);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be untouched");
        assertEq(mockUsdc.balanceOf(attacker), attackerBefore, "the attacker must receive nothing");
    }
}

// ──────────────────────────────────────────────
// SC-45IG: Revert when the escrow belongs to a different LP
// What: LP A funds intentId X. Attacker B reads X out of the public
//       DepositEscrowed log, signs their OWN intent naming themselves over X,
//       and calls the permissionless reclaimDeposit. They are refused with
//       NotIntentOwner — and A is not locked out.
// Why:  This is the single most security-critical check in the feature.
//       Neither the msg.sender == lp gate nor the signature check stops B,
//       because B genuinely is B and genuinely signed. _verifyMintIntent
//       compares the recovered signer against a caller-supplied `lp`, so a
//       valid signature over an intentId proves only that SOMEONE signed it,
//       never that they funded it. Without the recorded-depositor check,
//       reclaimDeposit — permissionless by design — becomes an unprivileged
//       drain of any pending deposit.
// Example: A escrows 600 against X. B signs (B, 20, 80, 600, X), waits 24h,
//          and still gets nothing; A can then mint or reclaim normally.
// ──────────────────────────────────────────────
contract ReclaimForeignEscrowTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("owned-by-lp-a");

    function setUp() public override {
        super.setUp();
        // LP A funds the intent. The intentId is public in the DepositEscrowed log.
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-45IG: B's own valid signature over A's intentId is refused
    function test_revertsWhenClaimantIsNotTheDepositor() public {
        bytes memory sigB = _signMintIntent(ATTACKER_PK, attacker, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(attacker);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDeposit(attacker, tickLower, tickUpper, usdcAmount, intentId, sigB);
    }

    // SC-45IG: waiting out RECLAIM_TIMELOCK does not help B — the check is on
    // recorded ownership, not on elapsed time
    function test_warpingPastTheTimelockDoesNotHelpTheAttacker() public {
        bytes memory sigB = _signMintIntent(ATTACKER_PK, attacker, tickLower, tickUpper, usdcAmount, intentId);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(attacker);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDeposit(attacker, tickLower, tickUpper, usdcAmount, intentId, sigB);

        assertEq(
            mockUsdc.balanceOf(attacker), 1_000_000, "the attacker's balance must be exactly what they started with"
        );
    }

    // SC-45IG: A's escrow is untouched and A is NOT locked out — B's attempt must
    // not set usedIntents or start the clock on A's behalf
    function test_depositorIsNotLockedOutByTheAttempt() public {
        bytes memory sigB = _signMintIntent(ATTACKER_PK, attacker, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(attacker);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.reclaimDeposit(attacker, tickLower, tickUpper, usdcAmount, intentId, sigB);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "A's escrow must be intact");
        assertFalse(vault.usedIntents(intentId), "usedIntents must stay false so A can still settle the intent");
        assertEq(vault.intentTimestamps(intentId), 0, "B must not start the timelock clock against A's intentId");

        // And A can still complete their own reclaim, start to finish.
        bytes memory sigA = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, sigA);
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 lpBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, sigA);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "A must still be able to recover their own deposit");
    }
}

// ──────────────────────────────────────────────
// SC-JAIM: Revert before timelock elapses
// What: Phase 2 call before RECLAIM_TIMELOCK has elapsed since Phase 1
//       reverts with TimelockNotElapsed. No state changes occur.
// Why:  The timelock gives the Operator a final window to fulfill the intent
//       before USDC is returned. Without this, an LP could submit Phase 1
//       and immediately execute Phase 2 in the next block, giving the
//       Operator no time to react.
// Example: Phase 1 at t=100, RECLAIM_TIMELOCK = 86400. At t=86499
//          (1 second before expiry), Phase 2 reverts.
// ──────────────────────────────────────────────
contract ReclaimTimelockNotElapsedTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-early");

    function setUp() public override {
        super.setUp();
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1: submit
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        // Warp to 1 second before RECLAIM_TIMELOCK expires
        vm.warp(block.timestamp + 24 hours - 1);
    }

    // SC-JAIM: calling Phase 2 before timelock reverts
    function test_revertsBeforeTimelockElapses() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIM: the escrow survives, so the Operator can still mint during the window
    function test_escrowSurvivesTheEarlyAttempt() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "the escrow must survive an early reclaim attempt");
        assertFalse(vault.usedIntents(intentId), "the intentId must remain unused");
    }
}

// ──────────────────────────────────────────────
// SC-JAIN: Revert when intent already fulfilled by mintPositionFor
// What: If the Operator already called mintPositionFor with this intentId,
//       usedIntents[intentId] == true and reclaimDeposit reverts with
//       IntentAlreadyUsed. Mutual exclusion via the shared mapping (ADR-JAIY).
// Why:  An LP whose intent was fulfilled has a position, not stuck USDC.
//       Allowing reclaim after fulfillment would let the LP double-dip:
//       keep the position AND get the USDC back. The mint also consumed the
//       escrow, so there is nothing left to pay out either way.
// ──────────────────────────────────────────────
contract ReclaimIntentAlreadyFulfilledTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("reclaim-fulfilled");

    function setUp() public override {
        super.setUp();

        // Operator escrows the deposit, then fulfills the intent via mintPositionFor.
        // The mint consumes the escrow, which is why nothing is left to reclaim.
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIN: reclaimDeposit reverts when intent already fulfilled
    function test_revertsWhenIntentAlreadyFulfilled() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }
}

// ──────────────────────────────────────────────
// SC-3ZA0: Reclaim succeeds with no registered operators
// What: The Admin removes every operator from the registry. The LP then drives
//       both phases of reclaimDeposit to completion and gets their USDC back.
// Why:  NFR-3Z9X — the escape hatch must depend on no Operator action, no
//       Operator signature, and no Operator registry state at execution time.
//       This is what makes it an escape hatch rather than another
//       Operator-gated path, and it removes the failure mode where an Admin
//       removing an operator invalidated a co-signature the LP had already
//       collected, stranding their deposit.
// ──────────────────────────────────────────────
contract ReclaimWithNoOperatorsTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("reclaim-no-operators");

    function setUp() public override {
        super.setUp();

        // Escrow first — this is the one step that does need a live Operator.
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Then the Admin removes every operator from the registry.
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
        assertEq(factory.operators(operatorAddr), 0, "the operator registry should now be empty");
    }

    // SC-3ZA0: both phases complete with no registered operator anywhere
    function test_bothPhasesCompleteWithNoRegisteredOperators() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
        assertEq(vault.intentTimestamps(intentId), block.timestamp, "Phase 1 should record the submission");

        vm.warp(block.timestamp + 24 hours + 1);

        // Phase 2
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "removing every operator must not strand the deposit");
        assertTrue(vault.usedIntents(intentId), "the intentId should be consumed");
        _assertNoEscrow(intentId, "the escrow should be cleared");
    }
}

// ──────────────────────────────────────────────
// SC-JAIP: Revert on replay (intentId already reclaimed)
// What: After a full reclaim cycle (Phase 1 + Phase 2), usedIntents is true.
//       Any subsequent reclaimDeposit call with the same intentId reverts
//       with IntentAlreadyUsed, preventing double-refund.
// Why:  Without replay protection, an LP could drain the vault by calling
//       reclaimDeposit repeatedly with the same intent. The shared
//       usedIntents mapping (ADR-JAIY) provides mutual exclusion with
//       mintPositionFor, and the deleted escrow means there is nothing to
//       pay out regardless.
// ──────────────────────────────────────────────
contract ReclaimReplayProtectionTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-replay");

    function setUp() public override {
        super.setUp();
        _escrow(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Leave extra USDC in the vault so a successful double-refund would have
        // somewhere to draw from — the guard, not an empty balance, is what stops it.
        mockUsdc.mint(address(vault), usdcAmount);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Complete full reclaim cycle: Phase 1 → warp → Phase 2
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIP: second reclaimDeposit with same intentId reverts
    function test_revertsOnReplayAfterSuccessfulReclaim() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIP: the LP is paid exactly once
    function test_lpIsPaidExactlyOnce() public {
        uint256 lpBalanceAfterOneReclaim = mockUsdc.balanceOf(lp);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        assertEq(mockUsdc.balanceOf(lp), lpBalanceAfterOneReclaim, "no second refund may be paid");
    }
}

// ──────────────────────────────────────────────
// FR-JAIV: RECLAIM_TIMELOCK constant value
// What: RECLAIM_TIMELOCK must be at least 86400 seconds (24 hours) to give
//       the Operator sufficient time to fulfill the intent.
// Why:  FR-JAIV requires >= 24 hours. The ±15s Polygon block.timestamp
//       tolerance is negligible at this scale but documented at the
//       declaration site per CLAUDE.md rule 12.
// ──────────────────────────────────────────────
contract ReclaimTimelockConstantTest is ReclaimDepositTestBase {
    // FR-JAIV: RECLAIM_TIMELOCK is at least 24 hours
    function test_reclaimTimelockIsAtLeast24Hours() public view {
        assertGe(vault.RECLAIM_TIMELOCK(), 86400, "RECLAIM_TIMELOCK should be >= 24 hours (86400 seconds)");
    }
}

// ──────────────────────────────────────────────
// NFR-JAIW: nonReentrant modifier on reclaimDeposit
// What: A malicious ERC-20 that calls back into reclaimDeposit during the
//       Phase 2 USDC transfer is blocked by the nonReentrant guard.
// Why:  Without reentrancy protection, a callback during _safeTransfer
//       could re-enter reclaimDeposit before usedIntents[intentId] is set,
//       allowing multiple withdrawals in a single transaction.
// Example: ReentrantERC20's transfer() calls vault.reclaimDeposit(). The
//          nonReentrant modifier detects _reentrancyGuard == 2 (already
//          entered) and reverts with Reentrancy. The outer call succeeds
//          because the reentrant attempt is try-caught inside the token.
// ──────────────────────────────────────────────
contract ReclaimReentrancyTest is Test {
    LPVaultFactory factory;
    LPVault vault;
    ReentrantERC20 reentrantUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    uint256 constant OPERATOR_PK = 0xB0B;
    address operatorAddr;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        lp = vm.addr(LP_PK);
        operatorAddr = vm.addr(OPERATOR_PK);

        LPVault impl = new LPVault();
        reentrantUsdc = new ReentrantERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(reentrantUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(reentrantUsdc), conditionId);

        vm.prank(oracleAddr);
        vault =
            LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq, conditionId, yesTokenId, noTokenId));

        // Fund the LP so the escrow can pull from them
        reentrantUsdc.mint(lp, 2000);
        vm.prank(lp);
        reentrantUsdc.approve(address(vault), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // NFR-JAIW: reentrant call during Phase 2 transfer is blocked
    function test_reentrancyDuringPhase2TransferIsBlocked() public {
        int24 tickLower = int24(20);
        int24 tickUpper = int24(80);
        uint256 usdcAmount = 1000;
        bytes32 intentId = keccak256("reclaim-reentrant");

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Escrow the deposit so there is something to reclaim
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        // Phase 1: submit reclaim request
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        // Configure the reentrant token to call reclaimDeposit on next transfer
        bytes memory reentrantCalldata = abi.encodeWithSelector(
            LPVault.reclaimDeposit.selector, lp, tickLower, tickUpper, usdcAmount, intentId, lpSig
        );
        reentrantUsdc.setReentrancyTarget(address(vault), reentrantCalldata);

        // Phase 2: warp past timelock, execute reclaim
        uint256 lpBefore = reentrantUsdc.balanceOf(lp);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);

        // The reentrant call was attempted and reverted (nonReentrant guard)
        assertTrue(reentrantUsdc.reentrancyAttempted(), "reentrancy should have been attempted");
        assertTrue(reentrantUsdc.reentrancyReverted(), "reentrant call should have reverted");
        // Assert the REASON, not just that it reverted. Strip the guard and the
        // callback still fails — on msg.sender != lp, since msg.sender is the token —
        // so a bare "did it revert" assertion would pass on an unguarded vault.
        assertEq(
            bytes4(reentrantUsdc.reentrantReturndata()),
            LPVault.Reentrancy.selector,
            "the callback must be stopped by the reentrancy guard specifically"
        );

        // Outer call succeeded — LP got their USDC back, exactly once
        assertEq(
            reentrantUsdc.balanceOf(lp),
            lpBefore + usdcAmount,
            "LP should have received their escrow back despite the reentrancy attempt"
        );
    }
}
