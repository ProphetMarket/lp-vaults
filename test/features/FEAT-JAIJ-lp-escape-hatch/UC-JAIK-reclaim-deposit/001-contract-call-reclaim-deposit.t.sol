// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JAIK: Reclaim Deposit
// SLICE-001: reclaim-deposit

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// MockERC20 with transfer and transferFrom support for reclaim tests.
// Tracks balances and allowances so tests can assert on USDC movement
// in both directions: vault→LP (reclaim) and LP→vault (mintPositionFor).
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
            (bool success,) = target.call(reentrantCalldata);
            reentrancyReverted = !success;
        }

        return true;
    }
}

// ──────────────────────────────────────────────
// Base test contract with shared setup for all reclaimDeposit scenarios.
// Deploys factory + vault, provides EIP-712 signing helpers for both
// LP and operator, and simulates the deposit-then-credit USDC flow.
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

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        operatorAddr = vm.addr(OPERATOR_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));
    }

    /// @dev Computes the EIP-712 domain separator for the vault.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    /// @dev Signs a MintIntent struct with the given private key.
    ///      Used for both LP signatures and operator co-signatures — both
    ///      sign over the same MintIntent struct (no separate TYPEHASH).
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

    /// @dev Funds the vault with USDC (simulating LP deposit-then-credit flow
    ///      where the LP wires USDC to the vault before the operator mints).
    function _depositUsdcToVault(uint256 amount) internal {
        mockUsdc.mint(address(vault), amount);
    }

    /// @dev Executes Phase 1 of reclaimDeposit (records timestamp).
    function _submitPhase1(
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        bytes memory lpSig,
        bytes memory opSig
    ) internal {
        vm.prank(lpAddr);
        vault.reclaimDeposit(lpAddr, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
    }
}

// ──────────────────────────────────────────────
// SC-JAIL: Successful reclaim after timelock — Phase 1 (submission)
// What: The first call to reclaimDeposit with a valid, unfulfilled intentId
//       records intentTimestamps[intentId] = block.timestamp, emits
//       ReclaimSubmitted, and does NOT transfer any USDC or mark usedIntents.
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
        _depositUsdcToVault(usdcAmount);
    }

    // SC-JAIL: Phase 1 records intentTimestamps to current block.timestamp
    function test_phase1RecordsTimestamp() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        assertEq(
            vault.intentTimestamps(intentId), block.timestamp, "intentTimestamps should equal current block.timestamp"
        );
    }

    // SC-JAIL: Phase 1 emits ReclaimSubmitted event with correct params
    function test_phase1EmitsReclaimSubmitted() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ReclaimSubmitted(intentId, lp, usdcAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
    }

    // SC-JAIL: Phase 1 does not transfer any USDC
    function test_phase1NoUsdcTransferred() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 lpBefore = mockUsdc.balanceOf(lp);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance should be unchanged after Phase 1");
        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance should be unchanged after Phase 1");
    }

    // SC-JAIL: Phase 1 does not mark usedIntents
    function test_phase1UsedIntentsRemainsFalse() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        assertFalse(vault.usedIntents(intentId), "usedIntents should remain false after Phase 1");
    }
}

// ──────────────────────────────────────────────
// SC-JAIL: Successful reclaim after timelock — Phase 2 (execution)
// What: After RECLAIM_TIMELOCK elapses since Phase 1, the second call to
//       reclaimDeposit marks usedIntents[intentId] = true, transfers
//       usdcAmount from the vault to the LP, and emits DepositReclaimed.
// Why:  This is the LP escape hatch's primary happy path — proving an LP
//       can recover their USDC when the Operator fails to fulfill.
// Example: LP deposited 1000 USDC, submitted Phase 1 at t=100,
//          RECLAIM_TIMELOCK = 86400. At t=86501 (past timelock),
//          Phase 2 succeeds: LP gets 1000 USDC back.
// ──────────────────────────────────────────────
contract ReclaimPhase2SuccessTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-phase2");

    bytes lpSig;
    bytes opSig;

    function setUp() public override {
        super.setUp();
        _depositUsdcToVault(usdcAmount);

        lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1: submit reclaim request
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        // Warp past RECLAIM_TIMELOCK (24 hours + 1 second margin)
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // SC-JAIL: Phase 2 transfers usdcAmount from vault to LP
    function test_phase2TransfersUsdcToLp() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore + usdcAmount, "LP balance should increase by usdcAmount");
        assertEq(
            mockUsdc.balanceOf(address(vault)), vaultBefore - usdcAmount, "vault balance should decrease by usdcAmount"
        );
    }

    // SC-JAIL: Phase 2 marks usedIntents as true
    function test_phase2MarksUsedIntents() public {
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        assertTrue(vault.usedIntents(intentId), "usedIntents should be true after Phase 2");
    }

    // SC-JAIL: Phase 2 emits DepositReclaimed event with correct params
    function test_phase2EmitsDepositReclaimed() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit DepositReclaimed(intentId, lp, usdcAmount);

        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
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
        _depositUsdcToVault(usdcAmount);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1: submit
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        // Warp to 1 second before RECLAIM_TIMELOCK expires
        vm.warp(block.timestamp + 24 hours - 1);
    }

    // SC-JAIM: calling Phase 2 before timelock reverts
    function test_revertsBeforeTimelockElapses() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
    }
}

// ──────────────────────────────────────────────
// SC-JAIN: Revert when intent already fulfilled by mintPositionFor
// What: If the Operator already called mintPositionFor with this intentId,
//       usedIntents[intentId] == true and reclaimDeposit reverts with
//       IntentAlreadyUsed. Mutual exclusion via the shared mapping (ADR-JAIY).
// Why:  An LP whose intent was fulfilled has a position, not stuck USDC.
//       Allowing reclaim after fulfillment would let the LP double-dip:
//       keep the position AND get the USDC back.
// ──────────────────────────────────────────────
contract ReclaimIntentAlreadyFulfilledTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("reclaim-fulfilled");

    function setUp() public override {
        super.setUp();

        // Fund LP and approve vault for mintPositionFor's transferFrom
        mockUsdc.mint(lp, usdcAmount);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Operator fulfills the intent via mintPositionFor
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig);
    }

    // SC-JAIN: reclaimDeposit reverts when intent already fulfilled
    function test_revertsWhenIntentAlreadyFulfilled() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
    }
}

// ──────────────────────────────────────────────
// SC-JAIO: Revert on invalid operator signature
// What: If the operator signature does not recover to a registered operator,
//       reclaimDeposit reverts with InvalidSignature. Also covers malleable
//       signatures (high-s) and invalid v values per NFR-JAIX.
// Why:  The operator co-signature proves the operator acknowledged the deposit.
//       Without valid operator attestation, anyone could fabricate a reclaim
//       for arbitrary USDC amounts. Malleability rejection prevents an attacker
//       from deriving a second valid signature from an observed one.
// ──────────────────────────────────────────────
contract ReclaimInvalidOperatorSignatureTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-badsig");

    bytes lpSig;

    function setUp() public override {
        super.setUp();
        _depositUsdcToVault(usdcAmount);
        lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
    }

    /// @dev Builds an operator signature with s flipped to the upper half of secp256k1.
    function _buildHighSOperatorSig() internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, digest);

        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(secp256k1n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        return abi.encodePacked(r, highS, flippedV);
    }

    /// @dev Builds an operator signature with invalid v value (26 instead of 27 or 28).
    function _buildBadVOperatorSig() internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, digest);
        return abi.encodePacked(r, s, uint8(26));
    }

    // SC-JAIO: signature from non-operator address reverts
    function test_revertsWhenSignerIsNotOperator() public {
        uint256 randomPk = 0xDEAD;
        bytes memory badOpSig = _signMintIntent(randomPk, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, badOpSig);
    }

    // SC-JAIO, NFR-JAIX: operator signature with high-s value reverts
    function test_revertsOnHighSOperatorSignature() public {
        bytes memory malleableSig = _buildHighSOperatorSig();

        vm.prank(lp);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, malleableSig);
    }

    // SC-JAIO, NFR-JAIX: operator signature with invalid v value reverts
    function test_revertsOnInvalidVOperatorSignature() public {
        bytes memory badVSig = _buildBadVOperatorSig();

        vm.prank(lp);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, badVSig);
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
//       mintPositionFor.
// ──────────────────────────────────────────────
contract ReclaimReplayProtectionTest is ReclaimDepositTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 1000;
    bytes32 intentId = keccak256("reclaim-replay");

    function setUp() public override {
        super.setUp();
        // Enough USDC for a potential double-refund
        _depositUsdcToVault(usdcAmount * 2);

        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Complete full reclaim cycle: Phase 1 → warp → Phase 2
        _submitPhase1(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
    }

    // SC-JAIP: second reclaimDeposit with same intentId reverts
    function test_revertsOnReplayAfterSuccessfulReclaim() public {
        bytes memory lpSig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(lp);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);
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

    function setUp() public {
        lp = vm.addr(LP_PK);
        operatorAddr = vm.addr(OPERATOR_PK);

        LPVault impl = new LPVault();
        reentrantUsdc = new ReentrantERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(reentrantUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        // Fund vault with USDC (simulating LP deposit)
        reentrantUsdc.mint(address(vault), 2000);
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
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        // Phase 1: submit reclaim request
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        // Configure the reentrant token to call reclaimDeposit on next transfer
        bytes memory reentrantCalldata = abi.encodeWithSelector(
            LPVault.reclaimDeposit.selector, lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig
        );
        reentrantUsdc.setReentrancyTarget(address(vault), reentrantCalldata);

        // Phase 2: warp past timelock, execute reclaim
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(lp);
        vault.reclaimDeposit(lp, tickLower, tickUpper, usdcAmount, intentId, lpSig, opSig);

        // The reentrant call was attempted and reverted (nonReentrant guard)
        assertTrue(reentrantUsdc.reentrancyAttempted(), "reentrancy should have been attempted");
        assertTrue(reentrantUsdc.reentrancyReverted(), "reentrant call should have reverted");

        // Outer call succeeded — LP got their USDC
        assertEq(reentrantUsdc.balanceOf(lp), usdcAmount, "LP should have received USDC despite reentrancy attempt");
    }
}
