---
id: FEAT-C0DJ
name: Vault Order Authorization
module: contracts
domain: "@vault"
status: implemented
version: 3
refs: [FEAT-REPZ, FEAT-9BQZ, FEAT-TOGR, FEAT-T7AF, FEAT-JXQO, FEAT-K1MD, FEAT-JGE7]
---

# Vault Order Authorization

> Lets a registered Operator author orders that name the vault itself as maker, by having the vault answer the exchange for a signature it holds no key for, only while the vault is Active and not paused, so vault-held capital is filled on the exchange without leaving the vault and a paused, wound-down, or frozen vault takes no new fill (decision C22).

## Non-Goals

- Does not construct, price, size, or decide which orders to post; that is off-chain keeper logic and this feature covers only whether the vault vouches for a given signature
- Does not track nonces or prevent order replay -- order hashing, fill accounting, and cancellation live in the exchange, and a second set of bookkeeping here would either duplicate or diverge from it. See ADR-C0E8, and NFR-C0E1 for why this is a deliberate departure from the `intentId` convention every LP-facing path follows
- Does not gate which orders an Operator may sign: no size cap, no price band, no side restriction, no per-market policy
- Does not change the LP-facing EIP-712 verification: the relayed LP paths recover the Safe's owner key and derive the Safe (`_verifySafeOwnerSignature`, ADR-9OYP in FEAT-T7AF). This feature leaves them untouched
- Does not give the vault a private key, and does not move vault assets to any externally-owned account at any point
- Does not widen what a compromised Operator can reach beyond the approvals already granted at initialization -- see NFR-C0E5
- Does not add support for the `EOA`, `POLY_PROXY`, or `POLY_GNOSIS_SAFE` signature types; none of them can ever admit an EIP-1167 clone
- Does not treat a vault sell order in any special way: the keeper posts buys only (decision C26), and the vault sees a hash, never a side
- Does not answer any caller other than the exchange: USDC `FiatTokenV2_2` routes `permit` and `transferWithAuthorization` bytes signatures to the payer's `isValidSignature` (ERC-7598), so an open vouch would let an Operator key move vault USDC around the exchange. See FR-CVPY and ADR-CVQ2

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Produces the signature bytes the vault vouches for | Any address with `operators[signer] == 1` on the factory. The Operator signs on the vault's behalf but never holds vault assets; the signature authorizes the exchange to move capital that stays in the vault until the moment of settlement |
| Keeper | Holds an Operator key off-chain and is what actually signs and submits in production | Not an on-chain role. Inherits exactly the Operator's authority, which is why revocation must bite immediately (FR-C0DY). Cancels its resting orders when it sees `EmergencyCancelExecuted`, `VaultWindDownStarted`, or `TradingPaused`, because the vault refuses their signatures at match time (FR-CVPX) |
| Exchange | The one caller the vault answers | `ProphetCTFExchange`, fixed at `initialize()`. It calls `isValidSignature` through `verifyPoly1271Signature` during `_validateOrder`, then pulls the USDC leg and delivers the outcome tokens |
| LP | Bears the economic consequence of every order signed against the vault | Never calls anything in this feature. An LP's protection is that assets never leave the vault except through a matched order on the exchange |

## Functional Requirements

### Vouching for a Signature

**FR-C0DU** `When the exchange asks the vault to validate a signature over a hash while the vault is in the Active phase and not paused, and the recovered signer is a registered Operator, the system shall return the ERC-1271 magic value 0x1626ba7e.`
Fit Criterion: Given a hash signed by an address with `operators[signer] == 1`, a call from the vault's configured `exchange` to `isValidSignature(hash, signature)` returns `0x1626ba7e`, and the exchange's `matchOrders` fills an order with `maker == signer == vault` and `signatureType == POLY_1271`. This is the single gate that makes vault-held capital fillable: every exchange entry point funnels through `_validateOrder`, which calls `validateOrderSignature` unconditionally, and none of the four signature types can admit a contract without this method.
Linked to: UC-C0DK, UC-C0DL

**FR-C0DV** `If the recovered signer is the zero address or is not a registered Operator, then the system shall return 0xffffffff.`
Fit Criterion: Given a hash signed by a key that was never added to the operator registry, `isValidSignature` returns `0xffffffff`, and the exchange rejects the order. The zero address is the value the recovery helper returns for every unusable signature, so it is excluded before the registry read. The return value is what the caller branches on, so a non-matching value -- rather than a revert or an empty return -- is the observable outcome that matters.
Linked to: UC-C0DK

**FR-C0DW** `The system shall return a value from every signature validation request rather than reverting.`
Fit Criterion: Given an empty signature, a signature shorter than 65 bytes, one longer than 65 bytes, or arbitrary bytes, `isValidSignature` returns the failure value and the call completes normally. The exchange treats a revert and a wrong return value as different outcomes, and callers probe this method speculatively, so a revert turns a merely-rejected order into a failed transaction -- and makes the vault trivially griefable by anyone who can hand it malformed bytes.
Linked to: UC-C0DK

**FR-C0DX** `If a signature carries an s value above secp256k1n/2 or a v outside {27, 28}, then the system shall return the failure value.`
Fit Criterion: Given a valid Operator signature and its malleated twin (`s' = n - s` with `v` flipped), the original returns `0x1626ba7e` and the twin returns the failure value. Without the bound, one authorization exists as two distinct byte strings, which breaks any off-chain system that treats the signature bytes as an identity. These are the same bounds the LP signature path in this vault already enforces, in the one shared helper.
Linked to: UC-C0DK

**FR-C0DY** `When the vault validates a signature, the system shall evaluate the recovered signer against the operator registry as it stands at that moment.`
Fit Criterion: Given an Operator signs a hash while registered, and the Admin then calls `removeOperator` on that address, a subsequent `isValidSignature` over the same hash and the same signature returns the failure value. Authorization is never captured at signing time, so a single registry write kills every unfilled order that key ever signed -- no per-order revocation list, and no window in which a removed Operator's outstanding orders can still fill.
Linked to: UC-C0DK

### Phase, Pause, and Caller

**FR-CVPX** `If the vault's phase is not Active, or trading is paused, then the system shall return 0xffffffff before it recovers a signer.`
Fit Criterion: Given a signature that returned `0x1626ba7e`, after `startWindDown`, after `pauseTrading`, and after `emergencyCancelAll` the same hash and signature return `0xffffffff`; after `unpauseTrading` on a paused Active vault they return `0x1626ba7e` again. A frozen, wound-down, or paused vault takes no new fill while its claims are paid at a fixed tick (decision C22, ADR-BZBZ in FEAT-JXQO). A resting order the keeper posted before the transition fails its signature check at match time instead of being cancelled.
Linked to: UC-C0DK, UC-C0DL

**FR-CVPY** `If the caller is not the vault's configured exchange, then the system shall return 0xffffffff.`
Fit Criterion: Given a hash signed by a registered Operator on an Active, unpaused vault, `isValidSignature(hash, signature)` returns `0x1626ba7e` when called from the `exchange` address and `0xffffffff` when called from any other address, including a wallet, the Operator, and the factory. The check closes the ERC-7598 path: USDC `FiatTokenV2_2` routes a bytes signature in `permit` and `transferWithAuthorization` to the payer's `isValidSignature`, so without it an Operator key could move vault USDC around the exchange (ADR-CVQ2).
Linked to: UC-C0DK

### Interface Discovery and Settlement

**FR-C0DZ** `When a caller queries interface support for EIP-1271, the system shall report it as supported.`
Fit Criterion: `supportsInterface(0x1626ba7e)` returns true, and `supportsInterface` still returns true for `IERC1155Receiver` and `IERC165`. Discovery is what lets an integrator route to the `POLY_1271` signature type rather than guessing; adding the new interface must not displace the ones the vault already advertises.
Linked to: UC-C0DL

**FR-C0E0** `When the exchange settles an order that names the vault as maker, the system shall pay the USDC leg under the allowance granted at initialize and accept the outcome tokens through onERC1155Received.`
Fit Criterion: Against the vendored `ProphetCTFExchange`, a two-buy match takes the vault's USDC and delivers YES to it, and a taker sell fills the vault's buy the same way. The vault's USDC balance falls by the amount the exchange pulled under the allowance granted at `initialize()`, the vault's ERC-1155 balance for the market's token ID rises by the filled amount, and receipt is acknowledged through `onERC1155Received`. This is the end-to-end proof that `approve(exchange, max)` and `setApprovalForAll(exchange, true)` -- set at initialization and unreachable until now -- were always predicated on the vault being the maker.
Linked to: UC-C0DL

## Non-Functional Requirements

**NFR-C0E1** Security: `Signature validation shall introduce no replay protection of its own.`
Rationale: the vault vouches for a signer, never for an order's uniqueness. Order hashing, partial-fill accounting, and cancellation all live in the exchange's `_performOrderChecks`. A nonce or `intentId` here would be a second ledger of order state that can only duplicate the exchange's or drift from it, and drift would either block legitimate fills or permit ones the exchange already retired. This is a deliberate and documented departure from the replay-protection convention every LP-facing path in this vault follows -- see ADR-C0E8. An auditor should read the absence as a decision, not an omission.

**NFR-C0E2** Security: `Signature validation shall mutate no state.`
Fit Criterion: `isValidSignature` is declared `view` and answers correctly under `staticcall`. It is callable by any address with any input, so a state-mutating implementation would be an unguarded external write reachable by anyone, and would make the method a reentrancy surface on a contract that holds LP capital.

**NFR-C0E3** Auditability: `Every function this feature adds shall carry an OPERATOR TRUST ASSUMPTION NatSpec block.`
Fit Criterion: the block states plainly that any registered Operator can author orders that spend vault assets through the exchange, that LPs are trusting Operators not to sign orders that trade against their interest, and that the vault enforces who signed but never what was signed. The vault checks who signed, never what was signed. The Operator's order sizes and prices are trusted. The block cites no economic bound: no deposit cap exists in the code (finding CV-07 of `audits/code-validation-round-1.md`), so the trust block stands on its own. Matches the style already used on every Operator-gated function in `ProphetCTFExchange.sol` and `LPVault.sol`.

**NFR-C0E4** Compatibility: `The success value shall be exactly 0x1626ba7e and the failure value shall be a fixed value distinguishable from it.`
Fit Criterion: the success path returns `0x1626ba7e` byte for byte, and every failure path returns `0xffffffff`. An almost-right magic value fails silently and identically to a rejected signature, which is the hardest class of integration bug to diagnose from on-chain evidence alone.

**NFR-C0E5** Security: `This feature shall not widen the Operator's reach over vault assets beyond the approvals already granted at initialization.`
Fit Criterion: the only new capability is that an order may now name the vault as `order.maker`. No new transfer path is added, no new approval is granted, and no Operator gains the ability to send vault assets to an address of their choosing -- the exchange remains the sole counterparty and moves assets only as part of a matched order. The blanket USDC and ERC-1155 approvals this relies on already exist and are already documented as an accepted trust boundary (CLAUDE.md security checklist item 11); this feature makes them reachable, it does not create them. The vouch answers the exchange only, so a token contract that consults the payer's `isValidSignature` (USDC `FiatTokenV2_2`, ERC-7598) cannot spend vault assets on an Operator's signature.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-C0DK and UC-C0DL pass with full coverage
- A registered Operator's signature returns `0x1626ba7e` from the exchange address, and the same signature returns `0xffffffff` once that Operator is removed, from any other caller, while paused, and after wind-down -- each pinned by a test
- No input causes `isValidSignature` to revert: empty, short, long, and arbitrary bytes are each driven and each return the failure value
- A malleated twin of a valid signature is rejected while the original is accepted
- `supportsInterface` reports EIP-1271, `IERC1155Receiver`, and `IERC165` together
- Against the vendored `ProphetCTFExchange`, two buys mint a pair into the vault, a taker sell fills the vault's buy, and the same match reverts `InvalidSignature()` once the vault is frozen
- No nonce, `intentId`, or order record is introduced anywhere in this feature
- Every added function carries an OPERATOR TRUST ASSUMPTION NatSpec block
- `forge fmt` passes; no `console.log` in production code
- `forge build --sizes --skip test --skip script` exits 0 and the report states the room left
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
