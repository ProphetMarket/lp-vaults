---
id: UC-9BR2
name: Apply Payout Ratios
feature: FEAT-9BQZ
status: implemented
version: 2
actor: LP
---

# UC-9BR2: Apply Payout Ratios

> An LP who exits receives the whole claim when the vault can cover it, and the same share as every other claimant when it cannot, per asset, never as a failed transaction, and the cut is final.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set
- The four totals are maintained per UC-9BR0 and UC-9BR1
- The Safe holds a live position; unless a scenario says otherwise it is the R9 example (300 USDC over `[5500, 6500)` minted at 6000, `liquidity = 3e23`), and a shortfall is made the way a fill makes one: the exchange's standing approval moves USDC out of the vault
- No scenario requires the vault to be paused, wound down, or frozen; every payout works the same in every phase (FEAT-7G40 FR-7G4V, FEAT-U079 FR-U07O)

## Trigger

The Safe calls `burnPosition` or `collect` on a position it owns, or the Operator relays the owner key's `BurnIntent` or `CollectIntent` through `burnPositionFor` or `collectFor`.

---

### SC-9BSC: A covered vault pays every claim in full

**Given:**
- The vault at 5700 holds 500 YES and 1,300 USDC against one position owed 247.3545 USDC plus 90 YES, and 9,999,999 units of fees (a 10 USDC report over its liquidity, after the Q128 floor)

**Steps:**
1. The Safe calls `burnPosition`
2. System reads the totals and computes the USDC ratio and the YES ratio, both 1
3. System pays the claim and the fees in full

**Outcomes:**
- The Safe receives 257,354,499 USDC units and 90 YES
- The vault keeps the 410 YES and the USDC it did not owe: a surplus is never a bonus

**Side Effects:**
- USDC and YES transferred to the Safe
- The totals storage: debited by the scaled claim and the scaled fees, to zero
- `PositionBurned(positionId, safe, 247354500, 9999999, 257354499, yesTokenId, 90000000, 90000000)` emitted

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
- Case A: three `PositionBurned` events with `tokenOwed = 90000000` and `tokenPaid = 50000000`; `totalYesOwedScaled` falls by `3e23 × 300` per burn
- Case B: three `PositionBurned` events with `usdcOwed = 247354500` and `usdcPaid = 123677250`; `totalUsdcOwedScaled` falls by the full scaled claim per burn
- No revert on any burn

---

### SC-9BSE: Escrowed USDC never pays a burn or a collect

**Given:**
- The Safe's position is at its mint tick, so its claim is 300 USDC only
- Another Safe escrowed 500 USDC that the Operator never minted, and the vault's USDC balance was drained below `totalEscrowed`

**Steps:**
1. The Safe calls `burnPosition`
2. System computes the USDC held as `balance + pairs − totalEscrowed`, floored at zero, so the USDC ratio is zero
3. System pays zero USDC and does not revert

**Outcomes:**
- The Safe receives nothing, the position is deleted, and `totalUsdcOwed()` falls by 300,000,000
- The pending depositor's later reclaim pays the recorded 500 USDC, because escrowed USDC is senior (decision C7) and the reclaim applies no ratio

**Side Effects:**
- `PositionBurned(positionId, safe, 300000000, 0, 0, 0, 0, 0)` emitted
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
- `PositionBurned(positionId, safe, 247354500, 0, 247354500, yesTokenId, 90000000, 45000000)` emitted
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
- No revert

---

### SC-COET: A collect at a ratio pays its share, zeroes tokensOwed, and emits both amounts

**Given:**
- The Safe's in-range position is owed 10 USDC of fees, and the USDC ratio is 0.4: the vault's USDC above escrow is 40 percent of `totalUsdcOwed() + totalFeesOwed()`

**Steps:**
1. The Safe calls `collect`
2. System pays `10 × 0.4 = 4` USDC, sets `tokensOwed` to zero, and debits `totalFeesOwedX128` by the whole scaled claim
3. The Operator later reports more fees and the Safe collects again

**Outcomes:**
- The Safe receives 4 USDC, and `positions[positionId].tokensOwed` reads zero
- The later collect owes only the fees that grew since: the 6 USDC not paid are not owed any more, because a cut is final and the LP chose the moment (ADR-COEN)

**Side Effects:**
- `FeesCollected(positionId, safe, 10000000, 4000000)` emitted
- USDC transferred: 4,000,000 units
- `totalFeesOwedX128` storage: decreased by the full scaled fee claim
- Position storage: `feeGrowthInsideLastX128` advanced, `tokensOwed = 0`

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
- `PositionBurned(positionId, safe, 247354500, 0, 200000000, yesTokenId, 90000000, 60000000)` emitted
- `totalUsdcOwedScaled` and `totalYesOwedScaled` storage: debited by the full scaled claim
- No revert

---
