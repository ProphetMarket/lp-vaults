---
id: UC-9BR2
name: Apply Payout Ratios
feature: FEAT-9BQZ
status: implemented
version: 6
actor: LP
---

# UC-9BR2: Apply Payout Ratios

> An LP who exits receives the whole claim when the vault can cover it, and the same share as every other claimant when it cannot, per asset before the switch and as one USDC sum after it, never as a failed transaction, and the cut is final.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set
- The three totals are maintained per UC-9BR0 and UC-9BR1
- The Safe holds a live position; unless a scenario says otherwise it is the R9 example (300 USDC over `[5500, 6500)` minted at 6000, `liquidity = 3e23`), and a shortfall is made the way a fill makes one: the exchange's standing approval moves USDC out of the vault
- No scenario requires the vault to be paused, wound down, or frozen; every payout works the same in every phase (FEAT-7G40 FR-7G4V)

## Trigger

The Safe calls `burnPosition` on a position it owns, or the Operator relays the owner key's `BurnIntent` through `burnPositionFor`.

Since R18 every burn credits the measured spread before it values the claim, the USDC ratio's denominator carries `totalSpreadOwed()`, and `PositionBurned` carries nine fields with `spreadOwed` and `spreadPaid` after `usdcPaid` (FEAT-E943 UC-E944, FR-9BRM, FR-9BRR). A burn whose debit takes `totalUsdcOwedScaled` to zero is the last live position's burn and also pays every USDC the vault holds above escrow and every token it still holds, reporting the excess in `ResidueSwept` (FEAT-E943 FR-E94C). In a shortfall scenario below the vault holds less than it owes, so the credit is zero and both spread fields read zero; the sweep still runs on the burn that empties the USDC total, and carries zeros when nothing is left over.

---

### SC-9BSC: A covered vault pays every claim in full

**Given:**
- The vault at 5700 holds 500 YES and 1,300 USDC against one position owed 247.3545 USDC plus 90 YES

**Steps:**
1. The Safe calls `burnPosition`
2. System reads both token balances, finds no free pair because it holds no NO, and reads its USDC balance
3. System measures 1,052,645,500 units of surplus, `1,300,000,000 − 247,354,500`, and credits 1,052,645,499 of it to the only liquidity in range, one unit below the measurement because the growth is floored per unit of liquidity, this position
4. System computes the USDC ratio and the YES ratio, both 1, and pays the claim and the spread in full
5. The ledger debit takes `totalUsdcOwedScaled` to zero, so the closing sweep runs

**Outcomes:**
- The Safe receives 1,300,000,000 USDC units in one transfer, 247,354,500 of principal, 1,052,645,499 of spread, and the one unit the sweep carries, and all 500 YES
- The vault keeps nothing above `totalEscrowed`: this is the last live position, so the sweep pays it every USDC above escrow and every remaining token (FEAT-E943 FR-E94C)
- A surplus is still never a bonus through the ratio, which stays capped at 1 (FR-9BRP). It reaches this LP as owed spread, which is what the credit is for

**Side Effects:**
- USDC and YES transferred to the Safe
- The totals storage: debited by the scaled claim and the scaled spread, to zero
- `SpreadCredited(1052645499, spreadGrowthGlobalX128)`, then `ResidueSwept(positionId, safe, 1, 410000000, 0)`, then `PositionBurned(positionId, safe, 247354500, 247354500, 1052645499, 1052645499, yesTokenId, 90000000, 90000000)` emitted, because `PositionBurned` reports the claim's own legs and `ResidueSwept` reports what went beyond them

---

### SC-9BSD: Three burns in a row each receive the same ratio

**Given:**
- Three positions of the R9 example, owned by the Safe, the vault at 5700, so `totalUsdcOwed() == 742,063,500` and `totalYesOwed() == 270,000,000`
- Case A: the vault holds 150 YES and every USDC it owes
- Case B: the vault holds 270 YES and its USDC was drained to 371,031,750, half of what it owes

**Steps:**
1. The Safe burns the first position
2. The Safe burns the second position
3. The Safe burns the third position

**Outcomes:**
- Case A: each burn pays 50 YES (`90 × 150 / 270`) and 247,354,500 USDC; after the first burn the vault holds 100 YES against 180 owed, the same ratio of 5/9, and after the third it holds no YES and owes none
- Case B: each burn pays 123,677,250 USDC (half) and all 90 YES; after the third the vault's USDC balance is zero and its USDC total reads zero
- No burn is made whole at another's expense and none is left with nothing because it came last

**Side Effects:**
- Case A: three `PositionBurned` events with `spreadOwed = spreadPaid = 0`, `tokenOwed = 90000000`, and `tokenPaid = 50000000`; `totalYesOwedScaled` falls by `3e23 × 300` per burn
- Case B: three `PositionBurned` events with `usdcOwed = 247354500`, `usdcPaid = 123677250`, and `spreadOwed = spreadPaid = 0`; `totalUsdcOwedScaled` falls by the full scaled claim per burn
- No `SpreadCredited` in either case: the vault holds no USDC above what it owes
- `ResidueSwept(positionId, safe, 0, 0, 0)` on the third burn in both cases, which takes the USDC total to zero and finds nothing left over
- No revert on any burn

---

### SC-9BSE: Escrowed USDC never pays a burn

**Given:**
- The Safe's position is at its mint tick, so its claim is 300 USDC only
- Another Safe escrowed 500 USDC that the Operator never minted, and the vault's USDC balance was drained below `totalEscrowed`

**Steps:**
1. The Safe calls `burnPosition`
2. System computes the USDC held as `balance + free pairs − totalEscrowed`, floored at zero, so the USDC ratio is zero
3. System pays zero USDC and does not revert

**Outcomes:**
- The Safe receives nothing, the position is deleted, and `totalUsdcOwed()` falls by 300,000,000
- The pending depositor's later reclaim pays the recorded 500 USDC, because escrowed USDC is senior (decision C7) and the reclaim applies no ratio

**Side Effects:**
- `PositionBurned(positionId, safe, 300000000, 0, 0, 0, 0, 0, 0)` emitted, and `ResidueSwept(positionId, safe, 0, 0, 0)` before it, because the debit takes the USDC total to zero and the vault holds nothing above `totalEscrowed`
- No `SpreadCredited`: the USDC above escrow is zero, so there is no surplus to measure
- No USDC transfer
- `totalEscrowed` unchanged
- `totalUsdcOwedScaled` storage: debited by the full scaled claim

---

### SC-9BSF: A shortfall in one asset does not cut the others

**Given:**
- Two positions of the R9 example, the vault at 5700, so 180 YES and 494,709,000 USDC are owed
- The vault holds 90 YES and every USDC it owes

**Steps:**
1. The Safe burns the first position
2. System reads the YES ratio as `90 / 180 = 1/2` and the USDC ratio as 1

**Outcomes:**
- The Safe receives 45 YES and 247,354,500 USDC: only the YES leg is cut
- The vault does not report itself covered on the strength of the asset it can pay in full

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, 0, 0, yesTokenId, 90000000, 45000000)` emitted, and no `ResidueSwept`, because the second position still holds a USDC claim
- No `SpreadCredited`: the vault holds exactly the USDC it owes
- USDC transferred in full; YES transferred at the reduced amount
- No revert

---

### SC-9BSG: A position devalued by the price alone is paid in full

**Given:**
- The Safe's position with the vault at 5700, so its claim is 247.3545 USDC plus 90 YES, worth less than the 300 USDC deposited at the band's average price of 0.585
- The vault holds 90 YES and 247.3545 USDC above escrow

**Steps:**
1. The Safe calls `burnPosition`
2. System reads both ratios as 1

**Outcomes:**
- The Safe receives 247,354,500 USDC units and 90 YES, the whole claim
- The composition differs from the deposit and may be worth less at the current price, but no cut applies: the ledger owes token counts and the vault holds those counts, so impermanent loss is not a shortfall (ADR-9BSJ)

**Side Effects:**
- Full payout transferred on both legs
- The totals storage: debited by the scaled claim, to zero
- No `SpreadCredited`: the vault holds exactly the USDC it owes
- `ResidueSwept(positionId, safe, 0, 0, 0)` emitted, because this burn takes the USDC total to zero and nothing is left over
- No revert

---

### SC-COEU: A burn debits the full owed amount when it pays less

**Given:**
- The Safe's position with the vault at 5700 (247.3545 USDC plus 90 YES owed), and the vault holds 200 USDC above escrow and 60 YES, the SC-BMF2 case

**Steps:**
1. The Safe calls `burnPosition`
2. System computes the ratios from the totals of this one claim: `200 / 247.3545` for USDC and `60 / 90` for YES
3. System pays 200 USDC and 60 YES and debits the totals by the full scaled claim

**Outcomes:**
- `PositionBurned` shows `usdcPaid < usdcOwed` and `tokenPaid < tokenOwed`, so an indexer sees the ratio
- `totalUsdcOwed()` and `totalYesOwed()` read zero, not the 47.3545 USDC and 30 YES that went unpaid: no phantom claim lowers the next claimant's ratio

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 200000000, 0, 0, yesTokenId, 90000000, 60000000)` emitted, and `ResidueSwept(positionId, safe, 0, 0, 0)` before it
- No `SpreadCredited`: the vault is short on both assets, so there is no surplus
- `totalUsdcOwedScaled` and `totalYesOwedScaled` storage: debited by the full scaled claim
- No revert

---

### SC-CYSB: Three burns after the switch receive the same ratio

**Given:**
- Three positions of the R9 example, owned by the Safe, the vault at 5700, so `totalUsdcOwed() == 742,063,500` and `totalYesOwed() == 270,000,000`
- The vault holds 270 YES and its USDC was drained to 371,031,750, half of what it owes
- The result `[1, 0]` is reported, the Oracle called `startWindDown` and `redeemOutcomeTokens`, so the vault holds 641,031,750 USDC above escrow and no token

**Steps:**
1. The first Safe position burns
2. The second burns
3. The third burns

**Outcomes:**
- Each burn pays `floor(337,354,500 × 641,031,750 ÷ 1,012,063,500) = 213,677,250` USDC units in one transfer, the same ratio each time
- After the third, `totalUsdcOwed()` and `totalYesOwed()` read zero and the vault holds `totalEscrowed`

**Side Effects:**
- Three `PositionBurned` events, each with `spreadOwed = spreadPaid = 0` and `usdcPaid + tokenPaid = 213677250`
- No `SpreadCredited`: after the switch the vault holds 641,031,750 against 1,012,063,500 owed, so there is no surplus
- `ResidueSwept(positionId, safe, 0, 0, 0)` on the third burn, which takes the USDC total to zero
- No `OutcomeTokensRedeemed`, because the Oracle redeemed first
- No `TransferSingle`

---

### SC-CYSC: A payout after the switch redeems late tokens first

**Given:**
- One R9 position at 5700, the Oracle redeemed after `[1, 0]`, so the vault holds 337.3545 USDC above escrow
- Then 5 YES and 5 NO arrived in the vault

**Steps:**
1. The Safe burns
2. System redeems the 5 YES and 5 NO for 5 USDC
3. System pays 337,354,500 USDC units

**Outcomes:**
- The Safe receives 342,354,500 USDC units: 337,354,500 of claim plus the 5,000,000 the late tokens redeemed for, of which the credit attributed 4,999,999 as spread and the closing sweep carried the last unit
- The vault holds no token and nothing above `totalEscrowed`, because this is the only position

**Side Effects:**
- `SpreadCredited(4999999, spreadGrowthGlobalX128)` emitted, because the redeemed value puts the vault above what it owes and the position is in range
- `OutcomeTokensRedeemed(safe, 5e6, 5e6, 5e6)` emitted, then `ResidueSwept(positionId, safe, 1, 0, 0)`, then `PositionBurned` with `spreadOwed = spreadPaid = 4999999`
- `PayoutRedemption` emitted by ConditionalTokens
- No `CompleteSetsMerged`

---

### SC-DFDY: Drift-free fills conserve value across claims on both sides of the price, before and after the switch

**Given:**
- Four positions minted at different ticks on both sides of the price, each mint after the tick move that precedes it: `[5500, 6500)` with 300 USDC at 6000, `[5500, 6500)` with 300 USDC at 5500, `[5000, 6000)` with 250 USDC at 5700, and `[6000, 7000)` with 400 USDC at 6300
- The moves 6000 → 5500 → 5700 → 6300 → 5800, each followed by the keeper's fill of every level the move crossed inside every live position's range, at the vault's bid price: at a spread σ of 0 the model price (`t / 10000` per YES, `1 − t / 10000` per NO); at σ = 2,000 bps the price the house board gives (`quotes.Board` in the Prophet server: each bid is its own probability less the board's split of the spread, floored at 100 bps with the blocked margin moved across), which spends `t × (1 − σ)` per YES and `(10000 − t) × (1 − σ)` per NO at every level above the floor
- The token count per level is the model's (`liquidity / 1e18` per tick) in both runs, so the ledger's owed totals and the free pairs are exact in both
- The USDC leaves through the exchange's standing approval and the tokens arrive through the receiver hook

**Steps:**
1. Run A (before the switch): every Safe burns its position
2. Run B (after the switch): the result `[1, 0]` is reported, the Oracle winds the vault down and redeems, then every Safe burns
3. Each run at σ = 0 and at σ = 2,000 bps

**Outcomes:**
- Every `PositionBurned` reports `paid == owed` on every leg, the spread leg included, in every run
- The Safes together receive their deposits plus the spread income the test summed over every fill (the model price less the bid, per token), within one unit per completed credit and per burn; that income is 0 at σ = 0
- The vault ends with 0 YES, 0 NO, and exactly `totalEscrowed`
- The last burn's `ResidueSwept` carries the dust only, below three units at σ = 2,000 bps and zero at σ = 0
- The spread income is paid, not held: since R18 the credit turns it into an obligation the ledger carries, and the income decision (O1b in `audits/audit-fixes-ranged.md`) is answered on chain -- the LPs own it, per tick

**Side Effects:**
- `CompleteSetsMerged` amounts sum to the round-trip pairs, the YES held above `totalYesOwed()` before the first burn, which equals the NO held above `totalNoOwed()`
- `SpreadCredited` at every report that moved a level with liquidity in range and at every mint and burn that found a surplus; the sum of every `spreadPaid` plus the final residue equals the fixture's spread income
- On the source before R14, run A fails at both spreads: the merge takes every pair, the last burns pay a cut token leg, and the vault keeps USDC above the spread income; run B passes on both sources, because after the switch every token redeems at the payout
- On the source before R18, both runs fail at σ = 2,000 bps: the spread income stays in the vault after the last burn instead of reaching the Safes

---
