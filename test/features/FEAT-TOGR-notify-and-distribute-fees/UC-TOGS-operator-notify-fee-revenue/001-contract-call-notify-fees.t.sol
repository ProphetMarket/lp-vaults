// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TOGS: Operator Notify Fee Revenue
// SLICE-001: notify-fees

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// Minimal ERC-20 mock with balanceOf, approve, transferFrom.
// Reused from FEAT-T7AF test patterns.
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
// Base test contract for notifyFees scenarios.
// Deploys the full stack (factory + vault clone), mints an in-range position
// to establish activeLiquidity > 0, and provides helpers for storage manipulation.
// ──────────────────────────────────────────────
contract NotifyFeesTestBase is Test {
    using stdStorage for StdStorage;

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

    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);

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

        // Mint a position to establish activeLiquidity > 0.
        // Range [0, 100] with 1000 USDC → liquidity = 1000 * 1e18 / 100 = 10e18.
        // currentTick defaults to 0, so [0, 100) is in-range → activeLiquidity = 10e18.
        mockUsdc.mint(lp, 1_000_000);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);

        bytes memory sig = _signMintIntent(LP_PK, lp, int24(0), int24(100), 1000, keccak256("setup-mint"));
        vm.prank(operatorAddr);
        vault.mintPositionFor(lp, int24(0), int24(100), 1000, keccak256("setup-mint"), sig);
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

    /// @dev Reference mulDiv for expected-value computation in tests.
    ///      Matches OpenZeppelin / Solady: (a * b) / denominator with full precision.
    function _refMulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) return prod0 / denominator;
        require(prod1 < denominator, "mulDiv overflow");
        unchecked {
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            return prod0 * inverse;
        }
    }
}

// ──────────────────────────────────────────────
// SC-TOGT: Successful fee notification with active liquidity
// What: When the Operator calls notifyFees(amount) on a vault with active
//       liquidity, feeGrowthGlobalX128 increases by mulDiv(amount, Q128,
//       activeLiquidity), a FeesNotified event is emitted, and no USDC
//       moves during the call.
// Why:  This is the primary happy path. The Q128 accumulator math must be
//       exact — any error compounds across every subsequent collect.
// Example: activeLiquidity = 10e18, amount = 500. Expected delta =
//          mulDiv(500, 2^128, 10e18) ≈ 1.7e22.
// ──────────────────────────────────────────────
contract NotifyFeesSuccessTest is NotifyFeesTestBase {
    uint256 amount = 500;

    // SC-TOGT: feeGrowthGlobalX128 increases by the correct Q128 delta
    function test_feeGrowthGlobalIncreasesByCorrectDelta() public {
        uint256 before_ = vault.feeGrowthGlobalX128();
        uint128 activeL = vault.activeLiquidity();
        uint256 expectedDelta = _refMulDiv(amount, Q128, uint256(activeL));

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), before_ + expectedDelta, "feeGrowthGlobalX128 delta incorrect");
    }

    // SC-TOGT: FeesNotified event emitted with correct amount and cumulative value
    function test_emitsFeesNotifiedEvent() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 expectedGlobal = vault.feeGrowthGlobalX128() + _refMulDiv(amount, Q128, uint256(activeL));

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeesNotified(amount, expectedGlobal);

        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    // SC-TOGT: vault USDC balance unchanged during the call (no transfers)
    function test_noUsdcTransferDuringNotify() public {
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBalBefore, "vault USDC balance should not change");
    }

    // SC-TOGT: no position-level state changes
    function test_positionStateUnchanged() public {
        (address owner, int24 tl, int24 tu, uint128 liq, uint256 feeGrowthLast, uint256 owed) = vault.positions(0);

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        (address owner2, int24 tl2, int24 tu2, uint128 liq2, uint256 feeGrowthLast2, uint256 owed2) = vault.positions(0);
        assertEq(owner2, owner, "position owner unchanged");
        assertEq(tl2, tl, "tickLower unchanged");
        assertEq(tu2, tu, "tickUpper unchanged");
        assertEq(liq2, liq, "liquidity unchanged");
        assertEq(feeGrowthLast2, feeGrowthLast, "feeGrowthInsideLastX128 unchanged");
        assertEq(owed2, owed, "tokensOwed unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-TOGU: Sequential notifications accumulate correctly
// What: Two back-to-back notifyFees calls produce the sum of the individual
//       Q128 deltas, and each emits its own FeesNotified event.
// Why:  The accumulator is additive. Getting this wrong (e.g., overwriting
//       instead of incrementing) would erase prior fee history.
// Example: A=200, B=300, L=10e18.
//          After both: feeGrowthGlobal = mulDiv(200, Q128, L) + mulDiv(300, Q128, L).
// ──────────────────────────────────────────────
contract NotifyFeesSequentialTest is NotifyFeesTestBase {
    uint256 amountA = 200;
    uint256 amountB = 300;

    // SC-TOGU: cumulative feeGrowthGlobalX128 equals sum of individual deltas
    function test_cumulativeFeeGrowthEqualsSum() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 deltaA = _refMulDiv(amountA, Q128, uint256(activeL));
        uint256 deltaB = _refMulDiv(amountB, Q128, uint256(activeL));

        vm.startPrank(operatorAddr);
        vault.notifyFees(amountA);
        vault.notifyFees(amountB);
        vm.stopPrank();

        assertEq(vault.feeGrowthGlobalX128(), deltaA + deltaB, "cumulative feeGrowthGlobal should be sum of deltas");
    }

    // SC-TOGU: two separate FeesNotified events with correct cumulative values
    function test_twoEventsEmittedWithCumulativeValues() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 deltaA = _refMulDiv(amountA, Q128, uint256(activeL));
        uint256 deltaB = _refMulDiv(amountB, Q128, uint256(activeL));

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeesNotified(amountA, deltaA);
        vm.prank(operatorAddr);
        vault.notifyFees(amountA);

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeesNotified(amountB, deltaA + deltaB);
        vm.prank(operatorAddr);
        vault.notifyFees(amountB);
    }
}

// ──────────────────────────────────────────────
// SC-TOGV: Revert when no active liquidity
// What: When activeLiquidity == 0 (no in-range positions), notifyFees must
//       revert with NoActiveLiquidity, regardless of the amount.
// Why:  CLAUDE.md security checklist item 9 — silently distributing fees
//       against zero liquidity would lock USDC with no way to claim it.
// ──────────────────────────────────────────────
contract NotifyFeesNoLiquidityTest is NotifyFeesTestBase {
    function setUp() public override {
        // Skip the parent setUp's position mint — we want activeLiquidity == 0.
        lp = vm.addr(LP_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, vaultTickSpacing, minFirstLiq));
    }

    // SC-TOGV: reverts with NoActiveLiquidity when activeLiquidity == 0
    function test_revertsWhenNoActiveLiquidity() public {
        assertEq(vault.activeLiquidity(), 0, "precondition: activeLiquidity should be 0");

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NoActiveLiquidity.selector);
        vault.notifyFees(100);
    }

    // SC-TOGV: feeGrowthGlobalX128 unchanged after revert
    function test_feeGrowthUnchangedAfterRevert() public {
        uint256 before_ = vault.feeGrowthGlobalX128();

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NoActiveLiquidity.selector);
        vault.notifyFees(100);

        assertEq(vault.feeGrowthGlobalX128(), before_, "feeGrowthGlobalX128 should be unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-TOGW: Revert for non-Operator caller
// What: Only registered Operators can call notifyFees. LP, Admin, Oracle,
//       and arbitrary addresses all get NotOperator.
// Why:  Access control prevents unauthorized fee inflation.
// ──────────────────────────────────────────────
contract NotifyFeesAccessControlTest is NotifyFeesTestBase {
    // SC-TOGW: LP calling reverts
    function test_revertsWhenLpCalls() public {
        vm.prank(lp);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);
    }

    // SC-TOGW: Admin calling reverts
    function test_revertsWhenAdminCalls() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);
    }

    // SC-TOGW: Oracle calling reverts
    function test_revertsWhenOracleCalls() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);
    }

    // SC-TOGW: arbitrary address calling reverts
    function test_revertsWhenArbitraryAddressCalls() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.notifyFees(100);
    }
}

// ──────────────────────────────────────────────
// SC-TOGX: Revert for zero amount
// What: notifyFees(0) reverts with ZeroAmount even when activeLiquidity > 0.
// Why:  A zero-amount notification wastes gas and produces no state change.
//       Failing fast signals a caller bug.
// ──────────────────────────────────────────────
contract NotifyFeesZeroAmountTest is NotifyFeesTestBase {
    // SC-TOGX: reverts with ZeroAmount
    function test_revertsOnZeroAmount() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.notifyFees(0);
    }
}

// ──────────────────────────────────────────────
// SC-TOGY: Q128 truncation dust behavior
// What: When amount * Q128 is not evenly divisible by activeLiquidity,
//       the result truncates downward (floor division). The accumulated
//       fees never exceed the notified amount.
// Why:  Truncation is inherent in integer fixed-point. The spec requires
//       floor behavior (never overpay) and documents the dust as negligible.
// Example: amount=7, L=3 → 7 * Q128 / 3 truncates. 3 * floor / Q128 <= 7.
// ──────────────────────────────────────────────
contract NotifyFeesTruncationDustTest is NotifyFeesTestBase {
    // SC-TOGY: truncation produces floor value, not ceiling
    function test_truncatesDownward() public {
        uint128 activeL = vault.activeLiquidity();
        // Pick an amount that doesn't divide evenly with activeLiquidity
        uint256 amount = 7;
        uint256 expectedDelta = _refMulDiv(amount, Q128, uint256(activeL));

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), expectedDelta, "should match floor division");
    }

    // SC-TOGY: accumulated fees never exceed notified amount
    function test_accumulatedFeesNeverExceedNotifiedAmount() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 amount = 7;

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        uint256 increment = vault.feeGrowthGlobalX128();
        // Reverse the Q128 computation: (increment * activeLiquidity) / Q128 <= amount
        uint256 backComputed = (increment * uint256(activeL)) / Q128;
        assertLe(backComputed, amount, "back-computed amount should not exceed notified amount");
    }
}

// ──────────────────────────────────────────────
// FR-TOH3: mulDiv overflow safety (fuzz)
// What: For very large amount values where amount * 2^128 would overflow
//       uint256, the inline mulDiv must still produce the correct result.
// Why:  Without overflow-safe multiplication, realistic fee amounts
//       (e.g., 1e24 USDC-units) would silently produce wrong Q128 deltas.
// ──────────────────────────────────────────────
contract NotifyFeesMulDivOverflowTest is NotifyFeesTestBase {
    // FR-TOH3: fuzz with amounts where the intermediate product (amount * Q128)
    // overflows uint256 but the final result still fits.
    // activeLiquidity = 10e18. Intermediate overflows when amount > 2^128.
    // Result overflows when amount > activeLiquidity * 2^128 / Q128 = activeLiquidity.
    // Wait — result = amount * Q128 / activeLiquidity. Result fits when
    // amount <= type(uint256).max * activeLiquidity / Q128.
    // For activeLiquidity = 10e18: max amount ≈ 10e18 * 2^128 ≈ 3.4e57.
    // Lower bound = 2^128 + 1 to guarantee intermediate overflow.
    function testFuzz_largeAmountDoesNotOverflow(uint256 amount) public {
        uint128 activeL = vault.activeLiquidity();
        // Ensure the intermediate amount * Q128 overflows uint256 (amount > 2^128)
        // but the result amount * Q128 / activeLiquidity still fits in uint256.
        uint256 maxAmount = _refMulDiv(type(uint256).max, uint256(activeL), Q128);
        amount = bound(amount, Q128 + 1, maxAmount);

        uint256 expectedDelta = _refMulDiv(amount, Q128, uint256(activeL));

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), expectedDelta, "fuzz: feeGrowthGlobal should match reference mulDiv");
    }

    // FR-TOH3: mulDiv reverts when the result would not fit in uint256.
    // This exercises the `require(prod1 < denominator)` boundary inside _mulDiv.
    // With activeLiquidity = 10e18 and amount = type(uint256).max, the result
    // (amount * 2^128 / 10e18) overflows uint256, so the require must trip.
    // Also cross-validates the test's reference mulDiv against production behavior
    // on the same input — both must revert with the same condition.
    function test_revertsWhenMulDivResultOverflows() public {
        uint128 activeL = vault.activeLiquidity();

        // Reference helper must also revert on the same inputs, so the helper
        // we use to compute expected values everywhere else is consistent with
        // production semantics at the overflow boundary.
        vm.expectRevert(bytes("mulDiv overflow"));
        this.refMulDivExternal(type(uint256).max, Q128, uint256(activeL));

        vm.prank(operatorAddr);
        vm.expectRevert(bytes("mulDiv overflow"));
        vault.notifyFees(type(uint256).max);
    }

    /// @dev External wrapper around the internal _refMulDiv so vm.expectRevert
    ///      catches the helper's revert (cheatcode requires an external call).
    function refMulDivExternal(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return _refMulDiv(a, b, denominator);
    }
}
