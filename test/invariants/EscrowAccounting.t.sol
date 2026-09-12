// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-3ZRI: Escrow Deposit for Mint Intent (FR-9OYM)
// Invariant required by CLAUDE.md's Foundry conventions (an invariant on every
// state-machine property): the escrow total is exact. totalEscrowed equals the
// sum of every recorded escrow amount, the vault's USDC balance covers it, and
// no recorded intent is marked used. R9 pays burns and collects from
// balance - totalEscrowed (decision C7), so a drift in the total would over-
// or under-pay every exit. Randomized sequences of deposit / mint / reclaim /
// relayed reclaim, with random Safes, amounts, and intent IDs, some expired and
// some reused, drive the four consumers of the record.

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Handler: bounded, mostly-valid action surface the invariant fuzzer drives.
// Every vault call is wrapped in try/catch so an expected revert (an expired
// deadline, a reused intentId, a foreign Safe, a below-floor first mint) does
// not abort the run. The handler remembers every intentId it ever created,
// so the invariant can sum the records the vault holds.
// ──────────────────────────────────────────────
contract EscrowAccountingHandler is LPVaultFixture {
    LPVault public vault;
    MockERC20 public mockUsdc;
    address public operatorAddr;

    /// @dev Three owner keys, three Safes. The fuzzer picks one per action.
    uint256[3] internal keys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA401)];

    bytes32[] public intentIds;
    uint256 internal intentNonce;

    constructor(LPVault vault_, MockERC20 mockUsdc_, address operatorAddr_) {
        vault = vault_;
        mockUsdc = mockUsdc_;
        operatorAddr = operatorAddr_;
    }

    function intentCount() external view returns (uint256) {
        return intentIds.length;
    }

    function _key(uint256 seed) internal view returns (uint256) {
        return keys[seed % 3];
    }

    function _pickIntent(uint256 seed) internal view returns (bytes32) {
        return intentIds[seed % intentIds.length];
    }

    /// @dev Escrows a fresh intent, or replays an existing intentId one time in four so the
    ///      DepositAlreadyEscrowed and IntentAlreadyUsed guards are exercised. Some deadlines
    ///      are already in the past.
    function deposit(uint256 keySeed, int256 tickLowerSeed, uint256 widthSeed, uint256 amountSeed, uint256 modeSeed)
        public
    {
        uint256 pk = _key(keySeed);
        address safe = _safeOf(vm.addr(pk));
        int24 tickLower = int24(bound(tickLowerSeed, -2000, 2000) / 10 * 10);
        int24 width = int24(uint24(bound(widthSeed, 10, 200) * 10));
        int24 tickUpper = tickLower + width;
        uint256 amount = bound(amountSeed, 1e6, 10e18);

        bytes32 intentId;
        if (intentIds.length > 0 && modeSeed % 4 == 0) {
            intentId = _pickIntent(modeSeed);
        } else {
            intentId = keccak256(abi.encode("handler-intent", intentNonce++));
            intentIds.push(intentId);
        }
        uint256 deadline = modeSeed % 5 == 0 ? block.timestamp - 1 : FAR_DEADLINE;

        _remember(intentId, tickLower, tickUpper, amount, deadline);
        _fundSafe(mockUsdc, safe, address(vault), amount);
        bytes memory sig = _signMintIntent(address(vault), pk, safe, tickLower, tickUpper, amount, intentId, deadline);
        vm.prank(operatorAddr);
        try vault.depositForIntent(safe, tickLower, tickUpper, amount, intentId, deadline, sig) {} catch {}
    }

    /// @dev Mints a recorded intent with its recorded terms, or with the wrong Safe one time in four.
    function mint(uint256 intentSeed, uint256 keySeed) public {
        if (intentIds.length == 0) return;
        bytes32 intentId = _pickIntent(intentSeed);
        (address recorded,,) = vault.pendingDeposits(intentId);
        if (recorded == address(0)) return;

        // The vault stores only the hash of the terms, so the handler replays the terms it
        // remembered at the deposit.
        Terms memory t = terms[intentId];
        address named = keySeed % 4 == 0 ? _safeOf(vm.addr(_key(keySeed))) : recorded;

        vm.prank(operatorAddr);
        try vault.mintPositionFor(named, t.tickLower, t.tickUpper, t.amount, intentId, t.deadline) {} catch {}
    }

    /// @dev The Safe reclaims, or a foreign Safe tries to.
    function reclaim(uint256 intentSeed, uint256 keySeed) public {
        if (intentIds.length == 0) return;
        bytes32 intentId = _pickIntent(intentSeed);
        (address recorded,,) = vault.pendingDeposits(intentId);
        address caller = keySeed % 4 == 0 || recorded == address(0) ? _safeOf(vm.addr(_key(keySeed))) : recorded;

        vm.prank(caller);
        try vault.reclaimDeposit(intentId) {} catch {}
    }

    /// @dev The Operator relays a reclaim signed by one of the keys, sometimes the wrong one.
    function reclaimFor(uint256 intentSeed, uint256 keySeed, uint256 modeSeed) public {
        if (intentIds.length == 0) return;
        bytes32 intentId = _pickIntent(intentSeed);
        uint256 pk = _key(keySeed);
        address safe = _safeOf(vm.addr(pk));
        uint256 deadline = modeSeed % 5 == 0 ? block.timestamp - 1 : FAR_DEADLINE;
        bytes memory sig = _signReclaimIntent(address(vault), pk, safe, intentId, deadline);

        vm.prank(operatorAddr);
        try vault.reclaimDepositFor(safe, intentId, deadline, sig) {} catch {}
    }

    /// @dev The terms of the first deposit attempt per intentId, so mint() can replay them
    ///      exactly. A replayed deposit never overwrites them, and a failed first deposit
    ///      leaves terms that the mint then rejects, which is a valid path too.
    struct Terms {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount;
        uint256 deadline;
    }

    mapping(bytes32 => Terms) internal terms;

    function _remember(bytes32 intentId, int24 tickLower, int24 tickUpper, uint256 amount, uint256 deadline) internal {
        if (terms[intentId].amount == 0) terms[intentId] = Terms(tickLower, tickUpper, amount, deadline);
    }
}

contract EscrowAccountingInvariantTest is StdInvariant, LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    EscrowAccountingHandler handler;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );

        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1e15)));

        handler = new EscrowAccountingHandler(vault, mockUsdc, operatorAddr);
        targetContract(address(handler));
    }

    // FR-9OYM: totalEscrowed equals the sum of every recorded escrow amount
    function invariant_totalEscrowedEqualsSumOfEntries() public view {
        uint256 sum = 0;
        uint256 count = handler.intentCount();
        for (uint256 i = 0; i < count; i++) {
            (, uint96 amount,) = vault.pendingDeposits(handler.intentIds(i));
            sum += amount;
        }
        assertEq(vault.totalEscrowed(), sum, "totalEscrowed must equal the sum of every escrow entry");
    }

    // FR-9OYM: the vault's USDC balance always covers the escrow total
    function invariant_balanceCoversEscrow() public view {
        assertGe(
            mockUsdc.balanceOf(address(vault)), vault.totalEscrowed(), "the vault must hold at least totalEscrowed"
        );
    }

    // ADR-45IC: a recorded escrow and a used intent are mutually exclusive
    function invariant_escrowedIntentIsUnused() public view {
        uint256 count = handler.intentCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.intentIds(i);
            (address recorded,,) = vault.pendingDeposits(id);
            if (recorded != address(0)) {
                assertFalse(vault.usedIntents(id), "a recorded escrow must not be marked used");
            }
        }
    }
}
