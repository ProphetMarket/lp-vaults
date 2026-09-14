---
id: FEAT-TVS0
name: Update Tick and Cross Ticks
module: contracts
domain: "@ticks"
status: implemented
version: 4
refs: [FEAT-REPZ, FEAT-T7AF, FEAT-TOGR, FEAT-JXQO, FEAT-9BQZ]
---

# Update Tick and Cross Ticks

> Operator-driven tick synchronization that crosses initialized ticks between the vault's current price and the CLOB mid-price, flipping per-tick fee accumulators and adjusting active liquidity so fee distributions split correctly between in-range and out-of-range positions.

## Non-Goals

- Does not handle fee collection by individual LPs — see feature 5
- Does not initialize or deinitialize ticks — tick lifecycle managed by mint (FEAT-T7AF) and burn (feature 6)
- Does not implement off-chain Keeper logic (price monitoring, chunking decisions) — only the on-chain `updateTick` entry point
- Does not move USDC or outcome tokens — only updates accounting state (feeGrowthOutside, activeLiquidity, noSideLiquidity, currentTick, and the four ledger totals of FEAT-9BQZ)

## Actors

| Actor | Role | Notes |
|-------|------|-------|
| Operator | Calls `updateTick(newTick)` on-chain to synchronize the vault's price tick with the CLOB mid-price | The off-chain Keeper signs with an Operator key per ACTORS.md but has no contract-level authority of its own |

## Functional Requirements

**FR-TVS9** `When the Operator calls updateTick(newTick), the system shall iterate from currentTick toward newTick, crossing each initialized tick encountered using the TickBitmap to skip uninitialized ticks.`
Fit Criterion: Given currentTick=100, newTick=300, and initialized ticks at 150, 200, 250 with gaps elsewhere, exactly three ticks are crossed in order and currentTick is 300 after the call.
Linked to: UC-TVS1

**FR-TVSA** `When an initialized tick is crossed in either direction, the system shall flip its feeGrowthOutsideX128 by computing feeGrowthGlobalX128 - tick.feeGrowthOutsideX128 and storing the result.`
Fit Criterion: Given feeGrowthGlobalX128=1000 and tick.feeGrowthOutsideX128=300, after crossing, tick.feeGrowthOutsideX128=700.
Linked to: UC-TVS1

**FR-TVSB** `When an initialized tick is crossed left-to-right (price increasing), the system shall add the tick's liquidityNet to activeLiquidity.`
Fit Criterion: Given activeLiquidity=500e18 and tick.liquidityNet=+100e18 at tick 200, after left-to-right crossing, activeLiquidity=600e18.
Linked to: UC-TVS1

**FR-TVSC** `When an initialized tick is crossed right-to-left (price decreasing), the system shall subtract the tick's liquidityNet from activeLiquidity.`
Fit Criterion: Given activeLiquidity=600e18 and tick.liquidityNet=+100e18 at tick 200, after right-to-left crossing, activeLiquidity=500e18.
Linked to: UC-TVS1

**FR-TVSD** `When updateTick completes successfully with newTick different from currentTick, the system shall store newTick as currentTick and record block.timestamp as lastOperatorActivityTimestamp.`
Fit Criterion: Given currentTick=100 before the call, after updateTick(300) at block.timestamp=T, currentTick=300 and lastOperatorActivityTimestamp=T.
Linked to: UC-TVS1

**FR-TVSE** `When updateTick completes successfully with newTick different from currentTick, the system shall emit a TickUpdated event containing the previous tick, the new tick, and the count of initialized ticks crossed.`
Fit Criterion: Given currentTick=100 and newTick=300 with 3 initialized ticks crossed, the emitted event contains oldTick=100, newTick=300, ticksCrossed=3. Given newTick equal to currentTick, no event is emitted.
Linked to: UC-TVS1

**FR-TVSF** `If the number of initialized ticks to cross in a single updateTick call exceeds 256, then the system shall revert.`
Fit Criterion: Given 257 initialized ticks between currentTick and newTick, the call reverts with TooManyTicksCrossed.
Linked to: UC-TVS1

**FR-TVSG** `If the caller is not an Operator, then the system shall revert.`
Fit Criterion: Given a non-Operator address calls updateTick, the call reverts with NotOperator.
Linked to: UC-TVS1

**FR-TVSH** `If newTick equals currentTick, then the system shall record block.timestamp as lastOperatorActivityTimestamp and return without crossing a tick, reading the tick bitmap, or emitting an event, and with no storage write other than lastOperatorActivityTimestamp and the reentrancy guard toggle, which ends at its starting value.`
Fit Criterion: Given currentTick=100 and initialized ticks on both sides of it, updateTick(100) succeeds, lastOperatorActivityTimestamp equals block.timestamp, no TickUpdated event is emitted, and currentTick, activeLiquidity, feeGrowthGlobalX128, and every tick record are unchanged.
Linked to: UC-TVS1

**FR-TVSI** `While the vault phase is not Active, when the Operator calls updateTick, the system shall revert.`
Fit Criterion: Given phase=WindDown, updateTick reverts with VaultNotActive.
Linked to: UC-TVS1

**FR-TVSJ** `The system shall maintain a bitmap structure that tracks which ticks are initialized, enabling updateTick to locate the next initialized tick in O(1) per word rather than iterating through every tick in the range.`
Fit Criterion: Given initialized ticks at 100 and 500 (no initialized ticks in between), updateTick from 50 to 600 crosses exactly two ticks without iterating 400 intermediate positions.
Linked to: UC-TVS1

**FR-5IDE** `When updateTick searches for the next initialized tick, the system shall bound that search to the bitmap word containing newTick, inclusive, so that ticks initialized beyond newTick are never scanned.`
Fit Criterion: Given currentTick = 100, a single initialized tick at 8388590, and no initialized ticks between 100 and 300, updateTick(300) succeeds with ticksCrossed = 0 and reads only the bitmap words spanning 100 to 300. Given instead an initialized tick at 260, inside the same word as the target 300, updateTick(300) crosses it, which confirms that the bound includes the target's own word.
Linked to: UC-TVS1

**FR-5IDF** `If no initialized tick exists within the bounded search range in either direction, then the system shall report "not found" and complete the call without reverting, including when the bounded range reaches the highest or lowest addressable bitmap word.`
Fit Criterion: Given currentTick = 8388000 with no initialized ticks at or above it, updateTick(8388600) succeeds with ticksCrossed = 0 instead of reverting with an arithmetic panic. Given currentTick = -8388400, inside the lowest bitmap word, with no initialized ticks at or below it, updateTick(-8388600) succeeds with ticksCrossed = 0.
Linked to: UC-TVS1

**FR-A2ZS** `The system shall keep activeLiquidity equal to the sum of the liquidity of every position whose range contains currentTick, noSideLiquidity equal to the sum over those positions whose mintTick is at or below currentTick, each tick's liquidityGross equal to the sum of the liquidity of every position that references that tick as tickLower, as tickUpper, or as an interior mint tick (tickLower < mintTick < tickUpper), and each tick's noLiquidityNet equal to the liquidity of the positions whose mintTick is that tick and below their tickUpper, less the liquidity of the positions whose tickUpper is that tick and whose mintTick is below it, after any sequence of mints, burns, tick updates, merges, and freezes.`
Fit Criterion: Given random sequences of mints near the current tick and against both extreme bitmap words, burns through both entry points, tick moves of at most 2,000 ticks, merges of two distinct positions with the same range and mint tick, and a freeze, the invariant test `test/invariants/TickState.t.sol` holds, and no `updateTick` in those sequences reverts for an undocumented reason. The summed form reads `Σ liquidityGross over the distinct referenced ticks == Σ liquidity × (2 + [tickLower < mintTick < tickUpper])`.
Linked to: UC-TVS1

## Non-Functional Requirements

**NFR-TVSK** Performance: `updateTick with zero initialized ticks crossed shall consume less than 50,000 gas on Polygon.`

**NFR-TVSL** Security: `updateTick shall apply an inline nonReentrant guard following checks-effects-interactions ordering.`

**NFR-TVSM** Security: OPERATOR TRUST ASSUMPTION — The Operator can report any tick value. LPs trust the Operator to report the CLOB mid-price accurately. A malicious or compromised Operator could report a false tick, causing incorrect fee distribution between positions. This matches the ProphetCTFExchange trust model.

**NFR-5IDG** Security: `The gas cost of updateTick shall be bounded by the distance between currentTick and newTick, and shall be independent of where any other party has initialized ticks outside that range.` An LP can initialize a tick at any aligned position by signing a mint intent. An unbounded search lets one planted tick at the edge of the scale push a later legitimate updateTick past the block gas limit: 76,618,321 gas for a move of 200 ticks, measured on 2026-09-12. The bound is as tight as the Operator's reported newTick, which is a trusted input under NFR-TVSM. This requirement removes third-party control over the search cost. It does not change the Operator trust assumption. A large single jump across a real gap of uninitialized ticks still reads one word per 256 ticks, so the Operator chunks large jumps across several calls, as ADR-TVUW already requires for crossings. No on-chain enforcement of that chunking is specified.

## Acceptance

- For any sequence of updateTick calls, feeGrowthInsideX128 computed for a position spanning ticks [a, b) correctly reflects fees accrued only while currentTick was in [a, b)
- After any updateTick, activeLiquidity equals the sum of liquidity from all positions whose range contains the new currentTick
- Multiple sequential chunked updateTick calls produce the same final state as a single hypothetical call crossing the same ticks (chunking equivalence)
- TickBitmap correctly tracks initialization state including word-boundary edge cases
- For any tick initialized strictly outside the range spanned by currentTick and newTick, updateTick produces the same state transition and the same gas cost as it would if that tick did not exist
- The next-initialized-tick search terminates and reports a result for every reachable combination of start tick and target tick, including targets and starts in the highest and lowest addressable bitmap words
- The tick invariant test (`test/invariants/TickState.t.sol`) holds
