---
id: UC-3Z92
name: Operator Escrow Deposit for Intent
feature: FEAT-3ZRI
status: implemented
version: 2
actor: Operator
---

# UC-3Z92: Operator Escrow Deposit for Intent

> An Operator executes the funding step of an LP's signed mint intent, pulling the USDC from the LP's Safe into the vault and recording it as escrow that only that Safe can spend.

## Preconditions

- A vault has been deployed and initialized for a market (FEAT-REPZ UC-REQ1)
- The vault is in Active phase (phase == 1) and is not paused
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The LP's Safe holds at least `usdcAmount` USDC and has approved the vault for at least that amount through a Safe transaction `USDC.approve(vault, amount)` that the owner key signed and the Operator relayed
- The owner key signed a MintIntent (lp = the Safe, tickLower, tickUpper, usdcAmount, intentId, deadline) with the vault's EIP-712 domain

## Trigger

Operator calls `depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, signature)` on the vault.

---

### SC-3Z94: Successful escrow of a signed mint intent

**Given:**
- The Safe holds >= 600 USDC and approved the vault for >= 600
- The owner key signed a valid MintIntent: lp = the Safe, tickLower = 20, tickUpper = 80, usdcAmount = 600, intentId = X, deadline in the future
- No escrow exists for X (`pendingDeposits[X].lp == address(0)`) and `usedIntents[X] == false`

**Steps:**
1. Operator submits the signed intent to `depositForIntent`
2. System validates: phase == Active, not paused, usdcAmount > 0, deadline not passed, range valid and aligned
3. System recovers the owner key from the signature and confirms the Safe derived from it equals `lp`
4. System confirms no escrow exists for X and that X has not been used
5. System records the escrow for X: the Safe, 600, and the intent's struct hash, and adds 600 to `totalEscrowed`
6. System pulls 600 USDC from the Safe via transferFrom

**Outcomes:**
- `pendingDeposits[X] == (Safe, 600, structHash)` and `totalEscrowed` increased by 600
- The Safe's USDC balance decreased by 600; the vault's USDC balance increased by 600
- Intent X is now mintable by `mintPositionFor` and refundable by both reclaim paths, for this Safe and nobody else
- No position exists yet, and no tick state has changed

**Side Effects:**
- `DepositEscrowed(X, Safe, 600)` event emitted
- `pendingDeposits[X]` storage: set to `(Safe, 600, structHash)`
- `totalEscrowed` storage: increased by 600
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful escrow is proof the Operator is alive (FEAT-JXQO)
- No `positions` storage written
- No `ticks` storage written
- No `usedIntents` storage written -- the intent is funded, not consumed
- No `activeLiquidity` change
- No `PositionMinted` event emitted

---

### SC-45IB: The escrow entry names its depositor and the intent hash

**Given:**
- The owner key of Safe A signed a valid MintIntent for intentId X, and the Operator escrowed it

**Steps:**
1. Anyone reads `pendingDeposits(X)`

**Outcomes:**
- The entry holds Safe A, the amount, and `keccak256(abi.encode(MINT_INTENT_TYPEHASH, lp, tickLower, tickUpper, usdcAmount, intentId, deadline))`
- A read for an intentId that was never escrowed returns a zero `lp`
- The escrow is a claim held by Safe A, not a pool that any signature naming X can draw on

**Why this is required:** a valid signature does not prove who owns an intentId. Any owner key can sign a MintIntent over X that names its own Safe. The recorded Safe is what every spending path checks (ADR-45IC), and the recorded hash is what binds the range, the amount, and the deadline for the mint (FEAT-T7AF FR-3Z9W).

**Side Effects:**
- `pendingDeposits[X].lp` storage: Safe A
- `pendingDeposits[X].structHash` storage: the intent's struct hash
- No storage anywhere grants another Safe a claim on X

---

### SC-3Z95: Revert when the intent is already escrowed

**Given:**
- An escrow of 600 already exists for X from a prior `depositForIntent` for Safe A
- Operator resubmits a valid signed intent for X, for Safe A or for a different Safe B

**Steps:**
1. Operator submits the signed intent for X to `depositForIntent`
2. System verifies the signature successfully
3. System detects an existing escrow entry for X

**Outcomes:**
- Call reverts with DepositAlreadyEscrowed error
- The original escrow of 600 is untouched -- Safe A is not charged a second time
- Two depositors can never straddle one intentId

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged -- a failed call is not proof of life

---

### SC-3Z96: Revert when the intent has already been used

**Given:**
- Intent X was already consumed, by a successful `mintPositionFor` or by a completed reclaim
- `usedIntents[X] == true` and no escrow entry remains for X

**Steps:**
1. Operator submits the signed intent X to `depositForIntent`
2. System verifies the signature successfully
3. System detects `usedIntents[X] == true`

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- A spent intent can never be funded again (ADR-JAIY)

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z97: Revert on an owner key that does not derive the Safe

**Given:**
- An intent names Safe S as `lp`
- The signature comes from a key whose derived Safe is not S, OR `lp` is the signer's own address instead of its Safe, OR the signature has a high `s`, a `v` outside {27, 28}, a wrong length, or a tampered field

**Steps:**
1. Operator submits the intent to `depositForIntent`
2. System recovers the signer, derives its Safe, and finds it is not S, or the signature fails the malleability or length check

**Outcomes:**
- Call reverts with InvalidSignature error
- No USDC can be pulled from a Safe whose owner key did not sign for this exact intent

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z98: Revert on non-operator caller

**Given:**
- Caller is not a registered Operator (the LP's Safe, its owner key, Admin, Oracle, or an arbitrary address)
- The caller holds a valid signed intent

**Steps:**
1. Non-operator calls `depositForIntent` with the valid signed intent
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The Operator chokepoint holds even for a caller with valid authorization (ADR-3Z9Z)

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z99: Revert on zero amount

**Given:**
- The owner key signed a MintIntent with usdcAmount = 0

**Steps:**
1. Operator submits the signed intent to `depositForIntent`
2. System detects usdcAmount == 0

**Outcomes:**
- Call reverts with ZeroAmount error
- No escrow entry is created, so intentId X stays fundable

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9A: Revert when the vault is not Active

**Given:**
- Vault is in WindDown phase (phase == 2) or Cancelled phase (phase == 3), OR the vault is paused
- The owner key signed a valid MintIntent

**Steps:**
1. Operator submits the signed intent to `depositForIntent`
2. System detects phase != Active, or that the vault is paused

**Outcomes:**
- Call reverts with VaultNotActive error in WindDown or Cancelled, and with TradingIsPaused error while paused
- No new USDC enters a vault that cannot mint

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9B: Failed escrow leaves the Operator silence timer untouched

**Given:**
- Vault is in Active phase
- `lastOperatorActivityTimestamp` holds some earlier value T

**Steps:**
1. Operator submits a deposit that fails validation -- for example a duplicate escrow (SC-3Z95) or a zero amount (SC-3Z99)
2. The whole transaction reverts

**Outcomes:**
- The call reverts with the relevant error
- `lastOperatorActivityTimestamp` is still T -- a failed call is not proof of life

**Side Effects:**
- No state changes at all
- No events emitted

---

### SC-9OY9: Revert after the deadline

**Given:**
- The owner key signed a valid MintIntent with deadline = T
- The Safe holds and approved the USDC

**Steps:**
1. Operator calls `depositForIntent` at `block.timestamp = T + 1`
2. System detects `block.timestamp > deadline`

**Outcomes:**
- Call reverts with IntentExpired error
- The same call at `block.timestamp = T` succeeds; a deadline is inclusive

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-9OYA: Revert on an inverted, out-of-scale, or misaligned range

**Given:**
- Vault with tickSpacing = 10
- The owner key signed a MintIntent with tickLower >= tickUpper, OR with tickLower < 0 or tickUpper > 10000, OR with a tick that is not a multiple of 10

**Steps:**
1. Operator submits the signed intent to `depositForIntent`
2. System detects the inverted range, the tick outside the price scale, or the misaligned tick

**Outcomes:**
- Call reverts with InvalidRange error for the inverted range and for the range outside [0, 10000], and with TickNotAligned error for the misaligned tick
- The vault never takes USDC it can only refund

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-9OYB: The derived Safe matches the deployed Safe factory

**Given:**
- A factory built with the Polygon Safe factory `0xD0d6655B69d5589402593a854836bbe5305ab09B` and the hash `0x4b856c0ca50349cc4a9add5f9bfa9cb369b54f8b87f90023a3fb45b49eadec50`
- The test key `0xA11CE`, whose owner address is `0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7`
- A second factory built with the Amoy Safe factory `0x0F95cE955dE28995F41f0A89B61aEa1c5e8F4c7a` and the hash `0x182112daed9969029a2a0edb10305e67a23eb3aa54543a1b8c7c08e9c8977c48`

**Steps:**
1. The owner key signs an intent naming `lp = 0x511894A9736bdE6F848364A33e81F67cC183655E` on the Polygon vault, and the Operator escrows it
2. The owner key signs an intent naming its own address as `lp` on the Polygon vault, and the Operator submits it
3. The owner key signs an intent naming `lp = 0x40953b353BFFa880AD4EF3A38f994625fD92aEf3` on the Amoy vault, and the Operator escrows it

**Outcomes:**
- Step 1 succeeds; step 2 reverts with InvalidSignature; step 3 succeeds
- Both expected Safe addresses were read from the live factories' `computeProxyAddress` on 2026-09-12, so the vault's formula matches the deployed contracts

**Side Effects:**
- `pendingDeposits` written for the two accepted intents
- No state change for the rejected intent

---

### SC-9OYC: A plain USDC transfer is not a deposit

**Given:**
- A Safe transferred 600 USDC to the vault directly, and the owner key signed a MintIntent for intentId X
- No `depositForIntent` was called for X

**Steps:**
1. Operator calls `mintPositionFor` for X
2. The Safe calls `reclaimDeposit(X)`

**Outcomes:**
- Step 1 reverts with DepositNotEscrowed error
- Step 2 reverts with DepositNotEscrowed error
- `totalEscrowed` is 0

**Side Effects:**
- No state changes
- No position created
- No USDC transferred by either call

---

### SC-9OYD: Revert when the Safe allowance is missing

**Given:**
- The Safe holds 600 USDC but approved the vault for less than 600
- The owner key signed a valid MintIntent for 600

**Steps:**
1. Operator submits the signed intent to `depositForIntent`
2. System writes nothing before the pull, and the pull fails

**Outcomes:**
- Call reverts with TransferFailed error
- No escrow entry exists for the intent

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---
