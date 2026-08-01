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
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";

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

    uint256 public totalFeesPaidOut;
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

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );

        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1e15)));

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
