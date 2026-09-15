---
id: FEAT-E943
name: Spread Attribution
module: contracts
domain: "@vault"
status: implemented
version: 1
refs: [FEAT-TVS0, FEAT-T7AF, FEAT-7G40, FEAT-9BQZ, FEAT-6HBN, FEAT-K1M2]
---

# Spread Attribution

> Gives the vault a measurement of the spread its round trips earned and a structure that attributes it to the liquidity that was in range at the levels where it was earned, so the surplus the payout ratio used to cap away becomes a claim the ledger owes, paid as a fourth leg of every burn, with the last live position taking whatever no credit could attribute.

## Non-Goals

- Does not account for the exchange fee. The fee is a charge the exchange takes on a fill, paid to whoever submits `matchOrders`, and it never enters the vault (step R17 removed every fee path on 2026-09-15). This feature is about the spread, which is inventory the vault buys cheap, and the two are different things
- Does not accept a spread amount from any caller. The source is the vault's own balances, so no Operator key can inflate what is credited -- see FR-E945
- Does not define what a claim's principal holds; FEAT-7G40 owns the claim formula (FR-7G4M) and FEAT-9BQZ owns the three principal totals
- Does not pay anything on its own. The credit writes accounting state; FEAT-7G40's burn is the only path that pays a position -- see FR-E94B
- Does not read a price feed, an oracle, or a fill record. The vault never sees a fill, and learns that trading happened only from `updateTick` and from its own balances
- Does not add a role, change a role's authority, or gate an existing function behind a new one
- Does not distribute the surplus through the payout ratio. FEAT-9BQZ FR-9BRP keeps its cap at 1, and the surplus reaches an LP as owed spread instead of as a bonus
- Does not add a setting. No value in this feature is configurable

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Drives three of the four credit sites: `updateTick`, `mintPositionFor`, and `burnPositionFor` | Cannot supply an amount, cannot create surplus, and cannot credit a position that was not in range. The reported tick decides which segments receive a credit, which the trust assumption on `updateTick` already covers (FEAT-TVS0 NFR-TVSM) |
| Any Wallet | Calls `mergeCompleteSets()`, which credits before it merges | The caller receives nothing. This is where a round trip that ends where it began is credited |
| LP | Receives the credited spread as a fourth leg of its burn | Never calls this feature directly. Observes it through `PositionBurned.spreadPaid`, through `ResidueSwept` on the last exit, and through the public views |

## Functional Requirements

### The Measurement

**FR-E945** `The system shall compute the creditable surplus from its own balances only: while the switch is off, the USDC balance plus the free pairs, less totalEscrowed and floored at zero, less totalUsdcOwed() and less totalSpreadOwed(); while the switch is on, the same with the vault's YES and NO balances valued at the stored payout added to what it holds and the YES and NO totals valued at the stored payout added to what it owes; and shall accept no spread amount from any caller.`
Fit Criterion: Given a vault holding 249.4560 USDC against a principal of 247.3545 USDC owed, no escrow, and nothing credited yet, the creditable surplus reads 2.1015 USDC (2,101,500 units). Given a holding at or below the sum of the principal and the credited spread, it reads zero and no credit is written. No function signature in this feature takes a spread, a fee, a margin, or a growth argument, so a compromised Operator key can redirect a credit between positions but can never create one. The floor at `totalEscrowed` is the same one `_availableUsdc` already applies (decision C7), so escrowed USDC is never credited as spread.
Linked to: UC-E944

**FR-E948** `While the switch is off, if either outcome-token balance is below that token's owed total, then the system shall credit nothing and shall leave the global growth, every outside snapshot, and the spread total unchanged.`
Fit Criterion: Given a report that books a spend the vault's USDC no longer holds because a fill the keeper reported never reached the vault, the vault's YES balance sits below `totalYesOwed()`, the call credits zero, and `spreadGrowthGlobalX128` and `totalSpreadOwedX128` read as before. The USDC that looks like surplus is unspent principal, not spread: it waits for the fill to arrive, or for the switch to value the missing token. After the switch the missing token's payout joins what the vault owes, so a claimant owed a winning token is paid from that USDC and only a losing token's unspent principal becomes surplus.
Linked to: UC-E944

### The Credit

**FR-E946** `When the system credits a surplus to a set of in-range liquidity, it shall add creditable × 2^128 ÷ active, rounded down, to spreadGrowthGlobalX128, add that growth times active to totalSpreadOwedX128, and emit SpreadCredited with the USDC credited after the floors and the global growth after the credit.`
Fit Criterion: The growth is stored per unit of liquidity and floored once, so the credited amount is the measured surplus less at most one USDC unit, and it is exactly one unit less whenever the surplus divides the in-range liquidity evenly. That unit stays measurable and the next credit takes it (FR-E949). Given `active` equal to one position's liquidity, that position's later spread claim equals the credited amount. Given two positions in range holding 0.3 and 0.2 tokens per level over the whole move, a credit of any size splits 60 to 40 between them exactly, whatever the fills' sizes were, because every position in one in-range set placed the same liquidity on every level of it. `SpreadCredited` is emitted once per credited segment and never for a zero credit.
Linked to: UC-E944

**FR-E947** `When updateTick credits, the system shall record each traversed segment's in-range liquidity and model spend during the crossing loop, measure the surplus once after the ledger shift, give segment i the share creditable × w_i ÷ Σ w_j with w_i = active_i × gross_i, add each segment's growth to the global, and add to each crossed tick's outside snapshot the growth credited before that tick was crossed.`
Fit Criterion: `gross_i` is the sum of `t` over the segment's levels on a fall and the sum of `10000 − t` on a rise. Worked: position A holds 0.3 tokens per level over `[5500, 6500)` and position B holds 0.2 over `[5000, 6000)`, both minted at 6000, and the keeper fills a fall from 6000 to 5000 at 400 bps down to 5500 and 600 bps below it, which leaves 8,882,300 units of surplus. Segment `[5500, 6000)` holds both, with `active = 5e23` and `gross = 2,874,750`; segment `[5000, 5500)` holds B alone, with `active = 2e23` and `gross = 2,624,750`. So the weights are 14,373,750 and 5,249,500 in units of 1e23, and the report credits `floor(8,882,300 × 14,373,750 ÷ 19,623,250) = 6,506,157` units to the first segment and `floor(8,882,300 × 5,249,500 ÷ 19,623,250) = 2,376,142` to the second, leaving one unit that the next credit takes (FR-E949). A move that crosses nothing has one segment and needs no array. The outside adjustment wraps the same way the crossing flip does, and the two forms write the same storage because the flip `outside = global − outside` is affine in the global.
Linked to: UC-E944

**FR-E949** `If no liquidity is in range across every segment a credit covers, then the system shall write no growth and shall leave the surplus measurable, so the next credit that finds liquidity takes it.`
Fit Criterion: Given a report whose every segment has `activeLiquidity == 0`, the call writes no growth and no spread total, and a later credit with liquidity in range credits the same surplus in full. Under drift-free fills this case holds only dust, because a fill needs an order and an order needs liquidity in range. What still cannot be attributed at the end of the vault's life reaches the last live position through the closing sweep (FR-E94C).
Linked to: UC-E944

**FR-E94A** `The system shall credit at exactly four sites -- the Operator's tick report, the public complete-set merge, the mint, and the burn -- through one internal helper that reads both token balances, the switch, the free pairs, and the USDC balance, and one internal writer that performs the credit; and the escrow refund shall not credit.`
Fit Criterion: Given any of `updateTick` with a moved tick, `mergeCompleteSets()`, `mintPositionFor`, or either burn entry point, a pending surplus is credited in that call. Given `reclaimDeposit` or `reclaimDepositFor`, no credit is written, because a refund changes no owed total. The four sites share one copy of the token-cover check and one copy of the measurement, so `SpreadCredited.amount` has one meaning everywhere. The mint credits before the new position joins the in-range set and the burn credits with the exiting position still counted.
Linked to: UC-E944

### The Claim and the Residue

**FR-E94B** `The system shall hold a per-position spreadGrowthInsideLastX128 written at the mint after both bounds are referenced and rewritten by a position merge, and shall value a position's spread claim as liquidity × (the growth inside its range now − that snapshot), computed with wrapping subtraction and truncated to USDC units.`
Fit Criterion: Given a position minted immediately after a credit, its spread claim reads exactly zero, because the snapshot equals the inside value. Given a credit of 2.1015 USDC to a single in-range position, that position's claim reads 2,101,500 units. Growth earned before a position was minted is never claimable (the attribution requirement), and the growth inside a range is read from the two bounds' outside snapshots only, so an interior mint tick's snapshot is written and flipped but never read.
Linked to: UC-E944

**FR-E94C** `When a burn's ledger debit takes totalUsdcOwedScaled to zero, the system shall pay that position's owner every USDC the vault holds above totalEscrowed and, while the switch is off, the vault's whole remaining YES and NO balances, and shall emit ResidueSwept with the amounts paid beyond that position's own claim.`
Fit Criterion: A live position always has a USDC claim above zero and a record a position merge consumed has none, so the burn that takes the USDC total to zero is the last live position's burn and no other. Under drift-free fills the residue is dust below three units and the vault afterwards holds exactly `totalEscrowed`. Given the unreported-fill case where Safe A left first and forfeited its share, Safe B's burn as the last position pays 253.668 USDC and all 165 YES and reports `ResidueSwept(idB, safeB, 0, 90000000, 0)`. The sweep runs inside the burn as its last interaction block, never as a function anyone could time, and it never pays more than the vault holds above escrow. This supersedes the sweep rejected in ADR-DFE2 of FEAT-6HBN, which was rejected because the residue had no owner.
Linked to: UC-E944

### Views

**FR-E94Y** `The system shall expose totalSpreadOwedX128, totalSpreadOwed(), and spreadGrowthGlobalX128 as public views, shall return spreadGrowthOutsideX128 as a fourth value of ticks(int24), and shall return spreadGrowthInsideLastX128 as a sixth word of positions(uint256).`
Fit Criterion: Given any vault state, an off-chain caller reads all five without a transaction and computes a position's spread claim with the formula of FR-E94B. This is the app's and the indexer's whole surface for the spread: no on-chain path reverts on a shortfall (FEAT-9BQZ FR-9BRS), so the views are the only way one becomes visible.
Linked to: UC-E944

## Non-Functional Requirements

**NFR-E94D** Precision: `A credit inside one segment shall be exact, and a credit split across segments shall carry a bounded, signed error that the keeper's reporting cadence removes.`
Fit Criterion: inside one segment every level has the same in-range set and every position in it placed the same liquidity on every level, so a split by liquidity is exact by construction whatever the fills were. Across segments the split by `w_i` equals the true margin split when the spread is the same at every level of the report; otherwise segment `i` receives `w_i × (σ̄ − σ_i) ÷ 10000`, where `σ̄` is the report's spend-weighted mean spread, so a segment whose spread is narrower than the mean receives too much and a wider one too little, by the same total. Worked on the FR-E947 example: the true margins are 5,737,500 units on `[5500, 6000)`, shared 60 to 40 between A and B, and 3,144,800 on `[5000, 5500)` to B alone. The split credits A 3,903,694 against 3,442,500 owed and B 4,978,604 against 5,439,800 owed, so 461,194 units move from B to A, 13.4 percent of what A was owed. One cadence removes it: the keeper reports at every initialized tick it crosses, so every report holds one segment with liquidity.

**NFR-E94E** Testability: `Every unit the vault measures as surplus shall reach a position or the closing sweep, and the spread total shall equal the sum over live positions of their spread claims, exactly, mod 2^256.`
Fit Criterion: `invariant_surplusIsCredited` in `test/invariants/SolvencyLedger.t.sol` holds over the drift-free handler: after any credit that found liquidity in range with both tokens covered, the uncredited surplus is below one USDC unit. `invariant_ledgerEqualsSumOfClaims` computes the fourth total per position beside the three principal totals and holds with no tolerance. The handler keeps ghost sums of `SpreadCredited` amounts and of `spreadPaid` amounts and checks `totalSpreadOwed()` against them within the dust bound. Two mutation checks fail: a credit written to the global without the spread total, and a burn that skips the spread debit.

**NFR-E94F** Gas: `Every credit site shall add constant-cost work, and updateTick's added cost shall grow only with the number of segments it traverses.`
Fit Criterion: the added cost at each site is independent of the number of live positions. `updateTick`'s per-segment work is bounded by the 256-crossing cap (FEAT-TVS0 ADR-TVUW) plus the trailing segment. The unchanged-tick report reads no balance and credits nothing, so it keeps its cost. The per-site bounds live with the functions they belong to: FEAT-TVS0 NFR-TVSK for the report, FEAT-T7AF NFR-T7B6 for the mint, and FEAT-7G40 NFR-7G5C for the burn.

**NFR-E94G** Security: `Every wrapping subtraction and addition of a growth value shall sit in an unchecked block carrying a comment that names the Uniswap v3 pattern it follows and why the wrap is correct.`
Fit Criterion: the sites are the inside computation, the flip in `_crossTick`, the products in the burn and in the position merge, and the outside adjustment after a per-segment credit. Each carries its own comment. A growth value is a difference on a circle of size 2^256: only the difference is meaningful, and it is correct as long as no position's claim exceeds 2^256 X128 units, which the liquidity and USDC scales make unreachable. This reinstates the fee-growth wraparound decision (ADR-8L1F in FEAT-T7AF) for the spread, with the comment shape the R1 review set.

**NFR-E94Z** Security: OPERATOR TRUST ASSUMPTION -- `The Operator's reported path decides which segments receive the credit, so a false report can redirect measured surplus between positions, and the Operator's choice of block for a relayed burn decides which credit that exit sees. The Operator can never create surplus, because the source is the vault's own balances and no entry point takes an amount.`
Fit Criterion: the trust block on `updateTick`, on `mintPositionFor`, and on `burnPositionFor` each state their part of this, and the MEV analysis on `mergeCompleteSets` states that the caller receives nothing and that a caller who is an LP in range can time the call, bounded by the surplus pending at that moment.

## Acceptance

> The feature is complete when all of the following are true:

- All scenarios in UC-E944 pass against the real ConditionalTokens bytecode
- The creditable surplus is computed from balances only, and no entry point accepts a spread amount
- A credit inside one segment splits by liquidity exactly; a credit across segments splits by `active × model spend`
- A report whose fill never arrived credits nothing while either token balance is below its owed total
- A report with nothing in range writes no growth, and the next credit with liquidity takes the surplus
- All four credit sites run through one helper and one writer; the escrow refund credits nothing
- A position minted right after a credit has a spread claim of exactly zero
- The last live position's burn pays every USDC above escrow and every remaining token, and emits `ResidueSwept`
- `invariant_surplusIsCredited` and the extended `invariant_ledgerEqualsSumOfClaims` hold in `test/invariants/SolvencyLedger.t.sol`
- Every `unchecked` growth site carries its comment
- Forge fmt passes; no console.log in production code
- `forge build --sizes --skip test --skip script` exits 0
- Coverage gate met against `.molcajete/settings.json` `testing.thresholds`
- FEATURES.md status is `implemented`
