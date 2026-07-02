// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JGEE: Start Wind Down
// SLICE-001: start-wind-down

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
// Base test contract for wind-down scenarios.
// Deploys factory + vault clone, mints an in-range position for the LP,
// and distributes fees so there is a position with claimable fees.
// ──────────────────────────────────────────────
contract StartWindDownTestBase is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

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
    event VaultWindDownStarted(bytes32 indexed marketId);
    event FeesCollected(uint256 indexed positionId, address indexed owner, uint256 amount);

    // Position minted in setUp for exit-path tests
    uint256 positionId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        // Mint a position: range [0, 100) with 1000 USDC so there's
        // something to collect and an existing position for exit-path tests.
        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 1000, keccak256("setup-mint"));
        vm.prank(operatorAddr);
        positionId = vault.mintPositionFor(lp, int24(0), int24(100), 1000, keccak256("setup-mint"), sig);

        // Distribute fees so the position has something to collect
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

    /// @dev Transitions the vault to WindDown using the real startWindDown() function.
    function _windDownVault() internal {
        vm.prank(oracleAddr);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEF: Successful wind-down transition
// What: When the Oracle calls startWindDown() on an Active vault, the phase
//       transitions from Active (1) to WindDown (2) and a VaultWindDownStarted
//       event is emitted with the vault's marketId.
// Why:  This is the core lifecycle transition — the only mechanism by which a
//       vault stops accepting new positions when its underlying market resolves.
// ──────────────────────────────────────────────
contract SuccessfulWindDownTest is StartWindDownTestBase {
    // SC-JGEF: phase transitions from Active to WindDown
    function test_phaseChangesToWindDown() public {
        assertEq(vault.phase(), 1, "precondition: vault should be Active");

        vm.prank(oracleAddr);
        vault.startWindDown();

        assertEq(vault.phase(), 2, "phase should be WindDown after startWindDown");
    }

    // SC-JGEF: VaultWindDownStarted event emitted with correct marketId
    function test_emitsVaultWindDownStartedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit VaultWindDownStarted(marketId);

        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    // SC-JGEF: no other state is modified (positions, ticks, fees unchanged)
    function test_noSideEffectsOnPositionState() public {
        // Snapshot position state before wind-down
        (address ownerBefore, int24 tlBefore, int24 tuBefore, uint128 liqBefore, uint256 feeGrowthBefore,) =
            vault.positions(positionId);
        uint256 feeGrowthGlobalBefore = vault.feeGrowthGlobalX128();
        uint128 activeLiqBefore = vault.activeLiquidity();
        int24 currentTickBefore = vault.currentTick();

        vm.prank(oracleAddr);
        vault.startWindDown();

        // Verify nothing changed except phase
        (address ownerAfter, int24 tlAfter, int24 tuAfter, uint128 liqAfter, uint256 feeGrowthAfter,) =
            vault.positions(positionId);
        assertEq(ownerAfter, ownerBefore, "owner unchanged");
        assertEq(tlAfter, tlBefore, "tickLower unchanged");
        assertEq(tuAfter, tuBefore, "tickUpper unchanged");
        assertEq(liqAfter, liqBefore, "liquidity unchanged");
        assertEq(feeGrowthAfter, feeGrowthBefore, "feeGrowthInsideLast unchanged");
        assertEq(vault.feeGrowthGlobalX128(), feeGrowthGlobalBefore, "feeGrowthGlobal unchanged");
        assertEq(vault.activeLiquidity(), activeLiqBefore, "activeLiquidity unchanged");
        assertEq(vault.currentTick(), currentTickBefore, "currentTick unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-JGEG: Revert when phase is not Active (idempotency)
// What: A second startWindDown() call reverts because the vault is already
//       in WindDown phase. This proves the transition is idempotent-safe.
// Why:  Prevents accidental double-calls from corrupting state or emitting
//       duplicate events.
// ──────────────────────────────────────────────
contract RevertWhenNotActiveTest is StartWindDownTestBase {
    function setUp() public override {
        super.setUp();
        // First wind-down — puts vault in WindDown phase
        _windDownVault();
    }

    // SC-JGEG: second call reverts with VaultNotActive
    function test_revertsOnSecondCall() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEH: Revert when non-Oracle calls
// What: Only the Oracle can transition the vault. Operator, LP, Admin, and
//       arbitrary addresses all revert with NotOracle.
// Why:  startWindDown is a lifecycle operation — compromise of the Operator
//       key must not allow an attacker to freeze minting across all vaults.
// ──────────────────────────────────────────────
contract RevertWhenNonOracleCallsTest is StartWindDownTestBase {
    // SC-JGEH: operator reverts
    function test_revertsWhenOperatorCalls() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: LP reverts
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: arbitrary address reverts
    function test_revertsWhenArbitraryAddressCalls() public {
        address arbitrary = makeAddr("arbitrary");
        vm.prank(arbitrary);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }

    // SC-JGEH: admin reverts (admin is registry-only, cannot call vault lifecycle functions)
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.startWindDown();
    }
}

// ──────────────────────────────────────────────
// SC-JGEI + SC-JGEJ: Mint paths revert in WindDown
// What: After startWindDown(), mintPositionFor reverts with VaultNotActive
//       even with a valid LP-signed intent. No position is created and the
//       intentId is not consumed.
// Why:  WindDown means the market has resolved — new capital entering a
//       resolved market would be trapped with no purpose.
// Note: mintPosition does not exist as a separate function in this codebase.
//       SC-JGEI is subsumed by SC-JGEJ since mintPositionFor is the only
//       mint entry point.
// ──────────────────────────────────────────────
contract MintRevertsInWindDownTest is StartWindDownTestBase {
    function setUp() public override {
        super.setUp();
        _windDownVault();
    }

    // SC-JGEI + SC-JGEJ: mintPositionFor reverts with VaultNotActive
    function test_mintPositionForRevertsInWindDown() public {
        bytes32 intentId = keccak256("wind-down-mint");
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, sig);
    }

    // SC-JGEJ: no position created (nextPositionId unchanged)
    function test_nextPositionIdUnchangedAfterRevert() public {
        uint256 nextIdBefore = vault.nextPositionId();

        bytes32 intentId = keccak256("wind-down-mint-2");
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, sig);

        assertEq(vault.nextPositionId(), nextIdBefore, "nextPositionId should not change");
    }

    // SC-JGEJ: intentId not consumed
    function test_intentIdNotConsumedAfterRevert() public {
        bytes32 intentId = keccak256("wind-down-mint-3");
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 500, intentId, sig);

        assertEq(vault.usedIntents(intentId), false, "intentId should not be marked as used");
    }
}

// ──────────────────────────────────────────────
// SC-JGEK: Exit paths succeed in WindDown
// What: After startWindDown(), collect still works for positions with accrued
//       fees. LPs can exit their positions without being blocked by the phase.
// Why:  Capital must never be stranded. The wind-down only prevents new mints;
//       all exit paths remain open so LPs can withdraw.
// ──────────────────────────────────────────────
contract ExitPathsSucceedInWindDownTest is StartWindDownTestBase {
    function setUp() public override {
        super.setUp();
        _windDownVault();
    }

    // SC-JGEK: collect succeeds in WindDown and transfers fees to LP
    function test_collectSucceedsInWindDown() public {
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.collect(positionId);

        assertTrue(mockUsdc.balanceOf(lp) > lpBalBefore, "LP should receive fees in WindDown");
    }

    // SC-JGEK: collect emits FeesCollected event in WindDown
    function test_collectEmitsEventInWindDown() public {
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        (,,,, uint256 feeGrowthInsideLast,) = vault.positions(positionId);
        uint256 feeGrowthDelta = feeGrowthGlobal - feeGrowthInsideLast;
        (,,, uint128 liquidity,,) = vault.positions(positionId);
        uint256 expectedOwed = uint256(liquidity) * feeGrowthDelta / Q128;

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesCollected(positionId, lp, expectedOwed);

        vm.prank(lp);
        vault.collect(positionId);
    }

    // SC-JGEK: tokensOwed zeroed after collect in WindDown
    function test_tokensOwedZeroedAfterCollectInWindDown() public {
        vm.prank(lp);
        vault.collect(positionId);

        (,,,,, uint256 tokensOwed) = vault.positions(positionId);
        assertEq(tokensOwed, 0, "tokensOwed should be zeroed after collect");
    }

    // SC-JGEK: vault phase remains WindDown after collect
    function test_phaseUnchangedAfterCollect() public {
        vm.prank(lp);
        vault.collect(positionId);

        assertEq(vault.phase(), 2, "phase should still be WindDown");
    }
}
