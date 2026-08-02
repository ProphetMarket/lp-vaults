---
id: UC-3Z92
name: Operator Escrow Deposit for Intent
feature: FEAT-3ZRI
status: implemented
version: 2
actor: Operator
---

# UC-3Z92: Operator Escrow Deposit for Intent

> An Operator executes the funding step of an LP's signed EIP-712 mint intent, pulling the LP's USDC into the vault and recording it as escrow attributable to that exact intentId.

## Preconditions

- A vault has been deployed and initialized for a market (FEAT-REPZ UC-REQ1)
- The vault is in Active phase (phase == 1)
- The Operator is registered in the vault's role registry (`operators[operator] == 1`)
- The LP has approved the vault contract to spend their USDC (`IERC20(usdc).approve(vault, amount)`)
- The LP has signed an EIP-712 MintIntent off-chain; the same signature will later authorize `mintPositionFor`

## Trigger

Operator calls `depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, lpSignature)` on the vault.

---

### SC-3Z94: Successful escrow of a signed mint intent

**Given:**
- Vault in Active phase, LP has approved the vault for >= 600 USDC and holds >= 600 USDC
- LP signed a valid MintIntent: lp = LP address, tickLower = 20, tickUpper = 80, usdcAmount = 600, intentId = X
- No escrow exists for X (`pendingDeposits[X].lp == address(0)`) and `usedIntents[X] == false`

**Steps:**
1. Operator submits the LP's signed intent to `depositForIntent`
2. System verifies the EIP-712 signature matches the LP's address using the cached domain separator
3. System validates: phase == Active, usdcAmount > 0
4. System confirms no escrow exists for intentId X and that X has not already been used
5. System records the escrow for intentId X against the LP's address
6. System pulls 600 USDC from the LP's wallet via transferFrom

**Outcomes:**
- `pendingDeposits[X].lp == LP address` and `pendingDeposits[X].amount == 600`
- LP's USDC balance decreased by 600; vault's USDC balance increased by 600
- Intent X is now fundable by `mintPositionFor` and refundable by the reclaim paths, for this LP and nobody else
- No position exists yet, and no tick state has changed

**Side Effects:**
- `DepositEscrowed(intentId, lp, usdcAmount)` event emitted
- `pendingDeposits[X]` storage: set to `(lp, 600)`
- `lastOperatorActivityTimestamp` storage: refreshed to `block.timestamp` -- a successful escrow is proof the Operator is alive (FEAT-JXQO)
- No `positions` storage written
- No `ticks` storage written
- No `usedIntents` storage written -- the intent is funded, not consumed
- No `activeLiquidity` change
- No `PositionMinted` event emitted

---

### SC-45IB: The escrow entry names its depositor

**Given:**
- LP A signed a valid MintIntent for intentId X and the Operator escrowed it
- An unrelated wallet, LP B, holds no escrow

**Steps:**
1. Operator submits LP A's signed intent to `depositForIntent`
2. System records the escrow against LP A

**Outcomes:**
- `pendingDeposits[X].lp` is LP A's address, readable on-chain by every consuming path
- The escrow is a claim held by LP A specifically, not a pool of USDC that any signature naming intentId X can draw on

**Why this is required, not merely tidy:** the EIP-712 scheme does not bind an intentId to an LP. `_verifyMintIntent` recovers a signer and compares it against a caller-supplied `lp` argument, so LP B can produce a signature that verifies over intentId X by signing with B's own key and naming B's own address. The recorded owner is the only thing that distinguishes A's deposit from B's forged claim on it. intentIds are published in the `DepositEscrowed` log, so an attacker does not even need to guess one.

**Side Effects:**
- `pendingDeposits[X].lp` storage: set to LP A's address
- No storage anywhere grants LP B a claim on intentId X

---

### SC-3Z95: Revert when the intent is already escrowed

**Given:**
- An escrow of 600 already exists for X from a prior successful `depositForIntent` by LP A
- Operator resubmits a valid signed intent for X

**Steps:**
1. Operator submits a valid signed intent for X to `depositForIntent`
2. System verifies the signature successfully
3. System detects an existing escrow entry for X (`pendingDeposits[X].lp != address(0)`)

**Outcomes:**
- Call reverts with DepositAlreadyEscrowed error
- The original escrow of 600 is untouched -- LP A is not charged a second time
- This holds whether the resubmission names LP A again or a different LP B, so two depositors can never straddle one intentId

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged -- a failed call is not proof of life

---

### SC-3Z96: Revert when the intent has already been used

**Given:**
- Intent X was already consumed, either by a successful `mintPositionFor` or by a completed reclaim
- `usedIntents[X] == true` and no escrow entry remains for X (the consuming path deleted it)

**Steps:**
1. Operator submits the LP's signed intent X to `depositForIntent`
2. System verifies the signature successfully
3. System detects `usedIntents[X] == true`

**Outcomes:**
- Call reverts with IntentAlreadyUsed error
- A spent intent can never be re-funded, so the LP cannot be charged again for a position they already hold or a deposit already refunded

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z97: Revert on invalid LP signature

**Given:**
- Operator submits an intent naming an LP who is not the actual signer
- OR the signature has been tampered with (wrong v, high-s, or modified fields)

**Steps:**
1. Operator submits the intent to `depositForIntent`
2. System recovers the signer from the EIP-712 signature
3. System detects the recovered signer != the named LP, or the signature fails the malleability check

**Outcomes:**
- Call reverts with InvalidSignature error
- No USDC can be pulled from a wallet whose owner did not sign for this exact intent

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z98: Revert on non-operator caller

**Given:**
- Caller is not a registered Operator (the LP themselves, Admin, Oracle, or an arbitrary address)
- The caller holds a genuinely valid LP-signed intent

**Steps:**
1. Non-operator calls `depositForIntent` with the LP's valid signed intent
2. System detects `operators[msg.sender] != 1`

**Outcomes:**
- Call reverts with NotOperator error
- The Operator chokepoint holds even for a caller holding valid LP authorization, preserving the front-running protection described in ADR-3Z9Z

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z99: Revert on zero amount

**Given:**
- LP signed a MintIntent with usdcAmount = 0

**Steps:**
1. Operator submits the LP's signed intent to `depositForIntent`
2. System detects usdcAmount == 0

**Outcomes:**
- Call reverts with ZeroAmount error
- No escrow entry is created, so intentId X stays genuinely fundable rather than holding a zero-value entry that could never be minted (minting rejects a zero usdcAmount) and could only be unwound through the 24-hour reclaim timelock

**Side Effects:**
- No state changes
- No USDC transferred
- No events emitted
- `lastOperatorActivityTimestamp` unchanged

---

### SC-3Z9A: Revert when the vault is not Active

**Given:**
- Vault is in WindDown phase (phase == 2) or Cancelled phase (phase == 3)
- LP signed a valid MintIntent with a correct range and amount

**Steps:**
1. Operator submits the LP's signed intent to `depositForIntent`
2. System detects phase != Active

**Outcomes:**
- Call reverts with VaultNotActive error
- No new USDC enters a vault that can no longer mint positions, so no deposit can be stranded awaiting a mint that would always revert

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
- `lastOperatorActivityTimestamp` is still T -- a failed call is not proof of life, so a stuck Operator cannot hold off `emergencyCancelAll` by spamming reverting deposits

**Side Effects:**
- No state changes at all
- No events emitted

---
