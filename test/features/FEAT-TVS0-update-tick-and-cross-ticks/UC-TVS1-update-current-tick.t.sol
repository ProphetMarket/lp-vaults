// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TVS1: Update Current Tick
// Integration tests for every scenario in this use case.
// Covers: SC-TVS2, SC-TVS3, SC-TVS4, SC-TVS5, SC-TVS6, SC-TVS7, SC-TVS8,
//         SC-5IDH, SC-5IDI, SC-5IDJ, SC-5IDL

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

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

contract MockConditionalTokens is CTFPositionIds {
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

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

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
        // Mint consumes an escrow rather than pulling tokens (FEAT-3ZRI).
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
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

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        // Create vault with tickSpacing=1 for dense tick initialization
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(keccak256("many-ticks"), int24(1), uint128(1), conditionId, yesTokenId, noTokenId)
        );

        // Fund LP generously
        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // First position [0, 300) — meets minimumFirstLiquidity floor
        _mintPositionOnVault(int24(0), int24(300), 300, keccak256("big-pos"));

        // Mint 129 positions to create 258 initialized ticks in (0, 260]
        // Each position [2i+1, 2i+2) creates ticks at odd and even indices
        for (uint256 i = 0; i < 129; i++) {
            // casting is safe because i < 129 so i*2+2 <= 260, well within int24 range
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 lower = int24(int256(i * 2 + 1));
            // forge-lint: disable-next-line(unsafe-typecast)
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

        // Mint consumes an escrow rather than pulling tokens (FEAT-3ZRI).
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
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

// ── Regression: fee-growth wraparound (audit NM-0986-Prophet) ──
//   Tick crossing succeeds even when a tick's feeGrowthOutside flip
//   wraps mod 2^256
// ─────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────
// Base test contract for the _crossTick wraparound reproduction.
//
// _crossTick's flip (`info.feeGrowthOutsideX128 = feeGrowthGlobalX128 -
// info.feeGrowthOutsideX128`) uses the identical mod-2^256 pattern as
// _computeFeeGrowthInside, mirroring Uniswap v3's audited _crossTick exactly.
// This test constructs a tick whose feeGrowthOutsideX128 exceeds the current
// feeGrowthGlobalX128 directly via vm.store, pinning FR-TVSA's contract:
// "the flip must not revert regardless of how the tick's outside snapshot
// arrived at that value" -- the same defensive posture Uniswap v3 itself
// applies to this exact line.
// ──────────────────────────────────────────────
contract CrossTickWraparoundTestBase is Test {
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
    uint128 minFirstLiq = uint128(1e18);

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);

    // `ticks` mapping is storage slot 13; feeGrowthOutsideX128 is the
    // struct's 2nd field (slot + 1) -- liquidityGross/liquidityNet share slot 0.
    uint256 constant TICKS_SLOT = 13;
    uint256 constant FEE_GROWTH_OUTSIDE_OFFSET = 1;

    uint256 posId;

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

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

        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // A position spanning [0, 200) initializes ticks 0 and 200, and
        // keeps activeLiquidity nonzero so notifyFees can run.
        posId = _mintPosition(int24(0), int24(200), 1000, keccak256("wide"));
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

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        returns (uint256)
    {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        // Mint consumes an escrow rather than pulling tokens (FEAT-3ZRI), so the
        // Operator has to fund the intent first. One LP signature authorizes both.
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    /// @dev Overwrites ticks[tick].feeGrowthOutsideX128 directly.
    function _setFeeGrowthOutside(int24 tick, uint256 value) internal {
        bytes32 baseSlot = keccak256(abi.encode(tick, TICKS_SLOT));
        vm.store(address(vault), bytes32(uint256(baseSlot) + FEE_GROWTH_OUTSIDE_OFFSET), bytes32(value));
    }
}

// ──────────────────────────────────────────────
// FR-TVSA: crossing a tick succeeds even when its feeGrowthOutside snapshot
// exceeds the current feeGrowthGlobalX128
// What: _crossTick's flip (feeGrowthGlobalX128 - tick.feeGrowthOutsideX128)
//       underflows if the tick's stored feeGrowthOutsideX128 is larger than
//       the current global -- a state that can arise as the wrapped,
//       mod-2^256-consistent result of the same tick's fee-growth history.
//       Before the fix, crossing such a tick reverts the whole updateTick
//       call; after the fix, the flip wraps mod 2^256 and the crossing
//       succeeds, exactly mirroring Uniswap v3's own audited pattern for
//       this line.
// ──────────────────────────────────────────────
contract CrossTickWraparoundTest is CrossTickWraparoundTestBase {
    function setUp() public override {
        super.setUp();

        // Give feeGrowthGlobalX128 a modest, known value...
        mockUsdc.mint(address(vault), 100);
        vm.prank(operatorAddr);
        vault.notifyFees(100);

        // ...then force tick 200 (the position's upper bound, about to be
        // crossed) to a feeGrowthOutsideX128 that exceeds the current global.
        _setFeeGrowthOutside(int24(200), type(uint256).max - 1000);
    }

    // FR-TVSA: crossing tick 200 succeeds instead of reverting. The target
    // is exactly tick 200 (not beyond it) so the crossing loop's outer
    // `while (tick < newTick)` condition is satisfied the instant tick 200
    // is reached -- exercising only _crossTick's flip on tick 200, without
    // the loop needing to search for any further initialized tick above it
    // (this vault has none above 200).
    function test_crossingSucceedsDespiteOutsideExceedingGlobal() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(200));

        assertEq(vault.currentTick(), int24(200), "currentTick should advance to 200");
    }

    // FR-TVSA: TickUpdated is still emitted with the correct crossing count.
    function test_emitsTickUpdatedEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(0), int24(200), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(200));
    }

    // FR-TVSA: activeLiquidity still adjusts correctly by the tick's
    // liquidityNet despite the wrapped feeGrowthOutside flip.
    function test_activeLiquidityStillAdjustsCorrectly() public {
        uint128 before_ = vault.activeLiquidity();

        vm.prank(operatorAddr);
        vault.updateTick(int24(200));

        // Tick 200 is the position's upper bound (liquidityNet negative);
        // crossing L-to-R removes it from activeLiquidity. Position liquidity
        // = usdcAmount(1000) * LIQUIDITY_PRECISION(1e18) / rangeWidth(200) = 5e18.
        assertEq(vault.activeLiquidity(), before_ - 5e18, "activeLiquidity should drop by the position's liquidity");
    }
}

// ── Regression: target-bounded tick search (audit NM-0986-Prophet) ──
//   updateTick's bitmap scan stops at the Operator's target tick, and
//   reaching an extreme bitmap word reports "not found" rather than
//   reverting with an arithmetic panic.
// ────────────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────
// Base fixture for the bounded-search scenarios.
//
// Deliberately mints nothing: each scenario below initializes exactly the
// ticks its own case needs, because what is being pinned is which words the
// search does and does not read. A shared fixture that pre-initialized ticks
// near the origin would mask the very behavior under test -- the buggy scan
// terminates as soon as it finds ANY set bit, so a stray nearby tick makes an
// unbounded scan look cheap.
//
// minimumFirstLiquidity is 1 so each scenario's first mint is unconstrained,
// and tickSpacing is 10 so the int24 extremes are reachable: 8388600 is the
// largest multiple of 10 within int24 (max 8388607).
// ──────────────────────────────────────────────
contract BoundedTickSearchTestBase is Test {
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

    /// @dev `currentTick` is storage slot 8, offset 0 -- an int24 alone in its slot,
    ///      preceded by activeLiquidity (slot 6) and feeGrowthGlobalX128 (slot 7) and
    ///      followed by nextPositionId, a full uint256. Writing it directly is what
    ///      lets a scenario start the vault at an extreme tick without first calling
    ///      updateTick, which is the function under test. `_setCurrentTick` reads the
    ///      value back so a future storage-layout change fails here, loudly, rather
    ///      than silently turning every assertion below into a test of the wrong tick.
    uint256 constant CURRENT_TICK_SLOT = 8;

    /// @dev The extreme ticks reachable at tickSpacing 10. int24 spans
    ///      [-8388608, 8388607], so these are the outermost aligned ticks.
    ///      8388600 lands in bitmap word 32767 == type(int16).max, and -8388600
    ///      in word -32768 == type(int16).min -- the two words whose boundary
    ///      handling FR-5IDF is about.
    int24 constant HIGHEST_ALIGNED_TICK = 8388600;
    int24 constant LOWEST_ALIGNED_TICK = -8388600;

    /// @dev Gas ceiling for a move that crosses nothing. A target-bounded scan
    ///      reads two or three bitmap words; an unbounded one walks up to 32768
    ///      cold words at 2100 gas each, roughly 69,000,000. The ceiling sits far
    ///      above the former and far below the latter, so it discriminates without
    ///      being brittle about the exact cost of a correct call.
    uint256 constant BOUNDED_SCAN_GAS_CEILING = 500_000;

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(keccak256("bounded-search"), int24(10), uint128(1), conditionId, yesTokenId, noTokenId)
        );

        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    function _setCurrentTick(int24 tick) internal {
        vm.store(address(vault), bytes32(CURRENT_TICK_SLOT), bytes32(uint256(uint24(tick))));
        assertEq(vault.currentTick(), tick, "fixture: currentTick slot write did not take -- storage layout moved?");
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId) internal {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Mint consumes an escrow rather than pulling tokens (FEAT-3ZRI).
        vm.prank(operatorAddr);
        vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    /// @dev Runs updateTick as the Operator and reports the gas it consumed.
    function _updateTickMeasuringGas(int24 newTick) internal returns (uint256 gasUsed) {
        vm.prank(operatorAddr);
        uint256 gasBefore = gasleft();
        vault.updateTick(newTick);
        gasUsed = gasBefore - gasleft();
    }
}

// ──────────────────────────────────────────────
// SC-5IDH: Initialized tick far above the target is never searched
// What: A position sits at the very top of the tick space, initializing ticks
//       in bitmap word 32767. The Operator then reports an ordinary move from
//       tick 100 to 300, with nothing initialized in between. The search must
//       stop at word 1 -- the word holding the target -- instead of hunting
//       upward for that distant tick.
// Why:  An LP chooses its own tick range, so an unbounded upward scan hands any
//       LP the ability to make a later, legitimate updateTick unaffordable
//       (NFR-5IDG). MAX_TICK_CROSSINGS does not help: nothing is crossed here,
//       and the cost is entirely in scanning empty words.
// ──────────────────────────────────────────────
contract BoundedTickSearchUpwardTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        // Initializes ticks 8388590 and 8388600, both in bitmap word 32767,
        // and nothing anywhere near the origin.
        _mintPosition(HIGHEST_ALIGNED_TICK - 10, HIGHEST_ALIGNED_TICK, 10, keccak256("far-above"));
        _setCurrentTick(int24(100));
    }

    // SC-5IDH: the move completes and currentTick advances
    function test_currentTickAdvancesPastTheDistantTick() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(300));

        assertEq(vault.currentTick(), int24(300), "currentTick should advance to 300");
    }

    // SC-5IDH: nothing is crossed -- the distant tick is above the target
    function test_emitsZeroCrossings() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(100), int24(300), 0);

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));
    }

    // SC-5IDH: the scan cost tracks the reported price move, not the distance
    // to the planted tick. This is the assertion that fails against an
    // unbounded search: it walks ~32766 empty words before finding the tick at
    // 8388590, then discards it for being above the target.
    function test_scanCostIsBoundedByTheTargetNotThePlantedTick() public {
        uint256 gasUsed = _updateTickMeasuringGas(int24(300));

        assertLt(gasUsed, BOUNDED_SCAN_GAS_CEILING, "updateTick scanned far past its target tick");
    }

    // SC-5IDH: the distant tick is left completely alone -- not crossed, its
    // accumulator not flipped, its liquidity not applied.
    function test_distantTickStateUntouched() public {
        (uint128 grossBefore, int128 netBefore, uint256 outsideBefore) = vault.ticks(HIGHEST_ALIGNED_TICK - 10);

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));

        (uint128 grossAfter, int128 netAfter, uint256 outsideAfter) = vault.ticks(HIGHEST_ALIGNED_TICK - 10);
        assertEq(grossAfter, grossBefore, "distant tick liquidityGross should be untouched");
        assertEq(netAfter, netBefore, "distant tick liquidityNet should be untouched");
        assertEq(outsideAfter, outsideBefore, "distant tick feeGrowthOutside should not have been flipped");
    }

    // SC-5IDH: activeLiquidity is unaffected -- the distant position never
    // enters range, so no liquidityNet is applied.
    function test_activeLiquidityUnchanged() public {
        uint128 before_ = vault.activeLiquidity();

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));

        assertEq(vault.activeLiquidity(), before_, "activeLiquidity should be unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-5IDI: Initialized tick far below the target is never searched
// What: The mirror of SC-5IDH. A position sits at the very bottom of the tick
//       space (bitmap word -32768) while the Operator reports an ordinary
//       downward move from 300 to 100.
// Why:  The downward loop already guards its decrement, so it never panicked --
//       but it was just as unbounded, and an LP planting a tick at the floor
//       could make every subsequent downward move unaffordable.
// ──────────────────────────────────────────────
contract BoundedTickSearchDownwardTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        // Initializes ticks -8388600 and -8388590, both in bitmap word -32768.
        _mintPosition(LOWEST_ALIGNED_TICK, LOWEST_ALIGNED_TICK + 10, 10, keccak256("far-below"));
        _setCurrentTick(int24(300));
    }

    // SC-5IDI: the move completes and currentTick descends
    function test_currentTickDescendsPastTheDistantTick() public {
        vm.prank(operatorAddr);
        vault.updateTick(int24(100));

        assertEq(vault.currentTick(), int24(100), "currentTick should descend to 100");
    }

    // SC-5IDI: nothing is crossed -- the distant tick is below the target
    function test_emitsZeroCrossings() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(300), int24(100), 0);

        vm.prank(operatorAddr);
        vault.updateTick(int24(100));
    }

    // SC-5IDI: the downward scan is bounded by the target too
    function test_scanCostIsBoundedByTheTargetNotThePlantedTick() public {
        uint256 gasUsed = _updateTickMeasuringGas(int24(100));

        assertLt(gasUsed, BOUNDED_SCAN_GAS_CEILING, "updateTick scanned far below its target tick");
    }

    // SC-5IDI: the distant tick is left completely alone
    function test_distantTickStateUntouched() public {
        (uint128 grossBefore, int128 netBefore, uint256 outsideBefore) = vault.ticks(LOWEST_ALIGNED_TICK);

        vm.prank(operatorAddr);
        vault.updateTick(int24(100));

        (uint128 grossAfter, int128 netAfter, uint256 outsideAfter) = vault.ticks(LOWEST_ALIGNED_TICK);
        assertEq(grossAfter, grossBefore, "distant tick liquidityGross should be untouched");
        assertEq(netAfter, netBefore, "distant tick liquidityNet should be untouched");
        assertEq(outsideAfter, outsideBefore, "distant tick feeGrowthOutside should not have been flipped");
    }
}

// ──────────────────────────────────────────────
// SC-5IDJ: Initialized tick inside the target's own word is still crossed
// What: Tick 260 and the target tick 300 share bitmap word 1. Moving from 100
//       to 300 must still find and cross 260.
// Why:  This is the guard on the other side of SC-5IDH. A bound that stopped
//       one word short of the target -- an easy off-by-one -- would silently
//       skip legitimate crossings, corrupting activeLiquidity and every
//       position's fee accounting without reverting anything. The bound must
//       include the target's own word.
// ──────────────────────────────────────────────
contract TargetWordInclusiveTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        // Ticks 260 and 400 both live in bitmap word 1 (ticks 256..511), the
        // same word as the target 300. Liquidity is
        // usdcAmount(140) * LIQUIDITY_PRECISION(1e18) / rangeWidth(140) = 1e18.
        // The upper tick sits above the target on purpose: the search will
        // surface it, and updateTick must discard it for being out of range
        // rather than cross it.
        _mintPosition(int24(260), int24(400), 140, keccak256("target-word"));
        _setCurrentTick(int24(100));
    }

    // SC-5IDJ: the tick sharing the target's word is crossed
    function test_crossesTheTickInsideTheTargetWord() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(100), int24(300), 1);

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));
    }

    // SC-5IDJ: crossing tick 260 L-to-R brings the position into range
    function test_activeLiquidityPicksUpTheCrossedPosition() public {
        assertEq(vault.activeLiquidity(), 0, "precondition: no liquidity in range at tick 100");

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));

        assertEq(vault.activeLiquidity(), 1e18, "activeLiquidity should pick up the position entered at tick 260");
    }

    // SC-5IDJ: the upper tick, above the target, is not crossed
    function test_doesNotCrossTheTickAboveTheTarget() public {
        (,, uint256 outsideBefore) = vault.ticks(int24(400));

        vm.prank(operatorAddr);
        vault.updateTick(int24(300));

        (,, uint256 outsideAfter) = vault.ticks(int24(400));
        assertEq(outsideAfter, outsideBefore, "tick 400 is above the target and must not be crossed");
    }
}

// ──────────────────────────────────────────────
// SC-5IDL: Target at the extreme bitmap word with no initialized ticks
// What: currentTick sits near the top of int24 with nothing initialized above
//       it. The upward search runs out of bitmap words and must report "not
//       found" so updateTick completes.
// Why:  This is the arithmetic-panic case. The upward loop's `wordPos++` was
//       unguarded, so reaching word 32767 == type(int16).max overflowed and
//       reverted with Panic(0x11) instead of ever returning "not found" --
//       leaving the vault's tick permanently unable to move into that region.
//       The downward direction has always guarded its decrement; it is pinned
//       here so the two directions are held to one symmetric contract.
// ──────────────────────────────────────────────
contract ExtremeWordSearchTest is BoundedTickSearchTestBase {
    function setUp() public override {
        super.setUp();
        // A position near the origin, so both extreme words are empty and the
        // vault still holds a position.
        _mintPosition(int24(0), int24(10), 10, keccak256("origin"));
    }

    // SC-5IDL: an upward move whose target is in the highest bitmap word
    // completes rather than panicking
    function test_upwardMoveIntoHighestWordSucceeds() public {
        _setCurrentTick(int24(8388000));

        vm.prank(operatorAddr);
        vault.updateTick(HIGHEST_ALIGNED_TICK);

        assertEq(vault.currentTick(), HIGHEST_ALIGNED_TICK, "currentTick should reach the highest aligned tick");
    }

    // SC-5IDL: and it crosses nothing, because nothing is initialized up there
    function test_upwardMoveIntoHighestWordCrossesNothing() public {
        _setCurrentTick(int24(8388000));

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(8388000), HIGHEST_ALIGNED_TICK, 0);

        vm.prank(operatorAddr);
        vault.updateTick(HIGHEST_ALIGNED_TICK);
    }

    // SC-5IDL: a target landing exactly on the last addressable tick of the
    // highest word is the tightest case for the boundary test -- one tick
    // further would leave int24 entirely.
    function test_upwardMoveToLastTickOfHighestWordSucceeds() public {
        _setCurrentTick(type(int24).max - 1);

        vm.prank(operatorAddr);
        vault.updateTick(type(int24).max);

        assertEq(vault.currentTick(), type(int24).max, "currentTick should reach int24 max");
    }

    // SC-5IDL: the symmetric downward case at the bottom of int24
    function test_downwardMoveIntoLowestWordSucceeds() public {
        _setCurrentTick(int24(-8388000));

        vm.prank(operatorAddr);
        vault.updateTick(LOWEST_ALIGNED_TICK);

        assertEq(vault.currentTick(), LOWEST_ALIGNED_TICK, "currentTick should reach the lowest aligned tick");
    }

    // SC-5IDL: and the tightest downward case, landing on int24 min itself
    function test_downwardMoveToInt24MinSucceeds() public {
        _setCurrentTick(type(int24).min + 1);

        vm.prank(operatorAddr);
        vault.updateTick(type(int24).min);

        assertEq(vault.currentTick(), type(int24).min, "currentTick should reach int24 min");
    }
}

// ──────────────────────────────────────────────
// FR-5IDE, FR-5IDF: fuzzed bounded search across the whole tick space
// What: For an arbitrary starting tick anywhere in int24 and an arbitrary
//       move of bounded size in either direction, updateTick completes and
//       lands on the target, at a cost that tracks the move.
// Why:  The scenario tests above pin specific words. These pin the property
//       itself over the full int24 range, including both extremes, so a future
//       change to how the target's word is derived cannot reintroduce either
//       the panic or the unbounded scan at some coordinate nobody enumerated.
//       Per this repo's tick-math rule, arithmetic-heavy code is fuzzed.
// ──────────────────────────────────────────────
contract BoundedTickSearchFuzzTest is BoundedTickSearchTestBase {
    /// @dev Widest move these fuzz cases make. NFR-5IDG is explicit that a
    ///      genuinely enormous jump across real empty space may still be
    ///      costly -- the guarantee is that cost follows the Operator's move,
    ///      not a third party's tick placement. 2000 ticks spans up to nine
    ///      bitmap words, enough to exercise multi-word scans and both
    ///      boundaries without asserting something the spec does not promise.
    int24 constant MAX_FUZZ_MOVE = 2000;

    function setUp() public override {
        super.setUp();
        // One position near the origin, far from every tick these cases visit,
        // so the search finds nothing and must rely on the bound to stop.
        _mintPosition(int24(0), int24(10), 10, keccak256("origin"));
    }

    // FR-5IDE, FR-5IDF: an upward move never reverts and always lands on target
    function testFuzz_upwardMoveAlwaysCompletes(int256 startSeed, uint256 moveSeed) public {
        int24 start = int24(bound(startSeed, type(int24).min, type(int24).max - int256(MAX_FUZZ_MOVE)));
        int24 move = int24(int256(bound(moveSeed, 1, uint256(int256(MAX_FUZZ_MOVE)))));
        int24 target = start + move;
        // Skip the region around the origin position, whose initialized ticks
        // would be legitimately crossed -- crossing is SC-TVS2's subject, not
        // this one. These cases are about the search terminating.
        vm.assume(start > int24(10) || target < int24(0));

        _setCurrentTick(start);

        uint256 gasUsed = _updateTickMeasuringGas(target);

        assertEq(vault.currentTick(), target, "currentTick should land exactly on the target");
        assertLt(gasUsed, BOUNDED_SCAN_GAS_CEILING, "upward scan cost should track the move, not the tick space");
    }

    // FR-5IDE, FR-5IDF: a downward move never reverts and always lands on target
    function testFuzz_downwardMoveAlwaysCompletes(int256 startSeed, uint256 moveSeed) public {
        int24 start = int24(bound(startSeed, type(int24).min + int256(MAX_FUZZ_MOVE), type(int24).max));
        int24 move = int24(int256(bound(moveSeed, 1, uint256(int256(MAX_FUZZ_MOVE)))));
        int24 target = start - move;
        vm.assume(target > int24(10) || start < int24(0));

        _setCurrentTick(start);

        uint256 gasUsed = _updateTickMeasuringGas(target);

        assertEq(vault.currentTick(), target, "currentTick should land exactly on the target");
        assertLt(gasUsed, BOUNDED_SCAN_GAS_CEILING, "downward scan cost should track the move, not the tick space");
    }

    // FR-5IDF: moves that end inside the highest bitmap word -- the word whose
    // boundary the unguarded increment used to run past -- always complete.
    function testFuzz_movesInsideHighestWordAlwaysComplete(uint256 startSeed, uint256 moveSeed) public {
        int24 maxTick = type(int24).max;
        int24 start = int24(int256(bound(startSeed, uint256(int256(maxTick)) - 500, uint256(int256(maxTick)) - 1)));
        int24 move = int24(int256(bound(moveSeed, 1, uint256(int256(maxTick - start)))));

        _setCurrentTick(start);

        vm.prank(operatorAddr);
        vault.updateTick(start + move);

        assertEq(vault.currentTick(), start + move, "currentTick should land on the target inside the highest word");
    }

    // FR-5IDF: the symmetric case at the bottom of int24.
    function testFuzz_movesInsideLowestWordAlwaysComplete(uint256 startSeed, uint256 moveSeed) public {
        int24 minTick = type(int24).min;
        int24 start = int24(-int256(bound(startSeed, uint256(-int256(minTick)) - 500, uint256(-int256(minTick)) - 1)));
        int24 move = int24(int256(bound(moveSeed, 1, uint256(int256(start - minTick)))));

        _setCurrentTick(start);

        vm.prank(operatorAddr);
        vault.updateTick(start - move);

        assertEq(vault.currentTick(), start - move, "currentTick should land on the target inside the lowest word");
    }
}
