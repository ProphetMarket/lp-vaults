---
id: UC-6HBP
name: Redeem Outcome Tokens After Resolution
feature: FEAT-6HBN
status: implemented
version: 1
actor: Oracle
---

# UC-6HBP: Redeem Outcome Tokens After Resolution

> The Oracle turns the vault's YES and NO tokens into USDC after the market's result reaches the ConditionalTokens contract, and that call switches every later payout to USDC at the reported payout.

## Preconditions

- The vault was created with a verified outcome-token identity (UC-REQ1), so `conditionId`, `yesTokenId`, and `noTokenId` name its market
- Prophet's `Resolution.finalizePayouts` forwarded the result to the ConditionalTokens contract, so `payoutDenominator(conditionId)` is non-zero, unless a scenario says otherwise
- The Oracle called `startWindDown`, or any address froze the vault, unless a scenario says otherwise

## Trigger

The Oracle calls `redeemOutcomeTokens()` on the vault.

---

### SC-6HCD: Oracle redeems after YES wins

**Given:**
- The ConditionalTokens contract holds payouts `[1, 0]`, so `payoutDenominator(conditionId) == 1`
- The Oracle called `startWindDown`
- The vault holds 100 YES, 60 NO, and B USDC

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()`
2. The vault checks that the phase is not Active
3. The vault reads `payoutDenominator(conditionId) = 1`
4. The vault reads the numerators `(1, 0)` from the ConditionalTokens contract and stores them, because the slot was zero
5. The vault reads its balances: 100 YES and 60 NO
6. The vault calls `redeemPositions(usdc, bytes32(0), conditionId, [1, 2])`
7. ConditionalTokens burns 100 YES and 60 NO and pays `100 × 1 ÷ 1 + 60 × 0 ÷ 1 = 100` USDC to the vault

**Outcomes:**
- The vault holds 0 YES, 0 NO, and B + 100 USDC
- `payoutNumerators()` returns `(1, 0)`
- The phase stays WindDown

**Side Effects:**
- `OutcomeTokensRedeemed(oracle, 100e6, 60e6, 100e6)` emitted by the vault
- `PayoutRedemption` emitted by ConditionalTokens
- No `CompleteSetsMerged` event
- `lastOperatorActivityTimestamp` unchanged

---

### SC-6HCE: Oracle redeems after a cancelled market

**Given:**
- The ConditionalTokens contract holds payouts `[1, 1]`, so `payoutDenominator(conditionId) == 2`
- The phase is WindDown
- The vault holds 100 YES, 60 NO, and B USDC

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()`
2. The vault stores `(1, 1)`
3. ConditionalTokens pays `100 × 1 ÷ 2 + 60 × 1 ÷ 2 = 50 + 30 = 80` USDC

**Outcomes:**
- The vault holds 0 YES, 0 NO, and B + 80 USDC
- `payoutNumerators()` returns `(1, 1)`

**Side Effects:**
- `OutcomeTokensRedeemed(oracle, 100e6, 60e6, 80e6)` emitted
- `PayoutRedemption` emitted by ConditionalTokens

---

### SC-6HCF: Redemption reverts before the result exists

**Given:**
- `payoutDenominator(conditionId) == 0`
- The phase is WindDown
- The vault holds 100 YES and 60 NO

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()`

**Outcomes:**
- The call reverts with `MarketNotResolved`
- Balances do not change
- `payoutNumerators()` stays `(0, 0)`

**Side Effects:**
- No `redeemPositions` call
- No event

---

### SC-6HCG: Non-Oracle callers cannot redeem

**Given:**
- The result is reported and the phase is WindDown
- The caller is the Operator, an Admin, an LP's Safe, or an address with no role

**Steps:**
1. The caller calls `redeemOutcomeTokens()`

**Outcomes:**
- Every call reverts with `NotOracle`

**Side Effects:**
- No state change
- No event

---

### SC-6HCH: Redemption reverts while Active and runs again in WindDown

**Given:**
- The result `[1, 0]` is reported
- The vault holds 10 YES and 0 NO

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()` while the phase is Active
2. The Oracle calls `startWindDown()`
3. The Oracle calls `redeemOutcomeTokens()`
4. The Oracle calls `redeemOutcomeTokens()` again
5. 5 YES arrive in the vault
6. The Oracle calls `redeemOutcomeTokens()` a third time

**Outcomes:**
- The first call reverts `VaultStillActive`
- The second redeems 10 YES and emits `OutcomeTokensRedeemed(oracle, 10e6, 0, 10e6)`
- The third succeeds, makes no `redeemPositions` call, and emits nothing
- The fourth redeems the 5 YES
- The phase stays WindDown

**Side Effects:**
- `PayoutRedemption` from ConditionalTokens in the second and fourth calls only
- No event from the first and third calls

---

### SC-6HCI: Redemption works after an emergency cancel

**Given:**
- The vault is in Cancelled phase (3) after `emergencyCancelAll()`
- The result `[1, 0]` is reported
- The vault holds 10 YES

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()`

**Outcomes:**
- The vault gains 10 USDC
- `payoutNumerators()` returns `(1, 0)`
- The phase stays Cancelled

**Side Effects:**
- `OutcomeTokensRedeemed(oracle, 10e6, 0, 10e6)` emitted
- No change to `phase`

---

### SC-CYS6: A numerator above 2^128 leaves the switch off

**Given:**
- The condition's oracle reported `[2^128, 0]`
- The phase is WindDown
- The vault holds 10 YES, and the Safe owns a position whose band holds those 10 YES

**Steps:**
1. The Oracle calls `redeemOutcomeTokens()`
2. The Safe burns its position

**Outcomes:**
- The first call reverts `SafeCastOverflow`, and `payoutNumerators()` stays `(0, 0)`
- The burn pays the 10 YES in kind

**Side Effects:**
- No `redeemPositions` call from the first call
- No event from the first call
- `TransferSingle` from the ConditionalTokens contract during the burn

---
