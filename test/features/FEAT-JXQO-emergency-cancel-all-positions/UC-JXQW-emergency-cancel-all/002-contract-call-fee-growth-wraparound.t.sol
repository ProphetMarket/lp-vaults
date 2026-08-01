// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-JXQW: Emergency Cancel All
// T-002: Emergency cancel succeeds and pays out correctly even when a
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
// Base test contract for the emergencyCancelAll wraparound reproduction.
//
// _computeFeeGrowthInside (fixed in T-001) can legitimately return a value
// that is small relative to a position's OWN feeGrowthInsideLastX128
// snapshot, whenever that snapshot was itself the wrapped (mod-2^256) result
// of an earlier _computeFeeGrowthInside call -- exactly what the audit
// describes happening at mint time for a position sharing an
// already-initialized tick. emergencyCancelAll's per-position payout loop
// then computes `fees = liquidity * (fresh - snapshot) / Q128`, which
// underflows if the fresh value is smaller than the stored snapshot.
//
// Rather than re-deriving the exact multi-step mint/cross/notify sequence
// that produces a wrapped snapshot naturally (already exercised end-to-end
// in FEAT-U079/UC-U07A's 002 test), this test constructs the condition
// directly via vm.store on the position's own feeGrowthInsideLastX128 slot --
// pinning FR-JXQP's contract precisely: "the payout loop must not revert
// regardless of how the stored snapshot arrived at that value."
// ──────────────────────────────────────────────
contract EmergencyCancelWraparoundTestBase is Test {
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

    // `positions` mapping is storage slot 12 (see src/LPVault.sol's field
    // order); feeGrowthInsideLastX128 is the struct's 3rd field (slot + 2).
    uint256 constant POSITIONS_SLOT = 12;
    uint256 constant FEE_GROWTH_INSIDE_LAST_OFFSET = 2;

    uint256 posOrdinary;
    uint256 posWrapped;

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

    /// @dev Overwrites positions[id].feeGrowthInsideLastX128 directly, bypassing
    ///      the normal mint/collect/merge write paths.
    function _setFeeGrowthInsideLast(uint256 id, uint256 value) internal {
        bytes32 baseSlot = keccak256(abi.encode(id, POSITIONS_SLOT));
        vm.store(address(vault), bytes32(uint256(baseSlot) + FEE_GROWTH_INSIDE_LAST_OFFSET), bytes32(value));
    }

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + vault.EMERGENCY_CANCEL_TIMELOCK() + 1);
    }
}

// ──────────────────────────────────────────────
// FR-JXQP: emergency cancel succeeds and pays out correctly despite a
// wrapped fee-delta snapshot on one of the positions being force-closed
// What: a position's feeGrowthInsideLastX128 snapshot can legitimately be a
//       wrapped (mod-2^256), near-type(uint256).max value -- the correct
//       representation _computeFeeGrowthInside produces per FR-U07H when a
//       stale tick is involved (see FEAT-U079/UC-U07A's 002 test). When
//       emergencyCancelAll later recomputes a small, ordinary feeGrowthInside
//       for the SAME range, its own `fresh - snapshot` line underflows unless
//       wrapped in unchecked. Before the fix, this reverts the ENTIRE
//       transaction -- bricking the one recovery path this feature exists to
//       guarantee, stranding every other position holder's principal too.
// Why:  This is the highest-severity consequence named in audit
//       NM-0986-Prophet: an attacker can "mine" a tick into this state to
//       brick emergencyCancelAll for every LP in the vault, not just the
//       position sharing the tick.
// ──────────────────────────────────────────────
contract EmergencyCancelWraparoundTest is EmergencyCancelWraparoundTestBase {
    event EmergencyCancelExecuted(address indexed caller);

    function setUp() public override {
        super.setUp();

        // An ordinary, unrelated position so the vault has activeLiquidity
        // and something else to pay out alongside the wrapped one.
        posOrdinary = _mintPosition(int24(0), int24(1000), 5000, keccak256("ordinary"));
        _notifyFees(1000);

        // A position whose snapshot models the exact wrapped value
        // _computeFeeGrowthInside can legitimately produce: near
        // type(uint256).max, representing "a small negative number" mod 2^256.
        posWrapped = _mintPosition(int24(100), int24(200), 500, keccak256("wrapped"));
        _setFeeGrowthInsideLast(posWrapped, type(uint256).max - 1000);

        _warpPastTimelock();
    }

    // FR-JXQP: emergencyCancelAll succeeds instead of reverting on the
    // position whose snapshot is a wrapped value.
    function test_emergencyCancelSucceedsDespiteWrappedSnapshot() public {
        vm.prank(lp);
        vault.emergencyCancelAll();

        assertEq(vault.phase(), 3, "vault should transition to Cancelled");
    }

    // FR-JXQP: every position -- the ordinary one and the wrapped one -- is
    // zeroed and every owner is paid at least their principal. No position
    // gets stranded because one of them required wraparound arithmetic.
    function test_allPositionsArePaidAndZeroedDespiteWrappedSnapshot() public {
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);

        vm.prank(lp);
        vault.emergencyCancelAll();

        (,,, uint128 liqOrdinary,,) = vault.positions(posOrdinary);
        (,,, uint128 liqWrapped,,) = vault.positions(posWrapped);
        assertEq(liqOrdinary, 0, "ordinary position liquidity should be zeroed");
        assertEq(liqWrapped, 0, "wrapped-snapshot position liquidity should be zeroed");

        // LP deposited 5000 (ordinary) + 500 (wrapped) = 5500 USDC principal.
        assertGe(mockUsdc.balanceOf(lp) - lpBalBefore, 5500, "LP should receive at least the total principal back");
    }

    // FR-JXQP: EmergencyCancelExecuted is still emitted.
    function test_emitsEmergencyCancelExecutedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit EmergencyCancelExecuted(lp);

        vm.prank(lp);
        vault.emergencyCancelAll();
    }
}
