// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TVS1: Update Current Tick
// SLICE-001: update-tick-with-crossing

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock — balanceOf, approve, transferFrom.
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
// Base test contract for updateTick scenarios.
// Deploys factory + vault clone, mints two positions to set up initialized
// ticks at 0, 100, 200, notifies fees to give feeGrowthGlobalX128 > 0.
//
// Tick state after setUp:
//   tick 0:   liquidityGross=10e18, liquidityNet=+10e18, feeGrowthOutside=feeGrowthGlobal
//   tick 100: liquidityGross=30e18, liquidityNet=+10e18, feeGrowthOutside=0
//   tick 200: liquidityGross=20e18, liquidityNet=-20e18, feeGrowthOutside=0
//   currentTick=0, activeLiquidity=10e18
// ──────────────────────────────────────────────
contract UpdateTickTestBase is Test {
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

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Declare events for vm.expectEmit matching
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

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

        // Fund LP and approve vault
        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Position A: [0, 100) with 1000 USDC → liquidity = 10e18
        _mintPosition(int24(0), int24(100), 1000, keccak256("pos-a"));

        // Position B: [100, 200) with 2000 USDC → liquidity = 20e18
        _mintPosition(int24(100), int24(200), 2000, keccak256("pos-b"));

        // Notify 500 USDC fees → feeGrowthGlobalX128 = mulDiv(500, 2^128, 10e18)
        vm.prank(operatorAddr);
        vault.notifyFees(500);
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId, address(vault));
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _domainSeparatorFor(address vaultAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, vaultAddr));
    }

    function _signMintIntent(
        uint256 pk,
        address lpAddr,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        address vaultAddr
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MINT_INTENT_TYPEHASH, lpAddr, tickLower, tickUpper, usdcAmount, intentId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparatorFor(vaultAddr), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

// ──────────────────────────────────────────────
// SC-TVS2: Price increases crossing initialized ticks (left-to-right)
// What: Operator calls updateTick(150) from currentTick=0. Tick 100 is the
//       only initialized tick in (0, 150]. The crossing flips feeGrowthOutside
//       at tick 100 and adds its +10e18 liquidityNet to activeLiquidity.
// Why:  L-to-R is the primary happy path. feeGrowthOutside flip correctness
//       is critical — every subsequent collect depends on it.
// ──────────────────────────────────────────────
contract UpdateTickLeftToRightTest is UpdateTickTestBase {
    // SC-TVS2: currentTick advances to newTick
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        assertEq(vault.currentTick(), int24(150), "currentTick should be 150");
    }

    // SC-TVS2: activeLiquidity reflects cumulative liquidityNet
    // Position A exits range at tick 100, position B enters → net +10e18
    function test_activeLiquidityAdjusted() public {
        uint128 before_ = vault.activeLiquidity();
        assertEq(before_, 10e18, "precondition: activeLiquidity should be 10e18");

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        // tick 100 liquidityNet = -10e18 (from A upper) + 20e18 (from B lower) = +10e18
        assertEq(vault.activeLiquidity(), 20e18, "activeLiquidity should be 20e18 after crossing tick 100");
    }

    // SC-TVS2: feeGrowthOutsideX128 at tick 100 flipped
    function test_feeGrowthOutsideFlipped() public {
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        (,, uint256 feeGrowthOutsideBefore) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideBefore, 0, "precondition: tick 100 feeGrowthOutside should be 0");

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        (,, uint256 feeGrowthOutsideAfter) = vault.ticks(int24(100));
        assertEq(
            feeGrowthOutsideAfter, feeGrowthGlobal, "tick 100 feeGrowthOutside should equal feeGrowthGlobal after flip"
        );
    }

    // SC-TVS2: TickUpdated event emitted with correct values
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(150), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));
    }

    // SC-TVS2: lastOperatorActivityTimestamp recorded
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(1000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        assertEq(vault.lastOperatorActivityTimestamp(), 1000, "lastOperatorActivityTimestamp should be block.timestamp");
    }
}

// ──────────────────────────────────────────────
// SC-TVS3: Price decreases crossing initialized ticks (right-to-left)
// What: Starting from currentTick=150 (after a forward move), Operator calls
//       updateTick(50). Tick 100 is crossed R-to-L: feeGrowthOutside flips
//       back, activeLiquidity has liquidityNet subtracted.
// Why:  R-to-L is the reverse path. The liquidityNet subtraction and
//       feeGrowthOutside double-flip must produce symmetric state.
// ──────────────────────────────────────────────
contract UpdateTickRightToLeftTest is UpdateTickTestBase {
    function setUp() public override {
        super.setUp();
        // Move to tick 150 first (crosses tick 100 L-to-R)
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));
    }

    // SC-TVS3: currentTick set to newTick
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.currentTick(), int24(50), "currentTick should be 50");
    }

    // SC-TVS3: activeLiquidity reverts to pre-forward-move value
    // Crossing tick 100 R-to-L subtracts liquidityNet (+10e18) → 20e18 - 10e18 = 10e18
    function test_activeLiquidityAdjusted() public {
        assertEq(vault.activeLiquidity(), 20e18, "precondition: activeLiquidity should be 20e18 at tick 150");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.activeLiquidity(), 10e18, "activeLiquidity should be 10e18 after R-to-L crossing");
    }

    // SC-TVS3: feeGrowthOutsideX128 at tick 100 flips back to 0
    function test_feeGrowthOutsideFlippedBack() public {
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();
        (,, uint256 feeGrowthOutsideBefore) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideBefore, feeGrowthGlobal, "precondition: tick 100 fGO should be feeGrowthGlobal");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        (,, uint256 feeGrowthOutsideAfter) = vault.ticks(int24(100));
        assertEq(feeGrowthOutsideAfter, 0, "tick 100 feeGrowthOutside should flip back to 0");
    }

    // SC-TVS3: flip formula is `global - old`, not `global` alone.
    // After setUp, tick 100 fGO = G1 (the first feeGrowthGlobal). We then
    // notify a second fee batch so feeGrowthGlobal becomes G2 > G1. When we
    // cross tick 100 R-to-L, fGO should become G2 - G1, NOT G2.
    // A mutation like `info.feeGrowthOutsideX128 = feeGrowthGlobalX128`
    // would set fGO to G2, which this test catches.
    function test_feeGrowthOutsideFlipUsesOldValue() public {
        uint256 g1 = vault.feeGrowthGlobalX128();
        (,, uint256 fGOBefore) = vault.ticks(int24(100));
        assertEq(fGOBefore, g1, "precondition: tick 100 fGO equals G1");

        // Second fee batch — activeLiquidity is now 20e18 (after L-to-R cross)
        // so the increment is mulDiv(750, Q128, 20e18) — strictly smaller than G1
        // but additive, so G2 > G1 and (G2 - G1) != G2 and (G2 - G1) != 0.
        vm.prank(operatorAddr);
        vault.notifyFees(750);
        uint256 g2 = vault.feeGrowthGlobalX128();
        assertGt(g2, g1, "precondition: G2 > G1");

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        (,, uint256 fGOAfter) = vault.ticks(int24(100));
        assertEq(fGOAfter, g2 - g1, "tick 100 fGO should be G2 - G1, not G2");
        assertGt(fGOAfter, 0, "fGO must be non-zero (guards against `new = global - global` mutation)");
        assertTrue(fGOAfter != g2, "fGO must differ from G2 (guards against `new = global` mutation)");
    }

    // SC-TVS3: TickUpdated event emitted for R-to-L direction
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(150), int24(50), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));
    }

    // SC-TVS3: lastOperatorActivityTimestamp updated
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(2000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.lastOperatorActivityTimestamp(), 2000, "lastOperatorActivityTimestamp should be 2000");
    }
}

// ──────────────────────────────────────────────
// SC-TVS4: No initialized ticks in range
// What: Operator calls updateTick(50) from currentTick=0. The only initialized
//       ticks above 0 are 100 and 200, both outside (0, 50]. No crossings
//       occur; activeLiquidity stays the same.
// Why:  The TickBitmap must correctly report "no initialized ticks in range"
//       and the function must still update currentTick and timestamp.
// ──────────────────────────────────────────────
contract UpdateTickNoTicksCrossedTest is UpdateTickTestBase {
    // SC-TVS4: currentTick advances even with no crossings
    function test_currentTickUpdated() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.currentTick(), int24(50), "currentTick should be 50");
    }

    // SC-TVS4: activeLiquidity unchanged
    function test_activeLiquidityUnchanged() public {
        uint128 before_ = vault.activeLiquidity();

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.activeLiquidity(), before_, "activeLiquidity should be unchanged");
    }

    // SC-TVS4: TickUpdated event with ticksCrossed = 0
    function test_emitsTickUpdatedWithZeroCrossings() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(50), 0);

        vm.prank(operatorAddr);
        vault.updateTick(int24(50));
    }

    // SC-TVS4: lastOperatorActivityTimestamp still updated
    function test_lastOperatorActivityTimestampUpdated() public {
        vm.warp(3000);
        vm.prank(operatorAddr);
        vault.updateTick(int24(50));

        assertEq(vault.lastOperatorActivityTimestamp(), 3000, "timestamp should be updated even with 0 crossings");
    }
}

// ──────────────────────────────────────────────
// SC-TVS5: Too many initialized ticks to cross
// What: A vault with tickSpacing=1 and 258 initialized ticks in the crossing
//       range. updateTick must revert with TooManyTicksCrossed when the count
//       exceeds the MAX_TICK_CROSSINGS cap (256).
// Why:  Gas griefing prevention. Without the cap, a large price move could
//       exhaust the block gas limit.
// ──────────────────────────────────────────────
contract UpdateTickTooManyTicksTest is Test {
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

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    function setUp() public {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        // Create vault with tickSpacing=1 for dense tick initialization
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(keccak256("many-ticks"), int24(1), uint128(1)));

        // Fund LP generously
        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // First position [0, 300) — meets minimumFirstLiquidity floor
        _mintPositionOnVault(int24(0), int24(300), 300, keccak256("big-pos"));

        // Mint 129 positions to create 258 initialized ticks in (0, 260]
        // Each position [2i+1, 2i+2) creates ticks at odd and even indices
        for (uint256 i = 0; i < 129; i++) {
            int24 lower = int24(int256(i * 2 + 1));
            int24 upper = int24(int256(i * 2 + 2));
            bytes32 intentId = keccak256(abi.encode("many-", i));
            _mintPositionOnVault(lower, upper, 1, intentId);
        }
    }

    function _mintPositionOnVault(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 domainSep =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    // SC-TVS5: reverts when crossing more than 256 initialized ticks
    function test_revertsWithTooManyTicksCrossed() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(260));
    }

    // SC-TVS5: state unchanged after revert (implicit in EVM revert semantics,
    // but we verify currentTick for belt-and-suspenders)
    function test_stateUnchangedAfterRevert() public {
        int24 tickBefore = vault.currentTick();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(260));

        assertEq(vault.currentTick(), tickBefore, "currentTick should be unchanged after revert");
    }

    // SC-TVS5: R-to-L direction also reverts with TooManyTicksCrossed
    // Moves the tick forward first, then tries a large reverse move.
    function test_revertsRightToLeftTooManyTicks() public {
        // First move forward to tick 260 (crossing ≤256 ticks since
        // some positions share ticks). Use a tick with exactly 256 crossings.
        // Move to tick 258 — crosses ticks 1..258 = 258 ticks. But we have
        // only 258 initialized ticks in (0, 260], so moving to 258 crosses
        // ticks 1..258 = 258 > 256. That also reverts. Let me move to 256.
        // ticks in (0, 256]: 1..256 = 256 ticks exactly. At the boundary.
        vm.prank(operatorAddr);
        vault.updateTick(int24(256));

        // Now try to move back from 256 to -1. Ticks in (-1, 256]:
        // 0, 1, 2, ..., 256 = 257 ticks > 256. Should revert.
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TooManyTicksCrossed.selector);
        vault.updateTick(int24(-1));
    }
}

// ──────────────────────────────────────────────
// SC-TVS6: Non-operator caller
// What: LP, Admin, Oracle, and arbitrary addresses all get NotOperator when
//       calling updateTick. Only registered Operators may move the tick.
// Why:  Access control prevents unauthorized price manipulation.
// ──────────────────────────────────────────────
contract UpdateTickNonOperatorTest is UpdateTickTestBase {
    // SC-TVS6: LP calling reverts
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: Admin calling reverts
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: Oracle calling reverts
    function test_revertsWhenOracleCalls() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }

    // SC-TVS6: arbitrary address calling reverts
    function test_revertsWhenArbitraryAddressCalls() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.updateTick(int24(150));
    }
}

// ──────────────────────────────────────────────
// SC-TVS7: Same tick
// What: Operator calls updateTick(currentTick). The call is a no-op and
//       wastes gas, so the contract reverts with SameTick.
// Why:  Fail-fast prevents the Keeper from burning gas on redundant calls.
// ──────────────────────────────────────────────
contract UpdateTickSameTickTest is UpdateTickTestBase {
    // SC-TVS7: reverts with SameTick
    function test_revertsWithSameTick() public {
        int24 current = vault.currentTick();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.SameTick.selector);
        vault.updateTick(current);
    }
}

// ──────────────────────────────────────────────
// SC-TVS8: Vault not in Active phase
// What: When the vault phase is not Active (e.g., WindDown), updateTick
//       reverts with VaultNotActive because price updates don't apply to
//       resolved markets.
// Why:  After wind-down there are no more trades, so tick updates are invalid.
// ──────────────────────────────────────────────
contract UpdateTickNotActiveTest is UpdateTickTestBase {
    function setUp() public override {
        super.setUp();
        // Set phase to 2 (WindDown) via direct storage write.
        // phase is at slot 5, offset 17 (packed with minimumFirstLiquidity and _initialized).
        bytes32 slot5 = vm.load(address(vault), bytes32(uint256(5)));
        // Clear byte at offset 17 and set to 2
        bytes32 mask = ~(bytes32(uint256(0xFF)) << (17 * 8));
        bytes32 newVal = (slot5 & mask) | (bytes32(uint256(2)) << (17 * 8));
        vm.store(address(vault), bytes32(uint256(5)), newVal);
    }

    // SC-TVS8: reverts with VaultNotActive
    function test_revertsWhenVaultNotActive() public {
        assertEq(vault.phase(), 2, "precondition: phase should be WindDown (2)");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.updateTick(int24(150));
    }
}

// ──────────────────────────────────────────────
// FR-TVSJ: TickBitmap tracks initialized ticks
// What: After minting positions, the TickBitmap correctly reflects which
//       ticks are initialized. The bitmap enables O(1) per-word lookup of
//       the next initialized tick.
// Why:  The bitmap is the backbone of updateTick's efficiency. Without it,
//       the function would need to iterate every tick in the range.
// ──────────────────────────────────────────────
contract TickBitmapTest is UpdateTickTestBase {
    // FR-TVSJ: bitmap bit set at tick 0 (word 0, bit 0)
    function test_bitmapSetAtTick0() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 0) != 0, "tick 0 should be set in bitmap word 0");
    }

    // FR-TVSJ: bitmap bit set at tick 100 (word 0, bit 100)
    function test_bitmapSetAtTick100() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 100) != 0, "tick 100 should be set in bitmap word 0");
    }

    // FR-TVSJ: bitmap bit set at tick 200 (word 0, bit 200)
    function test_bitmapSetAtTick200() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 200) != 0, "tick 200 should be set in bitmap word 0");
    }

    // FR-TVSJ: uninitialized tick has no bitmap bit
    function test_uninitializedTickNotInBitmap() public view {
        uint256 word = vault.tickBitmap(int16(0));
        assertTrue(word & (1 << 50) == 0, "tick 50 should NOT be set in bitmap");
    }

    // FR-TVSJ: cross-word boundary — tick 260 (word 1, bit 4) via a new position
    function test_bitmapCrossWordBoundary() public {
        // Mint a position at [260, 270) to initialize ticks in word 1
        _mintPosition(int24(260), int24(270), 1000, keccak256("pos-word1"));

        // Tick 260 is word 1 (260 >> 8 = 1), bit 4 (260 & 0xFF = 4)
        uint256 word1 = vault.tickBitmap(int16(1));
        assertTrue(word1 & (1 << 4) != 0, "tick 260 should be set in bitmap word 1");

        // Tick 270 is word 1, bit 14 (270 & 0xFF = 14)
        assertTrue(word1 & (1 << 14) != 0, "tick 270 should be set in bitmap word 1");
    }

    // FR-TVSJ: updateTick crosses word boundary correctly
    function test_updateTickCrossesWordBoundary() public {
        // Mint a position at [260, 270) so tick 260 is initialized in word 1
        _mintPosition(int24(260), int24(270), 1000, keccak256("pos-cross-word"));

        // Move from 0 to 265 — should cross ticks 100, 200 (word 0) and 260 (word 1)
        vm.prank(operatorAddr);
        vault.updateTick(int24(265));

        assertEq(vault.currentTick(), int24(265), "currentTick should be 265");
    }
}
