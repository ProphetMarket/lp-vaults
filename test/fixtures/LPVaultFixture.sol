// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// FEAT-3ZRI: Escrow Deposit for Mint Intent
// FEAT-T7AF: Mint LP Position
// FEAT-JAIJ: LP Escape Hatch
// FEAT-TOGR: Notify and Distribute Fees
// FEAT-7G40: Burn LP Position
// FEAT-U079: Collect Fees on a Position
// Shared test fixture: the base of every vault test. Deploys the factory with the Safe derivation
// constants, signs the four LP intent types with an owner key, derives the Safe the vault expects,
// runs the escrow-then-mint flow that every position starts from, and funds the Operator's fee report.
// Test files import it. src/ never does.

import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {ConditionalTokensFixture} from "./ConditionalTokensFixture.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Every vault test deploys a factory, so the constructor's two Safe derivation inputs live
///      here once. The values are made up: the derivation is pure arithmetic, the vault never calls
///      the Safe factory, and the one test against the real Polygon and Amoy inputs (SC-9OYB) builds
///      its own factories. An LP in a test is an owner key (a private key `vm.sign` can use) plus the
///      Safe that `_safeOf` derives from it; the Safe has no code, and `vm.prank(safe)` stands in for
///      a Safe transaction.
abstract contract LPVaultFixture is ConditionalTokensFixture {
    /// @dev A made-up Poly Safe factory address.
    address internal constant SAFE_FACTORY = 0x5AfeFaC70000000000000000000000000000aBcd;

    /// @dev A made-up combined proxy bytecode hash.
    bytes32 internal constant SAFE_PROXY_BYTECODE_HASH = keccak256("LPVaultFixture.safeProxyBytecodeHash");

    /// @dev The same typehashes the vault holds. Every LP type carries a deadline.
    bytes32 internal constant MINT_INTENT_TYPEHASH = keccak256(
        "MintIntent(address lp,int24 tickLower,int24 tickUpper,uint256 usdcAmount,bytes32 intentId,uint256 deadline)"
    );
    bytes32 internal constant RECLAIM_INTENT_TYPEHASH =
        keccak256("ReclaimIntent(address lp,bytes32 intentId,uint256 deadline)");
    bytes32 internal constant BURN_INTENT_TYPEHASH =
        keccak256("BurnIntent(address lp,uint256 positionId,uint256 deadline)");
    bytes32 internal constant COLLECT_INTENT_TYPEHASH =
        keccak256("CollectIntent(address lp,uint256 positionId,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev A deadline far enough ahead that no test reaches it by accident. Tests of the deadline
    ///      itself pass their own value.
    uint256 internal constant FAR_DEADLINE = type(uint256).max;

    // ──────────────────────────────────────────────
    // Factory
    // ──────────────────────────────────────────────

    /// @dev Deploys a factory with the seven per-test addresses and the two fixture constants.
    ///      The argument order matches the constructor's first seven arguments, so a call site
    ///      reads the same as the constructor it replaced.
    function _deployFactory(
        address impl,
        address usdc,
        address exchange,
        address conditionalTokens,
        address admin,
        address oracle,
        address operator
    ) internal returns (LPVaultFactory) {
        return new LPVaultFactory(
            impl, usdc, exchange, conditionalTokens, admin, oracle, operator, SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH
        );
    }

    // ──────────────────────────────────────────────
    // Safe derivation
    // ──────────────────────────────────────────────

    /// @dev The CREATE2 formula of the Poly Safe factory, with explicit inputs.
    function _deriveSafe(address safeFactory, bytes32 safeProxyBytecodeHash, address owner)
        internal
        pure
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(owner));
        bytes32 raw = keccak256(abi.encodePacked(bytes1(0xff), safeFactory, salt, safeProxyBytecodeHash));
        // casting to uint160 keeps the low 20 bytes, which is the CREATE2 address by definition
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(raw)));
    }

    /// @dev The Safe a vault built with the fixture constants derives for `owner`.
    function _safeOf(address owner) internal pure returns (address) {
        return _deriveSafe(SAFE_FACTORY, SAFE_PROXY_BYTECODE_HASH, owner);
    }

    // ──────────────────────────────────────────────
    // Signing
    // ──────────────────────────────────────────────

    /// @dev The vault's EIP-712 domain separator.
    function _domainSeparator(address vault) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LPVault"), keccak256("1"), block.chainid, vault));
    }

    /// @dev Signs a struct hash for `vault` with `pk` and returns the 65-byte signature.
    function _signStruct(address vault, uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(vault), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs a MintIntent with the owner key `pk`, naming `lp` (normally the key's Safe).
    function _signMintIntent(
        address vault,
        uint256 pk,
        address lp,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signStruct(
            vault,
            pk,
            keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId, deadline))
        );
    }

    /// @dev Signs a ReclaimIntent with the owner key `pk`, naming `lp` (normally the key's Safe).
    function _signReclaimIntent(address vault, uint256 pk, address lp, bytes32 intentId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signStruct(vault, pk, keccak256(abi.encode(RECLAIM_INTENT_TYPEHASH, lp, intentId, deadline)));
    }

    /// @dev Signs a BurnIntent with the owner key `pk`, naming `lp` (normally the key's Safe).
    function _signBurnIntent(address vault, uint256 pk, address lp, uint256 positionId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signStruct(vault, pk, keccak256(abi.encode(BURN_INTENT_TYPEHASH, lp, positionId, deadline)));
    }

    /// @dev Signs a CollectIntent with the owner key `pk`, naming `lp` (normally the key's Safe).
    function _signCollectIntent(
        address vault,
        uint256 pk,
        address lp,
        uint256 positionId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signStruct(vault, pk, keccak256(abi.encode(COLLECT_INTENT_TYPEHASH, lp, positionId, nonce, deadline)));
    }

    // ──────────────────────────────────────────────
    // Escrow and mint
    // ──────────────────────────────────────────────

    /// @dev Mints `amount` USDC to `safe` and approves `vault` for it, as the relayed Safe
    ///      transaction USDC.approve(vault, amount) would (decision C25).
    function _fundSafe(MockERC20 usdc, address safe, address vault, uint256 amount) internal {
        usdc.mint(safe, amount);
        vm.prank(safe);
        usdc.approve(vault, amount);
    }

    /// @dev The Operator escrows an intent that the owner key `pk` signed for `safe`. The Safe must
    ///      already hold and have approved the USDC (see _fundSafe).
    function _escrow(
        LPVault vault,
        address operator,
        uint256 pk,
        address safe,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId,
        uint256 deadline
    ) internal {
        bytes memory sig = _signMintIntent(
            address(vault), pk, safe, tickLower, tickUpper, usdcAmount, intentId, deadline
        );
        vm.prank(operator);
        vault.depositForIntent(safe, tickLower, tickUpper, usdcAmount, intentId, deadline, sig);
    }

    /// @dev The whole onboarding of one position for the owner key `pk`: fund its Safe with
    ///      `usdcAmount`, escrow the intent, and mint. Returns the position ID. Every test that
    ///      needs a position starts here.
    function _escrowAndMint(
        LPVault vault,
        address operator,
        uint256 pk,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        bytes32 intentId
    ) internal returns (uint256 positionId) {
        address safe = _safeOf(vm.addr(pk));
        _fundSafe(MockERC20(vault.usdc()), safe, address(vault), usdcAmount);
        _escrow(vault, operator, pk, safe, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
        vm.prank(operator);
        positionId = vault.mintPositionFor(safe, tickLower, tickUpper, usdcAmount, intentId, FAR_DEADLINE);
    }

    // ──────────────────────────────────────────────
    // Fee report
    // ──────────────────────────────────────────────

    /// @dev The Operator reports `amount` of fee income, funded the way the keeper will: the wallet
    ///      holds the swept USDC and has approved the vault, and notifyFees takes it (SC-TOGT,
    ///      decision C19). Mints per call, never a large pre-mint, so a fuzzed amount near the
    ///      mulDiv ceiling stays inside uint256 on the mock's balance.
    function _notifyFees(LPVault vault, address operator, uint256 amount) internal {
        _fundSafe(MockERC20(vault.usdc()), operator, address(vault), amount);
        vm.prank(operator);
        vault.notifyFees(amount);
    }
}
