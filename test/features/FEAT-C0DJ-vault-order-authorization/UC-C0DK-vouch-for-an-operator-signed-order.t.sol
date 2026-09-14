// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-C0DK: Vouch for an Operator-Signed Order
// Integration tests for every scenario in this use case.
// Covers: SC-C0DM, SC-C0DN, SC-C0DO, SC-C0DP, SC-C0DQ, SC-C0DR, SC-CVPZ, SC-CVQ0, SC-CVQ1,
//         FR-C0DU, FR-C0DV, FR-C0DW, FR-C0DX, FR-C0DY, FR-CVPX, FR-CVPY,
//         NFR-C0E1, NFR-C0E2, NFR-C0E4
//
// Every test here drives `isValidSignature` directly through the vault's contract-call port,
// as the exchange does: `vm.prank(address(exchange))` puts the fixture's real exchange in
// msg.sender, so the caller scenario (SC-CVQ1) and the fills of UC-C0DL share one deployment.
// Whether the vault vouches is a pure function of the caller, the vault's phase and pause
// flags, the signature bytes, and the operator registry, which the vault reads from the
// factory at call time: SC-C0DO removes the Operator on the FACTORY and expects the vault's
// answer to change with no vault call in between.

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {ExchangeFixture} from "../../fixtures/ExchangeFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

// ──────────────────────────────────────────────
// Shared setup: the real exchange, a factory whose exchange is that deployment and whose
// initial Operator is an address we hold the key for, a second registered Operator, and one
// key that is never registered at all.
// ──────────────────────────────────────────────
contract OrderAuthorizationTestBase is ExchangeFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");

    // Keys, so the tests produce real signatures rather than fixtures.
    uint256 constant OPERATOR_PK = 0x0FE9A704;
    uint256 constant SECOND_OPERATOR_PK = 0x0FE9A705;
    uint256 constant STRANGER_PK = 0xDEADBEEF;

    address operatorAddr;
    address secondOperator;
    address stranger;

    /// @dev ERC-1271's success value. Equal to the selector of `isValidSignature(bytes32,bytes)`,
    ///      which is also its ERC-165 interface id.
    bytes4 constant MAGIC = 0x1626ba7e;

    /// @dev The single value every refusal returns (NFR-C0E4). Asserted by equality rather than
    ///      as "not MAGIC", so a change of failure constant is caught here.
    bytes4 constant FAILURE = 0xffffffff;

    /// @dev The order of the secp256k1 curve, for computing a malleated twin.
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // A stand-in for an exchange order hash. Its contents are irrelevant: the vault vouches
    // for who signed, never for what was signed (NFR-C0E1).
    bytes32 orderHash = keccak256("PROPHET-ORDER-HASH-1");

    function setUp() public virtual {
        operatorAddr = vm.addr(OPERATOR_PK);
        secondOperator = vm.addr(SECOND_OPERATOR_PK);
        stranger = vm.addr(STRANGER_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        _deployExchange(address(mockUsdc));
        factory = _deployFactory(
            address(impl), address(mockUsdc), address(exchange), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));

        // A second Operator, so no test can pass by accident on a single-entry registry.
        vm.prank(admin);
        factory.addOperator(secondOperator);
    }

    /// @dev Produces a 65-byte `r || s || v` signature over `hash` from `pk`.
    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Asks the vault, as the exchange, whether it vouches for `signature` over `hash`.
    function _vouchAsExchange(bytes32 hash, bytes memory signature) internal returns (bytes4) {
        vm.prank(address(exchange));
        return vault.isValidSignature(hash, signature);
    }

    /// @dev Asks the vault, as `caller`, whether it vouches for `signature` over `hash`.
    function _vouchAs(address caller, bytes32 hash, bytes memory signature) internal returns (bytes4) {
        vm.prank(caller);
        return vault.isValidSignature(hash, signature);
    }
}

// ──────────────────────────────────────────────
// SC-C0DM: Registered Operator's signature is vouched for
// What: From the exchange, on an Active unpaused vault, a registered Operator's signature
//       returns the magic value.
// Why:  Until this returns the magic value the exchange cannot accept any order naming the
//       vault as maker: _validateOrder calls validateOrderSignature unconditionally, and none
//       of the other three signature types can admit an EIP-1167 clone.
// Example: isValidSignature(hash, sign(OPERATOR_PK, hash)) == 0x1626ba7e from the exchange.
// ──────────────────────────────────────────────
contract VouchForRegisteredOperatorTest is OrderAuthorizationTestBase {
    // SC-C0DM, FR-C0DU: the whole point of the feature
    function test_when_a_registered_operator_signs_then_the_vault_returns_the_magic_value() public {
        assertEq(
            _vouchAsExchange(orderHash, _sign(OPERATOR_PK, orderHash)),
            MAGIC,
            "a registered Operator must be vouched for"
        );
    }

    // SC-C0DM, FR-C0DY: the registry is consulted, not a single hard-coded address. An Operator
    // added after the vault was created is honoured on the same footing as the first one.
    function test_when_a_later_added_operator_signs_then_the_vault_returns_the_magic_value() public {
        assertEq(
            _vouchAsExchange(orderHash, _sign(SECOND_OPERATOR_PK, orderHash)),
            MAGIC,
            "an Operator added after deployment must be vouched for too"
        );
    }

    // SC-C0DM, NFR-C0E2: the vouch is a view. A staticcall, which is what the exchange's
    // isValidSignatureNow makes, gets the same answer.
    function test_when_asked_through_staticcall_then_the_vault_answers() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        vm.prank(address(exchange));
        (bool ok, bytes memory ret) =
            address(vault).staticcall(abi.encodeWithSelector(LPVault.isValidSignature.selector, orderHash, sig));
        assertTrue(ok, "the vouch must succeed under staticcall");
        assertEq(abi.decode(ret, (bytes4)), MAGIC, "the vouch must return the magic value under staticcall");
    }

    // NFR-C0E1: no nonce and no order record. The same signature over the same hash is
    // vouched for twice, because the vault never learns that a hash was consumed.
    function test_when_the_same_signature_is_asked_twice_then_both_answers_are_the_magic_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "first vouch");
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "second vouch: the vault records nothing");
    }

    // The gas of one vouch from a cold vault and a cold factory, for the report. Loosely
    // bounded so the test has an assertion; the figure itself is logged.
    function test_gas_of_one_vouch_from_a_cold_vault_and_factory() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        vm.prank(address(exchange));
        uint256 before = gasleft();
        bytes4 answer = vault.isValidSignature(orderHash, sig);
        uint256 used = before - gasleft();
        assertEq(answer, MAGIC, "the measured call must be a vouch");
        emit log_named_uint("isValidSignature gas, cold vault and factory", used);
        assertLt(used, 40_000, "one vouch must cost well under 40k gas");
    }
}

// ──────────────────────────────────────────────
// SC-C0DN: Signature from a non-operator is refused
// What: A key that was never registered signs; the vault returns 0xffffffff.
// Why:  Anyone may sign anything naming the vault as maker; only the registry decides
//       whether it counts.
// Example: isValidSignature(hash, sign(STRANGER_PK, hash)) == 0xffffffff.
// ──────────────────────────────────────────────
contract RefuseNonOperatorTest is OrderAuthorizationTestBase {
    // SC-C0DN, FR-C0DV
    function test_when_a_stranger_signs_then_the_vault_returns_the_failure_value() public {
        assertEq(_vouchAsExchange(orderHash, _sign(STRANGER_PK, orderHash)), FAILURE, "a stranger must be refused");
    }

    // SC-C0DN: the Admin is not an Operator. Holding the registry does not make a key a signer.
    function test_when_the_admin_key_signs_then_the_vault_returns_the_failure_value() public {
        uint256 adminPk = 0xAD31;
        vm.prank(admin);
        factory.addAdmin(vm.addr(adminPk));
        assertEq(_vouchAsExchange(orderHash, _sign(adminPk, orderHash)), FAILURE, "an Admin key is not an Operator");
    }
}

// ──────────────────────────────────────────────
// SC-C0DO: Operator revoked between signing and filling is refused
// What: A signature produced while registered returns the failure value once the Admin
//       removes the Operator, with no vault call in between.
// Why:  Authorization is read from the live registry at call time (FR-C0DY), so one
//       removeOperator kills every unfilled order that key ever signed.
// Example: vouch == MAGIC; removeOperator; vouch == 0xffffffff.
// ──────────────────────────────────────────────
contract RefuseRevokedOperatorTest is OrderAuthorizationTestBase {
    // SC-C0DO, FR-C0DY
    function test_when_the_operator_is_removed_after_signing_then_the_vault_returns_the_failure_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "vouched for while registered");

        vm.prank(admin);
        factory.removeOperator(operatorAddr);

        assertEq(_vouchAsExchange(orderHash, sig), FAILURE, "refused once removed, same bytes");
    }

    // SC-C0DO: revocation is per key. The second Operator keeps its authority.
    function test_when_one_operator_is_removed_then_the_other_is_still_vouched_for() public {
        vm.prank(admin);
        factory.removeOperator(operatorAddr);
        assertEq(
            _vouchAsExchange(orderHash, _sign(SECOND_OPERATOR_PK, orderHash)),
            MAGIC,
            "removing one Operator must not touch another"
        );
    }
}

// ──────────────────────────────────────────────
// SC-C0DP: Malleable high-s signature is refused
// What: The malleated twin (s' = n - s, v flipped) of a vouched signature returns 0xffffffff
//       while the original returns the magic value.
// Why:  One authorization must not exist as two distinct byte strings (FR-C0DX).
// Example: original == MAGIC, twin == 0xffffffff, over the same hash.
// ──────────────────────────────────────────────
contract RefuseHighSSignatureTest is OrderAuthorizationTestBase {
    // SC-C0DP, FR-C0DX: the twin is computed from the original, never captured as a constant
    function test_when_the_high_s_twin_is_presented_then_the_vault_returns_the_failure_value() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, orderHash);
        bytes memory original = abi.encodePacked(r, s, v);

        bytes32 sTwin = bytes32(SECP256K1N - uint256(s));
        uint8 vTwin = v == 27 ? 28 : 27;
        bytes memory twin = abi.encodePacked(r, sTwin, vTwin);

        assertEq(_vouchAsExchange(orderHash, original), MAGIC, "the original must be vouched for");
        assertEq(_vouchAsExchange(orderHash, twin), FAILURE, "the malleated twin must be refused");
    }
}

// ──────────────────────────────────────────────
// SC-C0DQ: Recovery identifier outside the accepted pair is refused
// What: A signature whose v byte is 0, 1, or 29 returns 0xffffffff.
// Why:  v is refused rather than normalized: a caller that got it wrong is told so (FR-C0DX).
// Example: (r, s, 0) == 0xffffffff even though (r, s, 27) or (r, s, 28) would be vouched for.
// ──────────────────────────────────────────────
contract RefuseInvalidVTest is OrderAuthorizationTestBase {
    // SC-C0DQ, FR-C0DX
    function test_when_v_is_outside_27_and_28_then_the_vault_returns_the_failure_value() public {
        (, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, abi.encodePacked(r, s, uint8(0))), FAILURE, "v = 0 must be refused");
        assertEq(_vouchAsExchange(orderHash, abi.encodePacked(r, s, uint8(1))), FAILURE, "v = 1 must be refused");
        assertEq(_vouchAsExchange(orderHash, abi.encodePacked(r, s, uint8(29))), FAILURE, "v = 29 must be refused");
    }
}

// ──────────────────────────────────────────────
// SC-C0DR: Malformed or empty signature returns a value rather than reverting
// What: Empty bytes, 64 bytes, 66 bytes, and arbitrary bytes each return 0xffffffff and
//       never revert.
// Why:  The exchange treats a revert and a wrong return value differently, and any address
//       can hand the vault bytes (FR-C0DW, ADR-C0E7).
// Example: isValidSignature(hash, "") == 0xffffffff, and the call completes.
// ──────────────────────────────────────────────
contract MalformedSignatureNeverRevertsTest is OrderAuthorizationTestBase {
    // SC-C0DR, FR-C0DW: an empty signature
    function test_when_the_signature_is_empty_then_the_vault_returns_the_failure_value() public {
        assertEq(_vouchAsExchange(orderHash, ""), FAILURE, "empty bytes must be refused, not reverted");
    }

    // SC-C0DR, FR-C0DW: one byte short
    function test_when_the_signature_is_64_bytes_then_the_vault_returns_the_failure_value() public {
        (, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, abi.encodePacked(r, s)), FAILURE, "64 bytes must be refused");
    }

    // SC-C0DR, FR-C0DW: one byte long, with a valid signature as its prefix
    function test_when_the_signature_is_66_bytes_then_the_vault_returns_the_failure_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, abi.encodePacked(sig, uint8(0))), FAILURE, "66 bytes must be refused");
    }

    // SC-C0DR, FR-C0DW: random 65-byte input never reverts. A random r, s, v almost never
    // recovers a registered key, and the assertion is only that the call completes with a
    // bytes4: the property is totality, not the answer.
    function testFuzz_when_random_65_bytes_are_presented_then_the_call_never_reverts(bytes32 r, bytes32 s, uint8 v)
        public
    {
        vm.prank(address(exchange));
        (bool ok, bytes memory ret) = address(vault)
            .staticcall(abi.encodeWithSelector(LPVault.isValidSignature.selector, orderHash, abi.encodePacked(r, s, v)));
        assertTrue(ok, "a random 65-byte signature must never revert");
        assertEq(ret.length, 32, "the call must return one word");
    }

    // SC-C0DR, FR-C0DW: random-length input never reverts
    function testFuzz_when_random_length_bytes_are_presented_then_the_call_never_reverts(bytes calldata blob) public {
        vm.prank(address(exchange));
        (bool ok, bytes memory ret) =
            address(vault).staticcall(abi.encodeWithSelector(LPVault.isValidSignature.selector, orderHash, blob));
        assertTrue(ok, "random bytes must never revert");
        if (blob.length != 65) {
            assertEq(abi.decode(ret, (bytes4)), FAILURE, "a length other than 65 must be refused");
        }
    }
}

// ──────────────────────────────────────────────
// SC-CVPZ: Paused vault refuses a vouched signature and accepts it again after unpause
// What: pauseTrading turns a vouch into 0xffffffff; unpauseTrading turns it back.
// Why:  A paused vault takes no new fill (FR-CVPX, decision C22), and a pause retires no
//       signature: the keeper re-posts after the unpause.
// Example: MAGIC; pauseTrading; 0xffffffff; unpauseTrading; MAGIC, same bytes throughout.
// ──────────────────────────────────────────────
contract PausedVaultRefusesTest is OrderAuthorizationTestBase {
    // SC-CVPZ, FR-CVPX
    function test_when_the_vault_is_paused_then_the_vault_returns_the_failure_value_until_unpaused() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "vouched for before the pause");

        vm.prank(admin);
        vault.pauseTrading();
        assertEq(_vouchAsExchange(orderHash, sig), FAILURE, "refused while paused");

        vm.prank(admin);
        vault.unpauseTrading();
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "vouched for again after the unpause");
    }
}

// ──────────────────────────────────────────────
// SC-CVQ0: Wound-down vault refuses every signature
// What: After startWindDown, a vouched signature returns 0xffffffff.
// Why:  A wound-down vault's claims are paid at a fixed tick from now on, so it takes no
//       new fill (FR-CVPX, decision C22).
// Example: MAGIC; startWindDown; 0xffffffff, same bytes.
// ──────────────────────────────────────────────
contract WoundDownVaultRefusesTest is OrderAuthorizationTestBase {
    // SC-CVQ0, FR-CVPX
    function test_when_the_vault_is_wound_down_then_the_vault_returns_the_failure_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "vouched for while Active");

        vm.prank(oracleAddr);
        vault.startWindDown();
        assertEq(_vouchAsExchange(orderHash, sig), FAILURE, "refused once wound down");
    }
}

// ──────────────────────────────────────────────
// SC-CVQ1: A caller other than the exchange is refused
// What: The same hash and signature return 0xffffffff from a wallet, the Operator, and the
//       factory, and the magic value from the exchange.
// Why:  USDC FiatTokenV2_2 routes a bytes signature in permit and transferWithAuthorization
//       to the payer's isValidSignature (ERC-7598). Answering only the exchange keeps the
//       vouch consumable by a matched order alone (FR-CVPY, ADR-CVQ2).
// Example: from makeAddr("wallet") == 0xffffffff; from the exchange == MAGIC.
// ──────────────────────────────────────────────
contract NonExchangeCallerRefusedTest is OrderAuthorizationTestBase {
    // SC-CVQ1, FR-CVPY
    function test_when_a_wallet_asks_then_the_vault_returns_the_failure_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        assertEq(_vouchAs(makeAddr("wallet"), orderHash, sig), FAILURE, "a wallet must be refused");
        assertEq(_vouchAs(operatorAddr, orderHash, sig), FAILURE, "the Operator itself must be refused");
        assertEq(_vouchAs(address(factory), orderHash, sig), FAILURE, "the factory must be refused");
        assertEq(_vouchAsExchange(orderHash, sig), MAGIC, "the exchange gets the magic value for the same bytes");
    }

    // SC-CVQ1, FR-CVPY: the refusal is a returned value, so a stand-in for the USDC contract
    // that consults the payer under staticcall gets 0xffffffff and no revert.
    function test_when_a_token_contract_asks_under_staticcall_then_it_gets_the_failure_value() public {
        bytes memory sig = _sign(OPERATOR_PK, orderHash);
        vm.prank(address(mockUsdc));
        (bool ok, bytes memory ret) =
            address(vault).staticcall(abi.encodeWithSelector(LPVault.isValidSignature.selector, orderHash, sig));
        assertTrue(ok, "the refusal must not revert");
        assertEq(abi.decode(ret, (bytes4)), FAILURE, "the token contract must get the failure value");
    }
}
