// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-C0DJ: Vault Order Authorization
// UC-C0DK: Vouch for an Operator-Signed Order
// UC-C0DL: Settle a Matched Order Into the Vault
// Shared test fixture: the vendored bytecode of the exchange Prophet deploys, and the helpers
// that register a vault's tokens on it and build the vault's and a taker's signed orders.
// Test files import it. src/ never does.

import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "./LPVaultFixture.sol";
import {Order, Side, SignatureType} from "exchange/libraries/OrderStructs.sol";

/// @dev The exchange functions the tests call directly, and the one error a fill test expects.
interface IProphetCTFExchange {
    error InvalidSignature();

    function setResolution(address resolution) external;
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId, bytes32 questionId) external;
    function hashOrder(Order memory order) external view returns (bytes32);
    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external;
    function isAdmin(address addr) external view returns (bool);
    function isOperator(address addr) external view returns (bool);
}

/// @dev Base for every test that fills a vault order. The artifact is `ProphetCTFExchange` from
///      ProphetMarket/contracts at commit b5903f1 ("Deploy to mainnet"), built over the ctf-exchange
///      mixins at 9e6d895 with solc 0.8.31, via_ir, 200 optimizer runs, and the osaka EVM. Its
///      bytecode matches the input of the Polygon deploy transaction of the exchange at
///      0x127aD3A6e55EbBDaecC0eaeb12615879611e1839 up to the metadata hash (checked 2026-09-14).
///      The exchange pins `pragma 0.8.15` in its upstream form and this repo pins `0.8.20`, so the
///      artifact is deployed, not compiled: the two compiler versions never meet. A later exchange
///      change is a visible mismatch against this pin, to re-vendor on purpose.
abstract contract ExchangeFixture is LPVaultFixture {
    /// @dev Vendored forge artifact, copied as forge wrote it. foundry.toml grants read access.
    string internal constant EXCHANGE_ARTIFACT = "test/artifacts/ProphetCTFExchange.json";

    IProphetCTFExchange internal exchange;

    // ──────────────────────────────────────────────
    // Deployment
    // ──────────────────────────────────────────────

    /// @dev Deploys the real exchange bytecode over `usdc` and the fixture's Conditional Tokens
    ///      contract, and keeps it in `exchange`. The deployer (this test contract) is the
    ///      exchange's admin and operator, by the Auth constructor. The proxy and Safe factories
    ///      are zero: no test signs as POLY_PROXY or POLY_GNOSIS_SAFE. `resolution` is this test
    ///      contract, because _prepareBinaryCondition prepares each condition with the test
    ///      contract as the Conditional Tokens oracle, and registerToken checks that.
    function _deployExchange(address usdc) internal returns (IProphetCTFExchange) {
        exchange =
            IProphetCTFExchange(deployCode(EXCHANGE_ARTIFACT, abi.encode(usdc, address(ctf), address(0), address(0))));
        exchange.setResolution(address(this));
        return exchange;
    }

    /// @dev Registers the vault's two token IDs on the exchange, with the vault's marketId as the
    ///      question ID: the value _createVault prepared the condition with.
    function _registerVaultTokens(LPVault vault) internal {
        exchange.registerToken(vault.yesTokenId(), vault.noTokenId(), vault.conditionId(), vault.marketId());
    }

    // ──────────────────────────────────────────────
    // Orders
    // ──────────────────────────────────────────────

    /// @dev The vault's buy of `takerAmount` of `tokenId` for `makerAmount` USDC, signed by the
    ///      Operator key `operatorPk` over the exchange's hashOrder. `signer = maker = vault` and
    ///      `signatureType = POLY_1271`, the shape the exchange's verifyPoly1271Signature needs,
    ///      and `feeRateBps = 0`, the house rule for the vault's own orders.
    function _vaultBuy(LPVault vault, uint256 operatorPk, uint256 tokenId, uint256 makerAmount, uint256 takerAmount)
        internal
        view
        returns (Order memory order)
    {
        order = Order({
            salt: uint256(keccak256(abi.encode("vault-buy", tokenId, makerAmount, takerAmount))),
            maker: address(vault),
            signer: address(vault),
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: Side.BUY,
            signatureType: SignatureType.POLY_1271,
            signature: ""
        });
        order.signature = _signOrderHash(operatorPk, exchange.hashOrder(order));
    }

    /// @dev An EOA's order: `side` of `tokenId`, `makerAmount` for `takerAmount`, signed by `pk`
    ///      as both maker and signer with the EOA signature type.
    function _eoaOrder(uint256 pk, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        view
        returns (Order memory order)
    {
        address eoa = vm.addr(pk);
        order = Order({
            salt: uint256(keccak256(abi.encode("eoa-order", eoa, tokenId, makerAmount, takerAmount, side))),
            maker: eoa,
            signer: eoa,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.EOA,
            signature: ""
        });
        order.signature = _signOrderHash(pk, exchange.hashOrder(order));
    }

    /// @dev Signs an exchange order hash with `pk` and returns the 65-byte `r || s || v` signature.
    function _signOrderHash(uint256 pk, bytes32 orderHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, orderHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Wraps one maker order and its fill amount for matchOrders.
    function _one(Order memory order, uint256 fillAmount)
        internal
        pure
        returns (Order[] memory orders, uint256[] memory fillAmounts)
    {
        orders = new Order[](1);
        orders[0] = order;
        fillAmounts = new uint256[](1);
        fillAmounts[0] = fillAmount;
    }
}
