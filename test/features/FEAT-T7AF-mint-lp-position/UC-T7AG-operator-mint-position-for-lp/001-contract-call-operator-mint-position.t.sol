// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-T7AG: Operator Mint Position for LP
// SLICE-001: operator-mint-position

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

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

contract MockConditionalTokens {
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

    function setUp() public virtual {
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20ForMint();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));

        // Fund LP with USDC and approve vault for max spending
        mockUsdc.mint(lp, 100_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
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

    // SC-T7AH: USDC transferred from LP to vault
    function test_usdcTransferredFromLpToVault() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        assertEq(mockUsdc.balanceOf(lp), lpBefore - usdcAmount, "LP balance should decrease");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBefore + usdcAmount, "vault balance should increase");
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

    // SC-T7AI: position created and USDC transferred
    function test_positionCreatedAndUsdcTransferred() public {
        uint256 lpBefore = mockUsdc.balanceOf(lp);
        bytes memory sig = _signMintIntent(LP_PK, lp, tickLower, tickUpper, usdcAmount, intentId);
        vm.prank(operatorAddr);
        uint256 posId = vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig);

        (address owner,,, uint128 liq,,) = vault.positions(posId);
        assertEq(owner, lp, "position owner should be LP");
        // liquidity = 300 * 1e18 / 30 = 10e18
        assertEq(liq, uint128(10e18), "liquidity should be correct");
        assertEq(mockUsdc.balanceOf(lp), lpBefore - usdcAmount, "USDC should be transferred");
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
        bytes memory sig1 = _signMintIntent(LP_PK, lp, int24(20), int24(60), 400, intentId1);
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(20), int24(60), 400, intentId1, sig1);
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
        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(10), 1, keccak256("tiny"));
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.BelowMinimumFirstLiquidity.selector);
        vault.mintPositionFor(lp, int24(0), int24(10), 1, keccak256("tiny"), sig);
    }

    // SC-T7AO: first mint with liquidity at exactly the floor succeeds
    function test_succeedsWhenFirstMintMeetsFloor() public {
        // minFirstLiq = 10e18. A mint of 100 USDC across [0, 10] gives
        // liquidity = 100 * 1e18 / 10 = 10e18, which == 10e18. Should succeed.
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
