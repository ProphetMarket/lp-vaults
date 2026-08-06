---
id: UC-9BR2
name: Apply Payout Ratios
feature: FEAT-9BQZ
status: pending
version: 1
actor: LP
---

# UC-9BR2: Apply Payout Ratios

> An LP exiting a vault receives their full claim when the vault can cover it, and the same proportional share as every other claimant when it cannot -- with the shortfall measured per asset, and never turned into a failed transaction.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set
- The ledger's seven totals are maintained per UC-9BR0 and UC-9BR1
- The LP holds a live position, or an unfulfilled escrowed deposit, depending on the scenario
- No scenario requires the vault to be paused, cancelled, or in any declared emergency

## Trigger

LP calls an exit path -- `burnPosition`, `collect`, or `reclaimDeposit` -- on a claim they own.

---

### SC-9BSC: Fully solvent vault pays every claim in full

**Given:**
- The vault's USDC, YES, and NO balances each cover the obligations recorded against them
- The LP holds a live position with accrued fees

**Steps:**
1. LP calls `burnPosition` for their position
2. System reads the three ratios, each at unity
3. System pays the full principal composition and the full accrued fees

**Outcomes:**
- The LP receives exactly what the position was owed, on every asset leg
- No leg is reduced
- A surplus in any asset is not distributed as a bonus -- the LP receives what they are owed and no more, so a donated or stranded balance cannot be drained by whoever exits first

**Side Effects:**
- USDC transferred to the LP; outcome tokens transferred to the LP for any nonzero leg
- Principal and fee totals storage: decreased by the amounts paid
- No revert on any path

---

### SC-9BSD: Under-collateralized vault applies the same haircut in either call order

**Given:**
- The vault's USDC balance covers only part of its recorded USDC obligations
- Two LPs each hold a claim against USDC

**Steps:**
1. The first LP exits and receives their claim scaled by `usdcRatio`
2. The second LP exits afterwards and receives their claim scaled by the ratio then in force
3. The same pair of exits is replayed with the call order reversed

**Outcomes:**
- Each LP receives the same proportional share of their own claim in both orderings
- Neither LP is made whole at the other's expense, and neither is left with nothing because they called second
- Losses scale with stake rather than with monitoring speed, the way an insolvency distributes recovery among claimants of the same class

**Side Effects:**
- USDC transferred to each LP, scaled by the ratio
- Totals storage: decreased by the amounts actually paid, not by the pre-haircut entitlements
- No revert on either exit, in either ordering

---

### SC-9BSE: Escrowed but unminted USDC counts against solvency

**Given:**
- The vault holds pending escrow against mint intents that have not been fulfilled
- The vault's USDC balance is short of its total USDC obligations once that escrow is counted
- An LP holds a live position and calls `burnPosition`

**Steps:**
1. LP calls `burnPosition`
2. System computes `usdcRatio` with `totalEscrowed` included in the denominator
3. System pays the USDC leg scaled by that ratio

**Outcomes:**
- The burning LP receives a reduced USDC leg rather than a full one
- The pending depositors' USDC is not paid out to the burner: omitting escrow from the denominator would have overstated solvency by exactly the pending-escrow balance and let this burn be settled in full out of money owed to someone else
- The escrowed depositors' later reclaim is scaled by the same ratio, taking the identical haircut

**Side Effects:**
- USDC transferred to the LP at the reduced amount
- `totalUsdcOwed` storage: decreased by the amount actually paid
- `totalEscrowed` storage: unchanged by this burn

---

### SC-9BSF: Shortfall in one asset does not haircut the others

**Given:**
- The vault's YES balance is short of its recorded YES obligations
- Its USDC and NO balances each cover their obligations in full
- An LP holds an in-range position owed all three assets

**Steps:**
1. LP calls `burnPosition`
2. System reads the three ratios independently
3. System scales only the YES leg

**Outcomes:**
- The YES leg is reduced; the USDC and NO legs are paid in full
- `yesRatio` reads below unity while `usdcRatio` and `noRatio` read unity
- The vault does not report itself solvent overall on the strength of the two assets it can cover

**Side Effects:**
- USDC and NO transferred in full; YES transferred at the reduced amount
- Principal totals storage: each decreased by the amount actually paid for that asset
- No revert

---

### SC-9BSG: A position devalued by price movement alone is paid in full

**Given:**
- A position whose asset composition has shifted substantially since mint because the price moved
- The vault holds every asset in the amounts the ledger records as owed

**Steps:**
1. LP calls `burnPosition`
2. System reads the three ratios, each at unity
3. System pays the position's current composition in full

**Outcomes:**
- The LP is paid at 100% of what the position now holds, on every leg
- The composition differs from what was deposited, and may be worth less at current prices, but no haircut is applied
- Impermanent loss is not a shortfall: the vault owes token counts, and it holds those token counts. A ledger denominated in dollars would have reported a shortfall here and haircut a solvent vault

**Side Effects:**
- Full payout transferred on every nonzero leg
- Principal totals storage: decreased by the amounts paid
- No ratio below unity, and no revert

---
