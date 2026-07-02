// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JXQW: Emergency Cancel All
// SLICE-001: emergency-cancel-all

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock with transfer + transferFrom + balanceOf + approve.
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
// Base test contract for emergency cancel scenarios.
// Deploys factory + vault, mints a position for LP-A, distributes fees.
// ──────────────────────────────────────────────
contract EmergencyCancelTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_A_PK = 0xA11CE;
    address lpA;

    uint256 constant LP_B_PK = 0xB0B;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;
    uint256 constant Q128 = 2 ** 128;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Events declared for expectEmit
    event EmergencyCancelExecuted(address indexed caller);
    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

    // Position minted in setUp for LP-A
    uint256 positionIdA;

    function setUp() public virtual {
        lpA = vm.addr(LP_A_PK);
        lpB = vm.addr(LP_B_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        // Mint a position for LP-A: range [0, 100) with 1000 USDC
        mockUsdc.mint(lpA, 1_000_000);
        vm.prank(lpA);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sigA = _signMintIntent(LP_A_PK, lpA, int24(0), int24(100), 1000, keccak256("mint-a-1"));
        vm.prank(operatorAddr);
        positionIdA = vault.mintPositionFor(lpA, int24(0), int24(100), 1000, keccak256("mint-a-1"), sigA);

        // Distribute fees so position has accrued fees
        mockUsdc.mint(address(vault), 500);
        vm.prank(operatorAddr);
        vault.notifyFees(500);
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

    /// @dev Warps block.timestamp past the emergency cancel timelock.
    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
    }
}

// ──────────────────────────────────────────────
// SC-JXQX: Successful emergency cancel after silence timelock
// What: When a position holder calls emergencyCancelAll() after the operator
//       has been silent for >= EMERGENCY_CANCEL_TIMELOCK, all positions are
//       closed, principal + fees distributed to owners, phase transitions to
//       Cancelled (3), and EmergencyCancelExecuted is emitted.
// Why:  This is the core safety-net mechanism — if the Operator disappears,
//       LPs must be able to recover their capital without any trusted party.
// ──────────────────────────────────────────────
contract SuccessfulEmergencyCancelTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXQX: phase transitions to Cancelled (3)
    function test_phaseChangesToCancelled() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
    }

    // SC-JXQX: activeLiquidity zeroed
    function test_activeLiquidityZeroed() public {
        assertTrue(vault.activeLiquidity() > 0, "precondition: activeLiquidity > 0");

        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should be zeroed");
    }

    // SC-JXQX: position liquidity zeroed
    function test_positionLiquidityZeroed() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        (,,, uint128 liquidity,,) = vault.positions(positionIdA);
        assertEq(liquidity, 0, "position liquidity should be zeroed");
    }

    // SC-JXQX: LP receives principal + accrued fees
    function test_lpReceivesPrincipalPlusFees() public {
        uint256 lpBalBefore = mockUsdc.balanceOf(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpBalAfter = mockUsdc.balanceOf(lpA);
        // LP deposited 1000 USDC and 500 in fees were distributed
        // Principal = liquidity * rangeWidth / PRECISION = 10e18 * 100 / 1e18 = 1000
        // Fees = liquidity * feeGrowthDelta / Q128 (should be ~500 minus Q128 truncation dust)
        assertTrue(lpBalAfter > lpBalBefore, "LP should receive USDC");
        assertTrue(lpBalAfter - lpBalBefore >= 1400, "LP should receive at least principal + most fees");
    }

    // SC-JXQX: EmergencyCancelExecuted event emitted
    function test_emitsEmergencyCancelExecutedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit EmergencyCancelExecuted(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();
    }

    // SC-JXQX: vault USDC balance is zero (or dust)
    function test_vaultBalanceZeroOrDust() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        // Allow up to 1 wei of dust from Q128 truncation
        assertLe(mockUsdc.balanceOf(address(vault)), 1, "vault should have zero or dust USDC");
    }
}

// ──────────────────────────────────────────────
// SC-JXQY: Revert before timelock elapses
// What: emergencyCancelAll() reverts if the operator-silence timelock has not
//       yet elapsed since the last operator action.
// Why:  Prevents premature cancellation — the operator might just be slow,
//       not absent.
// ──────────────────────────────────────────────
contract RevertBeforeTimelockTest is EmergencyCancelTestBase {
    // SC-JXQY: reverts with TimelockNotElapsed
    function test_revertsBeforeTimelockElapsed() public {
        // Don't warp — timelock has not elapsed
        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXQY: no state change after revert
    function test_noStateChangeOnRevert() public {
        uint8 phaseBefore = vault.phase();
        uint128 activeLiqBefore = vault.activeLiquidity();

        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), phaseBefore, "phase unchanged");
        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-JXQZ: Revert if caller holds no position
// What: emergencyCancelAll() reverts if the caller does not own any position
//       in the vault, even if the timelock has elapsed.
// Why:  Prevents griefing by external addresses with no stake in the vault.
// ──────────────────────────────────────────────
contract RevertIfNoPositionTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXQZ: arbitrary address with no position reverts
    function test_revertsWhenCallerHasNoPosition() public {
        address noPositionAddr = makeAddr("no-position");
        vm.prank(noPositionAddr);
        vm.expectRevert(LPVault.NoPositionHeld.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXQZ: operator with no position reverts
    function test_revertsWhenOperatorHasNoPosition() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NoPositionHeld.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-JXR0: Multi-LP distribution
// What: When multiple LPs have positions and emergencyCancelAll is triggered,
//       each LP receives their proportional share (principal + fees) across
//       all their positions.
// Why:  Proves the iteration distributes correctly to multiple owners with
//       different liquidity amounts and ranges.
// ──────────────────────────────────────────────
contract MultiLPDistributionTest is EmergencyCancelTestBase {
    uint256 positionIdA2;
    uint256 positionIdB;

    function setUp() public override {
        super.setUp();

        // Mint a second position for LP-A: range [0, 50) with 500 USDC
        bytes memory sigA2 = _signMintIntent(LP_A_PK, lpA, int24(0), int24(50), 500, keccak256("mint-a-2"));
        vm.prank(operatorAddr);
        positionIdA2 = vault.mintPositionFor(lpA, int24(0), int24(50), 500, keccak256("mint-a-2"), sigA2);

        // Mint a position for LP-B: range [0, 100) with 2000 USDC
        mockUsdc.mint(lpB, 1_000_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, int24(0), int24(100), 2000, keccak256("mint-b-1"));
        vm.prank(operatorAddr);
        positionIdB = vault.mintPositionFor(lpB, int24(0), int24(100), 2000, keccak256("mint-b-1"), sigB);

        // Distribute more fees
        mockUsdc.mint(address(vault), 1000);
        vm.prank(operatorAddr);
        vault.notifyFees(1000);

        _warpPastTimelock();
    }

    // SC-JXR0: LP-A receives correct total for both positions
    function test_lpAReceivesCorrectTotal() public {
        uint256 lpABalBefore = mockUsdc.balanceOf(lpA);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpAReceived = mockUsdc.balanceOf(lpA) - lpABalBefore;
        // LP-A deposited 1000 + 500 = 1500 USDC total principal
        assertTrue(lpAReceived >= 1500, "LP-A should receive at least principal");
    }

    // SC-JXR0: LP-B receives correct total for their position
    function test_lpBReceivesCorrectTotal() public {
        uint256 lpBBalBefore = mockUsdc.balanceOf(lpB);

        vm.prank(lpA);
        vault.emergencyCancelAll();

        uint256 lpBReceived = mockUsdc.balanceOf(lpB) - lpBBalBefore;
        // LP-B deposited 2000 USDC principal
        assertTrue(lpBReceived >= 2000, "LP-B should receive at least principal");
    }

    // SC-JXR0: vault USDC balance is zero or dust after multi-LP distribution
    function test_vaultBalanceZeroOrDust() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertLe(mockUsdc.balanceOf(address(vault)), 3, "vault should have zero or dust");
    }

    // SC-JXR0: all 3 positions have liquidity == 0
    function test_allPositionsZeroed() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        (,,, uint128 liq0,,) = vault.positions(positionIdA);
        (,,, uint128 liq1,,) = vault.positions(positionIdA2);
        (,,, uint128 liq2,,) = vault.positions(positionIdB);
        assertEq(liq0, 0, "positionA1 liquidity zeroed");
        assertEq(liq1, 0, "positionA2 liquidity zeroed");
        assertEq(liq2, 0, "positionB liquidity zeroed");
    }

    // SC-JXR0: phase is Cancelled
    function test_phaseCancelled() public {
        vm.prank(lpA);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "phase should be Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-JXR1: Terminal state gates off all operations
// What: After emergencyCancelAll(), every state-changing function reverts.
//       mintPositionFor, updateTick, startWindDown revert with VaultNotActive.
//       collect, notifyFees revert with VaultCancelled.
//       emergencyCancelAll itself reverts (already cancelled).
// Why:  The Cancelled state is terminal — no further operations should succeed
//       on a vault where all funds have been distributed.
// ──────────────────────────────────────────────
contract TerminalStateGatingTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();

        // Execute emergency cancel to enter Cancelled state
        vm.prank(lpA);
        vault.emergencyCancelAll();
    }

    // SC-JXR1: mintPositionFor reverts with VaultNotActive
    function test_mintPositionForReverts() public {
        bytes32 intentId = keccak256("post-cancel-mint");
        bytes memory sig = _signMintIntent(LP_A_PK, lpA, int24(0), int24(100), 500, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lpA, int24(0), int24(100), 500, intentId, sig);
    }

    // SC-JXR1: collect reverts with VaultCancelled
    function test_collectReverts() public {
        vm.prank(lpA);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.collect(positionIdA);
    }

    // SC-JXR1: notifyFees reverts with VaultCancelled
    function test_notifyFeesReverts() public {
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.notifyFees(100);
    }

    // SC-JXR1: updateTick reverts with VaultNotActive
    function test_updateTickReverts() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(int24(50));
    }

    // SC-JXR1: startWindDown reverts with VaultNotActive
    function test_startWindDownReverts() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.startWindDown();
    }

    // SC-JXR1: emergencyCancelAll reverts (already cancelled)
    function test_emergencyCancelAllRevertsAgain() public {
        vm.prank(lpA);
        vm.expectRevert(LPVault.VaultCancelled.selector);
        vault.emergencyCancelAll();
    }
}

// ──────────────────────────────────────────────
// SC-JXR2: Operator activity resets timelock
// What: When the Operator calls notifyFees, lastOperatorActivityTimestamp is
//       reset to block.timestamp, preventing an immediate emergencyCancelAll
//       even though the timelock would have elapsed before the operator action.
// Why:  An active operator proves they haven't abandoned the vault. The
//       timelock should only trigger when the operator truly goes silent.
// ──────────────────────────────────────────────
contract OperatorActivityResetsTimelockTest is EmergencyCancelTestBase {
    function setUp() public override {
        super.setUp();
        _warpPastTimelock();
    }

    // SC-JXR2: notifyFees resets lastOperatorActivityTimestamp
    function test_notifyFeesResetsTimestamp() public {
        // Fund and call notifyFees — this should reset the timer
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vault.notifyFees(100);

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "timestamp should be reset");
    }

    // SC-JXR2: emergencyCancelAll reverts after operator activity resets timer
    function test_emergencyCancelRevertsAfterOperatorActivity() public {
        // Operator acts — resets the timer
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vault.notifyFees(100);

        // Immediately try to cancel — should revert because timer was just reset
        vm.prank(lpA);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault.emergencyCancelAll();
    }

    // SC-JXR2: updateTick also resets timer (already implemented, sanity check)
    function test_updateTickResetsTimestamp() public {
        // updateTick already updates lastOperatorActivityTimestamp
        vm.prank(operatorAddr);
        vault.updateTick(int24(10));

        assertEq(vault.lastOperatorActivityTimestamp(), block.timestamp, "updateTick should reset timestamp");
    }
}
