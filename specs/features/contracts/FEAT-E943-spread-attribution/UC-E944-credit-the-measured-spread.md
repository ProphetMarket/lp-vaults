---
id: UC-E944
name: Credit the Measured Spread
feature: FEAT-E943
status: implemented
version: 1
actor: Operator
---

# UC-E944: Credit the Measured Spread

> The vault reads its own balances, works out how much USDC it holds above escrow, above the principal it owes, and above the spread it already credited, and gives that surplus to the liquidity that was in range at the levels where the fills earned it.

## Preconditions

- The vault was created with a verified outcome-token identity (UC-REQ1), so `conditionId`, `yesTokenId`, and `noTokenId` name its market
- At least one position exists, minted through UC-T7AG, so the vault has liquidity to attribute a credit to
- The keeper quotes each level as the house board does: the YES bid at `t − floor(spreadBps × t ÷ 10000)` and the NO bid at `(10000 − t) − (spreadBps − floor(spreadBps × t ÷ 10000))`, both inside the band `[100, 9900]`, which `test/fixtures/KeeperFillFixture.sol` models

## Trigger

The Operator reports a moved tick, any wallet merges the vault's free pairs, the Operator mints a position, or an LP burns one.

---

### SC-E94H: One report over one segment credits by liquidity, exactly

**Given:**
- The vault is Active with `tickSpacing = 10`, `currentTick = 6000`, and no escrow
- Safe A holds 300 USDC over `[5500, 6500)` minted at 6000, so `liquidity = 3e23` and A places 0.3 tokens on every level
- Safe B holds 200 USDC over `[5500, 6500)` minted at 6000, so `liquidity = 2e23` and B places 0.2 tokens on every level
- The keeper filled a drift-free fall from 6000 to 5700 at 400 basis points: over the 300 levels of `[5700, 6000)` it bought 150 YES and spent 84,240,000 USDC units against a model spend of 87,742,500, so the fills left 3,502,500 units of margin
- The vault holds 415,760,000 USDC units and 150,000,000 YES, and has not reported the move yet

**Steps:**
1. The Operator calls `updateTick(5700)`
2. The vault crosses the interior mint tick 6000, records the empty segment that ends there and then the segment `[5700, 6000)` with `active = 5e23`, and applies the ledger shift once
3. The ledger now owes 412,257,500 USDC units and 150,000,000 YES
4. The vault reads both token balances and its USDC balance, computes zero free pairs because it holds no NO, and finds both token balances at or above their owed totals
5. The vault computes the creditable surplus, `415,760,000 − 412,257,500 − 0 = 3,502,500` units
6. The vault gives the whole amount to the one segment that had liquidity, as `3,502,500 × 2^128 ÷ 5e23` of growth

**Outcomes:**
- A's spread claim reads 2,101,500 units and B's reads 1,401,000, a 3-to-2 split, each within one unit of rounding
- `totalSpreadOwed()` reads 3,502,499 units, one below the measurement, because the growth is floored per unit of liquidity and this surplus divides the liquidity evenly; `totalSpreadOwedX128` equals the exact sum of both claims in X128 units
- A second `updateTick(5700)` credits nothing, because the tick did not move
- The split holds whatever the fills' sizes were, because every position in one in-range set placed the same liquidity on every level of it

**Side Effects:**
- `SpreadCredited(3502499, spreadGrowthGlobalX128)` emitted once, before `TickUpdated`
- `spreadGrowthGlobalX128`, `totalSpreadOwedX128`, and the crossed tick's `spreadGrowthOutsideX128` written
- No token transfer and no `CompleteSetsMerged`, because the vault holds no free pair
- No position record and no `positions(id)` field other than the two snapshots is touched

---

### SC-E94I: A report over several segments splits by model spend

**Given:**
- The vault is Active with `currentTick = 6000` and no escrow
- Safe A holds 0.3 tokens per level over `[5500, 6500)`, minted at 6000, so `liquidity = 3e23`
- Safe B holds 0.2 tokens per level over `[5000, 6000)`, minted at 6000, so `liquidity = 2e23`
- The keeper filled the fall from 6000 to 5500 at 400 basis points and the fall from 5500 to 5000 at 600 basis points, in that order, with no report between them
- Over `[5500, 6000)` both positions were in range, with a model spend of 143,737,500 units and 5,737,500 of margin; over `[5000, 5500)` only B was, with a model spend of 52,495,000 units and 3,144,800 of margin
- The vault therefore holds 8,882,300 units of surplus above what the ledger will owe at 5000

**Steps:**
1. The Operator calls `updateTick(5000)`
2. The vault crosses the mint tick 6000 and then the boundary tick 5500, and records three segments: the empty one at 6000, `[5500, 6000)` with `active = 5e23` and `gross = 2,874,750`, and `[5000, 5500)` with `active = 2e23` and `gross = 2,624,750`
3. The vault applies the ledger shift, then measures the surplus at 8,882,300 units
4. The vault weights the two non-empty segments as `5e23 × 2,874,750` and `2e23 × 2,624,750`, and credits `floor(8,882,300 × 14,373,750 ÷ 19,623,250) = 6,506,157` to the first and `floor(8,882,300 × 5,249,500 ÷ 19,623,250) = 2,376,142` to the second

**Outcomes:**
- A's spread claim reads 3,903,694 units and B's reads 4,978,604, each within one unit of rounding
- One unit of the 8,882,300 is credited to neither and stays measurable for the next credit
- The split is not the true margin split, because the two segments carried different spreads: A is owed 3,442,500 and B 5,439,800, so 461,194 units moved from B to A, 13.4 percent of what A was owed
- Reporting the same move as two calls, 6000 to 5500 and then 5500 to 5000, credits each segment its own margin exactly and removes that error

**Side Effects:**
- `SpreadCredited` emitted twice, once per segment with liquidity, before `TickUpdated`
- `spreadGrowthOutsideX128` written on both crossed ticks, each gaining the growth credited before it was crossed
- No token transfer, because the vault holds no NO and so no free pair

---

### SC-E94J: The public merge credits a round trip that ended where it began

**Given:**
- The vault is Active with `currentTick = 6000` and no escrow
- Safe A holds 300 USDC over `[5500, 6500)` minted at 6000, so `liquidity = 3e23`
- The keeper filled a fall from 6000 to 5900 and then a rise back from 5900 to 6000, both at 400 basis points, with no report between them: it bought 30 YES for 17,136,000 units and 30 NO for 11,664,000, against model spends of 17,848,500 and 12,151,500
- The vault holds 271,200,000 USDC units, 30,000,000 YES, and 30,000,000 NO; the ledger owes 300,000,000 USDC units and no token, because the reported tick never left the mint tick

**Steps:**
1. The Operator calls `updateTick(6000)`, which finds the tick unchanged, refreshes the heartbeat, and returns without reading a balance
2. Any wallet calls `mergeCompleteSets()`
3. The vault reads both token balances and computes 30,000,000 free pairs
4. The vault reads its USDC balance and computes the creditable surplus, `271,200,000 + 30,000,000 − 300,000,000 − 0 = 1,200,000` units
5. The vault credits 1,199,999 of it to A, the only liquidity in range, one unit below the measurement because the growth is floored per unit of liquidity
6. The vault merges the 30,000,000 free pairs

**Outcomes:**
- A's spread claim reads 1,200,000 units, exactly 400 basis points of the 30 tokens the round trip turned over
- The vault holds 301,200,000 USDC units, 0 YES, and 0 NO
- The caller's balances do not change
- A second call credits nothing and merges nothing

**Side Effects:**
- `SpreadCredited(1199999, spreadGrowthGlobalX128)` emitted before `CompleteSetsMerged(caller, 30000000)`
- `spreadGrowthGlobalX128` and `totalSpreadOwedX128` written
- `lastOperatorActivityTimestamp` keeps its value, because the merge refreshes no heartbeat
- No tick record, position record, or phase is written

---

### SC-E94K: A reported fill the vault never received is withheld

**Given:**
- The vault is Active with `currentTick = 6000` and no escrow
- Safe A holds 300 USDC over `[5500, 6500)` minted at 6000, so `liquidity = 3e23`
- The vault holds its whole 300,000,000 USDC units, 0 YES, and 0 NO: no fill has happened

**Steps:**
1. The Operator calls `updateTick(5960)`, reporting a 40-level fall that no fill followed
2. The vault crosses the mint tick 6000 and accrues the segment `[5960, 6000)`
3. The ledger now owes 292,824,600 USDC units and 12,000,000 YES
4. The vault reads both token balances and finds its YES balance of 0 below the 12,000,000 it now owes

**Outcomes:**
- The call credits nothing, although the vault holds 7,175,400 USDC units above the principal
- `spreadGrowthGlobalX128` and `totalSpreadOwedX128` read as before, and every spread claim stays at its earlier value
- That USDC is unspent principal, not spread: when the fill arrives, or when the switch values the missing token, the check clears
- A's burn before either happens takes its share of the drift as a final cut, which decision C8 already accepts

**Side Effects:**
- `TickUpdated(6000, 5960, 1)` emitted
- No `SpreadCredited` and no outside snapshot adjustment
- The crossed tick's `spreadGrowthOutsideX128` is still flipped, because the flip belongs to the crossing and not to the credit

---

### SC-E94L: A credit with nothing in range carries the surplus forward

**Given:**
- The vault is Active at `currentTick = 5400`, below Safe A's range `[5500, 6500)`, so `activeLiquidity` is zero
- A's earlier fall from 6000 to 5400 was filled drift-free at 400 basis points and reported, and that report credited A the 3,442,500 units it earned
- The vault holds 217,200,000 USDC units and 150,000,000 YES, the ledger owes 213,757,500 USDC units and 150,000,000 YES, and `totalSpreadOwed()` reads 3,442,500
- A stranger then sends 10,000,000 USDC units to the vault

**Steps:**
1. Any wallet calls `mergeCompleteSets()`
2. The vault measures 10,000,000 units of creditable surplus and finds `activeLiquidity == 0`
3. The keeper fills the rise from 5400 to 5600 drift-free at 400 basis points, buying 30 NO for 12,816,000 units against a model spend of 13,351,500
4. The Operator calls `updateTick(5600)`, which crosses 5500 and brings A back in range over the segment `[5500, 5600)`

**Outcomes:**
- The merge in step 2 writes no growth and no spread total, and the surplus stays measurable
- The report in step 4 credits 10,535,500 units to A: the 10,000,000 that was carried plus the 535,500 the rise earned
- A's spread claim reads 13,978,000 units in total, within one unit of rounding
- Under drift-free fills this case holds only dust, because a fill needs an order and an order needs liquidity in range

**Side Effects:**
- No `SpreadCredited` from the merge of step 2, and no merge call, because the vault holds no free pair then
- `SpreadCredited(10535500, spreadGrowthGlobalX128)` emitted by the report of step 4, before `CompleteSetsMerged(operator, 30000000)` and `TickUpdated`. This surplus does not divide the liquidity evenly, so no unit is dropped

---

### SC-E94M: The mint credits the existing liquidity, then starts the new position at zero

**Given:**
- The state of SC-E94J after step 1: the round trip is filled and unreported, the vault holds 271,200,000 USDC units, 30,000,000 YES, and 30,000,000 NO, and 1,200,000 units of surplus are pending
- Safe A holds the only position, 300 USDC over `[5500, 6500)` minted at 6000
- Safe B has escrowed 200 USDC against a mint intent for `[5500, 6500)`

**Steps:**
1. The Operator calls `mintPositionFor` for B's intent
2. The vault runs its checks, then reads both token balances and its USDC balance and computes the 30,000,000 free pairs
3. The vault credits the 1,200,000 units of surplus to `activeLiquidity` as it stands, which is A's 3e23 alone
4. The vault consumes the escrow, references both bounds, and writes B's record with `mintTick = 6000`
5. The vault records B's `spreadGrowthInsideLastX128` as the growth inside `[5500, 6500)` after the credit
6. The vault merges the 30,000,000 free pairs as its one external call

**Outcomes:**
- A's spread claim reads 1,200,000 units, the whole round trip's margin
- B's spread claim reads exactly zero, so a position minted after a trade never claims that trade's value
- The vault holds 301,200,000 USDC units, 0 YES, and 0 NO
- `activeLiquidity` reads 5e23 after the mint, and the next credit splits 3 to 2

**Side Effects:**
- `SpreadCredited(1199999, spreadGrowthGlobalX128)` emitted, then `CompleteSetsMerged(operator, 30000000)`, then `PositionMinted`
- `spreadGrowthInsideLastX128` written on B's record and on no other
- `lastOperatorActivityTimestamp` set to `block.timestamp`, because the mint is an Operator call

---

### SC-E94N: A burn credits before it values its claim, and leaves nothing behind

**Given:**
- The state of SC-E94J after step 1: the round trip is filled and unreported, the vault holds 271,200,000 USDC units, 30,000,000 YES, and 30,000,000 NO, and 1,200,000 units of surplus are pending
- Safe A holds the only position, 300 USDC over `[5500, 6500)` minted at 6000, and the ledger owes 300,000,000 USDC units and no token
- No escrow is outstanding, so `totalEscrowed` is zero

**Steps:**
1. Safe A calls `burnPosition(positionId)`
2. The vault reads both token balances, the switch, the 30,000,000 free pairs, and its USDC balance
3. The vault credits the 1,200,000 units of surplus to `activeLiquidity`, which still counts A
4. The vault values A's claim: 300,000,000 USDC units of principal, 1,200,000 of spread, and no token, because the price sits at the mint tick
5. The vault finds the USDC ratio at 1, because 301,200,000 held covers 301,200,000 owed, and prorates `usdcOwed` and then `usdcOwed + spreadOwed`
6. The vault debits the four totals, deletes the record, merges the free pairs, and pays

**Outcomes:**
- A receives 301,200,000 USDC units in one transfer: 300,000,000 of principal and 1,200,000 of spread
- The position record is empty, and `totalUsdcOwedScaled`, `totalYesOwedScaled`, `totalNoOwedScaled`, and `totalSpreadOwedX128` all read zero
- The vault holds exactly `totalEscrowed`, which is zero, and 0 YES and 0 NO
- A later report, merge, or credit changes nothing for that position id
- The same burn through `burnPositionFor` pays identical amounts

**Side Effects:**
- `SpreadCredited(1199999, spreadGrowthGlobalX128)`, then `CompleteSetsMerged(safeA, 30000000)`, then `ResidueSwept(positionId, safeA, 1, 0, 0)` carrying the one unit the growth floor dropped, then `PositionBurned(positionId, safeA, 300000000, 300000000, 1199999, 1199999, 0, 0, 0)`
- `lastOperatorActivityTimestamp` keeps its value on the self-service path

---

### SC-E94O: The last live position takes the residue

**Given:**
- The vault is Active at `currentTick = 6000` with no escrow
- Safe A holds 0.3 tokens per level over `[5500, 6500)`, 300 USDC, minted at 6000
- Safe B holds 0.25 tokens per level over `[5000, 6200)`, 300 USDC, minted at 6000
- The keeper filled a fall from 6000 to 5700 at 400 basis points, buying 165,000,000 YES for 92,664,000 USDC units, and has not reported it
- The vault holds 507,336,000 USDC units and 165,000,000 YES, and the ledger still values both claims at 6000, so it owes 600,000,000 USDC units and no token

**Steps:**
1. Safe A calls `burnPosition` inside the report window
2. The vault credits nothing, because 507,336,000 held is below the 600,000,000 owed, and pays A `floor(300,000,000 × 507,336,000 ÷ 600,000,000) = 253,668,000` units and no token
3. The Operator calls `updateTick(5700)`, which books B's band and credits nothing, because the vault still holds less USDC than it owes
4. Safe B calls `burnPosition`, and the ledger debit takes `totalUsdcOwedScaled` to zero

**Outcomes:**
- A forfeited 46,332,000 units, its share of the unreported spend, which decision C8 accepts and finding CV-08 records
- B is owed 256,128,750 USDC units and 75,000,000 YES, at a USDC ratio of `253,668,000 ÷ 256,128,750`
- B's burn pays every USDC the vault holds above escrow, 253,668,000 units, and all 165,000,000 YES, so A's forfeit reaches the position that stayed instead of stranding
- The vault afterwards holds 0 USDC above escrow, 0 YES, and 0 NO
- Had B instead waited for the Oracle's redemption with YES winning, the 165,000,000 YES would redeem into a surplus of 87,539,250 units credited to B as spread, and B would leave with 418,668,000 units

**Side Effects:**
- `ResidueSwept(positionIdB, safeB, 0, 90000000, 0)` emitted before `PositionBurned`, carrying only the amounts paid beyond B's own claim
- No `ResidueSwept` on A's burn, because the USDC total was still above zero after its debit
- A record that `mergePositions` consumed never triggers the sweep, because it has no claim and cannot burn

---
