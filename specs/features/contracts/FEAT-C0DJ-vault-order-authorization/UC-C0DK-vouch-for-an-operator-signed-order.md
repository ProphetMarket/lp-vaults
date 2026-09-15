---
id: UC-C0DK
name: Vouch for an Operator-Signed Order
feature: FEAT-C0DJ
status: implemented
version: 3
actor: Operator
---

# UC-C0DK: Vouch for an Operator-Signed Order

> An Operator gets the vault to stand behind a signature they produced, so an order naming the vault as maker passes the exchange's signature check.

## Preconditions

- Vault is deployed and initialized, with `exchange` fixed at `initialize()`
- The operator registry on the factory holds at least one registered Operator
- The caller holds the hash the signature was produced over

## Trigger

The exchange calls `isValidSignature(hash, signature)` on the vault.

---

### SC-C0DM: Registered Operator's signature is vouched for

**Given:**
- The vault is Active and not paused
- The signing key is registered, so `operators[signer] == 1`
- The signature is well formed: 65 bytes, `s` in the lower half of the curve order, `v` in {27, 28}

**Steps:**
1. Operator signs the order hash with their registered key
2. Exchange asks the vault to validate that signature over that hash
3. System recovers the signer from the signature
4. System finds the recovered address in the operator registry
5. System returns the ERC-1271 magic value

**Outcomes:**
- The exchange receives `0x1626ba7e`
- The exchange's signature check passes and the order is treated as authored by the vault
- Vault-held capital becomes fillable for the first time -- every other signature type the exchange supports is structurally closed to an EIP-1167 clone

**Side Effects:**
- No storage written -- validation is a view
- No event emitted
- No nonce consumed and no order recorded; order lifecycle stays with the exchange

---

### SC-C0DN: Signature from a non-operator is refused

**Given:**
- The signing key was never added to the operator registry

**Steps:**
1. A key that is not a registered Operator signs the order hash
2. Exchange asks the vault to validate that signature
3. System recovers the signer and finds no registry entry for it
4. System returns the failure value

**Outcomes:**
- The exchange receives `0xffffffff`
- The exchange rejects the order and no vault assets move
- Anyone may sign anything naming the vault as maker; only the registry decides whether it counts

**Side Effects:**
- No storage written
- No event emitted
- No revert -- the caller gets a value it can branch on rather than a failed transaction

---

### SC-C0DO: Operator revoked between signing and filling is refused

**Given:**
- An Operator signed the order hash while they were registered
- The Admin has since removed that address from the operator registry
- The order has not been filled

**Steps:**
1. Admin removes the Operator from the registry
2. Exchange asks the vault to validate the signature produced earlier
3. System recovers the same signer as before
4. System evaluates that signer against the registry as it stands now and finds no entry
5. System returns the failure value

**Outcomes:**
- A signature that was valid when produced no longer authorizes anything
- Every unfilled order that key ever signed dies on the single registry write, with no per-order revocation list to maintain and no window in which a removed Operator's outstanding orders can still fill
- Removing a compromised Operator is sufficient response on its own

**Side Effects:**
- No storage written by the validation itself
- No event emitted
- No cancellation message sent to the exchange -- revocation is passive, and the vault never learns which orders existed

---

### SC-C0DP: Malleable high-s signature is refused

**Given:**
- A valid signature from a registered Operator
- Its malleated twin, with `s` replaced by `n - s` and `v` flipped

**Steps:**
1. Exchange presents the malleated twin over the same hash
2. System sees `s` above secp256k1n/2
3. System returns the failure value

**Outcomes:**
- The original signature returns `0x1626ba7e` and the twin returns `0xffffffff`
- One authorization cannot exist as two distinct byte strings, so any off-chain system that treats the signature bytes as an identity stays correct

**Side Effects:**
- No storage written
- No event emitted
- No revert

---

### SC-C0DQ: Recovery identifier outside the accepted pair is refused

**Given:**
- A signature whose `v` byte is a value other than 27 or 28, such as 0, 1, or 29

**Steps:**
1. Exchange presents the signature
2. System sees `v` outside {27, 28}
3. System returns the failure value

**Outcomes:**
- The exchange receives `0xffffffff`
- The system makes no attempt to normalize `v` into the accepted range -- a caller that got it wrong is told so rather than quietly corrected

**Side Effects:**
- No storage written
- No event emitted
- No revert

---

### SC-C0DR: Malformed or empty signature returns a value rather than reverting

**Given:**
- Signature bytes that are empty, shorter than 65 bytes, or longer than 65 bytes

**Steps:**
1. Exchange presents the malformed bytes
2. System sees the length is not 65
3. System returns the failure value

**Outcomes:**
- The call completes normally and the exchange receives `0xffffffff`
- Probing the vault with arbitrary bytes cannot make the call revert, so the method cannot be used to grief a caller that speculatively checks it

**Side Effects:**
- No storage written
- No event emitted
- No revert -- this is the distinguishing outcome of this scenario, and the one an implementation that decodes before length-checking would fail

---

### SC-CVPZ: Paused vault refuses a vouched signature and accepts it again after unpause

**Given:**
- A signature that SC-C0DM vouches for, on an Active vault

**Steps:**
1. Admin calls `pauseTrading`
2. Exchange asks the vault to validate the signature
3. System sees `paused == true` and returns the failure value before it recovers a signer
4. Admin calls `unpauseTrading`
5. Exchange asks the vault to validate the same signature
6. System returns the ERC-1271 magic value

**Outcomes:**
- While paused, the exchange receives `0xffffffff` and the match fails at the signature check, so a paused vault takes no new fill
- After the unpause, the exchange receives `0x1626ba7e` for the same bytes, so a pause retires no signature

**Side Effects:**
- No storage written by the validation itself
- No event emitted by the validation
- No resting order cancelled by the vault: the keeper cancels its orders when it sees `TradingPaused`

---

### SC-CVQ0: Wound-down vault refuses every signature

**Given:**
- A signature that SC-C0DM vouches for
- The Oracle has called `startWindDown`, so the phase is WindDown

**Steps:**
1. Exchange asks the vault to validate the signature
2. System sees `phase != Active` and returns the failure value before it recovers a signer

**Outcomes:**
- The exchange receives `0xffffffff`
- No order can fill against a wound-down vault, whose claims are paid at a fixed tick from now on (decision C22)

**Side Effects:**
- No storage written
- No event emitted
- No resting order cancelled by the vault: the keeper cancels its orders when it sees `VaultWindDownStarted`

---

### SC-CVQ1: A caller other than the exchange is refused

**Given:**
- A signature that SC-C0DM vouches for, on an Active, unpaused vault

**Steps:**
1. A wallet that is not the vault's configured exchange asks the vault to validate the signature
2. System sees `msg.sender != exchange` and returns the failure value before it recovers a signer
3. Exchange asks the vault to validate the same signature
4. System returns the ERC-1271 magic value

**Outcomes:**
- The wallet receives `0xffffffff` and the exchange receives `0x1626ba7e` for the same hash and bytes
- A token contract that consults the payer's `isValidSignature` (USDC `FiatTokenV2_2`, ERC-7598) cannot spend vault assets on an Operator's signature, so the vouch is consumable only by a matched order on the exchange

**Side Effects:**
- No storage written
- No event emitted
- No revert -- the refusal is a returned value, as every refusal in this use case

---
