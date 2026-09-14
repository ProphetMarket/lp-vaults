// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-TOGS: Operator Notify Fee Revenue
// Integration tests for every scenario in this use case.
// Covers: SC-TOGT, SC-TOGU, SC-TOGV, SC-TOGW, SC-TOGX, SC-TOGY, SC-ASNK, SC-COF0

import {Test, stdError} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for notifyFees scenarios.
// Deploys the full stack (factory + vault clone), mints an in-range position
// to establish activeLiquidity > 0, and provides helpers for storage manipulation.
// ──────────────────────────────────────────────
contract NotifyFeesTestBase is LPVaultFixture {
    using stdStorage for StdStorage;

    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

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

    event FeesNotified(uint256 amount, uint256 feeGrowthGlobalX128);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public virtual {
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));

        // Mint a position to establish activeLiquidity > 0.
        // Range [0, 100] with 1000 USDC → liquidity = 1000 * 1e18 / 100 = 10e18.
        // currentTick defaults to 0, so [0, 100) is in-range → activeLiquidity = 10e18.
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("setup-mint"));
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
//       activeLiquidity), amount USDC moves from the Operator wallet to the
//       vault in the same call, and a FeesNotified event is emitted after
//       the USDC Transfer log.
// Why:  This is the primary happy path. The Q128 accumulator math must be
//       exact — any error compounds across every subsequent collect. The
//       pull is decision C19: a credit cannot exist without the USDC behind it.
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

        _notifyFees(vault, operatorAddr, amount);

        assertEq(vault.feeGrowthGlobalX128(), before_ + expectedDelta, "feeGrowthGlobalX128 delta incorrect");
    }

    // SC-TOGT: FeesNotified event emitted with correct amount and cumulative value
    function test_emitsFeesNotifiedEvent() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 expectedGlobal = vault.feeGrowthGlobalX128() + _refMulDiv(amount, Q128, uint256(activeL));
        // Fund before expectEmit: the cheatcode watches the next call, which must be the report
        _fundSafe(mockUsdc, operatorAddr, address(vault), amount);

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeesNotified(amount, expectedGlobal);

        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    // SC-TOGT / FR-ASNL: the call moves amount USDC from the Operator wallet to the vault
    function test_usdcMovesFromOperatorToVault() public {
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));
        _fundSafe(mockUsdc, operatorAddr, address(vault), amount);
        uint256 operatorBalBefore = mockUsdc.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.notifyFees(amount);

        assertEq(
            mockUsdc.balanceOf(address(vault)), vaultBalBefore + amount, "vault USDC balance should rise by amount"
        );
        assertEq(mockUsdc.balanceOf(operatorAddr), operatorBalBefore - amount, "Operator balance should fall by amount");
    }

    // SC-TOGT / FR-ASNL: the USDC Transfer log precedes the FeesNotified log in the same call
    function test_transferLogPrecedesFeesNotified() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 expectedGlobal = vault.feeGrowthGlobalX128() + _refMulDiv(amount, Q128, uint256(activeL));
        _fundSafe(mockUsdc, operatorAddr, address(vault), amount);

        // Two expectEmit calls in a row require the two logs in this order
        vm.expectEmit(true, true, false, true, address(mockUsdc));
        emit Transfer(operatorAddr, address(vault), amount);
        vm.expectEmit(false, false, false, true, address(vault));
        emit FeesNotified(amount, expectedGlobal);

        vm.prank(operatorAddr);
        vault.notifyFees(amount);
    }

    // SC-TOGT: a successful notification refreshes the Operator silence timer.
    // notifyFees has always written this, but the side effect was undocumented
    // and unasserted here; it feeds the emergency-cancel timelock (FEAT-JXQO).
    function test_refreshesOperatorSilenceTimer() public {
        // Move well past vault creation so a stale timer would be obvious
        vm.warp(block.timestamp + 1 days);

        _notifyFees(vault, operatorAddr, amount);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            block.timestamp,
            "a successful notification should refresh the silence timer"
        );
    }

    // SC-TOGT: no position-level state changes
    function test_positionStateUnchanged() public {
        (address owner, int24 tl, int24 tu,, uint128 liq, uint256 feeGrowthLast, uint256 owed) = vault.positions(0);

        _notifyFees(vault, operatorAddr, amount);

        (address owner2, int24 tl2, int24 tu2,, uint128 liq2, uint256 feeGrowthLast2, uint256 owed2) =
            vault.positions(0);
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
//       Q128 deltas, each takes its own USDC from the Operator wallet, and
//       each emits its own FeesNotified event.
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

        _notifyFees(vault, operatorAddr, amountA);
        _notifyFees(vault, operatorAddr, amountB);

        assertEq(vault.feeGrowthGlobalX128(), deltaA + deltaB, "cumulative feeGrowthGlobal should be sum of deltas");
    }

    // SC-TOGU: the vault's USDC balance rises by A + B, one transfer per call
    function test_vaultBalanceRisesByBothAmounts() public {
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));

        _notifyFees(vault, operatorAddr, amountA);
        _notifyFees(vault, operatorAddr, amountB);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultBalBefore + amountA + amountB, "vault should hold A + B");
    }

    // SC-TOGU: two separate FeesNotified events with correct cumulative values
    function test_twoEventsEmittedWithCumulativeValues() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 deltaA = _refMulDiv(amountA, Q128, uint256(activeL));
        uint256 deltaB = _refMulDiv(amountB, Q128, uint256(activeL));
        // Fund both reports up front: expectEmit watches the next call, which must be the report
        _fundSafe(mockUsdc, operatorAddr, address(vault), amountA + amountB);

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
        lp = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, marketId, vaultTickSpacing, minFirstLiq));
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

    // SC-TOGX: the rejected call does not refresh the Operator silence timer.
    // This is why heartbeat() exists — on a market with no fee revenue, an
    // Operator cannot prove liveness through this path (FEAT-JXQO).
    function test_revertedNotifyLeavesSilenceTimerUntouched() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();

        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.notifyFees(0);

        assertEq(
            vault.lastOperatorActivityTimestamp(),
            timerBefore,
            "a reverted notification must not count as proof of life"
        );
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

        _notifyFees(vault, operatorAddr, amount);

        assertEq(vault.feeGrowthGlobalX128(), expectedDelta, "should match floor division");
    }

    // SC-TOGY: accumulated fees never exceed notified amount
    function test_accumulatedFeesNeverExceedNotifiedAmount() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 amount = 7;

        _notifyFees(vault, operatorAddr, amount);

        uint256 increment = vault.feeGrowthGlobalX128();
        // Reverse the Q128 computation: (increment * activeLiquidity) / Q128 <= amount
        uint256 backComputed = (increment * uint256(activeL)) / Q128;
        assertLe(backComputed, amount, "back-computed amount should not exceed notified amount");
    }
}

// ──────────────────────────────────────────────
// SC-ASNK: Revert when the Operator did not fund the report
// What: When the Operator wallet cannot cover the reported amount, either
//       because it holds too little USDC (case A) or because it approved the
//       vault for less than the amount (case B), notifyFees reverts with
//       TransferFailed. The accumulator increment that ran before the pull
//       rolls back, so nothing records the unfunded credit.
// Why:  This is the property R8 exists for (decision C19, audit issue 6.6):
//       no fee credit exists without the USDC that backs it. The mock's
//       transferFrom underflows on a missing balance or allowance, so the
//       low-level call fails and _safeTransferFrom reverts TransferFailed,
//       the same error the real USDC contract produces through its revert.
// Example: amount = 500. Case A: the Operator holds 0. Case B: the Operator
//          holds 500 and approved 499.
// ──────────────────────────────────────────────
contract NotifyFeesUnfundedTest is NotifyFeesTestBase {
    uint256 amount = 500;

    // SC-ASNK case A: no balance and no approval
    function test_revertsWhenOperatorHoldsNoUsdc() public {
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "precondition: the Operator holds no USDC");
        uint256 globalBefore = vault.feeGrowthGlobalX128();
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TransferFailed.selector);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), globalBefore, "feeGrowthGlobalX128 must be unchanged");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "a reverted report is not proof of life");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBalBefore, "vault balance must be unchanged");
        assertEq(mockUsdc.balanceOf(operatorAddr), 0, "Operator balance must be unchanged");
    }

    // SC-ASNK case B: the balance is there, the approval is one short
    function test_revertsWhenApprovalIsBelowAmount() public {
        mockUsdc.mint(operatorAddr, amount);
        vm.prank(operatorAddr);
        mockUsdc.approve(address(vault), amount - 1);
        uint256 globalBefore = vault.feeGrowthGlobalX128();
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.TransferFailed.selector);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), globalBefore, "feeGrowthGlobalX128 must be unchanged");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBalBefore, "vault balance must be unchanged");
        assertEq(mockUsdc.balanceOf(operatorAddr), amount, "Operator balance must be unchanged");
    }
}

// ──────────────────────────────────────────────
// FR-TOH3, SC-COF0: mulDiv overflow safety and the fee-total bound
// What: Every amount below 2^128 base units produces the exact Q128 delta and credits the
//       solvency ledger's fee total by that delta times activeLiquidity; an amount above 2^128
//       reverts with an arithmetic panic before any state changes, because the credit is
//       amount x 2^128 less its remainder modulo activeLiquidity (FEAT-9BQZ FR-9BRA, NFR-COEV).
// Why:  The bound is 3.4 x 10^32 USDC, which the user accepted on 2026-09-14; the fuzz test
//       that once asserted larger amounts succeed asserts the exact credit instead.
// ──────────────────────────────────────────────
contract NotifyFeesMulDivOverflowTest is NotifyFeesTestBase {
    // FR-TOH3: every amount inside the bound produces the exact accumulator delta and the exact
    // fee-total credit. activeLiquidity = 10e18, so amount x Q128 fits in uint256 for every
    // amount below 2^128 and the reference mulDiv is a plain product.
    function testFuzz_largeAmountDoesNotOverflow(uint256 amount) public {
        uint128 activeL = vault.activeLiquidity();
        amount = bound(amount, 1, Q128 - 1);

        uint256 expectedDelta = _refMulDiv(amount, Q128, uint256(activeL));

        // The helper mints the fuzzed amount to the Operator per call, so the mock's
        // balance never overflows near the bound.
        _notifyFees(vault, operatorAddr, amount);

        assertEq(vault.feeGrowthGlobalX128(), expectedDelta, "fuzz: feeGrowthGlobal should match reference mulDiv");
        assertEq(vault.totalFeesOwedX128(), expectedDelta * uint256(activeL), "fuzz: the fee total credit");
    }

    // SC-COF0: a report above 2^128 reverts with an arithmetic panic and pulls no USDC. At
    // exactly 2^128 the credit is 2^256 less its remainder modulo activeLiquidity, which fits
    // unless activeLiquidity is a power of two, so the first amount that reverts for every
    // activeLiquidity is 2^128 + 1.
    function test_whenAmountExceeds2Pow128ThenReportRevertsBeforeAnyStateChange() public {
        uint256 amount = Q128 + 1;
        _fundSafe(mockUsdc, operatorAddr, address(vault), amount);
        uint256 globalBefore = vault.feeGrowthGlobalX128();
        uint256 feesBefore = vault.totalFeesOwedX128();
        uint256 vaultBalBefore = mockUsdc.balanceOf(address(vault));

        vm.prank(operatorAddr);
        vm.expectRevert(stdError.arithmeticError);
        vault.notifyFees(amount);

        assertEq(vault.feeGrowthGlobalX128(), globalBefore, "feeGrowthGlobalX128 must be unchanged");
        assertEq(vault.totalFeesOwedX128(), feesBefore, "the fee total must be unchanged");
        assertEq(mockUsdc.balanceOf(address(vault)), vaultBalBefore, "no USDC pulled");
        assertEq(mockUsdc.balanceOf(operatorAddr), amount, "the Operator keeps its USDC");
    }

    // SC-COF0: one unit below the bound succeeds and credits the fee total
    function test_whenAmountIsOneBelow2Pow128ThenReportSucceeds() public {
        uint128 activeL = vault.activeLiquidity();
        uint256 amount = Q128 - 1;

        _notifyFees(vault, operatorAddr, amount);

        uint256 growth = _refMulDiv(amount, Q128, uint256(activeL));
        assertEq(vault.feeGrowthGlobalX128(), growth, "the accumulator delta");
        assertEq(vault.totalFeesOwedX128(), growth * uint256(activeL), "the fee-total credit");
    }

    // FR-TOH3: mulDiv reverts when the result would not fit in uint256.
    // This exercises the `require(prod1 < denominator)` boundary inside _mulDiv.
    // With activeLiquidity = 10e18 and amount = type(uint256).max, the result
    // (amount * 2^128 / 10e18) overflows uint256, so the require must trip.
    // The call stays unfunded: mulDiv reverts before the USDC pull runs.
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
