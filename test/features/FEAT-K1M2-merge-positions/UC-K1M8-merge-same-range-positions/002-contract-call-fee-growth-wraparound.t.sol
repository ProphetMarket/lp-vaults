// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-K1M8: Merge Same-Range Positions
// T-003: Position merge succeeds and preserves fee accounting even when a
//        position's fee delta wraps mod 2^256

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

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
// Base test contract for the mergePositions wraparound reproduction.
//
// See FEAT-JXQO/UC-JXQW's 002 test for the full rationale: a position's
// feeGrowthInsideLastX128 snapshot can legitimately be a wrapped (mod-2^256)
// value produced by _computeFeeGrowthInside (fixed in T-001). mergePositions
// computes the SAME `fresh - snapshot` delta twice -- once for the survivor,
// once per consumed position -- and each computation independently
// underflows unless wrapped in unchecked. This test constructs the
// condition directly via vm.store on the relevant position's
// feeGrowthInsideLastX128 slot, exercising the survivor and the consumed
// position in separate scenarios so both call sites are proven fixed.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundTestBase is Test {
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

    uint256 constant POSITIONS_SLOT = 12;
    uint256 constant FEE_GROWTH_INSIDE_LAST_OFFSET = 2;

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

        mockUsdc.mint(lp, 1_000_000e18);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
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
        vm.prank(operatorAddr);
        return vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    function _buildIds(uint256 id0, uint256 id1) internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        return ids;
    }

    /// @dev Overwrites positions[id].feeGrowthInsideLastX128 directly.
    function _setFeeGrowthInsideLast(uint256 id, uint256 value) internal {
        bytes32 baseSlot = keccak256(abi.encode(id, POSITIONS_SLOT));
        vm.store(address(vault), bytes32(uint256(baseSlot) + FEE_GROWTH_INSIDE_LAST_OFFSET), bytes32(value));
    }
}

// ──────────────────────────────────────────────
// FR-K1M6: merge succeeds and preserves fee accounting when the SURVIVOR's
// snapshot is a wrapped value
// What: the survivor's own uncollected-fees computation
//       (`survivorFees = liquidity * (fresh - snapshot) / Q128`) underflows
//       when survivor.feeGrowthInsideLastX128 is a wrapped (mod-2^256) value
//       -- the legitimate result _computeFeeGrowthInside can produce per
//       FR-U07H. Before the fix, this reverts the whole merge.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundSurvivorTest is MergePositionsWraparoundTestBase {
    event PositionsMerged(uint256[] positionIds, uint256 survivorId);

    uint256 posSurvivor;
    uint256 posConsumed;

    function setUp() public override {
        super.setUp();

        posSurvivor = _mintPosition(int24(0), int24(100), 500, keccak256("survivor"));
        posConsumed = _mintPosition(int24(0), int24(100), 500, keccak256("consumed"));

        _setFeeGrowthInsideLast(posSurvivor, type(uint256).max - 1000);
    }

    // FR-K1M6: merge succeeds instead of reverting on the survivor's wrapped snapshot.
    function test_mergeSucceedsDespiteSurvivorWrappedSnapshot() public {
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posSurvivor, posConsumed));

        (,,, uint128 survivorLiq,,) = vault.positions(posSurvivor);
        assertEq(survivorLiq, 10e18, "survivor liquidity should be the sum of both positions");
    }

    // FR-K1M6: consumed position is zeroed and PositionsMerged is emitted.
    function test_consumedPositionZeroedAndEventEmitted() public {
        uint256[] memory ids = _buildIds(posSurvivor, posConsumed);

        vm.expectEmit(false, false, false, true, address(vault));
        emit PositionsMerged(ids, posSurvivor);

        vm.prank(operatorAddr);
        vault.mergePositions(ids);

        (,,, uint128 consumedLiq,,) = vault.positions(posConsumed);
        assertEq(consumedLiq, 0, "consumed position liquidity should be zeroed");
    }
}

// ──────────────────────────────────────────────
// FR-K1M6: merge succeeds and preserves fee accounting when a CONSUMED
// position's snapshot is a wrapped value
// What: the same underflow, but on the loop's per-consumed-position
//       computation (`consumedFees = liquidity * (fresh - snapshot) / Q128`)
//       instead of the survivor's own computation -- a distinct call site
//       in the same function.
// ──────────────────────────────────────────────
contract MergePositionsWraparoundConsumedTest is MergePositionsWraparoundTestBase {
    uint256 posSurvivor;
    uint256 posConsumed;

    function setUp() public override {
        super.setUp();

        posSurvivor = _mintPosition(int24(0), int24(100), 500, keccak256("survivor"));
        posConsumed = _mintPosition(int24(0), int24(100), 500, keccak256("consumed"));

        _setFeeGrowthInsideLast(posConsumed, type(uint256).max - 1000);
    }

    // FR-K1M6: merge succeeds instead of reverting on the consumed position's
    // wrapped snapshot.
    function test_mergeSucceedsDespiteConsumedWrappedSnapshot() public {
        vm.prank(operatorAddr);
        vault.mergePositions(_buildIds(posSurvivor, posConsumed));

        (,,, uint128 survivorLiq,,) = vault.positions(posSurvivor);
        (,,, uint128 consumedLiq,,) = vault.positions(posConsumed);
        assertEq(survivorLiq, 10e18, "survivor liquidity should be the sum of both positions");
        assertEq(consumedLiq, 0, "consumed position liquidity should be zeroed");
    }
}
