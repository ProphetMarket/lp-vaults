// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-T7AG: Operator Mint Position for LP
// Integration tests for every scenario in this use case.
// Covers: SC-T7AH, SC-T7AI, SC-T7AJ, SC-T7AK, SC-T7AL, SC-T7AM, SC-T7AR, SC-T7AN, SC-T7AO, SC-T7AP, SC-T7AQ,
//         SC-3Z9J, SC-3Z9K, SC-45IE, SC-3XU5, SC-3XU6

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// MockERC20 with transferFrom support for mint tests.
// Tracks balances and allowances so tests can assert on USDC movement.
// ──────────────────────────────────────────────
contract MockERC20ForMint {
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
// Base test contract with shared setup for all mint scenarios.
// Deploys factory, creates vault, funds LP, and provides EIP-712 signing helper.
// ──────────────────────────────────────────────
contract MintPositionTestBase is Test {
    using stdStorage for StdStorage;

    LPVaultFactory factory;
    LPVault vault;
    MockERC20ForMint mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address lp;

    // A second, unrelated LP. Used by SC-45IE to prove that a validly-signed
    // intent does not entitle its signer to another LP's escrow.
    uint256 constant LP_B_PK = 0xB0B;
    address lpB;

    bytes32 marketId = bytes32(uint256(1));
    int24 vaultTickSpacing = int24(10);
    uint128 minFirstLiq = uint128(10e18);

    uint256 constant LIQUIDITY_PRECISION = 1e18;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 usdcAmount,
        bytes32 intentId
    );

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        lp = vm.addr(LP_PK);
        lpB = vm.addr(LP_B_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20ForMint();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault =
            LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq, conditionId, yesTokenId, noTokenId));

        // Fund both LPs with USDC and approve vault for max spending
        mockUsdc.mint(lp, 100_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        mockUsdc.mint(lpB, 100_000);
        vm.prank(lpB);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Escrows `amount` against `id` as the Operator, signing with `pk` on
    ///      behalf of `lpAddr`. Since mint no longer pulls tokens (FEAT-3ZRI), every
    ///      mint that is expected to reach the escrow check needs this to run first.
    function _escrow(uint256 pk, address lpAddr, int24 tl, int24 tu, uint256 amount, bytes32 id) internal {
        bytes memory sig = _signMintIntent(pk, lpAddr, tl, tu, amount, id);
        vm.prank(operatorAddr);
        vault.depositForIntent(lpAddr, tl, tu, amount, id, sig);
    }

    /// @dev Escrows for the canonical LP, who signs their own intent.
    function _escrowForLp(int24 tl, int24 tu, uint256 amount, bytes32 id) internal {
        _escrow(LP_PK, lp, tl, tu, amount, id);
    }

    /// @dev Asserts the escrow at `id` records exactly this depositor and amount.
    function _assertEscrow(bytes32 id, address expectedLp, uint96 expectedAmount, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, expectedLp, reason);
        assertEq(escrowAmount, expectedAmount, reason);
    }

    /// @dev Asserts no escrow exists at `id`. The sentinel is the zero lp address.
    function _assertNoEscrow(bytes32 id, string memory reason) internal {
        (address escrowLp, uint96 escrowAmount) = vault.pendingDeposits(id);
        assertEq(escrowLp, address(0), reason);
        assertEq(escrowAmount, 0, reason);
    }

    /// @dev Computes the EIP-712 domain separator for the vault.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    /// @dev Signs a MintIntent struct with the given private key.
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

    /// @dev Sets the vault's currentTick via storage manipulation (no updateTick yet).
    function _setCurrentTick(int24 tick) internal {
        stdstore.target(address(vault)).sig("currentTick()").checked_write_int(int256(tick));
    }

    /// @dev Sets the vault's feeGrowthGlobalX128 via storage manipulation (no notifyFees yet).
    function _setFeeGrowthGlobalX128(uint256 val) internal {
        stdstore.target(address(vault)).sig("feeGrowthGlobalX128()").checked_write(val);
    }

    /// @dev Sets the vault's phase via direct storage manipulation.
    ///      phase is a uint8 at slot 5, byte offset 17 (bits 136-143), packed with
    ///      minimumFirstLiquidity (bytes 0-15) and _initialized (byte 16).
    function _setPhase(uint8 p) internal {
        bytes32 slot = bytes32(uint256(5));
        bytes32 current = vm.load(address(vault), slot);
        bytes32 mask = ~bytes32(uint256(0xFF) << 136);
        bytes32 updated = (current & mask) | bytes32(uint256(p) << 136);
        vm.store(address(vault), slot, updated);
    }
}

// ──────────────────────────────────────────────
// SC-T7AH: Successful in-range mint with fresh ticks
// What: When the Operator submits a valid EIP-712 mint intent for a range
//       that spans the current tick (in-range), the vault creates the position,
//       initializes both bound ticks with correct feeGrowthOutside values,
//       adds liquidity to activeLiquidity, pulls USDC from the LP, and
//       emits PositionMinted. This is the primary happy path for LP onboarding.
// Why:  This scenario exercises the complete mint flow end-to-end: signature
//       verification, tick initialization, fee snapshot, active liquidity
//       update, and USDC transfer. It's the most common case in production.
// Example: vault at currentTick=50 with feeGrowthGlobal=1000, LP mints
//          range [20, 80] with 600 USDC. Tick 20 initializes with
//          feeGrowthOutside=1000 (below current), tick 80 with 0 (above).
//          liquidity = 600 * 1e18 / 60 = 10e18. activeLiquidity += 10e18.
// ──────────────────────────────────────────────
contract MintPositionInRangeSuccessTest is MintPositionTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("intent-1");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
        _setFeeGrowthGlobalX128(1000);

        // The Operator escrowed this intent first: the vault already holds the 600.
        // Mint converts that escrow into a position rather than pulling tokens.
        _escrowForLp(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-T7AH: position record has correct owner, ticks, and liquidity
    function test_positionRecordIsCorrect() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (address owner, int24 tl, int24 tu, uint128 liq,, uint256 owed) = vault.positions(posId);
        assertEq(owner, lp, "position owner should be LP");
        assertEq(tl, tickLower, "tickLower should match");
        assertEq(tu, tickUpper, "tickUpper should match");
        // liquidity = 600 * 1e18 / (80 - 20) = 10e18
        assertEq(liq, uint128(10e18), "liquidity should be usdcAmount * PRECISION / rangeWidth");
        assertEq(owed, 0, "tokensOwed should be 0 at mint");
    }

    // SC-T7AH: feeGrowthInsideLastX128 snapshot is correct
    function test_feeGrowthInsideSnapshotPreventsRetroactiveClaims() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        // feeGrowthInside = global(1000) - below(1000) - above(0) = 0
        // below: currentTick(50) >= tickLower(20) → ticks[20].feeGrowthOutside = 1000 (just initialized)
        // above: currentTick(50) < tickUpper(80) → ticks[80].feeGrowthOutside = 0 (just initialized)
        (,,,, uint256 feeGrowthLast,) = vault.positions(posId);
        assertEq(feeGrowthLast, 0, "feeGrowthInsideLast should be 0 (no retroactive fees)");
    }

    // SC-T7AH: tick 20 initialized with feeGrowthOutside = feeGrowthGlobal (below currentTick)
    function test_lowerTickInitializedCorrectly() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (uint128 liqGross, int128 liqNet, uint256 feeGrowthOutside) = vault.ticks(tickLower);
        assertEq(feeGrowthOutside, 1000, "tick 20 feeGrowthOutside should equal feeGrowthGlobal");
        assertEq(liqGross, uint128(10e18), "tick 20 liquidityGross should equal position liquidity");
        assertEq(liqNet, int128(int256(uint256(10e18))), "tick 20 liquidityNet should be positive");
    }

    // SC-T7AH: tick 80 initialized with feeGrowthOutside = 0 (above currentTick)
    function test_upperTickInitializedCorrectly() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (uint128 liqGross, int128 liqNet, uint256 feeGrowthOutside) = vault.ticks(tickUpper);
        assertEq(feeGrowthOutside, 0, "tick 80 feeGrowthOutside should be 0 (above currentTick)");
        assertEq(liqGross, uint128(10e18), "tick 80 liquidityGross should equal position liquidity");
        assertEq(liqNet, -int128(int256(uint256(10e18))), "tick 80 liquidityNet should be negative");
    }

    // SC-T7AH: activeLiquidity increased (position is in-range)
    function test_activeLiquidityIncreasedForInRangePosition() public {
        uint128 before_ = vault.activeLiquidity();
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertEq(vault.activeLiquidity(), before_ + uint128(10e18), "activeLiquidity should increase");
    }

    // SC-T7AH: the mint itself moves no USDC — the 600 moved at escrow time
    function test_mintMovesNoUsdc() public {
        // Balances are sampled AFTER the escrow in setUp, so they capture only
        // what the mint call itself does. The LP was already debited 600 then.
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        assertEq(vaultBefore, usdcAmount, "vault should already hold the escrowed 600 before the mint");

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance must be unchanged by the mint");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be unchanged by the mint");
    }

    // SC-T7AH: the escrow is consumed, so it can be neither re-minted nor reclaimed
    function test_mintClearsTheEscrowEntry() public {
        _assertEscrow(intentId, lp, uint96(usdcAmount), "escrow should be present before the mint");

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        _assertNoEscrow(intentId, "mint should delete the escrow entry it consumed");
    }

    // SC-T7AH: PositionMinted event emitted
    function test_emitsPositionMintedEvent() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionMinted(0, lp, tickLower, tickUpper, uint128(10e18), usdcAmount, intentId);

        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);
    }

    // SC-T7AH: intentId recorded as used
    function test_intentIdRecordedAsUsed() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertTrue(vault.usedIntents(intentId), "intentId should be marked as used");
    }

    // SC-T7AH: nextPositionId incremented
    function test_nextPositionIdIncremented() public {
        uint256 before_ = vault.nextPositionId();
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertEq(vault.nextPositionId(), before_ + 1, "nextPositionId should increment");
    }
}

// ──────────────────────────────────────────────
// SC-T7AI: Successful out-of-range mint (above current tick)
// What: When the LP's range is entirely above the current tick, the position
//       is created but activeLiquidity does NOT increase. Both ticks are
//       initialized with feeGrowthOutside = 0 (above currentTick convention).
// Why:  Out-of-range positions don't contribute to the fee denominator until
//       the price moves into their range. Getting this wrong would inflate
//       the fee split and dilute in-range LPs.
// ──────────────────────────────────────────────
contract MintPositionOutOfRangeTest is MintPositionTestBase {
    int24 tickLower = int24(60);
    int24 tickUpper = int24(90);
    uint256 usdcAmount = 300;
    bytes32 intentId = keccak256("intent-oor");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
        _setFeeGrowthGlobalX128(2000);

        _escrowForLp(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-T7AI: activeLiquidity unchanged for out-of-range position
    function test_activeLiquidityUnchangedWhenOutOfRange() public {
        uint128 before_ = vault.activeLiquidity();
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertEq(vault.activeLiquidity(), before_, "activeLiquidity should NOT change for out-of-range");
    }

    // SC-T7AI: both ticks initialized with feeGrowthOutside = 0 (both above currentTick)
    function test_bothTicksInitializedWithZeroFeeGrowthOutside() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (,, uint256 fgOutLower) = vault.ticks(tickLower);
        (,, uint256 fgOutUpper) = vault.ticks(tickUpper);
        assertEq(fgOutLower, 0, "tick 60 feeGrowthOutside should be 0 (above current)");
        assertEq(fgOutUpper, 0, "tick 90 feeGrowthOutside should be 0 (above current)");
    }

    // SC-T7AI: position created from the escrow, with no token movement at mint
    function test_positionCreatedAndEscrowConsumed() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (address owner,,, uint128 liq,,) = vault.positions(posId);
        assertEq(owner, lp, "position owner should be LP");
        // liquidity = 300 * 1e18 / 30 = 10e18
        assertEq(liq, uint128(10e18), "liquidity should be correct");
        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance must be unchanged by the mint");
        _assertNoEscrow(intentId, "mint should delete the escrow entry it consumed");
    }
}

// ──────────────────────────────────────────────
// SC-T7AJ: Second position on existing tick
// What: When a new position references a tick that already has liquidity
//       (from a prior mint), the tick's feeGrowthOutsideX128 must NOT be
//       re-initialized — only liquidityGross/Net are accumulated.
// Why:  Re-initializing feeGrowthOutside on an already-live tick would
//       corrupt the fee accounting for every position that references it.
//       The init convention (global if <= current, else 0) is only valid
//       at the tick's very first use.
// ──────────────────────────────────────────────
contract MintPositionExistingTickTest is MintPositionTestBase {
    bytes32 intentId1 = keccak256("intent-first");
    bytes32 intentId2 = keccak256("intent-second");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
        _setFeeGrowthGlobalX128(1000);

        // First mint establishes tick 20 with feeGrowthOutside = 1000 and tick 60 = 0
        _escrowForLp(int24(20), int24(60), 400, intentId1);
        bytes memory sig1 = _signMintIntent(LP_PK, lp, int24(20), int24(60), 400, intentId1);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(60), 400, intentId1, sig1);

        // Fund the second intent up front; escrowing touches no tick state, so it
        // cannot disturb what these tests observe about tick 20.
        _escrowForLp(int24(20), int24(80), 600, intentId2);
    }

    // SC-T7AJ: second position accumulates liquidityGross on shared tick
    function test_liquidityGrossAccumulatesOnExistingTick() public {
        (uint128 liqGrossBefore,,) = vault.ticks(int24(20));

        bytes memory sig2 = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, intentId2);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId2, sig2);

        // Second position liquidity: 600 * 1e18 / 60 = 10e18
        (uint128 liqGrossAfter,,) = vault.ticks(int24(20));
        assertEq(liqGrossAfter, liqGrossBefore + uint128(10e18), "liquidityGross should accumulate");
    }

    // SC-T7AJ: the second mint consumes its own escrow and moves no USDC
    function test_secondMintConsumesEscrowAndMovesNoUsdc() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        bytes memory sig2 = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, intentId2);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId2, sig2);

        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance must be unchanged by the mint");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be unchanged by the mint");
        _assertNoEscrow(intentId2, "the second mint should delete the escrow it consumed");
    }

    // SC-T7AJ: feeGrowthOutside preserved on existing tick (NOT re-initialized)
    function test_feeGrowthOutsidePreservedOnExistingTick() public {
        (,, uint256 fgOutBefore) = vault.ticks(int24(20));

        // Simulate fee growth changing between mints
        _setFeeGrowthGlobalX128(5000);

        bytes memory sig2 = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, intentId2);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId2, sig2);

        (,, uint256 fgOutAfter) = vault.ticks(int24(20));
        assertEq(fgOutAfter, fgOutBefore, "feeGrowthOutside should be preserved, not re-initialized");
    }
}

// ──────────────────────────────────────────────
// SC-T7AK: Inverted range revert
// SC-T7AL: Misaligned tick revert
// SC-T7AM: Non-active vault revert
// SC-T7AR: Zero amount revert
// What: Validation checks reject structurally invalid mint requests before
//       any state is touched. Each fires a distinct custom error.
// Why:  Early reverts protect the vault from recording positions with
//       impossible ranges, misaligned ticks, or zero liquidity. They also
//       prevent minting into a wound-down vault.
// ──────────────────────────────────────────────
contract MintPositionValidationTest is MintPositionTestBase {
    // SC-T7AK: tickLower >= tickUpper reverts with InvalidRange
    function test_revertsOnInvertedRange() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(80), int24(20), 600, keccak256("inv"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(80), int24(20), 600, keccak256("inv"), sig);
    }

    // SC-T7AK: tickLower == tickUpper reverts with InvalidRange
    function test_revertsOnEqualTicks() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(50), int24(50), 600, keccak256("eq"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(50), int24(50), 600, keccak256("eq"), sig);
    }

    // SC-T7AL: tick not aligned to tickSpacing reverts with TickNotAligned
    function test_revertsOnMisalignedLowerTick() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(15), int24(80), 600, keccak256("mis"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TickNotAligned.selector);
        vault.mintPositionFor(lp, int24(15), int24(80), 600, keccak256("mis"), sig);
    }

    // SC-T7AL: misaligned upper tick also reverts
    function test_revertsOnMisalignedUpperTick() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(75), 600, keccak256("mis2"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TickNotAligned.selector);
        vault.mintPositionFor(lp, int24(20), int24(75), 600, keccak256("mis2"), sig);
    }

    // SC-T7AM: mint on a non-active vault reverts with VaultNotActive
    function test_revertsWhenVaultNotActive() public {
        // Set phase to WindDown (2) via storage
        _setPhase(2);

        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("wd"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.VaultNotActive.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("wd"), sig);
    }

    // SC-T7AR: usdcAmount == 0 reverts with ZeroAmount
    function test_revertsOnZeroAmount() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 0, keccak256("zero"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 0, keccak256("zero"), sig);
    }
}

// ──────────────────────────────────────────────
// SC-T7AN: Non-operator caller revert
// What: Only registered Operators can call mintPositionFor. All other
//       callers — LP, Admin, Oracle, arbitrary addresses — get NotOperator.
// Why:  FR-RFS6 from FEAT-REPZ mandates operator-only position creation
//       to eliminate the first-LP inflation attack vector.
// ──────────────────────────────────────────────
contract MintPositionAccessControlTest is MintPositionTestBase {
    // SC-T7AN: LP calling directly reverts
    function test_revertsWhenLpCallsDirectly() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("lp-call"));
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("lp-call"), sig);
    }

    // SC-T7AN: Admin calling reverts
    function test_revertsWhenAdminCalls() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("admin-call"));
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("admin-call"), sig);
    }

    // SC-T7AN: Oracle calling reverts
    function test_revertsWhenOracleCalls() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("oracle-call"));
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("oracle-call"), sig);
    }

    // SC-T7AN: arbitrary address calling reverts
    function test_revertsWhenNobodyCalls() public {
        address nobody = makeAddr("nobody");
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("nobody-call"));
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("nobody-call"), sig);
    }
}

// ──────────────────────────────────────────────
// SC-T7AO: First mint below minimum liquidity
// What: When activeLiquidity == 0 and the computed liquidity from the mint
//       falls below minimumFirstLiquidity, the call reverts with
//       BelowMinimumFirstLiquidity.
// Why:  FR-RFS7 from FEAT-REPZ prevents a tiny first position from
//       manipulating the fee accumulator (the v3 analog of the ERC-4626
//       first-depositor inflation attack).
// ──────────────────────────────────────────────
contract MintPositionFirstMintFloorTest is MintPositionTestBase {
    // SC-T7AO: first mint with liquidity below floor reverts
    function test_revertsWhenFirstMintBelowFloor() public {
        // minFirstLiq = 10e18. A mint of 1 USDC across [0, 10] gives
        // liquidity = 1 * 1e18 / 10 = 0.1e18 = 1e17, which is < 10e18.
        // The escrow must exist so the call reaches the floor check, which sits
        // downstream of the escrow validation.
        _escrowForLp(int24(0), int24(10), 1, keccak256("tiny"));
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(10), 1, keccak256("tiny"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.BelowMinimumFirstLiquidity.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), 1, keccak256("tiny"), sig);
    }

    // SC-T7AO: first mint with liquidity at exactly the floor succeeds
    function test_succeedsWhenFirstMintMeetsFloor() public {
        // minFirstLiq = 10e18. A mint of 100 USDC across [0, 10] gives
        // liquidity = 100 * 1e18 / 10 = 10e18, which == 10e18. Should succeed.
        _escrowForLp(int24(0), int24(10), 100, keccak256("ok"));
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(10), 100, keccak256("ok"));
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(0), int24(10), 100, keccak256("ok"), sig);

        assertGt(vault.activeLiquidity(), 0, "activeLiquidity should be non-zero after first mint");
    }
}

// ──────────────────────────────────────────────
// SC-T7AP: Duplicate intentId revert
// What: Reusing an intentId that was already consumed in a successful mint
//       reverts with IntentAlreadyUsed. The usedIntents mapping is write-once.
// Why:  Replay protection prevents the same signed intent from being
//       executed twice — the LP only authorized one mint per intentId.
// ──────────────────────────────────────────────
contract MintPositionReplayProtectionTest is MintPositionTestBase {
    bytes32 intentId = keccak256("replay-me");

    // SC-T7AP: second use of the same intentId reverts
    function test_revertsOnDuplicateIntentId() public {
        _escrowForLp(int24(0), int24(10), 100, intentId);
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(10), 100, intentId);

        // First use succeeds
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(0), int24(10), 100, intentId, sig);

        // Second use reverts
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), 100, intentId, sig);
    }
}

// ──────────────────────────────────────────────
// SC-T7AQ: Invalid signature revert
// What: Signatures that don't match the declared LP, or that exhibit
//       malleability (high-s, invalid v), are rejected with InvalidSignature.
// Why:  EIP-712 verification is the LP's authorization gate. Accepting
//       invalid signatures would let anyone mint on the LP's behalf.
//       Malleability rejection (CLAUDE.md security checklist item 5)
//       prevents an attacker from deriving a second valid signature
//       from an observed one.
// ──────────────────────────────────────────────
contract MintPositionSignatureTest is MintPositionTestBase {
    // SC-T7AQ: wrong signer — LP signed but operator submits with different lp address
    function test_revertsWhenSignerMismatch() public {
        address fakeLp = makeAddr("fakeLp");
        // Sign as real LP but submit with fakeLp address
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, keccak256("wrong-signer"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(fakeLp, int24(20), int24(80), 600, keccak256("wrong-signer"), sig);
    }

    // SC-T7AQ: malleable signature (high-s value) reverts
    function test_revertsOnHighSValue() public {
        bytes32 intentId = keccak256("high-s");
        bytes32 structHash =
            keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, int24(20), int24(80), uint256(600), intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);

        // Flip s to the upper half of the secp256k1 curve (malleable counterpart)
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(secp256k1n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, highS, flippedV);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, malleableSig);
    }

    // SC-T7AQ: invalid v value reverts
    function test_revertsOnInvalidV() public {
        bytes32 intentId = keccak256("bad-v");
        bytes32 structHash =
            keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, int24(20), int24(80), uint256(600), intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);

        // Set v to invalid value (not 27 or 28)
        bytes memory badVSig = abi.encodePacked(r, s, uint8(26));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, badVSig);
    }

    // SC-T7AQ: empty signature reverts
    function test_revertsOnEmptySignature() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidSignature.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, keccak256("empty"), "");
    }
}

// ──────────────────────────────────────────────
// SC-3Z9J: Revert when no deposit is escrowed for the intent
// SC-3Z9K: Revert when the escrowed amount does not match the intent
// What: mintPositionFor no longer pulls USDC — it converts an escrow the vault
//       already holds. An intent with no escrow, or one whose escrow does not
//       exactly equal the intent's usdcAmount, reverts with DepositNotEscrowed.
// Why:  Without the escrow requirement, a signed intent alone would mint
//       liquidity against USDC the vault never collected. Exact equality rather
//       than a sufficiency check means a position can neither exceed the USDC
//       collected for it nor silently strand a remainder in escrow.
// Example: escrow 400 against intentId X, then submit an intent for 600 over the
//          same X. It reverts, and the 400 stays escrowed and still reclaimable.
// ──────────────────────────────────────────────
contract MintPositionEscrowRequirementTest is MintPositionTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    bytes32 intentId = keccak256("escrow-required");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));
    }

    // SC-3Z9J: an intent that was never escrowed cannot mint
    function test_revertsWhenNothingIsEscrowed() public {
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 600, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 600, intentId, sig);
    }

    // SC-3Z9J: the rejected mint creates no position and moves no USDC
    function test_unfundedMintCreatesNoPositionAndMovesNoUsdc() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));
        uint256 nextIdBefore = vault.nextPositionId();

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 600, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 600, intentId, sig);

        assertEq(vault.nextPositionId(), nextIdBefore, "no position may be created from an unfunded intent");
        assertEq(mockUsdc.balanceOf(lp), lpBefore, "LP balance must be untouched");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore, "vault balance must be untouched");
        assertFalse(vault.usedIntents(intentId), "a rejected mint must not consume the intentId");
    }

    // SC-3Z9J: a failed mint is not proof the Operator is alive
    function test_unfundedMintLeavesSilenceTimerUntouched() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 600, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 600, intentId, sig);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted mint must not count as proof of life");
    }

    // SC-3Z9K: an escrow of 400 cannot fund an intent for 600
    function test_revertsWhenEscrowedAmountIsLessThanTheIntent() public {
        // The LP signed and the Operator escrowed an intent for 400 against this id.
        _escrowForLp(tickLower, tickUpper, 400, intentId);

        // A different, also validly-signed intent over the same id claims 600.
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 600, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 600, intentId, sig);
    }

    // SC-3Z9K: the mismatched escrow survives intact and stays reclaimable
    function test_mismatchedEscrowRemainsIntact() public {
        _escrowForLp(tickLower, tickUpper, 400, intentId);

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 600, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 600, intentId, sig);

        _assertEscrow(intentId, lp, uint96(400), "the 400 must still be escrowed after the rejected mint");
        assertFalse(vault.usedIntents(intentId), "the intentId must stay unused so the LP can still reclaim");
    }

    // SC-3Z9K: an escrow larger than the intent is rejected just as firmly —
    // exact equality, not sufficiency, so no remainder is stranded
    function test_revertsWhenEscrowedAmountExceedsTheIntent() public {
        _escrowForLp(tickLower, tickUpper, 600, intentId);

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, 400, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.DepositNotEscrowed.selector);
        vault.mintPositionFor(lp, tickLower, tickUpper, 400, intentId, sig);

        _assertEscrow(intentId, lp, uint96(600), "the full 600 must remain escrowed");
    }
}

// ──────────────────────────────────────────────
// SC-45IE: Revert when the escrow belongs to a different LP
// What: LP A funds intentId X. LP B validly signs their own intent naming
//       themselves over the same X, and the Operator submits it. The mint is
//       rejected with NotIntentOwner and A's escrow is untouched.
// Why:  A valid signature over an intentId proves only that someone signed it,
//       never that they funded it — _verifyMintIntent compares the recovered
//       signer against a caller-supplied `lp`, so anyone can sign over any
//       intentId. The escrow's recorded depositor is what settles ownership.
//       Without this check a colluding or compromised Operator could mint B a
//       position funded entirely by A's deposit.
// Example: A escrows 600 against X. B signs (B, 20, 80, 600, X) with B's own
//          key — a genuine signature that recovers to B. The mint still reverts.
// ──────────────────────────────────────────────
contract MintPositionEscrowOwnershipTest is MintPositionTestBase {
    int24 tickLower = int24(20);
    int24 tickUpper = int24(80);
    uint256 usdcAmount = 600;
    bytes32 intentId = keccak256("escrow-owned-by-a");

    function setUp() public override {
        super.setUp();
        _setCurrentTick(int24(50));

        // LP A (the canonical `lp`) funds the intent.
        _escrowForLp(tickLower, tickUpper, usdcAmount, intentId);
    }

    // SC-45IE: B's own valid signature over A's intentId does not mint
    function test_revertsWhenMintingForNonDepositor() public {
        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, tickLower, tickUpper, usdcAmount, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.mintPositionFor(lpB, tickLower, tickUpper, usdcAmount, intentId, sigB);
    }

    // SC-45IE: A's escrow survives the attempt, and A can still mint it
    function test_depositorsEscrowSurvivesAndRemainsMintable() public {
        bytes memory sigB = _signMintIntent(LP_B_PK, lpB, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotIntentOwner.selector);
        vault.mintPositionFor(lpB, tickLower, tickUpper, usdcAmount, intentId, sigB);

        _assertEscrow(intentId, lp, uint96(usdcAmount), "A's escrow must be untouched");
        assertEq(vault.nextPositionId(), 0, "no position may be created for B");

        // A's own mint still works, proving the rejection cost A nothing.
        bytes memory sigA = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sigA);

        (address owner,,,,,) = vault.positions(posId);
        assertEq(owner, lp, "the position belongs to the depositor, A");
    }
}

// ──────────────────────────────────────────────
// SC-3XU5, SC-3XU6: Minting feeds the Operator silence timer
// What: A successful mintPositionFor refreshes lastOperatorActivityTimestamp;
//       a mint that reverts leaves it exactly where it was.
// Why:  Processing LP deposits is real Operator work and should count as proof
//       of life against the emergency-cancel timelock (FEAT-JXQO, FR-JXQS).
//       A failed call must not count — otherwise a broken Operator could prove
//       liveness by failing repeatedly.
// Example: warp a day forward, mint succeeds → timer == block.timestamp;
//          replay the same intentId → reverts, timer unchanged.
// ──────────────────────────────────────────────
contract MintRefreshesOperatorSilenceTimerTest is MintPositionTestBase {
    // SC-3XU5: a successful mint advances the timer to the current block
    function test_successfulMintRefreshesSilenceTimer() public {
        bytes32 intentId = keccak256("mint-refreshes-timer");

        // Escrow first, then move well past it so a stale timer would be obvious.
        // depositForIntent also touches the heartbeat, so the warp has to come
        // after it for the assertion to be about the mint and not the escrow.
        _escrowForLp(int24(20), int24(80), 600, intentId);
        vm.warp(block.timestamp + 1 days);

        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, intentId);

        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, sig);

        assertEq(
            vault.lastOperatorActivityTimestamp(), block.timestamp, "a successful mint should refresh the silence timer"
        );
    }

    // SC-3XU6: a mint rejected for a duplicate intentId leaves the timer alone
    function test_revertedMintOnDuplicateIntentLeavesSilenceTimerUntouched() public {
        bytes32 intentId = keccak256("mint-duplicate-intent");
        _escrowForLp(int24(20), int24(80), 600, intentId);
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(20), int24(80), 600, intentId);

        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, sig);

        uint256 timerAfterFirstMint = vault.lastOperatorActivityTimestamp();

        // Time passes, then the same intent is replayed and rejected
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.IntentAlreadyUsed.selector);
        vault.mintPositionFor(lp, int24(20), int24(80), 600, intentId, sig);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            timerAfterFirstMint,
            "a reverted mint must not count as proof of life"
        );
    }

    // SC-3XU6: the same holds for a mint rejected on range validation
    function test_revertedMintOnInvertedRangeLeavesSilenceTimerUntouched() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.warp(block.timestamp + 1 days);

        bytes32 intentId = keccak256("mint-inverted-range");
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(80), int24(20), 600, intentId);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.InvalidRange.selector);
        vault.mintPositionFor(lp, int24(80), int24(20), 600, intentId, sig);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted mint must not count as proof of life");
    }
}
