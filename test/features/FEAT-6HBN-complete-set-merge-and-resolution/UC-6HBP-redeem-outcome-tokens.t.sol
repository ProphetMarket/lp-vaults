// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-6HBN: Complete-Set Merge and Resolution Redemption
// UC-6HBP: Redeem Outcome Tokens After Resolution
// Integration tests for every scenario in this use case, against the real ConditionalTokens
// bytecode: the test contract is each condition's oracle, so it reports the result the way
// Prophet's Resolution.finalizePayouts does, and the Oracle's redemption runs against the
// payout the contract itself pays.
// Covers: SC-6HCD, SC-6HCE, SC-6HCF, SC-6HCG, SC-6HCH, SC-6HCI, SC-CYS6, NFR-CYS3

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for redemption scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, gives the vault
// B = 500e6 USDC, funds it with outcome tokens the way fills would, and reports the result
// through the fixture. Unless a scenario says otherwise the Oracle has wound the vault down.
// ──────────────────────────────────────────────
contract RedeemOutcomeTokensTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");
    address nobody = makeAddr("nobody");

    uint256 constant LP_PK = 0xA11CE;
    address safe;

    bytes32 marketId = bytes32(uint256(1));

    // USDC the vault holds before any redemption (B in the scenarios)
    uint256 constant VAULT_USDC = 500e6;

    event OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount);
    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event PayoutRedemption(
        address indexed redeemer,
        address indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    function setUp() public virtual {
        safe = _safeOf(vm.addr(LP_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1)));

        mockUsdc.mint(address(vault), VAULT_USDC);
    }

    /// @dev Moves YES and NO tokens into the vault, as exchange fills would.
    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    /// @dev Reports the result of the vault's condition; the question ID is the market ID.
    function _report(uint256 yesNumerator, uint256 noNumerator) internal {
        _resolve(marketId, _payouts(yesNumerator, noNumerator));
    }

    function _windDown() internal {
        vm.prank(oracleAddr);
        vault.startWindDown();
    }

    function _redeem() internal {
        vm.prank(oracleAddr);
        vault.redeemOutcomeTokens();
    }

    function _vaultYes() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.yesTokenId());
    }

    function _vaultNo() internal view returns (uint256) {
        return ctf.balanceOf(address(vault), vault.noTokenId());
    }

    function _assertSwitchOff() internal view {
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        assertEq(numYes, 0, "the YES numerator must stay zero");
        assertEq(numNo, 0, "the NO numerator must stay zero");
    }

    /// @dev Counts the logs of one event selector from one emitter in a recorded window.
    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == selector) n++;
        }
    }
}

// ──────────────────────────────────────────────
// SC-6HCD: Oracle redeems after YES wins
// What: With payouts [1, 0] reported, the vault in WindDown holding 100 YES and 60 NO,
//       redeemOutcomeTokens stores (1, 0), burns both balances, and the ConditionalTokens
//       contract pays 100 × 1 ÷ 1 + 60 × 0 ÷ 1 = 100 USDC to the vault.
// Why:  After resolution the tokens have a fixed value, USDC is what exits pay, and the
//       stored payout is what every later burn reads (ADR-6HCK).
// Example: vault 100e6 YES, 60e6 NO, 500e6 USDC → Oracle redeems → 0, 0, 600e6 USDC.
// ──────────────────────────────────────────────
contract RedeemAfterYesWinsTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(100e6, 60e6);
        _report(1, 0);
        _windDown();
    }

    // SC-6HCD: the vault holds 0 YES, 0 NO, and B + 100 USDC
    function test_redeemsBothBalancesAtTheWinningPayout() public {
        _redeem();

        assertEq(_vaultYes(), 0, "every YES must be redeemed");
        assertEq(_vaultNo(), 0, "every NO must be redeemed");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 100e6, "the vault gains 100 USDC");
    }

    // SC-6HCD: payoutNumerators() returns (1, 0) and the phase stays WindDown
    function test_storesTheReportedNumeratorsAndKeepsThePhase() public {
        _redeem();

        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        assertEq(numYes, 1, "the YES numerator is the reported 1");
        assertEq(numNo, 0, "the NO numerator is the reported 0");
        assertEq(vault.phase(), 2, "the phase stays WindDown");
    }

    // SC-6HCD: OutcomeTokensRedeemed(oracle, 100e6, 60e6, 100e6)
    function test_emitsOutcomeTokensRedeemedWithTheOracleAndTheAmounts() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(oracleAddr, 100e6, 60e6, 100e6);

        _redeem();
    }

    // SC-6HCD: the ConditionalTokens contract emits PayoutRedemption to the vault for [1, 2]
    function test_conditionalTokensEmitsPayoutRedemption() public {
        vm.expectEmit(true, true, true, true, address(ctf));
        emit PayoutRedemption(
            address(vault), address(mockUsdc), bytes32(0), vault.conditionId(), _binaryPartition(), 100e6
        );

        _redeem();
    }

    // SC-6HCD: no CompleteSetsMerged, and lastOperatorActivityTimestamp unchanged
    function test_mergesNothingAndRefreshesNoHeartbeat() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 1 days);

        vm.recordLogs();
        _redeem();

        assertEq(_countLogs(vm.getRecordedLogs(), address(vault), CompleteSetsMerged.selector), 0, "no merge event");
        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "the Oracle's call is not Operator activity");
    }

    // SC-6HCD: the caller receives nothing; the ConditionalTokens contract pays its caller, the vault
    function test_oracleReceivesNothing() public {
        _redeem();

        assertEq(mockUsdc.balanceOf(oracleAddr), 0, "the Oracle must receive no USDC");
    }
}

// ──────────────────────────────────────────────
// SC-6HCE: Oracle redeems after a cancelled market
// What: With payouts [1, 1], each token pays 0.5 USDC: 100 YES and 60 NO redeem for
//       50 + 30 = 80 USDC, and the vault stores (1, 1).
// Why:  The half-payout case Prophet's Resolution.sol allows.
// ──────────────────────────────────────────────
contract RedeemAfterCancelledMarketTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(100e6, 60e6);
        _report(1, 1);
        _windDown();
    }

    // SC-6HCE: the vault holds 0 YES, 0 NO, and B + 80 USDC, and payoutNumerators() returns (1, 1)
    function test_redeemsAtHalfAndStoresBothNumerators() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(oracleAddr, 100e6, 60e6, 80e6);

        _redeem();

        assertEq(_vaultYes(), 0, "every YES must be redeemed");
        assertEq(_vaultNo(), 0, "every NO must be redeemed");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 80e6, "the vault gains 80 USDC");
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        assertEq(numYes, 1, "the YES numerator is 1");
        assertEq(numNo, 1, "the NO numerator is 1");
    }
}

// ──────────────────────────────────────────────
// SC-6HCF: Redemption reverts before the result exists
// What: While payoutDenominator(conditionId) is 0, redeemOutcomeTokens reverts with
//       MarketNotResolved, balances do not change, and the switch stays off.
// Why:  The vault trusts only the ConditionalTokens contract for the result, and names
//       the cause itself instead of surfacing the contract's string.
// ──────────────────────────────────────────────
contract RedeemBeforeResultTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(100e6, 60e6);
        _windDown();
    }

    // SC-6HCF: revert MarketNotResolved, nothing changes
    function test_revertsMarketNotResolvedAndChangesNothing() public {
        vm.expectRevert(LPVault.MarketNotResolved.selector);
        _redeem();

        assertEq(_vaultYes(), 100e6, "the YES balance must not change");
        assertEq(_vaultNo(), 60e6, "the NO balance must not change");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC, "the USDC balance must not change");
        _assertSwitchOff();
    }
}

// ──────────────────────────────────────────────
// SC-6HCG: Non-Oracle callers cannot redeem
// What: With the result reported and the phase WindDown, the Operator, an Admin, an LP's
//       Safe, and an address with no role each revert NotOracle.
// Why:  Lifecycle actions belong to the Oracle, and the switch changes the ratio shape for
//       every LP. Oracle and Operator are separate accounts (CLAUDE.md hard rules).
// ──────────────────────────────────────────────
contract RedeemNonOracleTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(100e6, 60e6);
        _report(1, 0);
        _windDown();
    }

    function _expectNotOracle(address caller) internal {
        vm.expectRevert(LPVault.NotOracle.selector);
        vm.prank(caller);
        vault.redeemOutcomeTokens();
    }

    // SC-6HCG: the Operator
    function test_operatorCannotRedeem() public {
        _expectNotOracle(operatorAddr);
        assertEq(_vaultYes(), 100e6, "nothing changes");
        _assertSwitchOff();
    }

    // SC-6HCG: an Admin
    function test_adminCannotRedeem() public {
        _expectNotOracle(admin);
        assertEq(_vaultYes(), 100e6, "nothing changes");
    }

    // SC-6HCG: an LP's Safe
    function test_safeCannotRedeem() public {
        _expectNotOracle(safe);
        assertEq(_vaultYes(), 100e6, "nothing changes");
    }

    // SC-6HCG: an address with no role
    function test_walletWithNoRoleCannotRedeem() public {
        _expectNotOracle(nobody);
        assertEq(_vaultYes(), 100e6, "nothing changes");
    }
}

// ──────────────────────────────────────────────
// SC-6HCH: Redemption reverts while Active and runs again in WindDown
// What: With [1, 0] reported and 10 YES held, the call reverts VaultStillActive while
//       Active; after startWindDown it redeems the 10 YES; a second call with nothing to
//       redeem makes no redeemPositions call and emits nothing; 5 YES that arrive later
//       are redeemed by a third call.
// Why:  updateTick and mintPositionFor revert in WindDown, so once the switch is on no
//       tick report can move value between claims that are now fixed USDC (FR-6HC7).
// ──────────────────────────────────────────────
contract RedeemPhaseAndRepeatTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(10e6, 0);
        _report(1, 0);
    }

    // SC-6HCH: the first call, while Active, reverts VaultStillActive and changes nothing
    function test_revertsVaultStillActiveWhileActive() public {
        vm.expectRevert(LPVault.VaultStillActive.selector);
        _redeem();

        assertEq(_vaultYes(), 10e6, "nothing changes");
        _assertSwitchOff();
    }

    // SC-6HCH: the same call succeeds after startWindDown and redeems the 10 YES
    function test_succeedsAfterWindDown() public {
        _windDown();

        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(oracleAddr, 10e6, 0, 10e6);
        _redeem();

        assertEq(_vaultYes(), 0, "the 10 YES are redeemed");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 10e6, "the vault gains 10 USDC");
        assertEq(vault.phase(), 2, "the phase stays WindDown");
    }

    // SC-6HCH: a repeat with nothing to redeem makes no redeemPositions call and emits nothing
    function test_repeatWithNothingToRedeemMakesNoCallAndEmitsNothing() public {
        _windDown();
        _redeem();

        vm.recordLogs();
        _redeem();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "no event from the vault or the ConditionalTokens contract");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 10e6, "no USDC moves");
    }

    // SC-6HCH: tokens that arrive after a redemption are redeemed by the next call
    function test_lateTokensAreRedeemedByTheNextCall() public {
        _windDown();
        _redeem();
        _fundVault(5e6, 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(oracleAddr, 5e6, 0, 5e6);
        vm.recordLogs();
        _redeem();

        assertEq(_countLogs(vm.getRecordedLogs(), address(ctf), PayoutRedemption.selector), 1, "one redemption");
        assertEq(_vaultYes(), 0, "the late YES are redeemed");
        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 15e6, "the vault gains 5 more USDC");
    }

    // SC-6HCH: the redemption works while trading is paused
    function test_worksWhilePaused() public {
        _windDown();
        vm.prank(admin);
        vault.pauseTrading();

        _redeem();

        assertEq(_vaultYes(), 0, "the pause does not stop the redemption");
    }
}

// ──────────────────────────────────────────────
// SC-6HCI: Redemption works after an emergency cancel
// What: With the vault frozen by a real emergencyCancelAll after the timelock, the
//       result [1, 0] reported, and 10 YES held, the redemption pays 10 USDC, stores
//       (1, 0), and the phase stays Cancelled.
// Why:  R10 made every exit work in every phase (decision C9), and the freeze must not
//       stop the switch.
// ──────────────────────────────────────────────
contract RedeemAfterEmergencyCancelTest is RedeemOutcomeTokensTestBase {
    function setUp() public override {
        super.setUp();
        _fundVault(10e6, 0);
        _report(1, 0);
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vm.prank(nobody);
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: the vault is frozen");
    }

    // SC-6HCI: the vault gains 10 USDC, stores the payout, and stays Cancelled
    function test_redeemsInTheCancelledPhase() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit OutcomeTokensRedeemed(oracleAddr, 10e6, 0, 10e6);

        _redeem();

        assertEq(mockUsdc.balanceOf(address(vault)), VAULT_USDC + 10e6, "the vault gains 10 USDC");
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        assertEq(numYes, 1, "the YES numerator is stored");
        assertEq(numNo, 0, "the NO numerator is stored");
        assertEq(vault.phase(), 3, "the phase stays Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-CYS6: A numerator above 2^128 leaves the switch off
// What: A condition whose oracle reported [2^128, 0]: the redemption reverts
//       SafeCastOverflow through the inline _toUint128, the stored payout stays (0, 0),
//       and a burn still pays the band's 10 YES in kind.
// Why:  CLAUDE.md item 3 makes the inline SafeCast the designed behavior, and the
//       permanent state is safe: every exit keeps working without the switch. Prophet's
//       Resolution.sol reports only [1, 0], [0, 1], and [1, 1], so the path is unreachable
//       in production.
// Example: 100 USDC over [5500, 6500) minted at 6000, the vault at 5900: liquidity 1e23,
//          the YES band [5900, 6000) holds 1e23 × 100 / 1e18 = 10e6 units, 10 YES.
// ──────────────────────────────────────────────
contract RedeemNumeratorOverflowTest is RedeemOutcomeTokensTestBase {
    uint256 positionId;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    function setUp() public override {
        super.setUp();
        vm.prank(operatorAddr);
        vault.updateTick(6000);
        positionId = _escrowAndMint(vault, operatorAddr, LP_PK, 5500, 6500, 100e6, keccak256("overflow"));
        vm.prank(operatorAddr);
        vault.updateTick(5900);
        _fundVault(10e6, 0);
        _report(2 ** 128, 0);
        _windDown();
    }

    // SC-CYS6: the call reverts SafeCastOverflow and the switch stays off
    function test_revertsSafeCastOverflowAndLeavesTheSwitchOff() public {
        vm.recordLogs();
        vm.expectRevert(LPVault.SafeCastOverflow.selector);
        _redeem();

        assertEq(vm.getRecordedLogs().length, 0, "no event, no redeemPositions call");
        _assertSwitchOff();
        assertEq(_vaultYes(), 10e6, "the 10 YES stay in the vault");
    }

    // SC-CYS6: the burn pays the 10 YES in kind
    function test_burnPaysTheTokenInKind() public {
        vm.expectRevert(LPVault.SafeCastOverflow.selector);
        _redeem();

        vm.expectEmit(true, true, true, true, address(ctf));
        emit TransferSingle(address(vault), address(vault), safe, vault.yesTokenId(), 10e6);
        vm.prank(safe);
        vault.burnPosition(positionId);

        assertEq(ctf.balanceOf(safe, vault.yesTokenId()), 10e6, "the Safe receives the 10 YES");
        assertEq(_vaultYes(), 0, "the vault holds no YES after the burn");
    }
}

// ──────────────────────────────────────────────
// NFR-CYS3: the Oracle's first redemption, with both tokens held and the payout to store,
//           stays under 180,000 call gas measured cold
// ──────────────────────────────────────────────
contract RedeemGasTest is RedeemOutcomeTokensTestBase {
    // NFR-CYS3: measured cold, as the other gas bounds are. The bound describes the optimized
    // bytecode that deploys (ADR-9FOM in FEAT-J92H); `forge coverage` compiles with the
    // optimizer off, so the test is skipped there and asserted under `forge test`.
    function test_firstRedemptionWithBothTokensStaysUnderBound() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
        _fundVault(90e6, 40e6);
        _report(1, 0);
        _windDown();
        vm.cool(address(vault));
        vm.cool(address(factory));
        vm.cool(address(mockUsdc));
        vm.cool(address(ctf));

        vm.prank(oracleAddr);
        uint256 before = gasleft();
        vault.redeemOutcomeTokens();
        uint256 used = before - gasleft();

        assertLt(used, 180_000, "the first redemption must stay under the NFR-CYS3 bound");
        assertEq(_vaultYes(), 0, "the redemption ran");
    }
}
