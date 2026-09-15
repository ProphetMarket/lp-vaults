// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-7G40: Burn LP Position
// UC-7G41: Burn Position
// Integration tests for every scenario in this use case, against the real ConditionalTokens
// bytecode: the claim model of decision C26, the merge-first rule, the pro-rata rule of
// decision O2 (FEAT-9BQZ), the tick deinitialization that closes audit issue 6.15, and the
// resolved branch after the Oracle's redemption (FEAT-6HBN, the switch).
// Covers: SC-7G43, SC-7G44, SC-7G45, SC-7G47, SC-7G48, SC-7G49, SC-7G4A, SC-7G4B, SC-BMF1,
//         SC-BMF2, SC-BMF3, SC-CYS7, SC-CYS8, SC-CYS9, SC-CYSA, SC-DFDX, SC-DYNJ

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault, IConditionalTokens} from "../../../src/LPVault.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {KeeperFillFixture} from "../../fixtures/KeeperFillFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Base test contract for burn scenarios.
// Deploys the factory and a vault on the real ConditionalTokens contract, reports tick
// 6000, and mints the worked example of decision C26: 300 USDC over [5500, 6500), so
// liquidity = 300e6 * 1e18 / 1000 = 3e23 and mintTick = 6000. USDC has six decimals in
// every amount below.
// ──────────────────────────────────────────────
contract BurnPositionTestBase is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant LP_PK = 0xA11CE;
    address safe;
    uint256 constant LP_B_PK = 0xB0B;
    address safeB;

    bytes32 marketId = bytes32(uint256(1));

    // The worked example
    int24 constant LOWER = 5500;
    int24 constant UPPER = 6500;
    int24 constant MINT_TICK = 6000;
    uint256 constant PRINCIPAL = 300e6;
    uint128 constant LIQUIDITY = 3e23;
    // The vault at 5700: the YES band [5700, 6000), 90 YES, and the USDC the band did not spend
    uint256 constant FELL_USDC = 247_354_500;
    // The vault at 6300: the NO band [6000, 6300), 90 NO
    uint256 constant ROSE_USDC = 265_345_500;
    // An outcome token has USDC's six decimals: 90 tokens are 90e6 units, worth 90 USDC at par
    uint256 constant BAND_TOKENS = 90e6;
    // What the band's fills spent on the 90 YES: the deposit less the claim's USDC at 5700
    uint256 constant BAND_SPENT = PRINCIPAL - FELL_USDC;
    // What the band's fills spent on the 90 NO after a rise to 6300
    uint256 constant ROSE_SPENT = PRINCIPAL - ROSE_USDC;

    uint256 positionId;

    event PositionBurned(
        uint256 indexed positionId,
        address indexed owner,
        uint256 usdcOwed,
        uint256 usdcPaid,
        uint256 spreadOwed,
        uint256 spreadPaid,
        uint256 tokenId,
        uint256 tokenOwed,
        uint256 tokenPaid
    );
    event CompleteSetsMerged(address indexed caller, uint256 amount);
    event SpreadCredited(uint256 amount, uint256 spreadGrowthGlobalX128);
    event ResidueSwept(
        uint256 indexed positionId, address indexed owner, uint256 usdcResidue, uint256 yesResidue, uint256 noResidue
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TickUpdated(int24 indexed oldTick, int24 indexed newTick, uint256 ticksCrossed);
    event OutcomeTokensRedeemed(address indexed caller, uint256 yesAmount, uint256 noAmount, uint256 usdcAmount);
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
        safeB = _safeOf(vm.addr(LP_B_PK));

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1)));

        _moveTick(MINT_TICK);
        positionId = _mintExample(LP_PK, keccak256("example"));
    }

    /// @dev Mints the worked example for the owner key `pk`.
    function _mintExample(uint256 pk, bytes32 intentId) internal returns (uint256) {
        return _escrowAndMint(vault, operatorAddr, pk, LOWER, UPPER, PRINCIPAL, intentId);
    }

    function _moveTick(int24 tick) internal {
        vm.prank(operatorAddr);
        vault.updateTick(tick);
    }

    /// @dev Gives the vault outcome tokens, as the keeper's fills would.
    function _fundVault(uint256 yesAmount, uint256 noAmount) internal {
        _giveOutcomeTokens(address(vault), vault.conditionId(), yesAmount, noAmount);
    }

    /// @dev Moves USDC out of the vault through the exchange's standing approval, as a fill
    ///      would (decision C8). This is how a test makes the vault short.
    function _drainThroughExchange(uint256 amount) internal {
        vm.prank(exchangeAddr);
        assertTrue(mockUsdc.transferFrom(address(vault), exchangeAddr, amount), "the fill should spend");
    }

    function _yesOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.yesTokenId());
    }

    function _noOf(address who) internal view returns (uint256) {
        return ctf.balanceOf(who, vault.noTokenId());
    }

    function _burn(uint256 id) internal {
        vm.prank(safe);
        vault.burnPosition(id);
    }

    /// @dev Reports the result, winds the vault down, and has the Oracle redeem: the switch
    ///      (FEAT-6HBN UC-6HBP). The question ID of the vault's condition is the market ID.
    function _resolveAndRedeem(uint256 yesNumerator, uint256 noNumerator) internal {
        _resolve(marketId, _payouts(yesNumerator, noNumerator));
        vm.prank(oracleAddr);
        vault.startWindDown();
        vm.prank(oracleAddr);
        vault.redeemOutcomeTokens();
    }

    /// @dev Counts the logs of one event selector from one emitter in a recorded window.
    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == selector) n++;
        }
    }

    function _bitIsSet(int24 tick) internal view returns (bool) {
        // casting to 'int16' is safe because an int24 shifted right by 8 fits in 16 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        int16 wordPos = int16(tick >> 8);
        // casting to 'uint24' then 'uint8' is safe because the mask keeps eight bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 bitPos = uint8(uint24(tick) & 0xff);
        return (vault.tickBitmap(wordPos) >> bitPos) & 1 == 1;
    }

    function _assertDeleted(uint256 id) internal view {
        (address owner, int24 tl, int24 tu, int24 mt, uint128 liq,) = vault.positions(id);
        assertEq(owner, address(0), "owner should be zero");
        assertEq(tl, 0, "tickLower should be zero");
        assertEq(tu, 0, "tickUpper should be zero");
        assertEq(mt, 0, "mintTick should be zero");
        assertEq(liq, 0, "liquidity should be zero");
    }

    /// @dev The one PositionBurned log of a burn, decoded.
    function _burnedLog(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 usdcOwed, uint256 usdcPaid, uint256 tokenId, uint256 tokenOwed, uint256 tokenPaid)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PositionBurned.selector) {
                // Seven non-indexed fields since R18: the two spread legs sit after usdcPaid
                (usdcOwed, usdcPaid,,, tokenId, tokenOwed, tokenPaid) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return (usdcOwed, usdcPaid, tokenId, tokenOwed, tokenPaid);
            }
        }
        revert("a burn must emit PositionBurned");
    }
}

// ──────────────────────────────────────────────
// SC-7G43: Burn at the mint tick pays the whole principal in USDC
// What: With the vault at the mint tick, the burn pays 300 USDC, no token, deletes the
//       record, removes the liquidity from both ticks and from activeLiquidity, and
//       leaves the heartbeat alone.
// Why:  No level was crossed, so every level still holds its USDC. This is the base
//       case of the claim model and the parity anchor for the relayed path.
// ──────────────────────────────────────────────
contract BurnAtMintTickTest is BurnPositionTestBase {
    // SC-7G43: the Safe receives exactly 300 USDC and no token
    function test_whenAtMintTickThenSafeReceivesWholePrincipal() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe should receive 300 USDC");
        assertEq(_yesOf(safe), 0, "no YES");
        assertEq(_noOf(safe), 0, "no NO");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault paid everything it held");
    }

    // SC-7G43: PositionBurned carries the exact amounts, with tokenId zero
    function test_whenAtMintTickThenEventCarriesUsdcOnly() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0, 0, 0);

        _burn(positionId);
    }

    // SC-7G43: the record is deleted and cannot be burned again
    function test_whenBurnedThenRecordIsDeleted() public {
        _burn(positionId);

        _assertDeleted(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(positionId);
    }

    // SC-7G43: both ticks lose the liquidity, and activeLiquidity falls by it
    function test_whenBurnedThenTicksAndActiveLiquidityFall() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY, "precondition: in range");

        _burn(positionId);

        (uint128 gLower, int128 nLower,,) = vault.ticks(LOWER);
        (uint128 gUpper, int128 nUpper,,) = vault.ticks(UPPER);
        assertEq(gLower, 0, "tick 5500 liquidityGross");
        assertEq(nLower, 0, "tick 5500 liquidityNet");
        assertEq(gUpper, 0, "tick 6500 liquidityGross");
        assertEq(nUpper, 0, "tick 6500 liquidityNet");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should fall by the position's liquidity");
    }

    // SC-7G43: the self-service burn never refreshes the heartbeat
    function test_whenBurnedThenHeartbeatIsUnchanged() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 3 days);

        _burn(positionId);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "burnPosition must not touch the heartbeat");
    }

    // SC-7G43: no ERC-1155 transfer and no merge when the vault holds no token
    function test_whenAtMintTickThenNoTokenTransferAndNoMerge() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != TransferSingle.selector, "no ERC-1155 transfer");
            assertTrue(logs[i].topics[0] != CompleteSetsMerged.selector, "no merge");
        }
    }

    // FR-7G4T: the burned id is never reassigned
    function test_whenBurnedThenIdIsRetired() public {
        _burn(positionId);

        uint256 nextId = _mintExample(LP_B_PK, keccak256("after-burn"));
        assertEq(nextId, positionId + 1, "a later mint draws the next id, never the burned one");
    }
}

// ──────────────────────────────────────────────
// SC-7G44: Burn after the price fell pays USDC plus YES
// What: The vault moved to 5700, so the YES band is [5700, 6000): 90 YES, and
//       3e23 * (1000 * 10000 - 1,754,850) / 1e22 = 247,354,500 USDC units.
// Why:  Below the mint tick a level bought YES at its own price when the price fell
//       through it. The vault spent 52.6455 USDC on 90 YES, an average of 0.585.
// ──────────────────────────────────────────────
contract BurnAfterPriceFellTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(5700);
        // The fill bought the 90 YES and spent the USDC the claim no longer names, so the vault
        // holds exactly what the ledger owes and nothing is creditable as spread (FEAT-E943)
        _fundVault(BAND_TOKENS, 0);
        _drainThroughExchange(BAND_SPENT);
    }

    // SC-7G44: the Safe receives 247.3545 USDC and 90 YES
    function test_whenPriceFellThenSafeReceivesUsdcPlusYes() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the USDC leg");
        assertEq(_yesOf(safe), BAND_TOKENS, "the YES leg");
        assertEq(_noOf(safe), 0, "no NO");
    }

    // SC-7G44: PositionBurned names the YES token and the exact amounts
    function test_whenPriceFellThenEventNamesYes() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, 0, 0, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);

        _burn(positionId);
    }

    // NFR-7G59: the ERC-1155 transfer is the last external call, after the USDC transfer
    function test_whenPriceFellThenTokenTransferIsLast() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 usdcAt = type(uint256).max;
        uint256 tokenAt = type(uint256).max;
        uint256 burnedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Transfer.selector && logs[i].emitter == address(mockUsdc)) usdcAt = i;
            if (logs[i].topics[0] == TransferSingle.selector) tokenAt = i;
            if (logs[i].topics[0] == PositionBurned.selector) burnedAt = i;
        }
        assertLt(usdcAt, tokenAt, "USDC before the token");
        assertLt(tokenAt, burnedAt, "the token before the event");
    }

    // FR-7G4N: no call reaches the exchange
    function test_whenPriceFellThenExchangeIsNeverCalled() public {
        uint256 exchangeBefore = mockUsdc.balanceOf(exchangeAddr);
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(exchangeAddr), exchangeBefore, "the exchange is not part of a burn");
        assertEq(exchangeAddr.code.length, 0, "the exchange stub has no code, so any call would revert");
    }
}

// ──────────────────────────────────────────────
// SC-7G45: Burn after the price rose pays USDC plus NO
// What: The vault moved to 6300, so the NO band is [6000, 6300): 90 NO, and
//       3e23 * (700 * 10000 + 1,844,850) / 1e22 = 265,345,500 USDC units.
// Why:  At or above the mint tick a level bought NO at one minus its price when the
//       price rose through it. The vault spent 34.6545 USDC on 90 NO, an average NO
//       price of 0.38505.
// ──────────────────────────────────────────────
contract BurnAfterPriceRoseTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        _moveTick(6300);
        // The fill bought the 90 NO and spent 34.6545 USDC, so the vault holds exactly what the
        // ledger owes and nothing is creditable as spread (FEAT-E943)
        _fundVault(0, BAND_TOKENS);
        _drainThroughExchange(ROSE_SPENT);
    }

    // SC-7G45: the Safe receives 265.3455 USDC and 90 NO
    function test_whenPriceRoseThenSafeReceivesUsdcPlusNo() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), ROSE_USDC, "the USDC leg");
        assertEq(_noOf(safe), BAND_TOKENS, "the NO leg");
        assertEq(_yesOf(safe), 0, "no YES");
    }

    // SC-7G45: PositionBurned names the NO token and the exact amounts
    function test_whenPriceRoseThenEventNamesNo() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, ROSE_USDC, ROSE_USDC, 0, 0, vault.noTokenId(), BAND_TOKENS, BAND_TOKENS);

        _burn(positionId);
    }

    // FR-7G4Q: at 6300 the position is in range, so activeLiquidity falls
    function test_whenPriceRoseThenActiveLiquidityFalls() public {
        assertEq(vault.activeLiquidity(), LIQUIDITY, "precondition: in range at 6300");
        _burn(positionId);
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity should fall by the position's liquidity");
    }
}

// ──────────────────────────────────────────────
// SC-7G47: Burning the last position at a tick deinitializes it
// What: Safe B holds [5500, 6000), so tick 5500 stays referenced and tick 6500 is
//       referenced only by the example. After the burn, ticks[6500] reads zero and its
//       bitmap bit is clear; ticks[5500] keeps its record and its bit. A later move from
//       6400 to 6600 crosses nothing.
// Why:  Audit issue 6.15: a set bit must mean liquidityGross > 0, or updateTick would
//       cross a tick with no liquidity behind it.
// ──────────────────────────────────────────────
contract BurnDeinitializesTickTest is BurnPositionTestBase {
    uint256 positionB;

    function setUp() public override {
        super.setUp();
        positionB = _escrowAndMint(vault, operatorAddr, LP_B_PK, LOWER, MINT_TICK, 100e6, keccak256("b"));
        assertTrue(_bitIsSet(UPPER), "precondition: tick 6500 is set");
        assertTrue(_bitIsSet(LOWER), "precondition: tick 5500 is set");
    }

    // SC-7G47: tick 6500 is deleted and its bit cleared
    function test_whenLastReferenceBurnsThenTickIsDeinitialized() public {
        _burn(positionId);

        (uint128 gross, int128 net,,) = vault.ticks(UPPER);
        assertEq(gross, 0, "tick 6500 liquidityGross");
        assertEq(net, 0, "tick 6500 liquidityNet");
        assertFalse(_bitIsSet(UPPER), "tick 6500 bit must be clear");
    }

    // SC-7G47: tick 5500 keeps its bit and its net
    function test_whenAnotherReferenceRemainsThenTickIsPreserved() public {
        (uint128 grossBefore, int128 netBefore,,) = vault.ticks(LOWER);

        _burn(positionId);

        (uint128 gross, int128 net,,) = vault.ticks(LOWER);
        assertEq(gross, grossBefore - LIQUIDITY, "tick 5500 liquidityGross decreased by the example's liquidity");
        // casting to 'int128' is safe because LIQUIDITY is 3e23, far below the int128 maximum of about 1.7e38
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(net, netBefore - int128(LIQUIDITY), "tick 5500 liquidityNet decreased by the example's liquidity");
        assertTrue(_bitIsSet(LOWER), "tick 5500 bit must stay set");
    }

    // SC-7G47: a later updateTick across 6500 crosses nothing
    function test_whenTickIsDeinitializedThenLaterMoveCrossesNothing() public {
        _moveTick(6400);
        _burn(positionId);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(int24(6400), int24(6600), 0);
        _moveTick(6600);
    }
}

// ──────────────────────────────────────────────
// SC-7G48: Revert when the caller is not the owner
// What: Safe B, the Operator, and the Admin each revert NotPositionOwner on Safe A's
//       position, which stays live.
// Why:  Timing control (ADR-7G5I): the claim depends on currentTick at call time.
// ──────────────────────────────────────────────
contract BurnNonOwnerTest is BurnPositionTestBase {
    function _expectNotOwner(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.burnPosition(positionId);
    }

    // SC-7G48: another Safe cannot burn it
    function test_whenAnotherSafeCallsThenReverts() public {
        _expectNotOwner(safeB);
    }

    // SC-7G48: the Operator cannot burn it directly
    function test_whenOperatorCallsThenReverts() public {
        _expectNotOwner(operatorAddr);
    }

    // SC-7G48: the Admin cannot burn it
    function test_whenAdminCallsThenReverts() public {
        _expectNotOwner(admin);
    }

    // SC-7G48: the position stays live and the owner can still burn it
    function test_whenRejectedThenPositionStaysLive() public {
        _expectNotOwner(safeB);

        (,,,, uint128 liq,) = vault.positions(positionId);
        assertEq(liq, LIQUIDITY, "the position stays live");
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the owner still exits in full");
    }
}

// ──────────────────────────────────────────────
// SC-7G49: Burn in WindDown and in Cancelled succeeds identically to Active
// What: Case A: after startWindDown the burn pays the SC-7G43 amounts and the phase stays
//       WindDown. Case B: after a real emergencyCancelAll the burn pays the same amounts,
//       because the freeze keeps every record.
// Why:  Decisions C5 and C9: no phase gates the exit, and a frozen vault pays in full.
// ──────────────────────────────────────────────
contract BurnPhaseTest is BurnPositionTestBase {
    // SC-7G49: case A — the same amounts in WindDown
    function test_whenWindDownThenBurnPaysAsInActive() public {
        vm.prank(oracleAddr);
        vault.startWindDown();

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC in WindDown");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity falls as in Active");
        assertEq(vault.phase(), 2, "phase stays WindDown");
    }

    // SC-7G49: case C — the burn works while paused
    function test_whenPausedThenBurnSucceeds() public {
        vm.prank(admin);
        vault.pauseTrading();

        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC while paused");
    }

    // SC-7G49: case B — after the freeze the burn pays the SC-7G43 amounts and deletes the record
    function test_whenCancelledThenBurnPaysInFull() public {
        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vm.prank(makeAddr("anyone"));
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "precondition: Cancelled");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC after the freeze");
        assertEq(vault.activeLiquidity(), 0, "activeLiquidity falls as in Active");
        (address owner,,,, uint128 liq,) = vault.positions(positionId);
        assertEq(owner, address(0), "the record is deleted");
        assertEq(liq, 0, "the record is deleted");
        assertEq(vault.phase(), 3, "phase stays Cancelled");
    }
}

// ──────────────────────────────────────────────
// SC-7G4A: Burn succeeds with zero registered operators
// What: The Admin removes the only Operator; the Safe still burns and receives 300 USDC.
// Why:  FR-7G4Z, NFR-7G5B: the escape hatch reads no Operator state.
// ──────────────────────────────────────────────
contract BurnWithNoOperatorTest is BurnPositionTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
        assertEq(vault.operators(operatorAddr), 0, "precondition: no operator");
    }

    // SC-7G4A: the burn pays in full with no Operator
    function test_whenNoOperatorThenBurnPays() public {
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC");
        _assertDeleted(positionId);
    }

    // SC-7G4A: no heartbeat write
    function test_whenNoOperatorThenHeartbeatUnchanged() public {
        uint256 timerBefore = vault.lastOperatorActivityTimestamp();
        vm.warp(block.timestamp + 10 days);

        _burn(positionId);

        assertEq(vault.lastOperatorActivityTimestamp(), timerBefore, "no heartbeat write");
    }
}

// ──────────────────────────────────────────────
// SC-7G4B: Revert on a nonexistent, burned, or merged-away position
// What: A never-minted id, a burned id, and a position that mergePositions consumed each
//       revert PositionNotFound.
// Why:  A consumed position's liquidity already moved to a survivor; burning it would
//       touch the ticks by zero and could clear a bit the survivor needs.
// ──────────────────────────────────────────────
contract BurnNotFoundTest is BurnPositionTestBase {
    // SC-7G4B: case A — never minted
    function test_whenNeverMintedThenReverts() public {
        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(999);
    }

    // SC-7G4B: case B — already burned
    function test_whenAlreadyBurnedThenReverts() public {
        _burn(positionId);

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(positionId);
    }

    // SC-7G4B: case C — consumed by a merge, so the owner is set and the liquidity is zero
    function test_whenMergedAwayThenReverts() public {
        uint256 second = _mintExample(LP_PK, keccak256("second"));
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = second;
        vm.prank(operatorAddr);
        vault.mergePositions(ids);
        (address owner,,,, uint128 liq,) = vault.positions(second);
        assertEq(owner, safe, "precondition: the consumed record keeps its owner");
        assertEq(liq, 0, "precondition: the consumed record has zero liquidity");

        vm.prank(safe);
        vm.expectRevert(LPVault.PositionNotFound.selector);
        vault.burnPosition(second);

        // The survivor still burns for both principals, and the ticks stay consistent
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), 2 * PRINCIPAL, "the survivor pays both principals");
        assertFalse(_bitIsSet(UPPER), "the last reference cleared the bit");
    }
}

// ──────────────────────────────────────────────
// SC-BMF1: Burn merges the vault's pairs first
// What: The vault holds 50 YES and 50 NO. The burn merges them, then pays 300 USDC, so the
//       vault's USDC falls by 250 net and both token balances read zero.
//       CompleteSetsMerged(safe, 50) precedes PositionBurned in the log.
// Why:  Decision C26: a pair is worth exactly 1 USDC, and a payout turns it into USDC first.
// ──────────────────────────────────────────────
contract BurnMergesFirstTest is BurnPositionTestBase {
    uint256 constant PAIRS = 50e6;

    function setUp() public override {
        super.setUp();
        // A drift-free round trip: the vault bought the pair for exactly 1 USDC each, so it holds
        // 50 pairs and 50 USDC less, and owes exactly what it holds (FEAT-E943)
        _fundVault(PAIRS, PAIRS);
        _drainThroughExchange(PAIRS);
    }

    // SC-BMF1: the pairs are gone and the vault's USDC fell by 250 net
    function test_whenVaultHoldsPairsThenBurnMergesThem() public {
        uint256 vaultBefore = mockUsdc.balanceOf(address(vault));

        _burn(positionId);

        assertEq(_yesOf(address(vault)), 0, "no YES after the merge");
        assertEq(_noOf(address(vault)), 0, "no NO after the merge");
        assertEq(vaultBefore - mockUsdc.balanceOf(address(vault)), PRINCIPAL - PAIRS, "300 out, 50 in");
        assertEq(mockUsdc.balanceOf(safe), PRINCIPAL, "the Safe receives 300 USDC");
    }

    // SC-BMF1: CompleteSetsMerged(safe, 50) precedes PositionBurned
    function test_whenVaultHoldsPairsThenMergeLogPrecedesBurnLog() public {
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 mergedAt = type(uint256).max;
        uint256 burnedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CompleteSetsMerged.selector) {
                mergedAt = i;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), safe, "the caller is the Safe");
                assertEq(abi.decode(logs[i].data, (uint256)), PAIRS, "50 pairs merged");
            }
            if (logs[i].topics[0] == PositionBurned.selector) burnedAt = i;
        }
        assertLt(mergedAt, burnedAt, "the merge precedes the burn event");
    }
}

// ──────────────────────────────────────────────
// SC-DFDX: Two claims on opposite sides of the tick are both paid in full
// What: Safe A holds the example minted at 6000 and Safe B the same range minted at 5500.
//       Drift-free fills through the exchange approval and the receiver hook: the fall to
//       5500 bought 150 YES on A's levels for 86,242,500 units, and the rise to 5700 bought
//       60 NO on A's levels and 60 NO on B's for 52,806,000 units. The vault holds 150 YES,
//       120 NO, and 460,951,500 USDC units against 90 YES, 60 NO, and 520,951,500 owed.
//       A's burn computes 60 free pairs, merges them, and pays 247,354,500 USDC and 90 YES;
//       B's burn finds no free pair and pays 273,597,000 USDC and 60 NO. Every leg reports
//       paid == owed, and the vault ends with no token and nothing above escrow.
// Why:  Finding CV-01 of audits/code-validation-round-1.md: on the source before R14 the
//       same steps merged 120 pairs, paid A 30 YES and B 0 NO, and left 60 USDC in the vault
//       with no live position. The free pairs are read before the ledger debit, so A's own
//       band never counts as free at A's burn.
// ──────────────────────────────────────────────
contract TwoClaimsPaidInFullTest is BurnPositionTestBase, KeeperFillFixture {
    // B's claim at 5700: the NO band [5500, 5700) and the USDC the band did not spend
    uint256 constant B_USDC = 273_597_000;
    uint256 constant B_TOKENS = 60e6;
    uint256 constant FILLS_LEFT = 460_951_500;
    uint256 constant FREE_PAIRS = 60e6;

    uint256 positionB;

    function setUp() public override {
        super.setUp();
        _moveTick(5500);
        _fillMove(vault, exchangeAddr, MINT_TICK, 5500, 0);
        positionB = _mintExample(LP_B_PK, keccak256("B"));
        _moveTick(5700);
        _fillMove(vault, exchangeAddr, 5500, 5700, 0);
    }

    // SC-DFDX: the fills leave the two-claim state of the finding
    function test_theFillsLeaveTheTwoClaimState() public view {
        assertEq(_yesOf(address(vault)), 150e6, "150 YES bought on the fall");
        assertEq(_noOf(address(vault)), 120e6, "60 NO bought on each claim's levels on the rise");
        assertEq(mockUsdc.balanceOf(address(vault)), FILLS_LEFT, "the USDC the fills left");
        assertEq(vault.totalYesOwed(), BAND_TOKENS, "A's band owes 90 YES");
        assertEq(vault.totalNoOwed(), B_TOKENS, "B's band owes 60 NO");
        assertEq(vault.totalUsdcOwed(), FELL_USDC + B_USDC, "the two claims' USDC");
    }

    // SC-DFDX: A's burn merges the 60 free pairs and pays both legs in full
    function test_whenClaimsHoldBothTokensThenTheFirstBurnPaysInFull() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit CompleteSetsMerged(safe, FREE_PAIRS);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, 0, 0, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);

        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "A receives its USDC in full");
        assertEq(_yesOf(safe), BAND_TOKENS, "A receives its 90 YES in full");
        assertEq(_yesOf(address(vault)), 0, "no YES left after A's band is paid");
        assertEq(_noOf(address(vault)), B_TOKENS, "B's 60 NO stay for B");
    }

    // SC-DFDX: B's burn finds no free pair and pays both legs in full, and the vault ends empty
    function test_whenClaimsHoldBothTokensThenBothBurnsPayInFull() public {
        _burn(positionId);

        vm.recordLogs();
        vm.prank(safeB);
        vault.burnPosition(positionB);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, address(vault), CompleteSetsMerged.selector), 0, "B's burn merges nothing");
        (uint256 usdcOwed, uint256 usdcPaid, uint256 tokenId, uint256 tokenOwed, uint256 tokenPaid) = _burnedLog(logs);
        assertEq(usdcOwed, B_USDC, "B's USDC owed");
        assertEq(usdcPaid, B_USDC, "B's USDC paid in full");
        assertEq(tokenId, vault.noTokenId(), "B's band is NO");
        assertEq(tokenOwed, B_TOKENS, "B's NO owed");
        assertEq(tokenPaid, B_TOKENS, "B's NO paid in full");
        assertEq(mockUsdc.balanceOf(safeB), B_USDC, "B receives its USDC");
        assertEq(_noOf(safeB), B_TOKENS, "B receives its 60 NO");

        assertEq(_yesOf(address(vault)), 0, "the vault holds no YES");
        assertEq(_noOf(address(vault)), 0, "the vault holds no NO");
        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "nothing above escrow strands");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed() + vault.totalNoOwed(), 0, "every total is zero");
    }

    // SC-DFDX: one CompleteSetsMerged(safeA, 60) across both burns, before A's PositionBurned
    function test_whenClaimsHoldBothTokensThenOneMergePrecedesTheFirstBurnLog() public {
        vm.recordLogs();
        _burn(positionId);
        vm.prank(safeB);
        vault.burnPosition(positionB);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 mergedAt = type(uint256).max;
        uint256 firstBurnAt = type(uint256).max;
        uint256 merges;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CompleteSetsMerged.selector) {
                merges++;
                mergedAt = i;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), safe, "the caller is Safe A");
                assertEq(abi.decode(logs[i].data, (uint256)), FREE_PAIRS, "60 free pairs merged");
            }
            if (logs[i].topics[0] == PositionBurned.selector && firstBurnAt == type(uint256).max) firstBurnAt = i;
        }
        assertEq(merges, 1, "exactly one merge across both burns");
        assertLt(mergedAt, firstBurnAt, "the merge precedes A's burn event");
    }
}

// ──────────────────────────────────────────────
// SC-DYNJ: Burn inside the report window takes its share of the cut and leaves the fill's tokens
// What: The keeper filled the move from 6000 to 5700 and has not reported it, so the ledger
//       still values the claim at the mint tick: 300 USDC and no band. Case A, one claim:
//       the fill spent 52,645,500 units and left 90 YES; the burn pays 300 USDC times the
//       USDC ratio, 247,354,500 units and no token, debits the full 300, and leaves the 90
//       YES with every total at zero. Case B, two claims: Safe B holds 300 USDC over
//       [5000, 6200) minted at 6000; the fill spent 96,516,750 units and left 165 YES; A's
//       burn pays 251,741,625 units; the report of 5700 re-values B at 256,128,750 units
//       plus 75 YES; B's burn pays 251,741,625 units plus 75 YES, and 90 YES stay with no
//       claim.
// Why:  Finding CV-08 of audits/code-validation-round-1.md, kept by decision on 2026-09-14
//       (C8, O2, ADR-DYNK): a burn is valued at the last reported tick, and the pooled ratio
//       spreads every unreported fill over every claim. SC-BMF2 case A already models a short
//       vault with a drained balance; this one shows what it does not: the ledger still at
//       the mint tick with 90 YES held, no merge, and the tokens left with every total at
//       zero.
// Setup: KeeperFillFixture._fillMove models the fill, after B's mint in case B, and
//        _moveTick is never called before the first burn.
// ──────────────────────────────────────────────
contract BurnInsideReportWindowTest is BurnPositionTestBase, KeeperFillFixture {
    // Case B: Safe B's range and liquidity, what the fill spent on both claims' levels, the
    // pooled payout both burns receive, and B's claim once the report lands
    int24 constant B_LOWER = 5000;
    int24 constant B_UPPER = 6200;
    uint256 constant B_TOKENS = 75e6;
    uint256 constant TWO_CLAIM_SPENT = 96_516_750;
    uint256 constant POOLED_PAID = 251_741_625;
    uint256 constant B_USDC_AFTER_REPORT = 256_128_750;

    // SC-DYNJ: case A — the read, the pooled payout, no token, and the tokens left with no claim
    function test_whenFillIsUnreportedThenBurnPaysItsShareAndLeavesTheTokens() public {
        _fillMove(vault, exchangeAddr, MINT_TICK, 5700, 0);
        assertEq(mockUsdc.balanceOf(address(vault)), FELL_USDC, "the fill spent 52,645,500 units");
        // The read the NatSpec names: a balance above the owed total is an unreported fill
        assertEq(vault.totalYesOwed(), 0, "the ledger owes no YES before the report");
        assertEq(_yesOf(address(vault)), BAND_TOKENS, "the vault holds the 90 YES the fill bought");
        assertEq(vault.totalUsdcOwed(), PRINCIPAL, "the claim is still valued at the mint tick");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, FELL_USDC, 0, 0, 0, 0, 0);
        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "300 USDC times the USDC ratio");
        // The claim holds no band at the mint tick, so PositionBurned reports no token leg. Since
        // R18 the 90 YES the fill bought reach this position anyway, through the closing sweep:
        // it is the last live position, and the tokens belong to no other claim (FEAT-E943
        // FR-E94C). Before R18 they stayed in the vault with no owner.
        assertEq(_yesOf(safe), BAND_TOKENS, "the fill's tokens reach the last live position");
        assertEq(_countLogs(logs, address(vault), CompleteSetsMerged.selector), 0, "no merge: the vault holds no NO");
        assertEq(
            _countLogs(logs, address(vault), SpreadCredited.selector), 0, "no credit: the vault is below what it owes"
        );
        assertEq(_yesOf(address(vault)), 0, "the vault keeps no YES");
        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "nothing above escrow");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed() + vault.totalNoOwed(), 0, "every total is zero");
        _assertDeleted(positionId);
    }

    // SC-DYNJ: case B — the leaver's pooled cut, the report, and the stayer's cut after it
    function test_whenTwoClaimsShareTheUnreportedFillThenTheStayerTakesTheRest() public {
        uint256 positionB = _escrowAndMint(vault, operatorAddr, LP_B_PK, B_LOWER, B_UPPER, PRINCIPAL, keccak256("B"));
        _fillMove(vault, exchangeAddr, MINT_TICK, 5700, 0);
        assertEq(mockUsdc.balanceOf(address(vault)), 2 * PRINCIPAL - TWO_CLAIM_SPENT, "the fill spent 96,516,750 units");
        assertEq(_yesOf(address(vault)), BAND_TOKENS + B_TOKENS, "165 YES bought on both claims' levels");
        assertEq(vault.totalUsdcOwed(), 2 * PRINCIPAL, "both claims still valued at their mint tick");

        // The leaver: 300 USDC times the pooled ratio, a cut smaller than its own fill's spend
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, POOLED_PAID, 0, 0, 0, 0, 0);
        _burn(positionId);
        assertEq(mockUsdc.balanceOf(safe), POOLED_PAID, "A's pooled cut");
        assertEq(_yesOf(safe), 0, "A receives no token");
        assertLt(PRINCIPAL - POOLED_PAID, BAND_SPENT, "A's cut is less than A's own fill");

        // The report crosses B's interior mint tick and re-values B: the YES band [5700, 6000)
        vm.expectEmit(true, true, false, true, address(vault));
        emit TickUpdated(MINT_TICK, 5700, 1);
        _moveTick(5700);
        assertEq(vault.totalUsdcOwed(), B_USDC_AFTER_REPORT, "B's USDC after the report");
        assertEq(vault.totalYesOwed(), B_TOKENS, "B's 75 YES after the report");

        // The stayer: its USDC at the ratio A's cut left, and its YES in full
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(
            positionB, safeB, B_USDC_AFTER_REPORT, POOLED_PAID, 0, 0, vault.yesTokenId(), B_TOKENS, B_TOKENS
        );
        vm.prank(safeB);
        vault.burnPosition(positionB);
        assertEq(mockUsdc.balanceOf(safeB), POOLED_PAID, "B receives what A's cut left");
        assertEq(
            B_USDC_AFTER_REPORT - POOLED_PAID,
            BAND_SPENT - (PRINCIPAL - POOLED_PAID),
            "B's cut is the part of A's fill that A's cut did not cover"
        );
        // B is the last live position, so the sweep adds the 90 YES A forfeited to its 75
        // (FEAT-E943 FR-E94C). Before R18 those 90 stayed in the vault with no owner.
        assertEq(_yesOf(safeB), B_TOKENS + BAND_TOKENS, "B receives its 75 YES and the 90 A forfeited");

        assertEq(_yesOf(address(vault)), 0, "the vault keeps no YES: the sweep took the last of them");
        assertEq(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "nothing above escrow");
        assertEq(vault.totalUsdcOwed() + vault.totalYesOwed() + vault.totalNoOwed(), 0, "every total is zero");
    }
}

// ──────────────────────────────────────────────
// SC-BMF2: Burn pays its share when the vault is short
// What: Case A: the claim is 247.3545 USDC plus 90 YES, the vault holds 200 USDC and 60
//       YES; with this one claim each ratio is what is held over what is owed, so the burn
//       pays 200 and 60, emits owed and paid, deletes the record, and debits the totals by
//       the full claim. Case B: the vault's USDC balance is below totalEscrowed; the burn
//       pays zero USDC and does not revert. Case C: a vault richer than the claim pays the
//       claim exactly.
// Why:  Decisions C6, C7, and O2 (FR-COEX, FEAT-9BQZ FR-9BRM to FR-9BRR). A checked
//       subtraction would revert every exit once a fill took the balance below the escrow
//       total, and a debit by the paid amount would leave a phantom claim in the ledger.
// Setup: the exchange's standing approval moves USDC out of the vault, as a fill would.
// ──────────────────────────────────────────────
contract BurnShortVaultTest is BurnPositionTestBase {
    // SC-BMF2: case A — short in USDC and in the token, per asset
    function test_whenVaultIsShortThenBurnPaysItsShare() public {
        _moveTick(5700);
        _fundVault(60e6, 0);
        _drainThroughExchange(PRINCIPAL - 200e6);
        assertEq(mockUsdc.balanceOf(address(vault)), 200e6, "precondition: 200 USDC above escrow");
        assertEq(vault.totalUsdcOwed(), FELL_USDC, "precondition: one claim in the ledger");
        assertEq(vault.totalYesOwed(), BAND_TOKENS, "precondition: one claim in the ledger");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, 200e6, 0, 0, vault.yesTokenId(), BAND_TOKENS, 60e6);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 200e6, "the USDC the vault held");
        assertEq(_yesOf(safe), 60e6, "the YES the vault held");
        _assertDeleted(positionId);
    }

    // SC-BMF2: the totals fall by the full claim, whatever was paid
    function test_whenVaultIsShortThenTotalsFallByTheFullClaim() public {
        _moveTick(5700);
        _fundVault(60e6, 0);
        _drainThroughExchange(PRINCIPAL - 200e6);

        _burn(positionId);

        assertEq(vault.totalUsdcOwed(), 0, "the USDC total falls by 247,354,500, not by the 200 paid");
        assertEq(vault.totalYesOwed(), 0, "the YES total falls by 90, not by the 60 paid");
        assertEq(vault.totalUsdcOwedScaled(), 0, "no phantom claim in the scaled total");
        assertEq(vault.totalYesOwedScaled(), 0, "no phantom claim in the scaled total");
    }

    // SC-BMF2: case B — a balance below totalEscrowed pays zero USDC and does not revert
    function test_whenBalanceIsBelowEscrowThenBurnPaysZeroUsdc() public {
        // Safe B escrows 500 USDC that the Operator never mints
        _fundSafe(mockUsdc, safeB, address(vault), 500e6);
        _escrow(vault, operatorAddr, LP_B_PK, safeB, LOWER, UPPER, 500e6, keccak256("escrow-b"), FAR_DEADLINE);
        assertEq(vault.totalEscrowed(), 500e6, "precondition: escrow recorded");
        _drainThroughExchange(400e6);
        assertLt(mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "precondition: below escrow");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, PRINCIPAL, 0, 0, 0, 0, 0, 0);
        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 0, "nothing to pay");
        assertEq(vault.totalEscrowed(), 500e6, "escrowed USDC never pays a burn");
        assertEq(vault.totalUsdcOwed(), 0, "the claim settled in the ledger");
        _assertDeleted(positionId);
    }

    // SC-BMF2: case C — a vault richer than the claim credits the difference as spread and,
    // because this is the last live position, sweeps what the credit could not attribute
    // (FEAT-E943 FR-E946, FR-E94C). Before R18 the extra USDC and the extra YES stayed in the
    // vault with no owner; the ratio still caps at 1, and the surplus now reaches the LP as owed
    // spread rather than through the ratio.
    function test_whenVaultIsRichThenBurnCreditsTheDifferenceAndSweeps() public {
        _moveTick(5700);
        _fundVault(500e6, 0);
        mockUsdc.mint(address(vault), 1_000e6);

        _burn(positionId);

        assertEq(mockUsdc.balanceOf(safe), 1_300e6, "the claim's USDC plus the credited spread");
        assertEq(_yesOf(safe), 500e6, "the claim's YES plus the swept residue");
        assertEq(_yesOf(address(vault)), 0, "the vault keeps nothing");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault keeps nothing above escrow");
    }

    // SC-BMF2: no USDC transfer when nothing is paid
    function test_whenNothingIsPaidThenNoUsdcTransfer() public {
        _fundSafe(mockUsdc, safeB, address(vault), 500e6);
        _escrow(vault, operatorAddr, LP_B_PK, safeB, LOWER, UPPER, 500e6, keccak256("escrow-b"), FAR_DEADLINE);
        _drainThroughExchange(400e6);

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(mockUsdc), "no USDC transfer");
        }
    }
}

// ──────────────────────────────────────────────
// SC-BMF3: Burn of a clamped mint tick pays NO for the levels the price rose through
// What: The Operator reported 5000 before the mint, so mintTick = 5500. After a move to
//       5800 the NO band is [5500, 5800): 90 NO and
//       3e23 * (700 * 10000 + 300 * (5500 + 5800 - 1) / 2) / 1e22 = 260,845,500 USDC units.
// Why:  A mint below its range has an empty YES side and a NO side that is the whole range.
// ──────────────────────────────────────────────
contract BurnClampedMintTickTest is BurnPositionTestBase {
    uint256 clamped;

    function setUp() public override {
        super.setUp();
        _burn(positionId);
        _moveTick(5000);
        clamped = _mintExample(LP_PK, keccak256("clamped"));
        (,,, int24 mintTick,,) = vault.positions(clamped);
        assertEq(mintTick, LOWER, "precondition: the mint tick clamped to tickLower");
        _moveTick(5800);
        // The fill bought the 90 NO and spent the USDC the claim no longer names
        _fundVault(0, BAND_TOKENS);
        _drainThroughExchange(PRINCIPAL - 260_845_500);
    }

    // SC-BMF3: 260.8455 USDC plus 90 NO
    function test_whenMintTickClampedBelowThenRiseBuysNo() public {
        uint256 before = mockUsdc.balanceOf(safe);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(clamped, safe, 260_845_500, 260_845_500, 0, 0, vault.noTokenId(), BAND_TOKENS, BAND_TOKENS);
        _burn(clamped);

        assertEq(mockUsdc.balanceOf(safe) - before, 260_845_500, "the USDC leg");
        assertEq(_noOf(safe), BAND_TOKENS, "the NO leg");
    }

    // FR-7G4M: a mint clamped above its range with the price still above pays USDC only
    function test_whenMintTickClampedAboveAndPriceStaysAboveThenUsdcOnly() public {
        _moveTick(7000);
        uint256 above = _mintExample(LP_PK, keccak256("above"));
        (,,, int24 mintTick,,) = vault.positions(above);
        assertEq(mintTick, UPPER, "precondition: the mint tick clamped to tickUpper");
        uint256 before = mockUsdc.balanceOf(safe);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(above, safe, PRINCIPAL, PRINCIPAL, 0, 0, 0, 0, 0);
        _burn(above);

        assertEq(mockUsdc.balanceOf(safe) - before, PRINCIPAL, "every level is still USDC");
    }
}

// ──────────────────────────────────────────────
// FR-7G4M: the closed-form claim equals a per-level loop
// What: For a random liquidity, range, reported tick before the mint (so the clamp cases
//       occur), and current tick, a real burn's PositionBurned carries usdcOwed and
//       tokenOwed equal to a loop that adds L tokens and L * (ONE - t) or L * t per band
//       level, summed exactly and divided once.
// Why:  The arithmetic series is the audited shape; the loop is the definition. The
//       product stays under 2^156, so neither needs _mulDiv.
// ──────────────────────────────────────────────
contract BurnClaimFuzzTest is BurnPositionTestBase {
    uint256 constant ONE = 10_000;
    uint256 constant P = 1e18;

    function setUp() public override {
        super.setUp();
        _burn(positionId);
    }

    function testFuzz_claimEqualsPerLevelLoop(
        uint256 usdcSeed,
        uint256 lowerSeed,
        uint256 widthSeed,
        int256 reportSeed,
        int256 currentSeed
    ) public {
        uint256 usdcAmount = bound(usdcSeed, 1e6, 1e12);
        int24 lower = int24(int256(bound(lowerSeed, 0, 990) * 10));
        int24 width = int24(int256(bound(widthSeed, 1, 100) * 10));
        if (lower + width > 10000) lower = 10000 - width;
        int24 upper = lower + width;
        // The reported tick can sit outside the range, so the mint tick clamps to a bound
        int24 report = int24(bound(reportSeed, int256(lower) - 500, int256(upper) + 500));
        int24 current = int24(bound(currentSeed, int256(lower) - 500, int256(upper) + 500));

        _moveTick(report);
        uint256 id = _escrowAndMint(vault, operatorAddr, LP_PK, lower, upper, usdcAmount, keccak256("fuzz"));
        (,,, int24 m, uint128 liquidity,) = vault.positions(id);
        _moveTick(current);

        vm.recordLogs();
        _burn(id);
        (uint256 usdcOwed,, uint256 tokenId, uint256 tokenOwed,) = _burnedLog(vm.getRecordedLogs());

        (uint256 loopUsdc, uint256 loopTokenId, uint256 loopTokens) = _loop(liquidity, lower, upper, m, current);
        assertEq(usdcOwed, loopUsdc, "the USDC leg must equal the per-level loop");
        assertEq(tokenId, loopTokenId, "the token id must match the band's side");
        assertEq(tokenOwed, loopTokens, "the token leg must equal the per-level loop");
    }

    /// @dev The definition of the claim, level by level: every level holds L USDC-units-per-P;
    ///      a YES level spent L * t / ONE of it, a NO level spent L * (ONE - t) / ONE. The sums
    ///      stay exact and divide once at the end.
    function _loop(uint128 liquidity, int24 lower, int24 upper, int24 m, int24 c)
        internal
        view
        returns (uint256 usdc, uint256 tokenId, uint256 tokens)
    {
        uint256 l = liquidity;
        uint256 usdcTimes = 0;
        uint256 tokenTimes = 0;
        for (int24 t = lower; t < upper; t++) {
            // casting to 'uint256' is safe because the one caller bounds lower to [0, 9900], so t is never negative
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 tick = uint256(int256(t));
            if (c < m && t >= c && t < m) {
                usdcTimes += l * (ONE - tick);
                tokenTimes += l;
                tokenId = vault.yesTokenId();
            } else if (c > m && t >= m && t < c) {
                usdcTimes += l * tick;
                tokenTimes += l;
                tokenId = vault.noTokenId();
            } else {
                usdcTimes += l * ONE;
            }
        }
        usdc = usdcTimes / (ONE * P);
        tokens = tokenTimes / P;
        if (tokens == 0 && tokenTimes == 0) tokenId = 0;
    }
}

// ──────────────────────────────────────────────
// NFR-7G58, NFR-7G59: a re-entering Safe meets the guard with the position already gone
// What: Code etched at the Safe's address re-enters the vault from onERC1155Received. Its
//       burn of a second position reverts Reentrancy, and the burn completes with the full payout.
// Why:  A Safe owner can replace the Safe's fallback handler, so the ERC-1155 callback is a
//       live reentrancy surface, not defense in depth.
// ──────────────────────────────────────────────
contract ReentrantSafe {
    LPVault immutable vault;
    uint256 immutable target;
    bytes4 public recorded;

    constructor(LPVault vault_, uint256 target_) {
        vault = vault_;
        target = target_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try vault.burnPosition(target) {
            recorded = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            // casting to 'bytes4' is safe because the cast keeps the first four bytes, the error selector.
            // A shorter reason pads with zeros, so the test's selector check fails.
            // forge-lint: disable-next-line(unsafe-typecast)
            recorded = bytes4(reason);
        }
        return 0xf23a6e61;
    }
}

contract BurnReentrancyTest is BurnPositionTestBase {
    uint256 other;

    function setUp() public override {
        super.setUp();
        other = _mintExample(LP_PK, keccak256("other"));
        _moveTick(5700);
        // Two identical positions, so the fall bought two bands and spent two bands' USDC
        _fundVault(2 * BAND_TOKENS, 0);
        _drainThroughExchange(2 * BAND_SPENT);
    }

    // NFR-7G58: the re-entering burn reverts Reentrancy and the outer burn pays in full
    function test_whenSafeReentersThenGuardRejectsAndBurnCompletes() public {
        // The deployed instance's runtime code carries its immutables, so the copy at the
        // Safe's address re-enters the same vault for the same position.
        ReentrantSafe attacker = new ReentrantSafe(vault, other);
        vm.etch(safe, address(attacker).code);

        _burn(positionId);

        assertEq(ReentrantSafe(safe).recorded(), LPVault.Reentrancy.selector, "the re-entry meets the guard");
        assertEq(_yesOf(safe), BAND_TOKENS, "the burn still delivers the YES leg");
        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the burn still delivers the USDC leg");
    }
}

// ──────────────────────────────────────────────
// NFR-7G5C: a burn with a merge, tick deinitialization, and both transfers stays under
//           250,000 gas against the mock USDC
// ──────────────────────────────────────────────
contract BurnGasTest is BurnPositionTestBase {
    // NFR-7G5C: measured cold, as R3 measured, so every slot starts cold as in a real transaction.
    // The bound describes the optimized bytecode that deploys (ADR-9FOM in FEAT-J92H). `forge
    // coverage` compiles with the optimizer off, where this burn costs about 256,500 gas, so the
    // test is skipped there and asserted under `forge test`.
    function test_burnWithMergeAndBothLegsStaysUnderBound() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
        _moveTick(5700);
        _fundVault(BAND_TOKENS + 50e6, 50e6);
        vm.cool(address(vault));
        vm.cool(address(factory));
        vm.cool(address(mockUsdc));
        vm.cool(address(ctf));

        vm.prank(safe);
        uint256 before = gasleft();
        vault.burnPosition(positionId);
        uint256 used = before - gasleft();

        assertLt(used, 320_000, "the burn must stay under the NFR-7G5C bound");
    }

    // NFR-7G5C: after the switch, with nothing to redeem, the burn pays one USDC transfer
    function test_burnAfterTheSwitchWithNothingToRedeemStaysUnderBound() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        _resolveAndRedeem(1, 0);
        vm.cool(address(vault));
        vm.cool(address(factory));
        vm.cool(address(mockUsdc));
        vm.cool(address(ctf));

        vm.prank(safe);
        uint256 before = gasleft();
        vault.burnPosition(positionId);
        uint256 used = before - gasleft();

        assertLt(used, 320_000, "the resolved burn must stay under the NFR-7G5C bound");
    }

    // NFR-7G5C: after the switch, a burn that redeems late tokens first still fits the bound
    function test_burnAfterTheSwitchWithALateRedemptionStaysUnderBound() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        _resolveAndRedeem(1, 0);
        _fundVault(5e6, 5e6);
        vm.cool(address(vault));
        vm.cool(address(factory));
        vm.cool(address(mockUsdc));
        vm.cool(address(ctf));

        vm.prank(safe);
        uint256 before = gasleft();
        vault.burnPosition(positionId);
        uint256 used = before - gasleft();

        assertLt(used, 320_000, "the resolved burn with a redemption must stay under the NFR-7G5C bound");
    }
}

// ──────────────────────────────────────────────
// Resolved-branch base: the SC-7G44 state (the vault at 5700 holding 90 YES), with the USDC
// the band's fills spent moved out through the exchange, so the vault holds exactly the
// claim's USDC before the switch and exactly the claim plus the redeemed token leg after it.
// ──────────────────────────────────────────────
contract BurnAfterResolutionTestBase is BurnPositionTestBase {
    function setUp() public virtual override {
        super.setUp();
        _moveTick(5700);
        _fundVault(BAND_TOKENS, 0);
        _drainThroughExchange(BAND_SPENT);
        assertEq(mockUsdc.balanceOf(address(vault)), FELL_USDC, "precondition: the vault holds the claim's USDC");
    }

    /// @dev Burns the example and asserts the one USDC transfer, the event, and no token leg.
    function _assertResolvedBurn(uint256 usdcOut, uint256 tokenPaid) internal {
        vm.expectEmit(true, true, false, true, address(mockUsdc));
        emit Transfer(address(vault), safe, usdcOut);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, 0, 0, vault.yesTokenId(), BAND_TOKENS, tokenPaid);

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(mockUsdc.balanceOf(safe), usdcOut, "the Safe receives the claim's USDC and the token leg's USDC");
        assertEq(_yesOf(safe), 0, "the Safe receives no YES");
        assertEq(_noOf(safe), 0, "the Safe receives no NO");
        assertEq(_countLogs(logs, address(mockUsdc), Transfer.selector), 1, "one USDC transfer");
        assertEq(_countLogs(logs, address(ctf), TransferSingle.selector), 0, "no ERC-1155 transfer");
        assertEq(_countLogs(logs, address(ctf), PayoutRedemption.selector), 0, "nothing left to redeem");
        assertEq(_countLogs(logs, address(vault), OutcomeTokensRedeemed.selector), 0, "no redemption event");
        assertEq(mockUsdc.balanceOf(address(vault)), 0, "the vault paid the whole claim");
    }
}

// ──────────────────────────────────────────────
// SC-CYS7: Burn after the switch pays the winning leg in USDC
// What: With [1, 0] reported and the Oracle's redemption done, the vault holds
//       247,354,500 + 90,000,000 = 337,354,500 USDC units and no token. The burn values
//       the 90 YES at 90 USDC, finds one ratio of 1, and pays 337,354,500 in one transfer.
// Why:  The USDC is in the vault, and one transfer costs less than one transfer plus an
//       ERC-1155 transfer (FR-CYS4). tokenPaid reports the token leg's USDC after the switch.
// ──────────────────────────────────────────────
contract BurnAfterSwitchWinningLegTest is BurnAfterResolutionTestBase {
    function setUp() public override {
        super.setUp();
        _resolveAndRedeem(1, 0);
        assertEq(mockUsdc.balanceOf(address(vault)), FELL_USDC + BAND_TOKENS, "precondition: the redeemed YES");
        assertEq(_yesOf(address(vault)), 0, "precondition: no token");
    }

    // SC-CYS7: one transfer of 337,354,500, PositionBurned with tokenPaid = 90e6, no token leg
    function test_paysTheWinningLegAtParInOneUsdcTransfer() public {
        _assertResolvedBurn(FELL_USDC + BAND_TOKENS, BAND_TOKENS);
    }
}

// ──────────────────────────────────────────────
// SC-CYS8: Burn after the switch pays the losing leg nothing
// What: With [0, 1] reported and redeemed, the 90 YES redeemed for nothing, so the vault
//       holds 247,354,500 and the burn pays that with tokenPaid = 0. tokenOwed still reports
//       the 90 tokens the claim held.
// ──────────────────────────────────────────────
contract BurnAfterSwitchLosingLegTest is BurnAfterResolutionTestBase {
    function setUp() public override {
        super.setUp();
        _resolveAndRedeem(0, 1);
        assertEq(mockUsdc.balanceOf(address(vault)), FELL_USDC, "precondition: the YES redeemed for nothing");
    }

    // SC-CYS8: 247,354,500 in one transfer, tokenPaid = 0
    function test_paysTheLosingLegNothing() public {
        _assertResolvedBurn(FELL_USDC, 0);
    }
}

// ──────────────────────────────────────────────
// SC-CYS9: Burn after a cancelled market pays half the token leg
// What: With [1, 1] reported and redeemed, the 90 YES redeemed for 45 USDC, so the vault
//       holds 292,354,500 and the burn pays that with tokenPaid = 45e6.
// ──────────────────────────────────────────────
contract BurnAfterSwitchCancelledMarketTest is BurnAfterResolutionTestBase {
    function setUp() public override {
        super.setUp();
        _resolveAndRedeem(1, 1);
        assertEq(mockUsdc.balanceOf(address(vault)), FELL_USDC + BAND_TOKENS / 2, "precondition: half");
    }

    // SC-CYS9: 292,354,500 in one transfer, tokenPaid = 45e6
    function test_paysHalfTheTokenLeg() public {
        _assertResolvedBurn(FELL_USDC + BAND_TOKENS / 2, BAND_TOKENS / 2);
    }
}

// ──────────────────────────────────────────────
// SC-CYSA: Burn between resolution and the switch pays the token in kind
// What: With [1, 0] reported but the Oracle's redemption not yet called, the stored payout
//       is (0, 0), so the burn takes the pre-switch path: 247,354,500 USDC and 90 YES, with
//       the ERC-1155 transfer as the last call. The Safe then redeems the 90 YES itself for
//       90 USDC.
// Why:  No LP waits on the Oracle (ADR-6HCK).
// ──────────────────────────────────────────────
contract BurnBetweenResolutionAndSwitchTest is BurnAfterResolutionTestBase {
    function setUp() public override {
        super.setUp();
        _resolve(marketId, _payouts(1, 0));
        (uint128 numYes, uint128 numNo) = vault.payoutNumerators();
        assertEq(numYes | numNo, 0, "precondition: the switch is off");
    }

    // SC-CYSA: identical to SC-7G44, with no redemption call
    function test_paysTheTokenInKindAsBeforeTheResolution() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PositionBurned(positionId, safe, FELL_USDC, FELL_USDC, 0, 0, vault.yesTokenId(), BAND_TOKENS, BAND_TOKENS);

        vm.recordLogs();
        _burn(positionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC, "the claim's USDC");
        assertEq(_yesOf(safe), BAND_TOKENS, "the 90 YES in kind");
        assertEq(_countLogs(logs, address(ctf), PayoutRedemption.selector), 0, "no redemption");
        assertEq(_countLogs(logs, address(vault), OutcomeTokensRedeemed.selector), 0, "no redemption event");
        assertEq(
            logs[logs.length - 2].topics[0], TransferSingle.selector, "the ERC-1155 transfer is the last external call"
        );
    }

    // SC-CYSA: the Safe redeems the 90 YES at the ConditionalTokens contract for 90 USDC
    function test_safeRedeemsTheTokenItselfForTheSameUsdc() public {
        _burn(positionId);

        // The arguments are read first, so the prank lands on the redemption call itself
        bytes32 conditionId = vault.conditionId();
        uint256[] memory partition = _binaryPartition();
        vm.prank(safe);
        IConditionalTokens(address(ctf)).redeemPositions(address(mockUsdc), bytes32(0), conditionId, partition);

        assertEq(mockUsdc.balanceOf(safe), FELL_USDC + BAND_TOKENS, "the same 337.3545 USDC, one step later");
        assertEq(_yesOf(safe), 0, "the YES are redeemed");
    }
}
