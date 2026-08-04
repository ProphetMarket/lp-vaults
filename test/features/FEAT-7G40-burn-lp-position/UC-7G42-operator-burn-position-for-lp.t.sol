// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-7G42: Operator Burn Position for LP
// Integration tests for every scenario in this use case.
// Covers: SC-7G4C, SC-7G4D, SC-7G4E, SC-7G4F, SC-7G4G, SC-7G4H, SC-7G4I, SC-7G4J, SC-7G4K

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

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

interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
}

contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[id][to] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        if (to.code.length > 0) {
            bytes4 ack = IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(ack == 0xf23a6e61, "ERC1155: receiver rejected");
        }
    }
}

// ──────────────────────────────────────────────
// Base fixture. Same stack and same position as UC-7G41 so the operator-path scenarios
// are directly comparable to their self-service twins.
// ──────────────────────────────────────────────
contract OperatorBurnTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");
    address stranger = makeAddr("stranger");

    uint256 constant LP_PK = 0xA11CE;
    uint256 constant LP_B_PK = 0xB0B;
    address lp;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(1e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;
    uint256 constant Q128 = 2 ** 128;

    /// @dev secp256k1 group order — used to build the high-s malleable form of a signature.
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    int24 constant TICK_LOWER = 200;
    int24 constant TICK_UPPER = 400;
    uint256 constant DEPOSIT = 1000;
    uint128 constant LIQUIDITY = 5e18;
    uint256 constant PRINCIPAL = 1000;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant BURN_INTENT_TYPEHASH = keccak256("BurnIntent(uint256 positionId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcAmount,
        uint256 outcomeTokenAmount,
        uint256 feesAmount
    );

    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    uint256 posId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        lpB = vm.addr(LP_B_PK);

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

        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        mockCt.mint(address(vault), yesTokenId, 1_000_000);
        mockCt.mint(address(vault), noTokenId, 1_000_000);

        posId = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-a"));
    }

    // ── helpers ───────────────────────────────

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

    function _signReclaimIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(RECLAIM_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _burnIntentDigest(uint256 positionId) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, positionId));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signBurnIntentParts(uint256 pk, uint256 positionId)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(pk, _burnIntentDigest(positionId));
    }

    function _signBurnIntent(uint256 pk, uint256 positionId) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = _signBurnIntentParts(pk, positionId);
        return abi.encodePacked(r, s, v);
    }

    function _mintPosition(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal returns (uint256) {
        bytes memory sig = _signMintIntent(pk, lpAddr, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tickLower, tickUpper, usdcAmount, intentId, sig);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lpAddr, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _moveTick(int24 newTick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(newTick);
    }

    function _notifyFees(uint256 amount) internal {
        mockUsdc.mint(address(vault), amount);
        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    function _burnFor(uint256 positionId, uint256 pk) internal {
        vm.prank(operatorAddr);
        vault.burnPositionFor(positionId, _signBurnIntent(pk, positionId));
    }

    function _positionLiquidity(uint256 id) internal view returns (uint128 liquidity) {
        (,,, liquidity,,) = vault.positions(id);
    }

    function _assertOperatorReceivedNothing() internal view {
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "operator must receive no USDC");
        assertEq(mockCt.balanceOf(yesTokenId, operatorAddr), 0, "operator must receive no YES tokens");
        assertEq(mockCt.balanceOf(noTokenId, operatorAddr), 0, "operator must receive no NO tokens");
    }
}

// ──────────────────────────────────────────────
// SC-7G4C: Operator burn below range pays the LP entirely in USDC
// What: The relayed burn of a below-range position pays the LP the full principal in
//       USDC, matching SC-7G43 exactly because both entry points share one body.
// Why:  Parity is the guarantee ADR-7G5E exists to provide — two functions that computed
//       payouts independently would eventually drift.
// Example: currentTick 150, range [200, 400] → 1000 USDC to the LP, nothing to the caller.
// ──────────────────────────────────────────────
contract OperatorBurnBelowRangeTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(150);
    }

    // SC-7G4C: the LP receives the full principal
    function test_operatorBurnBelowRangePaysLpInUsdc() public {
        uint256 before = mockUsdc.balanceOf(lp);

        _burnFor(posId, LP_PK);

        assertEq(mockUsdc.balanceOf(lp) - before, PRINCIPAL);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 0);
    }

    // SC-7G4C: the Operator paid gas and received nothing
    function test_operatorReceivesNothing() public {
        _burnFor(posId, LP_PK);
        _assertOperatorReceivedNothing();
    }

    // SC-7G4C: activeLiquidity is untouched for an out-of-range position
    function test_activeLiquidityUnchanged() public {
        _burnFor(posId, LP_PK);
        assertEq(vault.activeLiquidity(), uint128(0));
    }

    // SC-7G4C: PositionBurned names the owner, not the caller
    function test_emitsPositionBurnedForOwner() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, PRINCIPAL, 0, 0);

        _burnFor(posId, LP_PK);
    }

    // SC-7G4C: the authorization is recorded as used
    function test_authorizationRecordedAsUsed() public {
        bytes32 digest = _burnIntentDigest(posId);
        assertFalse(vault.usedBurnAuthorizations(digest));

        _burnFor(posId, LP_PK);

        assertTrue(vault.usedBurnAuthorizations(digest));
    }
}

// ──────────────────────────────────────────────
// SC-7G4D: Operator burn above range pays the LP entirely in outcome tokens
// What: The relayed burn delivers a complete set and no USDC principal. Relaying a burn
//       does not authorize the Operator to convert the LP's outcome tokens.
// Why:  FR-7G4N — the vault never sells on the LP's behalf, through either entry point.
// Example: currentTick 450 → 1000 YES + 1000 NO to the LP.
// ──────────────────────────────────────────────
contract OperatorBurnAboveRangeTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(450);
    }

    // SC-7G4D: the complete set lands with the LP
    function test_operatorBurnAboveRangePaysCompleteSetToLp() public {
        uint256 beforeUsdc = mockUsdc.balanceOf(lp);

        _burnFor(posId, LP_PK);

        assertEq(mockCt.balanceOf(yesTokenId, lp), PRINCIPAL);
        assertEq(mockCt.balanceOf(noTokenId, lp), PRINCIPAL);
        assertEq(mockUsdc.balanceOf(lp), beforeUsdc, "no USDC principal above the range");
    }

    // SC-7G4D: no outcome tokens are diverted to the caller
    function test_noOutcomeTokensToCaller() public {
        _burnFor(posId, LP_PK);
        _assertOperatorReceivedNothing();
    }

    // SC-7G4D: PositionBurned reports an outcome-token-only payout
    function test_emitsOutcomeOnlyPayout() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, 0, PRINCIPAL, 0);

        _burnFor(posId, LP_PK);
    }
}

// ──────────────────────────────────────────────
// SC-7G4E: Operator burn in range pays the LP a split, never the caller
// What: Split payout plus accrued fees, every unit of it landing with position.owner
//       read from storage, and activeLiquidity down by exactly the burned liquidity.
// Why:  The recipient must never be msg.sender or a caller-supplied address — that is
//       what stops a compromised Operator key redirecting an exit.
// Example: currentTick 300 with 1000 in fees → 500 USDC + fees, 500 YES, 500 NO.
// ──────────────────────────────────────────────
contract OperatorBurnInRangeTest is OperatorBurnTestBase {
    uint256 constant FEE_REVENUE = 1000;
    uint256 expectedFees;

    function setUp() public override {
        super.setUp();
        _moveTick(300);
        _notifyFees(FEE_REVENUE);

        uint256 feeGrowth = FEE_REVENUE * Q128 / uint256(LIQUIDITY);
        expectedFees = uint256(LIQUIDITY) * feeGrowth / Q128;
    }

    // SC-7G4E: the LP receives both legs plus the fees
    function test_operatorBurnInRangePaysSplitPlusFees() public {
        uint256 before = mockUsdc.balanceOf(lp);

        _burnFor(posId, LP_PK);

        assertEq(mockUsdc.balanceOf(lp) - before, 500 + expectedFees);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
    }

    // SC-7G4E: nothing at all reaches msg.sender
    function test_nothingReachesCaller() public {
        _burnFor(posId, LP_PK);
        _assertOperatorReceivedNothing();
    }

    // SC-7G4E: activeLiquidity drops by exactly the burned liquidity
    function test_activeLiquidityDropsByLiquidity() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY);

        _burnFor(posId, LP_PK);

        assertEq(vault.activeLiquidity(), uint128(0));
    }

    // SC-7G4E: all three amounts appear on the event
    function test_emitsAllThreeAmounts() public {
        vm.expectEmit(true, true, false, true);
        emit PositionBurned(posId, lp, 500, 500, expectedFees);

        _burnFor(posId, LP_PK);
    }

    // FR-7G57: a successful relay refreshes the Operator silence timer
    function test_refreshesOperatorHeartbeat() public {
        vm.warp(block.timestamp + 3 days);

        _burnFor(posId, LP_PK);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp);
    }
}

// ──────────────────────────────────────────────
// SC-7G4F: Revert when the burn authorization is missing
// What: An absent, empty, or foreign-signer signature is rejected. Operator authority
//       alone never closes a position.
// Why:  The Operator can pay for an exit the LP asked for; they cannot decide that an
//       exit happens.
// Example: empty bytes, a 64-byte blob, or LP B's signature over LP A's position.
// ──────────────────────────────────────────────
contract OperatorBurnMissingSignatureTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G4F: empty signature
    function test_emptySignatureReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, "");
    }

    // SC-7G4F: wrong-length signature
    function test_shortSignatureReverts() public {
        (, bytes32 r, bytes32 s) = _signBurnIntentParts(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, s));
    }

    // SC-7G4F: a valid signature from the wrong signer
    function test_foreignSignerReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_B_PK, posId));
    }

    // SC-7G4F: a signature over a different positionId does not transfer
    function test_signatureForAnotherPositionReverts() public {
        uint256 other = _mintPosition(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-other"));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, other));
    }

    // SC-7G4F: the position survives and nothing moves
    function test_rejectedRelayChangesNothing() public {
        uint256 vaultUsdcBefore = mockUsdc.balanceOf(address(vault));
        uint256 heartbeatBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, "");

        assertEq(_positionLiquidity(posId), LIQUIDITY);
        assertEq(vault.activeLiquidity(), LIQUIDITY);
        assertEq(mockUsdc.balanceOf(address(vault)), vaultUsdcBefore);
        assertEq(vault.lastOperatorActivityTimestamp(), heartbeatBefore, "a revert must not refresh the heartbeat");
    }

    // SC-7G4F: the owner's own path is unaffected
    function test_ownerCanStillBurnAfterFailedRelay() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, "");

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(_positionLiquidity(posId), uint128(0));
    }
}

// ──────────────────────────────────────────────
// SC-7G4G: Revert when the burn authorization is malformed
// What: High-s signatures and v values outside {27, 28} are rejected before recovery.
// Why:  A malleable signature is a second valid encoding of the same authorization. The
//       replay guard keys on the digest, so accepting malleability would let a rejected
//       encoding masquerade as a fresh one.
// Example: s replaced by n - s with v flipped, or v = 29.
// ──────────────────────────────────────────────
contract OperatorBurnMalformedSignatureTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G4G: high-s form is rejected
    function test_highSSignatureReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signBurnIntentParts(LP_PK, posId);
        bytes32 flippedS = bytes32(SECP256K1N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, flippedS, flippedV));
    }

    // SC-7G4G: v = 29 is rejected
    function test_invalidVReverts() public {
        (, bytes32 r, bytes32 s) = _signBurnIntentParts(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, s, uint8(29)));
    }

    // SC-7G4G: v = 0 is rejected
    function test_zeroVReverts() public {
        (, bytes32 r, bytes32 s) = _signBurnIntentParts(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, s, uint8(0)));
    }

    // SC-7G4G: the position stays live through every malformed attempt
    function test_positionSurvivesMalformedAttempts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signBurnIntentParts(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, bytes32(SECP256K1N - uint256(s)), v == 27 ? 28 : 27));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, abi.encodePacked(r, s, uint8(29)));

        assertEq(_positionLiquidity(posId), LIQUIDITY);
        assertFalse(vault.usedBurnAuthorizations(_burnIntentDigest(posId)));
    }
}

// ──────────────────────────────────────────────
// SC-7G4H: Revert when a burn authorization is replayed
// What: Resubmitting a consumed authorization reverts with IntentAlreadyUsed, not with
//       PositionNotFound.
// Why:  The rejection must not depend on the position record happening to be empty — a
//       replay has to stay distinguishable from a burn of a position that never existed.
//       This is why the used-check runs before the liveness check.
// Example: burn successfully, then submit the identical signature again.
// ──────────────────────────────────────────────
contract OperatorBurnReplayTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G4H: the replay is rejected as a replay, explicitly
    function test_replayRevertsAsAlreadyUsed() public {
        bytes memory sig = _signBurnIntent(LP_PK, posId);

        vm.prank(operatorAddr);
        vault.burnPositionFor(posId, sig);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.burnPositionFor(posId, sig);
    }

    // SC-7G4H: a freshly re-signed authorization for the same id is rejected too — the
    // guard keys on the digest, which does not depend on the signature bytes
    function test_reSignedAuthorizationAlsoRejected() public {
        _burnFor(posId, LP_PK);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }

    // SC-7G4H: no second payout is drawn
    function test_replayDrawsNoSecondPayout() public {
        bytes memory sig = _signBurnIntent(LP_PK, posId);

        vm.prank(operatorAddr);
        vault.burnPositionFor(posId, sig);
        uint256 afterFirst = mockUsdc.balanceOf(lp);
        uint256 yesAfterFirst = mockCt.balanceOf(yesTokenId, lp);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.burnPositionFor(posId, sig);

        assertEq(mockUsdc.balanceOf(lp), afterFirst);
        assertEq(mockCt.balanceOf(yesTokenId, lp), yesAfterFirst);
    }

    // SC-7G4B via the relayed path: a never-minted id is PositionNotFound, which is what
    // makes the IntentAlreadyUsed above a meaningful distinction
    function test_neverMintedIdIsPositionNotFound() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPositionFor(999, _signBurnIntent(LP_PK, 999));
    }

    // D4: burn authorizations live in their own mapping, so a mint intentId that happens
    // to collide with a burn digest cannot deny the position its gas-sponsored exit
    function test_mintIntentCannotPoisonABurnDigest() public {
        // An attacker reads positionId 0's burn digest — it is publicly computable — and
        // spends it as their own mint intentId.
        bytes32 poison = _burnIntentDigest(posId);
        _mintPosition(LP_B_PK, lpB, TICK_LOWER, TICK_UPPER, DEPOSIT, poison);
        assertTrue(vault.usedIntents(poison), "the collision really is present in usedIntents");

        // The victim's relayed exit still works.
        _burnFor(posId, LP_PK);

        assertEq(_positionLiquidity(posId), uint128(0));
    }
}

// ──────────────────────────────────────────────
// SC-7G4I: Revert when a mint or reclaim authorization is reused as a burn
// What: MintIntent and ReclaimIntent signatures are rejected by burnPositionFor, and a
//       BurnIntent signature is rejected by depositForIntent, mintPositionFor, and
//       reclaimDepositFor. Three disjoint namespaces.
// Why:  An Operator holding an LP's mint authorization must not be able to turn it into
//       an exit — closing a position requires the LP to have signed a burn specifically.
// Example: submit the exact MintIntent signature that opened the position.
// ──────────────────────────────────────────────
contract OperatorBurnTypehashSeparationTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G4I: the MintIntent that opened the position cannot close it
    function test_mintIntentSignatureRejectedByBurn() public {
        bytes memory mintSig = _signMintIntent(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-a"));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, mintSig);
    }

    // SC-7G4I: a ReclaimIntent signature is rejected too
    function test_reclaimIntentSignatureRejectedByBurn() public {
        bytes memory reclaimSig =
            _signReclaimIntent(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("some-intent"));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, reclaimSig);
    }

    // SC-7G4I: the converse — a BurnIntent signature cannot escrow a deposit
    function test_burnIntentSignatureRejectedByDepositForIntent() public {
        bytes memory burnSig = _signBurnIntent(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.depositForIntent(lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("burn-as-deposit"), burnSig);
    }

    // SC-7G4I: nor mint a position
    function test_burnIntentSignatureRejectedByMintPositionFor() public {
        bytes memory burnSig = _signBurnIntent(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("burn-as-mint"), burnSig);
    }

    // SC-7G4I: nor reclaim an escrow
    function test_burnIntentSignatureRejectedByReclaimDepositFor() public {
        bytes memory burnSig = _signBurnIntent(LP_PK, posId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.reclaimDepositFor(lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("burn-as-reclaim"), burnSig);
    }

    // SC-7G4I: the position and its liquidity survive every cross-namespace attempt
    function test_positionIntactAfterCrossNamespaceAttempts() public {
        bytes memory mintSig = _signMintIntent(LP_PK, lp, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-a"));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.burnPositionFor(posId, mintSig);

        assertEq(_positionLiquidity(posId), LIQUIDITY);
        assertEq(vault.activeLiquidity(), LIQUIDITY);
    }
}

// ──────────────────────────────────────────────
// SC-7G4J: Revert on non-operator caller
// What: A caller outside the operator registry is rejected even holding a genuinely
//       valid LP-signed authorization.
// Why:  The gas-sponsored relay is an Operator privilege — a third party must not be able
//       to use a leaked authorization to time an LP's exit.
// Example: the Admin, the Oracle, a stranger, or even the LP themselves.
// ──────────────────────────────────────────────
contract OperatorBurnAccessControlTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
    }

    // SC-7G4J: a stranger with a valid signature is rejected
    function test_strangerCannotRelay() public {
        vm.prank(stranger);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }

    // SC-7G4J: the Admin is not an Operator
    function test_adminCannotRelay() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }

    // SC-7G4J: the Oracle is not an Operator
    function test_oracleCannotRelay() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }

    // SC-7G4J: even the owner must use their own entry point for the relayed form
    function test_ownerCannotRelayOwnBurn() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }

    // SC-7G4J: the gate does not touch the owner's own path
    function test_selfServicePathUnaffectedByGate() public {
        vm.prank(stranger);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));

        vm.prank(lp);
        vault.burnPosition(posId);

        assertEq(_positionLiquidity(posId), uint128(0));
    }

    // SC-7G4J: a removed operator loses the privilege
    function test_removedOperatorCannotRelay() public {
        vm.prank(admin);
        factory.removeOperator(operatorAddr);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.burnPositionFor(posId, _signBurnIntent(LP_PK, posId));
    }
}

// ──────────────────────────────────────────────
// SC-7G4K: Operator burn in WindDown phase succeeds identically to Active
// What: The relayed exit stays open through wind-down, with the same payout, tick
//       updates, and activeLiquidity delta as in Active.
// Why:  An LP with no gas must not be pushed onto the self-service path just because the
//       market resolved.
// Example: oracle calls startWindDown, then the Operator relays the LP's burn.
// ──────────────────────────────────────────────
contract OperatorBurnDuringWindDownTest is OperatorBurnTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(300);
        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-7G4K: identical split during wind-down
    function test_windDownRelayPaysIdenticalSplit() public {
        assertEq(vault.phase(), uint8(2));
        uint256 before = mockUsdc.balanceOf(lp);

        _burnFor(posId, LP_PK);

        assertEq(mockUsdc.balanceOf(lp) - before, 500);
        assertEq(mockCt.balanceOf(yesTokenId, lp), 500);
        assertEq(mockCt.balanceOf(noTokenId, lp), 500);
    }

    // SC-7G4K: tick and liquidity accounting is unchanged by the phase
    function test_windDownRelayUpdatesStateIdentically() public {
        _burnFor(posId, LP_PK);

        assertEq(vault.activeLiquidity(), uint128(0));
        (uint128 grossLower,,) = vault.ticks(TICK_LOWER);
        (uint128 grossUpper,,) = vault.ticks(TICK_UPPER);
        assertEq(grossLower, uint128(0));
        assertEq(grossUpper, uint128(0));
    }

    // SC-7G4K: the heartbeat still refreshes, and the phase does not move
    function test_windDownRelayRefreshesHeartbeatAndHoldsPhase() public {
        vm.warp(block.timestamp + 2 days);

        _burnFor(posId, LP_PK);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp);
        assertEq(vault.phase(), uint8(2));
    }
}

// ──────────────────────────────────────────────
// ADR-7G5E: the two entry points are one implementation
// What: Identical positions burned at an identical currentTick through the two entry
//       points produce identical payouts, identical tick deltas, and identical
//       activeLiquidity deltas.
// Why:  This is the property that makes "no payout or accounting arithmetic is written
//       twice" testable rather than merely asserted in a comment.
// Example: LP A burns for themselves; the Operator relays LP B's identical burn.
// ──────────────────────────────────────────────
contract BurnPathParityTest is OperatorBurnTestBase {
    uint256 posB;

    function setUp() public override {
        super.setUp();
        posB = _mintPosition(LP_B_PK, lpB, TICK_LOWER, TICK_UPPER, DEPOSIT, keccak256("mint-parity"));
        _moveTick(300);
    }

    // ADR-7G5E: both paths pay the same assets in the same amounts
    function test_bothPathsPayIdenticalAmounts() public {
        uint256 usdcBeforeA = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.burnPosition(posId);
        uint256 usdcA = mockUsdc.balanceOf(lp) - usdcBeforeA;
        uint256 yesA = mockCt.balanceOf(yesTokenId, lp);
        uint256 noA = mockCt.balanceOf(noTokenId, lp);

        uint256 usdcBeforeB = mockUsdc.balanceOf(lpB);
        _burnFor(posB, LP_B_PK);
        uint256 usdcB = mockUsdc.balanceOf(lpB) - usdcBeforeB;

        assertEq(usdcB, usdcA, "USDC leg must match across paths");
        assertEq(mockCt.balanceOf(yesTokenId, lpB), yesA, "YES leg must match across paths");
        assertEq(mockCt.balanceOf(noTokenId, lpB), noA, "NO leg must match across paths");
    }

    // ADR-7G5E: both paths apply the same activeLiquidity delta
    function test_bothPathsApplyIdenticalActiveLiquidityDelta() public {
        uint128 start = vault.activeLiquidity();

        vm.prank(lp);
        vault.burnPosition(posId);
        uint128 afterSelfService = vault.activeLiquidity();

        _burnFor(posB, LP_B_PK);
        uint128 afterRelay = vault.activeLiquidity();

        assertEq(start - afterSelfService, afterSelfService - afterRelay, "deltas must match");
        assertEq(afterRelay, uint128(0));
    }

    // ADR-7G5E: both paths apply the same tick deltas
    function test_bothPathsApplyIdenticalTickDeltas() public {
        (uint128 grossStart,,) = vault.ticks(TICK_LOWER);

        vm.prank(lp);
        vault.burnPosition(posId);
        (uint128 grossMid,,) = vault.ticks(TICK_LOWER);

        _burnFor(posB, LP_B_PK);
        (uint128 grossEnd,,) = vault.ticks(TICK_LOWER);

        assertEq(grossStart - grossMid, grossMid - grossEnd, "tick deltas must match");
        assertEq(grossEnd, uint128(0));
    }

    // FR-7G50 vs FR-7G57: the heartbeat is the one thing that differs
    function test_onlyTheRelayedPathTouchesTheHeartbeat() public {
        vm.warp(block.timestamp + 1 days);
        uint256 beforeSelfService = vault.lastOperatorActivityTimestamp();

        vm.prank(lp);
        vault.burnPosition(posId);
        assertEq(vault.lastOperatorActivityTimestamp(), beforeSelfService, "self-service must not refresh");

        _burnFor(posB, LP_B_PK);
        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "relay must refresh");
    }
}
