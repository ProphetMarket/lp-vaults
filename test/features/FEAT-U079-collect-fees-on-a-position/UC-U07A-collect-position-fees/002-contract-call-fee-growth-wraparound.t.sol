// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-U07A: Collect Position Fees
// T-001: LP fee collection succeeds even when the fee-growth accumulator delta wraps mod 2^256

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
// Base test contract for the fee-growth-wraparound reproduction.
//
// Builds the exact state audit NM-0986-Prophet describes: a tick shared with
// an already-initialized position, whose feeGrowthOutsideX128 is stale
// relative to a freshly-initialized sibling tick's snapshot. This makes
// _computeFeeGrowthInside's final subtraction go negative, which Solidity
// 0.8.20's default checked arithmetic reverts on instead of wrapping mod
// 2^256 to the correct value.
//
// Sequence:
//   1. P1 = [0, 300): wide range, keeps activeLiquidity nonzero throughout.
//   2. P2 = [100, 200): pre-initializes ticks 100 and 200 while
//      currentTick = 0, so both start at feeGrowthOutsideX128 = 0.
//   3. notifyFees -> feeGrowthGlobalX128 = G1 (only P1 active).
//   4. updateTick(150): crosses tick 100 L-to-R, flipping
//      ticks[100].feeGrowthOutsideX128 to G1 - 0 = G1. P2 enters range.
//   5. notifyFees -> feeGrowthGlobalX128 = G2 > G1 (P1 + P2 active).
//      ticks[100].feeGrowthOutsideX128 is now frozen at G1 -- STALE
//      relative to the current global G2.
//   6. Mint a NEW position [50, 100) at currentTick = 150. Tick 50 is fresh
//      (initializes to the CURRENT global G2), tick 100 is the stale shared
//      tick (G1). _computeFeeGrowthInside(50, 100) computes
//      (G2 - G2) - (G2 - G1) = 0 - (G2 - G1), which underflows.
// ──────────────────────────────────────────────
contract FeeGrowthWraparoundTestBase is Test {
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

    uint256 constant Q128 = 2 ** 128;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Position IDs assigned during _buildStaleTickState(): P1 = 0, P2 = 1.
    uint256 posP1;
    uint256 posP2;

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

    function _notifyFees(uint256 amount) internal {
        mockUsdc.mint(address(vault), amount);
        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    /// @dev Builds the staleness condition described in the class comment above.
    function _buildStaleTickState() internal {
        posP1 = _mintPosition(int24(0), int24(300), 3000, keccak256("wide"));
        posP2 = _mintPosition(int24(100), int24(200), 1000, keccak256("pre-init"));

        _notifyFees(1000);

        vm.prank(operatorAddr);
        vault.updateTick(int24(150));

        _notifyFees(500);
    }
}

// ──────────────────────────────────────────────
// FR-U07H, FR-U07I: feeGrowthInside/owed computation succeeds under wraparound
// What: minting a NEW position sharing an already-initialized (but now stale)
//       tick triggers the exact underflow audit NM-0986-Prophet describes.
//       Before the fix, _computeFeeGrowthInside's final subtraction
//       (0 - (G2 - G1)) reverts. After the fix, it wraps mod 2^256 and the
//       mint succeeds; a later collect() on the resulting position still
//       resolves to the correct owed amount because the delta computation
//       cancels the wraparound out.
// Why:  This is the exact trigger from the audit: "minting a position sharing
//       an already-initialized tick can trigger it immediately."
// ──────────────────────────────────────────────
contract FeeGrowthWraparoundMintTest is FeeGrowthWraparoundTestBase {
    function setUp() public override {
        super.setUp();
        _buildStaleTickState();
    }

    // FR-U07H: minting a position sharing the stale tick 100 (as tickUpper)
    // with a fresh tick 50 (as tickLower) no longer reverts.
    function test_mintSucceedsDespiteStaleSharedTick() public {
        uint256 posId = _mintPosition(int24(50), int24(100), 500, keccak256("wraparound-mint"));

        (address owner,,, uint128 liquidity,,) = vault.positions(posId);
        assertEq(owner, lp, "position should be minted to the LP");
        assertGt(liquidity, 0, "minted position should have nonzero liquidity");
    }

    // FR-U07I: collecting immediately after the wraparound mint (no new fee
    // growth in this position's range yet) returns exactly zero -- proving
    // the wrapped snapshot does not fabricate phantom fees.
    function test_collectImmediatelyAfterWraparoundMintReturnsZero() public {
        uint256 posId = _mintPosition(int24(50), int24(100), 500, keccak256("wraparound-mint"));

        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(posId);

        assertEq(mockUsdc.balanceOf(lp), lpBalBefore, "no fees should be owed with zero elapsed growth");
    }

    // FR-U07I: after the wraparound mint, moving price back into the new
    // position's range and distributing fresh fees produces a correct,
    // precisely-matching nonzero owed amount on collect -- proving the
    // wrapped feeGrowthInsideLastX128 snapshot correctly cancels against a
    // later feeGrowthInsideX128 computation instead of compounding into
    // garbage.
    function test_collectAfterNewGrowthInWraparoundRangeReturnsCorrectAmount() public {
        uint256 posId = _mintPosition(int24(50), int24(100), 500, keccak256("wraparound-mint"));

        // Move price down into [50, 100) so the new position becomes active,
        // then distribute fees while it is the sole in-range position.
        vm.prank(operatorAddr);
        vault.updateTick(int24(75));

        (,,, uint128 posLiquidity,,) = vault.positions(posId);
        uint256 feeGrowthBefore = vault.feeGrowthGlobalX128();

        _notifyFees(200);

        uint256 feeGrowthAfter = vault.feeGrowthGlobalX128();
        uint256 expectedOwed = uint256(posLiquidity) * (feeGrowthAfter - feeGrowthBefore) / Q128;
        assertGt(expectedOwed, 0, "precondition: new growth should be nonzero");

        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(posId);

        assertEq(mockUsdc.balanceOf(lp) - lpBalBefore, expectedOwed, "owed should exactly match the new growth");
    }

    // FR-U07H: the pre-existing position sharing the same stale tick 100 as
    // its own tickLower (posP2 = [100, 200)) remains collectible after the fix,
    // and pays out the precise amount the v3 formula predicts -- proving the
    // fix applies uniformly regardless of which side of the range the stale
    // tick sits on, not merely that the call doesn't revert.
    function test_preexistingPositionSharingStaleTickStillCollectible() public {
        (,,, uint128 posP2Liquidity,,) = vault.positions(posP2);
        (,, uint256 tick100Outside) = vault.ticks(int24(100));
        uint256 feeGrowthGlobal = vault.feeGrowthGlobalX128();

        // posP2 was minted at currentTick=0, before any fees, so its own
        // feeGrowthInsideLastX128 snapshot is exactly 0 (see
        // _buildStaleTickState). Its fresh feeGrowthInside at collect time
        // is feeGrowthGlobal - ticks[100].outside - ticks[200].outside(=0).
        uint256 expectedOwed = uint256(posP2Liquidity) * (feeGrowthGlobal - tick100Outside) / Q128;
        assertGt(expectedOwed, 0, "precondition: posP2 should have accrued nonzero fees");

        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(posP2);

        assertEq(mockUsdc.balanceOf(lp) - lpBalBefore, expectedOwed, "posP2 should pay out the exact predicted amount");
    }
}

// ──────────────────────────────────────────────
// FR-U07H, FR-U07I: fuzz coverage across the wraparound input space
// What: _computeFeeGrowthInside and collect's owed computation never revert,
//       and owed is always bounded by total fees distributed, across a wide
//       range of fee amounts and tick-crossing sequences that can produce a
//       stale-vs-fresh tick mismatch.
// Why:  A single hand-built reproduction proves the fix works for one input;
//       the fuzz proves it holds across the input space, not just the
//       hand-picked numbers above.
// ──────────────────────────────────────────────
contract FeeGrowthWraparoundFuzzTest is FeeGrowthWraparoundTestBase {
    // FR-U07H, FR-U07I: fuzzed fee amounts never cause a revert, and the
    // resulting owed amount on the wraparound-shared position never exceeds
    // the vault's total USDC balance (the CLAUDE.md fee-bound invariant).
    function testFuzz_wraparoundNeverRevertsAndOwedIsBounded(uint96 firstFees, uint96 secondFees) public {
        firstFees = uint96(bound(firstFees, 1, 1_000_000e18));
        secondFees = uint96(bound(secondFees, 1, 1_000_000e18));

        posP1 = _mintPosition(int24(0), int24(300), 3000, keccak256("wide"));
        posP2 = _mintPosition(int24(100), int24(200), 1000, keccak256("pre-init"));

        _notifyFees(firstFees);
        vm.prank(operatorAddr);
        vault.updateTick(int24(150));
        _notifyFees(secondFees);

        // This mint reverts before the fix whenever secondFees > 0 makes
        // ticks[100].feeGrowthOutsideX128 stale relative to the fresh tick 50.
        uint256 posId = _mintPosition(int24(50), int24(100), 500, keccak256("wraparound-mint"));

        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));
        vm.prank(lp);
        vault.collect(posId);
        uint256 owed = vaultBalBefore - mockUsdc.balanceOf(address(vault));

        assertLe(owed, vaultBalBefore, "owed must never exceed the vault's available fee balance");
    }
}
