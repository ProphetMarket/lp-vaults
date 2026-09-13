# R7 exploration — open questions

Context: audit issues 6.9 (first-mint floor) and 6.14 (mergePositions duplicate IDs), decisions C15, C16, and C26 in `audits/audit-fixes-ranged.md`.

## Where we are

- The floor check is at `src/LPVault.sol:876`: `activeLiquidity == 0 && liquidity < minimumFirstLiquidity`.
- The `Position` struct (`src/LPVault.sol:169`) has six fields and no mint tick.
- `mergePositions` (`src/LPVault.sol:1207`) has no duplicate check, so `[a, a]` doubles `a`.
- Six spec elements state the old condition in words: FR-RFS7, FR-RG4W, ADR-RFS9, the Data Model invariant in FEAT-REPZ and FEAT-T7AF, the FEAT-REPZ acceptance line that names a fuzz test that does not exist, and SC-T7AO. REFERENCE.md, FLOWS.md, and the glossary `Position` entry state the old shapes too.
- The `positions(uint256)` getter tuple is read at 52 test lines in 9 files. Any new field changes all 52 lines.
- Prototype, measured then reverted: vault 16,266 → 16,583 bytes (7,993 of room). All 537 tests pass. Mint median 213,523 → 212,044 gas. Merge median 53,717 → 54,617 gas. `mintTick` packs into the position's first slot, so no new storage slot.
- Prerequisite candidates: none.

## Questions

### 1. Clamp the mint tick into the range at mint?

When `currentTick < tickLower`, every level sits above the mint tick. When `currentTick >= tickUpper`, every level sits below it.

- Recommended: store `mintTick = tickLower` in the first case and `mintTick = tickUpper` in the second, inside `mintPositionFor`. Two positions minted below the range at different prices then hold the same mix and can merge under C16. R9 already has to decide what the level exactly at the mint tick holds for an in-range mint, so the clamp adds no new question for R9.
- Alternative: store the raw `currentTick` and clamp in R9 at read time. This blocks those merges.

### 2. What happens to `setMinimumFirstLiquidity` after the first mint?

With C15 the floor applies exactly once. A later setter call changes a value that nothing reads.

- Recommended: keep the setter, and reword FR-RG4W, SC-RG75, its NatSpec, and REFERENCE.md to say it matters only before the first mint. The auditors suggested exactly C15, and the change stays surgical.
- Alternative: make the setter revert once `nextPositionId > 0`.
- Alternative: remove the setter.

The two alternatives reach the factory feature's tests and its role scenarios.

### 3. Add `mintTick` to the `PositionMinted` event?

C26 makes the mint tick part of the claim, and the app and indexer show a claim.

- Recommended: add one `int24` data field. Cost: about 300 gas per mint, an ABI change for the event listener outside this repo, and 3 to 4 `expectEmit` test sites.
- Alternative: leave the event as it is. The indexer then calls `positions(id)` after each mint.

This widens the prompt's scope by one event field.

### 4. Where the fuzzed merge invariant lives

Recommended, four pieces:

1. A fuzz test in the UC-K1M8 test file: mint a random count of same-range positions with random amounts, merge them, and assert the survivor equals the sum.
2. A second fuzz test that injects one repeated ID at a random place and asserts `DuplicatePositionId` with no state change.
3. A new invariant in `test/invariants/TickState.t.sol`: the sum of every position's liquidity equals the liquidity the handler minted. A merge must conserve it, and R9 extends it with burns. The handler gains `mergePositions([a, a])` as a documented rejection, and it picks merge pairs by range and mint tick so merges keep succeeding after tick moves.
4. The conservation invariant joins the required list in `CLAUDE.md`'s Foundry conventions.

Say if you want fewer pieces.

### 5. Error names

- Recommended: two new errors, `DuplicatePositionId` for a repeated ID and `MintTickMismatch` for a different mint tick.
- Alternative: reuse `RangeMismatch` for the mint tick. Saves one error, tells the Operator less.

## Answers (2026-09-12)

### 1. Clamp at mint

Yes, the recommended option. Store `mintTick = tickLower` when the price is below the range and `mintTick = tickUpper` when it is at or above it, inside `mintPositionFor`. Two positions minted outside the range then hold the same mix and can merge under C16. Record the clamp in the position feature's decision records, so R9 reads it as settled.

### 2. `setMinimumFirstLiquidity` after the first mint

Keep the setter and reword the documents, as recommended. The auditors asked for C15 and nothing more, and the two alternatives reach the factory's tests and role scenarios. Write in the NatSpec and in REFERENCE.md that the value matters only before the first mint. Record the revert alternative as a rejected option, so a later step can pick it up if the Oracle service needs a hard stop.

### 3. `mintTick` in `PositionMinted`

Yes, add the field. C26 makes the mint tick part of the claim, and the app and the indexer show claims. One `int24` costs about 300 gas on a mint, which is rare, and it saves the indexer one call per mint. R5 already changes the events the listener reads, so the listener is being updated in this plan anyway. Add the ABI change to the "Outside this repo" list in Part 6 of the plan.

### 4. The fuzzed merge invariant

All four pieces. The conservation invariant is the one that R9 extends with burns, so it belongs in `test/invariants/TickState.t.sol` and in the required list in `CLAUDE.md`. Keep the handler's `[a, a]` rejection documented as such, so a later reader does not mistake it for a gap.

### 5. Error names

Two new errors, `DuplicatePositionId` and `MintTickMismatch`. The Operator must be able to tell the two failures apart, and one error costs almost nothing.
