// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TVS1: Update Current Tick
// T-004: Tick crossing succeeds even when a tick's feeGrowthOutside flip
//        wraps mod 2^256

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
    // (this vault has none, which is an unrelated, separate pre-existing
    // issue in _nextInitializedTick's empty-scan path, out of scope here).
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
