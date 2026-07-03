// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-K1MK: Pause and Unpause Vault
// SLICE-001: pause-and-unpause-vault

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
// Base test contract for pauseTrading / unpauseTrading scenarios.
// Deploys factory + vault clone, mints one in-range position (so
// notifyFees has nonzero activeLiquidity), and provides helpers.
// ──────────────────────────────────────────────
contract PauseTradingTestBase is Test {
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

    uint256 constant LIQUIDITY_PRECISION = 1e18;
    uint256 constant Q128 = 2 ** 128;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event TradingPaused(address indexed caller);
    event TradingUnpaused(address indexed caller);

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

        // Fund LP and approve vault
        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        // Mint one position: range [0, 100), 1000 USDC → liquidity = 10e18
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 1000, keccak256("setup-mint"));
        vm.prank(operatorAddr);
        positionId = vault.mintPositionFor(lp, int24(0), int24(100), 1000, keccak256("setup-mint"), sig);
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

    function _pause() internal {
        vm.prank(admin);
        vault.pauseTrading();
    }
}

// ──────────────────────────────────────────────
// SC-K1ML: Admin pauses vault and gated functions revert
// What: When Admin calls pauseTrading(), paused becomes true and
//       TradingPaused is emitted. Subsequently, mintPositionFor,
//       notifyFees, updateTick, and mergePositions all revert with
//       TradingIsPaused.
// Why:  The circuit breaker must immediately halt all trading entry
//       points to contain damage from a bug or market anomaly.
// ──────────────────────────────────────────────
contract PauseTradingPauseAndGateTest is PauseTradingTestBase {
    // SC-K1ML: paused flag set to true
    function test_pausedFlagSetToTrue() public {
        assertEq(vault.paused(), false, "precondition: not paused");

        _pause();

        assertEq(vault.paused(), true, "paused should be true");
    }

    // SC-K1ML: TradingPaused event emitted with correct caller
    function test_emitsTradingPausedEvent() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit TradingPaused(admin);

        vm.prank(admin);
        vault.pauseTrading();
    }

    // SC-K1ML: mintPositionFor reverts while paused
    function test_mintPositionForRevertsWhilePaused() public {
        _pause();

        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 100, keccak256("paused-mint"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mintPositionFor(lp, int24(0), int24(100), 100, keccak256("paused-mint"), sig);
    }

    // SC-K1ML: notifyFees reverts while paused
    function test_notifyFeesRevertsWhilePaused() public {
        _pause();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.notifyFees(100);
    }

    // SC-K1ML: updateTick reverts while paused
    function test_updateTickRevertsWhilePaused() public {
        _pause();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.updateTick(int24(10));
    }

    // SC-K1ML: mergePositions reverts while paused
    function test_mergePositionsRevertsWhilePaused() public {
        // Mint a second position to make merge possible
        bytes memory sig2 = _signMintIntent(LP_PK, lp, int24(0), int24(100), 500, keccak256("mint-2"));
        vm.prank(operatorAddr);
        uint256 pos2 = vault.mintPositionFor(lp, int24(0), int24(100), 500, keccak256("mint-2"), sig2);

        _pause();

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = pos2;

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.mergePositions(ids);
    }
}

// ──────────────────────────────────────────────
// SC-K1MM: Unpause returns vault to normal
// What: After Admin calls unpauseTrading(), paused becomes false,
//       TradingUnpaused is emitted, and gated functions work again.
// Why:  The circuit breaker must be reversible so trading can resume
//       once the issue is resolved.
// ──────────────────────────────────────────────
contract PauseTradingUnpauseTest is PauseTradingTestBase {
    // SC-K1MM: paused flag set to false after unpause
    function test_pausedFlagSetToFalse() public {
        _pause();
        assertEq(vault.paused(), true, "precondition: paused");

        vm.prank(admin);
        vault.unpauseTrading();

        assertEq(vault.paused(), false, "paused should be false after unpause");
    }

    // SC-K1MM: TradingUnpaused event emitted with correct caller
    function test_emitsTradingUnpausedEvent() public {
        _pause();

        vm.expectEmit(true, false, false, false, address(vault));
        emit TradingUnpaused(admin);

        vm.prank(admin);
        vault.unpauseTrading();
    }

    // SC-K1MM: notifyFees succeeds after unpause
    function test_notifyFeesSucceedsAfterUnpause() public {
        _pause();

        // Verify it reverts while paused
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TradingIsPaused.selector);
        vault.notifyFees(100);

        // Unpause and verify it works
        vm.prank(admin);
        vault.unpauseTrading();

        uint256 feeGrowthBefore = vault.feeGrowthGlobalX128();
        vm.prank(operatorAddr);
        vault.notifyFees(100);
        assertGt(vault.feeGrowthGlobalX128(), feeGrowthBefore, "feeGrowth should increase after unpause");
    }
}

// ──────────────────────────────────────────────
// SC-K1MN: Revert if non-Admin calls
// What: pauseTrading and unpauseTrading revert with NotAdmin for
//       Operator, LP, and arbitrary addresses.
// Why:  Only Admins should be able to toggle the circuit breaker.
//       Compromise of the Operator must not unlock pause control.
// ──────────────────────────────────────────────
contract PauseTradingAccessControlTest is PauseTradingTestBase {
    // SC-K1MN: Operator calling pauseTrading reverts
    function test_operatorCannotPause() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.pauseTrading();
    }

    // SC-K1MN: LP calling pauseTrading reverts
    function test_lpCannotPause() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.pauseTrading();
    }

    // SC-K1MN: arbitrary address calling unpauseTrading reverts
    function test_arbitraryCannotUnpause() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.unpauseTrading();
    }
}

// ──────────────────────────────────────────────
// SC-K1MO: Collect works while paused
// What: While the vault is paused, LP can still call collect() to
//       withdraw accrued fees from their position.
// Why:  LP exit paths must never be blocked — capital should never
//       be trapped by the circuit breaker.
// Example: Distribute 500 USDC fees, pause, collect → LP receives fees.
// ──────────────────────────────────────────────
contract PauseTradingCollectTest is PauseTradingTestBase {
    // SC-K1MO: collect succeeds while paused
    function test_collectSucceedsWhilePaused() public {
        // Distribute fees so the position has something to collect
        vm.prank(operatorAddr);
        vault.notifyFees(500);

        // Fund vault with USDC for fee payout (notifyFees doesn't move USDC)
        mockUsdc.mint(address(vault), 500);

        _pause();

        // Collect should succeed despite pause
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.collect(positionId);
        uint256 lpBalAfter = mockUsdc.balanceOf(lp);

        assertGt(lpBalAfter, lpBalBefore, "LP should receive fees while paused");
    }
}

// ──────────────────────────────────────────────
// SC-K1MP: ReclaimDeposit works while paused
// What: While the vault is paused, LP can still call reclaimDeposit()
//       to recover USDC from an unfulfilled mint intent after timelock.
// Why:  LP exit paths must never be blocked by pause.
// ──────────────────────────────────────────────
contract PauseTradingReclaimTest is PauseTradingTestBase {
    uint256 constant OPERATOR_PK = 0xBEEF;

    function setUp() public override {
        super.setUp();

        // Register the operator key so we can sign operator signatures
        address opSigner = vm.addr(OPERATOR_PK);
        vm.prank(admin);
        factory.addOperator(opSigner);
    }

    // SC-K1MP: reclaimDeposit succeeds while paused
    function test_reclaimDepositSucceedsWhilePaused() public {
        // Set up an unfulfilled mint intent with a fresh intentId
        bytes32 intentId = keccak256("reclaim-intent");
        uint256 reclaimAmount = 200;

        // LP signs the mint intent
        bytes memory lpSig = _signMintIntent(LP_PK, lp, int24(0), int24(100), reclaimAmount, intentId);

        // Operator signs the same mint intent
        bytes memory opSig = _signMintIntent(OPERATOR_PK, lp, int24(0), int24(100), reclaimAmount, intentId);

        // Phase 1: submit the reclaim (records timestamp)
        vm.prank(lp);
        vault.reclaimDeposit(lp, int24(0), int24(100), reclaimAmount, intentId, lpSig, opSig);

        // Advance past RECLAIM_TIMELOCK (24 hours)
        vm.warp(block.timestamp + 24 hours + 1);

        // Fund vault with USDC for the refund
        mockUsdc.mint(address(vault), reclaimAmount);

        // Pause the vault
        _pause();

        // Phase 2: execute reclaim while paused — should succeed
        uint256 lpBalBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        vault.reclaimDeposit(lp, int24(0), int24(100), reclaimAmount, intentId, lpSig, opSig);
        uint256 lpBalAfter = mockUsdc.balanceOf(lp);

        assertEq(lpBalAfter - lpBalBefore, reclaimAmount, "LP should receive reclaim amount while paused");
    }
}

// ──────────────────────────────────────────────
// NFR-K1MJ: Pause independent of phase
// What: Pausing does not change the vault's phase, and unpausing
//       restores normal phase-gated behavior.
// Why:  Phase and pause are orthogonal controls — conflating them
//       would create edge cases where pause side-effects alter
//       the vault lifecycle.
// ──────────────────────────────────────────────
contract PauseTradingPhaseIndependenceTest is PauseTradingTestBase {
    // NFR-K1MJ: phase unchanged after pause/unpause cycle
    function test_phaseUnchangedAfterPauseUnpause() public {
        uint8 phaseBefore = vault.phase();

        _pause();
        assertEq(vault.phase(), phaseBefore, "phase unchanged after pause");

        vm.prank(admin);
        vault.unpauseTrading();
        assertEq(vault.phase(), phaseBefore, "phase unchanged after unpause");
    }
}
