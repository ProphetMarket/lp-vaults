// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-C0DL: Settle a Matched Order Into the Vault
// Integration tests for every scenario in this use case.
// Covers: SC-C0DS, SC-CVQ5, SC-CVQ6, SC-C0DT, FR-C0DZ, FR-C0E0, NFR-C0E5
//
// Every fill here runs through the real exchange: the vendored bytecode of ProphetCTFExchange
// (see ExchangeFixture for the pin). The exchange operator is this test contract, the vault's
// order is signed by the factory's Operator key with `signer = maker = vault` and
// `signatureType = POLY_1271`, and the vault answers the exchange's isValidSignature during
// _validateOrder. The USDC leg moves under the allowance initialize() granted, and the YES leg
// arrives through onERC1155Received, so a fill proves both approvals were always predicated on
// the vault being the maker (FR-C0E0).

import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {ExchangeFixture, IProphetCTFExchange} from "../../fixtures/ExchangeFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";
import {Order, Side} from "exchange/libraries/OrderStructs.sol";

// ──────────────────────────────────────────────
// Shared setup: USDC, the real Conditional Tokens contract, the real exchange, a factory whose
// exchange is that deployment, a vault with its tokens registered on the exchange, and a
// 1,000 USDC position so the vault holds the USDC its order spends.
// ──────────────────────────────────────────────
contract SettlementTestBase is ExchangeFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");

    uint256 constant OPERATOR_PK = 0x0FE9A704;
    uint256 constant LP_PK = 0xA11CE;
    uint256 constant TAKER_PK = 0x7A4E5;

    address operatorAddr;
    address taker;

    uint256 yesId;
    uint256 noId;
    bytes32 conditionId;

    // The vault's order: buy 100 YES for 60 USDC. With the taker's 40 USDC for 100 NO the pair
    // costs exactly 1.00, so the two-buy match splits 100 USDC with nothing left over.
    uint256 constant VAULT_PAYS = 60_000_000;
    uint256 constant VAULT_GETS = 100_000_000;
    uint256 constant TAKER_PAYS = 40_000_000;

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );

    function setUp() public virtual {
        operatorAddr = vm.addr(OPERATOR_PK);
        taker = vm.addr(TAKER_PK);

        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        _deployExchange(address(mockUsdc));
        factory = _deployFactory(
            address(impl), address(mockUsdc), address(exchange), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
        _registerVaultTokens(vault);

        yesId = vault.yesTokenId();
        noId = vault.noTokenId();
        conditionId = vault.conditionId();

        // 1,000 USDC in the vault, from one minted position over [0, 100)
        _escrowAndMint(vault, operatorAddr, LP_PK, int24(0), int24(100), 1_000_000_000, keccak256("mint-1"));
    }

    /// @dev The taker holds `amount` USDC and has approved the exchange for it.
    function _fundTakerUsdc(uint256 amount) internal {
        mockUsdc.mint(taker, amount);
        vm.prank(taker);
        mockUsdc.approve(address(exchange), amount);
    }

    /// @dev The two orders of the pair mint: the vault buys YES, the taker buys NO.
    function _pairMintOrders() internal returns (Order memory takerBuy, Order memory vaultBuy) {
        _fundTakerUsdc(TAKER_PAYS);
        vaultBuy = _vaultBuy(vault, OPERATOR_PK, yesId, VAULT_PAYS, VAULT_GETS);
        takerBuy = _eoaOrder(TAKER_PK, noId, TAKER_PAYS, VAULT_GETS, Side.BUY);
    }
}

// ──────────────────────────────────────────────
// SC-C0DS: Two buys mint a pair into the vault
// What: matchOrders with the vault's YES buy and a taker's NO buy takes 60 USDC from the vault
//       and 40 from the taker, splits 100 USDC into a pair, and delivers 100 YES to the vault
//       and 100 NO to the taker.
// Why:  This is the end-to-end proof that the vault is a maker: the exchange's own
//       _validateOrder ran the POLY_1271 branch and the vault vouched.
// Example: vault USDC 1,000,000,000 -> 940,000,000; vault YES 0 -> 100,000,000.
// ──────────────────────────────────────────────
contract TwoBuysMintAPairTest is SettlementTestBase {
    // SC-C0DS, FR-C0E0, FR-C0DU: balances after the match
    function test_when_two_buys_match_then_the_vault_pays_usdc_and_receives_yes() public {
        (Order memory takerBuy, Order memory vaultBuy) = _pairMintOrders();
        uint256 vaultUsdcBefore = mockUsdc.balanceOf(address(vault));
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);

        exchange.matchOrders(takerBuy, makers, TAKER_PAYS, fills);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultUsdcBefore - VAULT_PAYS, "the vault paid 60 USDC");
        assertEq(ctf.balanceOf(address(vault), yesId), VAULT_GETS, "the vault received 100 YES");
        assertEq(ctf.balanceOf(address(vault), noId), 0, "the vault received no NO");
        assertEq(ctf.balanceOf(taker, noId), VAULT_GETS, "the taker received 100 NO");
        assertEq(mockUsdc.balanceOf(taker), 0, "the taker paid 40 USDC");
    }

    // SC-C0DS: the exchange names the vault as the maker of the filled order
    function test_when_two_buys_match_then_the_exchange_emits_order_filled_with_the_vault_as_maker() public {
        (Order memory takerBuy, Order memory vaultBuy) = _pairMintOrders();
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);

        vm.expectEmit(true, true, true, true, address(exchange));
        emit OrderFilled(exchange.hashOrder(vaultBuy), address(vault), taker, 0, yesId, VAULT_PAYS, VAULT_GETS, 0);
        exchange.matchOrders(takerBuy, makers, TAKER_PAYS, fills);
    }

    // SC-C0DS, NFR-C0E5: a fill changes the vault's inventory and nothing it owes. No position
    // is created, no LP is credited, and no ledger total moves.
    function test_when_two_buys_match_then_no_position_and_no_ledger_total_changes() public {
        (Order memory takerBuy, Order memory vaultBuy) = _pairMintOrders();
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);
        uint256 nextIdBefore = vault.nextPositionId();
        uint256 usdcOwedBefore = vault.totalUsdcOwed();
        uint256 yesOwedBefore = vault.totalYesOwed();
        uint256 noOwedBefore = vault.totalNoOwed();

        exchange.matchOrders(takerBuy, makers, TAKER_PAYS, fills);

        assertEq(vault.nextPositionId(), nextIdBefore, "no position created");
        assertEq(vault.totalUsdcOwed(), usdcOwedBefore, "USDC owed unchanged");
        assertEq(vault.totalYesOwed(), yesOwedBefore, "YES owed unchanged");
        assertEq(vault.totalNoOwed(), noOwedBefore, "NO owed unchanged");
    }
}

// ──────────────────────────────────────────────
// SC-CVQ5: A taker sell fills the vault's buy
// What: A taker who holds 100 YES sells them for 60 USDC against the vault's buy. The vault
//       pays 60 USDC and receives 100 YES; the taker receives 60 USDC; nothing is split.
// Why:  The complementary match is the other way a vault buy fills, and it exercises the
//       operator approval the vault granted the exchange on the Conditional Tokens contract.
// Example: taker YES 100,000,000 -> 0; taker USDC 0 -> 60,000,000; CTF's USDC unchanged.
// ──────────────────────────────────────────────
contract TakerSellFillsVaultBuyTest is SettlementTestBase {
    // SC-CVQ5, FR-C0E0
    function test_when_a_taker_sells_yes_then_the_vault_pays_usdc_and_receives_yes_with_no_split() public {
        // The taker holds 100 YES (and 100 NO) from a complete set, and lets the exchange move them.
        _mintCompleteSets(mockUsdc, taker, conditionId, VAULT_GETS);
        vm.prank(taker);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory vaultBuy = _vaultBuy(vault, OPERATOR_PK, yesId, VAULT_PAYS, VAULT_GETS);
        Order memory takerSell = _eoaOrder(TAKER_PK, yesId, VAULT_GETS, VAULT_PAYS, Side.SELL);
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);

        uint256 vaultUsdcBefore = mockUsdc.balanceOf(address(vault));
        uint256 ctfUsdcBefore = mockUsdc.balanceOf(address(ctf));

        exchange.matchOrders(takerSell, makers, VAULT_GETS, fills);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultUsdcBefore - VAULT_PAYS, "the vault paid 60 USDC");
        assertEq(ctf.balanceOf(address(vault), yesId), VAULT_GETS, "the vault received 100 YES");
        assertEq(ctf.balanceOf(taker, yesId), 0, "the taker sold all 100 YES");
        assertEq(mockUsdc.balanceOf(taker), VAULT_PAYS, "the taker received 60 USDC");
        assertEq(mockUsdc.balanceOf(address(ctf)), ctfUsdcBefore, "no USDC was split: no new pair minted");
    }
}

// ──────────────────────────────────────────────
// SC-CVQ6: A fill reverts once the vault is frozen
// What: After emergencyCancelAll, the same two-buy match reverts with the exchange's
//       InvalidSignature() and no balance moves.
// Why:  A frozen vault takes no new fill while its claims are paid at the frozen tick
//       (FR-CVPX, decision C22). The order was signed before the freeze, and it fails at
//       match time instead of being cancelled.
// Example: vm.warp past the timelock; emergencyCancelAll(); matchOrders reverts.
// ──────────────────────────────────────────────
contract FrozenVaultRefusesFillTest is SettlementTestBase {
    // SC-CVQ6, FR-CVPX
    function test_when_the_vault_is_frozen_then_the_match_reverts_and_nothing_moves() public {
        (Order memory takerBuy, Order memory vaultBuy) = _pairMintOrders();
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);

        vm.warp(block.timestamp + vault.emergencyCancelTimelock() + 1);
        vault.emergencyCancelAll();
        assertEq(vault.phase(), 3, "the vault is Cancelled");

        uint256 vaultUsdcBefore = mockUsdc.balanceOf(address(vault));
        uint256 takerUsdcBefore = mockUsdc.balanceOf(taker);

        vm.expectRevert(IProphetCTFExchange.InvalidSignature.selector);
        exchange.matchOrders(takerBuy, makers, TAKER_PAYS, fills);

        assertEq(mockUsdc.balanceOf(address(vault)), vaultUsdcBefore, "the vault's USDC did not move");
        assertEq(ctf.balanceOf(address(vault), yesId), 0, "the vault received no YES");
        assertEq(mockUsdc.balanceOf(taker), takerUsdcBefore, "the taker's USDC did not move");
        assertEq(ctf.balanceOf(taker, noId), 0, "the taker received no NO");
    }

    // SC-CVQ6: the same orders fill before the freeze, so the revert is the freeze's doing
    function test_when_the_vault_is_not_frozen_then_the_same_orders_fill() public {
        (Order memory takerBuy, Order memory vaultBuy) = _pairMintOrders();
        (Order[] memory makers, uint256[] memory fills) = _one(vaultBuy, VAULT_PAYS);

        exchange.matchOrders(takerBuy, makers, TAKER_PAYS, fills);

        assertEq(ctf.balanceOf(address(vault), yesId), VAULT_GETS, "the same orders fill on an Active vault");
    }
}

// ──────────────────────────────────────────────
// SC-C0DT: Vault advertises EIP-1271 alongside the ERC-1155 receiver
// What: supportsInterface returns true for EIP-1271, IERC1155Receiver, and ERC-165, and false
//       for 0xffffffff.
// Why:  An integrator discovers that POLY_1271 is the signature type for this maker instead of
//       guessing it, and the receiver interface the token-delivery path relies on stays.
// Example: supportsInterface(0x1626ba7e) == true.
// ──────────────────────────────────────────────
contract AdvertisesEIP1271Test is SettlementTestBase {
    // SC-C0DT, FR-C0DZ
    function test_when_probed_then_the_vault_reports_eip1271_receiver_and_erc165_together() public view {
        assertTrue(vault.supportsInterface(0x1626ba7e), "EIP-1271 must be reported");
        assertTrue(vault.supportsInterface(0x4e2312e0), "IERC1155Receiver must still be reported");
        assertTrue(vault.supportsInterface(0x01ffc9a7), "ERC-165 must still be reported");
        assertFalse(vault.supportsInterface(0xffffffff), "0xffffffff must not be reported");
    }
}
