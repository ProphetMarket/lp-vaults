---
id: UC-C0DL
name: Settle a Matched Order Into the Vault
feature: FEAT-C0DJ
status: implemented
version: 2
actor: Operator
---

# UC-C0DL: Settle a Matched Order Into the Vault

> An Operator gets an order filled against vault-held capital, so the vault takes on outcome-token inventory without its assets ever passing through anyone's wallet.

## Preconditions

- Vault is deployed, initialized, and in the Active phase, and not paused
- Vault holds USDC from a minted position
- `initialize()` has granted the exchange an ERC-20 allowance over the vault's USDC and ERC-1155 operator approval over its outcome tokens
- The exchange registered the vault's two token IDs against the vault's `conditionId`, and its `resolution` is the address that prepared the condition
- The submitting address is registered as an Operator on the exchange, and the signing key is registered as an Operator on the vault's factory

## Trigger

The exchange operator submits `matchOrders` with a taker order and the vault's order, which names the vault as `maker` and as `signer` with `signatureType == POLY_1271`.

---

### SC-C0DS: Two buys mint a pair into the vault

**Given:**
- The vault holds 1,000 USDC of a minted position and no outcome tokens
- The vault's order buys 100 YES for 60 USDC: `makerAmount 60_000_000`, `takerAmount 100_000_000`, `side BUY`, `signer = maker = vault`, `signatureType POLY_1271`, `feeRateBps 0`, signed by a registered Operator key over the exchange's `hashOrder`
- A taker EOA holds 40 USDC, approved the exchange for it, and signed an order that buys 100 NO for 40 USDC

**Steps:**
1. Exchange operator calls `matchOrders(takerOrder, [vaultOrder], 40_000_000, [60_000_000])`
2. Exchange asks the vault to validate the vault order's signature, and the vault vouches for it
3. Exchange pulls 60 USDC from the vault under the allowance granted at initialization, and 40 USDC from the taker
4. Exchange splits 100 USDC into 100 YES and 100 NO through the Conditional Tokens contract
5. Exchange delivers 100 YES to the vault and 100 NO to the taker

**Outcomes:**
- The vault's USDC balance falls by 60,000,000
- The vault's YES balance rises by 100,000,000
- The taker's NO balance rises by 100,000,000
- The exchange emits `OrderFilled` with the vault as `maker`, the taker as `taker`, `makerAmountFilled 60_000_000`, and `takerAmountFilled 100_000_000`

**Side Effects:**
- Receipt acknowledged through `onERC1155Received`, which validates that the delivered token ID belongs to this vault's market
- No position record created and no LP credited -- a fill changes the vault's inventory, never any LP's claim
- No solvency-ledger total written: the ledger records what the vault owes, and a fill converts assets without changing an obligation
- No event emitted by the vault; the exchange is the publisher for the trade itself

---

### SC-CVQ5: A taker sell fills the vault's buy

**Given:**
- The vault's order is the buy of SC-C0DS: 100 YES for 60 USDC
- A taker EOA holds 100 YES from a complete set, approved the exchange on the Conditional Tokens contract, and signed an order that sells 100 YES for 60 USDC

**Steps:**
1. Exchange operator calls `matchOrders(takerSell, [vaultOrder], 100_000_000, [60_000_000])`
2. Exchange asks the vault to validate the vault order's signature, and the vault vouches for it
3. Exchange pulls 100 YES from the taker and 60 USDC from the vault
4. Exchange delivers 100 YES to the vault and 60 USDC to the taker, with no split

**Outcomes:**
- The vault's USDC balance falls by 60,000,000
- The vault's YES balance rises by 100,000,000
- The taker's USDC balance rises by 60,000,000
- No new pair is minted: the Conditional Tokens contract's supply of the vault's condition is unchanged

**Side Effects:**
- Receipt acknowledged through `onERC1155Received`
- No position record created, no LP credited, and no solvency-ledger total written
- No event emitted by the vault

---

### SC-CVQ6: A fill reverts once the vault is frozen

**Given:**
- The same pair of orders as SC-C0DS, signed before the freeze
- The Operator has been silent for the vault's emergency-cancel timelock, and any address has called `emergencyCancelAll`, so the phase is Cancelled

**Steps:**
1. Exchange operator calls `matchOrders(takerOrder, [vaultOrder], 40_000_000, [60_000_000])`
2. Exchange asks the vault to validate the vault order's signature
3. System sees `phase != Active` and returns `0xffffffff`
4. Exchange reverts with `InvalidSignature()`

**Outcomes:**
- The call reverts with the exchange's `InvalidSignature()` error
- The vault's USDC and YES balances and the taker's USDC and NO balances are unchanged
- A resting order the keeper posted before the freeze fails at match time instead of being cancelled, so a frozen vault takes no new fill while its claims are paid at the frozen tick (decision C22, ADR-BZBZ in FEAT-JXQO)

**Side Effects:**
- No storage written on the vault or on the exchange: the whole transaction reverts
- No `OrderFilled` emitted
- No token moved

---

### SC-C0DT: Vault advertises EIP-1271 alongside the ERC-1155 receiver

**Given:**
- A deployed, initialized vault

**Steps:**
1. An integrator queries the vault's interface support for EIP-1271
2. System reports it as supported
3. Integrator queries interface support for `IERC1155Receiver`
4. System reports it as supported

**Outcomes:**
- Both queries return true, as does the query for `IERC165`
- `supportsInterface(0xffffffff)` still returns false
- An integrator can discover that `POLY_1271` is the correct signature type for this maker rather than guessing it
- Adding EIP-1271 support does not displace the receiver interface the vault already advertised, so the token-delivery path in SC-C0DS keeps working

**Side Effects:**
- No storage written -- a pure view
- No event emitted

---
