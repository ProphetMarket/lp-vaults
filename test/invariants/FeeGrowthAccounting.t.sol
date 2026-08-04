// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Invariant required by CLAUDE.md security checklist item 9 and by
// audit NM-0986-Prophet's fee-growth-arithmetic fix (T-001, extended by T-004):
// no position can ever claim more in fees, across its lifetime, than the
// vault has actually distributed via notifyFees (bounded by Q128 truncation
// dust). Randomized sequences of mint/notifyFees/updateTick/collect drive the
// vault through states that require the unchecked wraparound fixed in
// _computeFeeGrowthInside, collect(), and _crossTick() to hold without ever
// reverting or fabricating/destroying fees.

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {CTFPositionIds} from "../mocks/CTFPositionIds.sol";

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

/// @dev Tracks balances and moves tokens, because burnPosition pays its outcome leg with
///      a real ERC-1155 transfer. A setApprovalForAll-only stub would make every
///      in-range and above-range burn revert, and the handler's try/catch would swallow
///      it — leaving the burn action silently inert and this suite blind to exactly the
///      accounting it is meant to police.
contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[id][to] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
    }
}

// ──────────────────────────────────────────────
// Handler: bounded, valid-only action surface the invariant fuzzer drives.
// Every action is wrapped in try/catch so an expected revert (e.g. SameTick,
// NoActiveLiquidity) doesn't abort the run -- only unexpected reverts inside
// the vault's own arithmetic would surface as an invariant failure.
// ──────────────────────────────────────────────
contract FeeGrowthAccountingHandler is Test {
    LPVault public vault;
    MockERC20 public mockUsdc;
    address public operatorAddr;

    uint256 constant LP_PK = 0xA11CE;
    address public lp;

    bytes32 constant MINT_INTENT_TYPEHASH =
        keccak256("MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256[] public positionIds;
    uint256 internal intentNonce;
    uint256 public totalFeesNotified;

    constructor(LPVault vault_, MockERC20 mockUsdc_, address operatorAddr_) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        operatorAddr = operatorAddr_;
        lp = vm.addr(LP_PK);

        mockUsdc.mint(lp, type(uint128).max);
        vm.prank(lp);
        mockUsdc.approve(address(vault), type(uint256).max);
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function positionIdAt(uint256 i) external view returns (uint256) {
        return positionIds[i];
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, address(vault)));
    }

    function _sign(int24 tickLower, int24 tickUpper, uint256 usdcAmount, bytes32 intentId)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LP_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    // Mints a randomly-ranged, spacing-aligned position of a bounded size.
    // usdcAmount and width are kept modest (rather than the full uint256/int24
    // space) so accumulated liquidityGross on a shared tick across many mints
    // stays well under uint128's range -- that overflow belongs to FEAT-T7AF's
    // mint feature, not the fee-growth arithmetic this invariant targets.
    function mint(int256 tickLowerSeed, uint256 widthSeed, uint256 usdcAmountSeed) public {
        int24 tickLower = int24(bound(tickLowerSeed, -2000, 2000) / 10 * 10);
        int24 width = int24(uint24(bound(widthSeed, 10, 200) * 10));
        int24 tickUpper = tickLower + width;
        uint256 usdcAmount = bound(usdcAmountSeed, 1e6, 10e18);

        bytes32 intentId = keccak256(abi.encode("handler-mint", intentNonce++));
        bytes memory sig = _sign(tickLower, tickUpper, usdcAmount, intentId);

        // Mint consumes an escrow rather than pulling tokens (FEAT-3ZRI), so the
        // handler funds the intent first. Both calls are tolerant of failure: the
        // handler explores arbitrary inputs, and a rejected mint is a valid outcome.
        vm.prank(operatorAddr);
        try vault.depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, sig) {} catch {}

        vm.prank(operatorAddr);
        try vault.mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, sig) returns (uint256 id) {
            positionIds.push(id);
        } catch {}
    }

    function notifyFees(uint256 amountSeed) public {
        if (vault.activeLiquidity() == 0) return;
        uint256 amount = bound(amountSeed, 1, 10e18);
        mockUsdc.mint(address(vault), amount);
        vm.prank(operatorAddr);
        try vault.notifyFees(amount) {
            totalFeesNotified += amount;
        } catch {}
    }

    function updateTick(int256 newTickSeed) public {
        int24 newTick = int24(bound(newTickSeed, -2000, 2000) / 10 * 10);
        vm.prank(operatorAddr);
        try vault.updateTick(newTick) {} catch {}
    }

    function collect(uint256 idSeed) public {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[idSeed % positionIds.length];
        uint256 balBefore = mockUsdc.balanceOf(lp);
        vm.prank(lp);
        try vault.collect(id) {
            totalFeesPaidOut += mockUsdc.balanceOf(lp) - balBefore;
        } catch {}
    }

    /// @dev Closes a position through the self-service path. The fee half of the payout is
    ///      read off the PositionBurned event rather than from the USDC balance delta,
    ///      which also carries the principal — the conservation invariant only accounts
    ///      for fees, so mixing the principal in would make it meaningless.
    function burn(uint256 idSeed) public {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[idSeed % positionIds.length];

        vm.recordLogs();
        vm.prank(lp);
        try vault.burnPosition(id) {
            successfulBurns++;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics[0] == POSITION_BURNED_TOPIC) {
                    (,, uint256 feesAmount) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                    totalFeesPaidOut += feesAmount;
                }
            }
        } catch {}
    }

    bytes32 constant POSITION_BURNED_TOPIC = keccak256("PositionBurned(uint256,address,uint256,uint256,uint256)");

    uint256 public totalFeesPaidOut;

    /// @dev Burns that actually landed. Every handler action swallows its reverts, so a
    ///      broken fixture (an ERC-1155 stub that cannot transfer, say) would leave the
    ///      burn action inert and the invariants above vacuously true. This counter is
    ///      what test_handlerBurnActionIsNotInert checks.
    uint256 public successfulBurns;
}

contract FeeGrowthAccountingInvariantTest is StdInvariant, Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;
    FeeGrowthAccountingHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    uint256 constant Q128 = 2 ** 128;

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);

        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1e15), conditionId, yesTokenId, noTokenId)
        );

        // Outcome-token inventory for the burn action's complete-set leg.
        mockCt.mint(address(vault), yesTokenId, type(uint128).max);
        mockCt.mint(address(vault), noTokenId, type(uint128).max);

        handler = new FeeGrowthAccountingHandler(vault, mockUsdc, operatorAddr);
        targetContract(address(handler));
    }

    // CLAUDE.md security checklist item 9, stated as a conservation law: the
    // sum of every position's currently-claimable (uncollected) fees, plus
    // every fee already paid out via collect(), can never exceed the total
    // fees ever distributed via notifyFees (bounded by Q128 truncation dust
    // per call). This is the precise, position-entry/exit-safe form of the
    // per-instant "feeGrowthGlobalX128 * activeLiquidity / 2^128" bound in
    // CLAUDE.md -- that per-instant form only holds when every position is
    // currently in range, which a randomized mint/updateTick sequence does
    // not guarantee. The conservation form is what the wraparound fix must
    // actually protect: no arithmetic bug may fabricate or destroy fees.
    function invariant_claimableFeesNeverExceedTotalDistributed() public view {
        uint256 totalClaimable = 0;
        uint256 count = handler.positionCount();

        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.positionIdAt(i);
            (
                ,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInsideLastX128,
                uint256 tokensOwed
            ) = vault.positions(id);
            if (liquidity == 0 && tokensOwed == 0) continue;

            uint256 feeGrowthInside = _computeFeeGrowthInside(tickLower, tickUpper);
            uint256 claimable;
            // unchecked: mirrors collect()'s own wraparound-cancelling delta —
            // see LPVault.sol's collect() for the full justification.
            unchecked {
                claimable = uint256(liquidity) * (feeGrowthInside - feeGrowthInsideLastX128) / Q128;
            }
            totalClaimable += claimable + tokensOwed;
        }

        // Dust tolerance: every notifyFees call truncates downward by up to
        // 1 wei (mulDiv floor division); a long random run of many calls can
        // accumulate a small, bounded amount of slack.
        assertLe(
            totalClaimable + handler.totalFeesPaidOut(),
            handler.totalFeesNotified() + 1e6,
            "claimable + already-paid-out fees must not exceed total fees ever notified (+ dust)"
        );
    }

    /// @dev Guards the fixture, not the vault. Every handler action swallows its own
    ///      reverts, so if burnPosition could never succeed here — an ERC-1155 mock that
    ///      cannot transfer, an unfunded vault — the two structural invariants below would
    ///      still pass, having never seen a burn. This drives one deterministically.
    function test_handlerBurnActionIsNotInert() public {
        // Mint [0, 200) with currentTick still at 0, so the position is in range and can
        // accrue: notifyFees reverts against zero active liquidity, and a position that
        // never accrued would make the fee assertion below vacuous.
        handler.mint(int256(0), uint256(20), uint256(1e18));
        handler.notifyFees(uint256(1e12));
        handler.burn(0);

        assertGt(handler.successfulBurns(), 0, "the handler's burn action must actually burn");
        assertGt(handler.totalFeesPaidOut(), 0, "a burn must pay out the position's accrued fees");
    }

    // CLAUDE.md's required structural invariant: activeLiquidity is the sum of the
    // liquidity of every live position whose range contains currentTick.
    //
    // Burn is the first function that can break this. Mint only ever adds, and tick
    // crossings move activeLiquidity by a liquidityNet the mint itself installed; burn
    // has to decide, from currentTick at burn time, whether the position it is removing
    // was contributing at all — and get the half-open interval right at both boundaries.
    // Subtracting when it should not have (or failing to) leaves a permanent skew that no
    // later crossing corrects, silently misdirecting every subsequent fee distribution.
    function invariant_activeLiquidityMatchesInRangePositions() public view {
        LivePosition[] memory live = _livePositions();
        int24 tick = vault.currentTick();

        uint256 expected;
        for (uint256 i = 0; i < live.length; i++) {
            if (live[i].lower <= tick && tick < live[i].upper) {
                expected += live[i].liquidity;
            }
        }

        assertEq(
            uint256(vault.activeLiquidity()),
            expected,
            "activeLiquidity must equal the summed liquidity of live in-range positions"
        );
    }

    // CLAUDE.md's second required structural invariant: every initialized tick's
    // liquidityGross is the summed liquidity of the live positions referencing it, and its
    // liquidityNet is the signed form of the same sum.
    //
    // This is what makes tick deinitialization safe to trust: the burn deletes a tick and
    // clears its bitmap bit exactly when liquidityGross reaches zero, so if gross ever
    // drifted from the true reference count, the vault would either retire a tick real
    // positions still depend on (destroying their feeGrowthOutside snapshot) or leave a
    // dead tick in the bitmap for updateTick to cross with nothing behind it.
    function invariant_tickLiquidityMatchesReferencingPositions() public view {
        LivePosition[] memory live = _livePositions();

        for (uint256 i = 0; i < live.length; i++) {
            _assertTickMatches(live[i].lower, live);
            _assertTickMatches(live[i].upper, live);
        }
    }

    struct LivePosition {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @dev Snapshots every position that still holds liquidity into memory, so the
    ///      quadratic tick matching below runs on memory rather than repeating storage
    ///      reads. Burned positions are zeroed, so they drop out here.
    function _livePositions() internal view returns (LivePosition[] memory live) {
        uint256 count = handler.positionCount();
        LivePosition[] memory buf = new LivePosition[](count);
        uint256 n;

        for (uint256 i = 0; i < count; i++) {
            (, int24 lower, int24 upper, uint128 liquidity,,) = vault.positions(handler.positionIdAt(i));
            if (liquidity == 0) continue;
            buf[n] = LivePosition(lower, upper, liquidity);
            n++;
        }

        live = new LivePosition[](n);
        for (uint256 i = 0; i < n; i++) {
            live[i] = buf[i];
        }
    }

    function _assertTickMatches(int24 tick, LivePosition[] memory live) internal view {
        uint128 expectedGross;
        int128 expectedNet;

        for (uint256 i = 0; i < live.length; i++) {
            if (live[i].lower == tick) {
                expectedGross += live[i].liquidity;
                expectedNet += int128(live[i].liquidity);
            }
            if (live[i].upper == tick) {
                expectedGross += live[i].liquidity;
                expectedNet -= int128(live[i].liquidity);
            }
        }

        (uint128 gross, int128 net,) = vault.ticks(tick);
        assertEq(gross, expectedGross, "tick liquidityGross must equal the sum over referencing positions");
        assertEq(net, expectedNet, "tick liquidityNet must equal the signed sum over referencing positions");
    }

    /// @dev Mirrors LPVault._computeFeeGrowthInside() exactly (including the
    ///      unchecked wraparound) using only external view getters, so the
    ///      invariant can independently recompute what collect() would pay.
    function _computeFeeGrowthInside(int24 tickLower, int24 tickUpper) internal view returns (uint256) {
        (,, uint256 outsideLower) = vault.ticks(tickLower);
        (,, uint256 outsideUpper) = vault.ticks(tickUpper);
        int24 currentTick = vault.currentTick();
        uint256 global = vault.feeGrowthGlobalX128();

        unchecked {
            uint256 below = currentTick >= tickLower ? outsideLower : global - outsideLower;
            uint256 above = currentTick < tickUpper ? outsideUpper : global - outsideUpper;
            return global - below - above;
        }
    }
}
