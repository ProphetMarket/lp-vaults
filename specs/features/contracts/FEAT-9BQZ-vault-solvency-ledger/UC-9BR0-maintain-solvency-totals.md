---
id: UC-9BR0
name: Maintain Solvency Totals
feature: FEAT-9BQZ
status: implemented
version: 2
actor: Operator
---

# UC-9BR0: Maintain Solvency Totals

> Every vault operation that changes what the vault owes moves the matching running total in the same call, so the ledger answers "what do we owe, per asset" at any moment without iterating a single position.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`yesTokenId`, `noTokenId`)
- The vault's phase is Active or WindDown unless a scenario states otherwise
- All seven totals are readable through public views

## Trigger

Any vault operation that creates, discharges, or transforms an obligation -- a mint, a burn, a fee collection, a fee notification, an escrow deposit, a reclaim, an emergency cancellation, or a merge.

---

### SC-9BRZ: Mint increments principal totals by the position's starting split

**Given:**
- Ledger totals are all zero
- An escrowed mint intent for an LP, at a market ratio that produces an unbalanced split

**Steps:**
1. Operator calls `mintPositionFor` for the LP's intent
2. System creates the position and records its starting asset split
3. System raises each principal total by that split's share of the corresponding asset

**Outcomes:**
- `totalUsdcOwed`, `totalYesOwed`, and `totalNoOwed` each equal the new position's starting amount of that asset
- `totalYesOwed` and `totalNoOwed` differ from one another, because the mint exchanged USDC for shares at the market ratio rather than a balanced one
- The fee totals are unchanged
- Reading the totals costs no iteration over `positions`

**Side Effects:**
- `totalUsdcOwed`, `totalYesOwed`, `totalNoOwed` storage: each increased by the position's starting amount of that asset
- `totalEscrowed` storage: decreased by the consumed escrow
- No fee total written
- No price, oracle, or valuation read

---

### SC-9BS0: Burn decrements principal totals by the position's current split

**Given:**
- A live position whose split has shifted since mint because the price moved
- Principal totals reflect that position alongside others

**Steps:**
1. LP calls `burnPosition` for their position
2. System computes the position's payout composition at the current price
3. System lowers each principal total by that composition's amount of the corresponding asset

**Outcomes:**
- Each principal total falls by exactly what the burn paid out for that asset, before any ratio scaling
- The decrement matches the split at burn time, not the split recorded at mint
- The remaining totals still equal the obligations of the positions that are still live

**Side Effects:**
- `totalUsdcOwed`, `totalYesOwed`, `totalNoOwed` storage: each decreased by the burned position's current amount of that asset
- Fee totals decreased by the fees the same call paid out
- No total left overstating an obligation the burn discharged

---

### SC-9BS1: Fee collection leaves principal totals unchanged

**Given:**
- A live position with accrued fees
- Principal totals reflect that position's principal claim

**Steps:**
1. LP calls `collect` for their position
2. System pays the accrued fees and leaves the position open
3. System lowers only the fee totals

**Outcomes:**
- `totalUsdcOwed`, `totalYesOwed`, and `totalNoOwed` read identically before and after
- The fee total for each paid asset falls by the amount actually transferred
- The position remains live with its liquidity and tick range unchanged, so its principal claim is genuinely unchanged

**Side Effects:**
- Fee totals storage: decreased by the amounts paid
- No principal total written
- No `activeLiquidity` write
- No tick state write

---

### SC-9BS2: Fee notification increments the fee total for the asset it arrived in

**Given:**
- A vault with nonzero active liquidity
- Fee totals at known values

**Steps:**
1. Operator notifies fees that the exchange settled in outcome tokens rather than USDC
2. System raises the fee total for that asset alone

**Outcomes:**
- The fee total for the notified asset rises by the notified amount
- The other two fee totals are unchanged
- All three fee totals are reachable across calls, because which asset a fee arrives in follows the fill the exchange executed and not a choice the vault makes

**Side Effects:**
- The notified asset's fee total storage: increased by the notified amount
- No principal total written
- No `totalEscrowed` write

---

### SC-9BS3: Escrow deposit raises totalEscrowed and the consuming mint lowers it

**Given:**
- An LP-signed mint intent not yet fulfilled
- `totalEscrowed` at a known value

**Steps:**
1. Operator calls `depositForIntent`, pulling the LP's USDC into the vault
2. System raises `totalEscrowed` by the deposited amount in that same call
3. Operator later calls `mintPositionFor` against the same intent
4. System lowers `totalEscrowed` by the consumed amount as it raises the principal totals

**Outcomes:**
- After the deposit, `totalEscrowed` includes the pending amount and the vault's USDC balance includes the USDC backing it
- After the mint, `totalEscrowed` has fallen by the consumed amount and the principal totals have risen by the new position's split
- The obligation is never double-counted across the two calls, and never dropped between them -- it changes form from a pending refund into a live position claim

**Side Effects:**
- `totalEscrowed` storage: increased on deposit, decreased on the consuming mint
- Principal totals storage: increased in the same call that decreases `totalEscrowed`
- No fee total written by either call

---

### SC-9BS4: Reclaim refund lowers totalEscrowed

**Given:**
- An escrowed deposit against an intent that was never minted
- `totalEscrowed` includes that deposit

**Steps:**
1. LP reclaims the unfulfilled deposit
2. System refunds the USDC and lowers `totalEscrowed`

**Outcomes:**
- `totalEscrowed` falls by exactly the amount refunded, which is the amount transferred after `usdcRatio` is applied rather than the amount originally escrowed
- No principal total moves, because no position ever existed for this intent

**Side Effects:**
- `totalEscrowed` storage: decreased by the refunded amount
- No principal total written
- No fee total written

---

### SC-9BS5: Emergency cancellation discharges every total it pays out

**Given:**
- A vault with several live positions and accrued fees
- The operator-silence timelock has elapsed
- All seven totals hold nonzero values

**Steps:**
1. A position holder calls `emergencyCancelAll`
2. System pays out every live position's principal and fees and enters the terminal cancelled state
3. System reduces every total by the obligations that payout discharged

**Outcomes:**
- No total is left claiming an obligation the cancellation discharged
- The ratios computed against the drained vault do not report a total shortfall against obligations that no longer exist
- The vault is in its terminal state with a ledger that agrees with it

**Side Effects:**
- All seven totals storage: reduced by the discharged obligations
- `phase` storage: set to the cancelled state
- `activeLiquidity` storage: zeroed

---

### SC-9BS6: Merge leaves every total unchanged

**Given:**
- Two live positions with the same owner and the same tick range, each with uncollected fees
- At least one position's deposit does not divide evenly by its range width, so the `liquidity` derived from it truncates
- All seven totals at known values

**Steps:**
1. Operator calls `mergePositions` for the two positions
2. System combines them into one survivor, preserving total liquidity and rolling the consumed position's fees into the survivor's record

**Outcomes:**
- All seven totals read byte-identical before and after
- The vault's obligations are unchanged in both composition and amount: no assets moved, the range is the same, and the fees were rolled up rather than paid
- The survivor's reconstructed claim may exceed the sum of the credits recorded for the positions it consumed, by up to one base unit per asset leg per position merged away -- principal is reconstructed from a truncated `liquidity`, and the merge collapses those truncations into one. The totals are still not adjusted to match: the discrepancy is a documented dust convention (ADR-9Q3Y), carried in NFR-9BRX's tolerance

**Side Effects:**
- No ledger total written at all
- No token transfer

---

### SC-9BS7: Opposing tilts are reported separately, never netted

**Given:**
- One position tilted heavily toward YES and another tilted heavily toward NO
- The vault holds neither outcome token in the amounts these positions are owed

**Steps:**
1. An observer reads `totalYesOwed` and `totalNoOwed`
2. An observer reads `yesRatio` and `noRatio`

**Outcomes:**
- `totalYesOwed` and `totalNoOwed` each report their own obligation in full, and neither is reduced by the other
- Both `yesRatio` and `noRatio` report below unity, each against its own obligation
- The vault does not report itself solvent: under a single signed net the two tilts would cancel and a vault holding neither token would look fully covered while unable to pay either side

**Side Effects:**
- No storage written -- both reads are views
- No price or valuation read

---
