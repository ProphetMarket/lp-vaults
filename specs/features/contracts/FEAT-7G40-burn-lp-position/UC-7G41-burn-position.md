---
id: UC-7G41
name: Burn Position
feature: FEAT-7G40
status: implemented
version: 8
actor: LP
---

# UC-7G41: Burn Position

> The LP's Safe closes a position it owns and receives what the claim holds under decision C26, USDC plus at most one outcome token before the switch, and USDC only after the Oracle's redemption, without needing the Operator to cooperate, or to exist.

## Preconditions

- Vault is deployed and initialized, with its outcome-token identity set (`conditionId`, `yesTokenId`, `noTokenId`)
- The Safe holds a live position: `positions[positionId].owner == safe` and `liquidity > 0`
- No Operator action, Operator signature, or Operator registry state is required by anything in this use case

## Trigger

The LP's Safe calls `burnPosition(positionId)` on the vault, through a Safe transaction the owner key signs.

---

### SC-7G43: Burn at the mint tick pays the whole principal in USDC

**Given:**
- The Safe owns a position of 300 USDC over `[5500, 6500)`, minted with the vault at tick 6000, so `liquidity = 3e23` and `mintTick = 6000`
- `currentTick == 6000`

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System confirms the caller owns the live position
3. System finds the current tick equal to the mint tick and values the claim as USDC only
4. System removes the position's liquidity from ticks 5500 and 6500 and from `activeLiquidity`, and deletes the position record
5. System transfers 300 USDC to the Safe

**Outcomes:**
- The Safe's USDC balance increases by 300,000,000 units (300 USDC)
- The Safe receives no outcome token
- The position no longer exists and cannot be burned again
- `activeLiquidity` decreases by `3e23`, because the position was in range

**Side Effects:**
- `PositionBurned(positionId, safe, 300000000, 300000000, 0, 0, 0)` emitted
- `positions[positionId]` storage: deleted
- `ticks[5500]` and `ticks[6500]` storage: `liquidityGross` decreased by `3e23`; `liquidityNet` decreased by `3e23` at 5500 and increased by `3e23` at 6500; `noLiquidityNet` increased by `3e23` at 6500
- `ticks[6000]` storage (the interior mint tick): `liquidityGross` and `noLiquidityNet` decreased by `3e23`, the record deleted and its bitmap bit cleared, because nothing else references it
- `noSideLiquidity` storage: decreased by `3e23`, because the position sat on the NO side of its mint tick
- The three totals of the solvency ledger (FEAT-9BQZ): `totalUsdcOwedScaled` decreased by `3e23 × 10,000,000`
- USDC transferred from vault to the Safe
- No ERC-1155 transfer
- No call to the CTF Exchange
- No `lastOperatorActivityTimestamp` write

---

### SC-7G44: Burn after the price fell pays USDC plus YES

**Given:**
- The Safe owns the position of SC-7G43 (`liquidity = 3e23`, range `[5500, 6500)`, `mintTick = 6000`)
- The Operator moved the tick to 5700, so the YES band is `[5700, 6000)`
- The vault holds 90 YES (90,000,000 units, because an outcome token has USDC's six decimals) and no NO, the tokens the keeper's fills left for that band

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System confirms the caller owns the live position
3. System values the claim: 90 YES for the 300-tick band, and `3e23 × (1000 × 10000 − 1,754,850) / 1e22 = 247,354,500` USDC units for the rest
4. System removes the position's liquidity from both ticks and from `activeLiquidity`, and deletes the position record
5. System transfers 247.3545 USDC and 90 YES to the Safe

**Outcomes:**
- The Safe's USDC balance increases by 247,354,500 units
- The Safe's YES balance increases by 90
- The vault spent `300 − 247.3545 = 52.6455` USDC on the 90 YES, an average price of 0.585, the middle of the band
- The position no longer exists

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)` emitted
- `positions[positionId]` storage: deleted
- `ticks[5500]` and `ticks[6500]` storage: liquidity removed as in SC-7G43
- USDC transferred from vault to the Safe
- ERC-1155 YES transferred from vault to the Safe, as the last external call
- No order placed, matched, or settled on the CTF Exchange

---

### SC-7G45: Burn after the price rose pays USDC plus NO

**Given:**
- The Safe owns the position of SC-7G43
- The Operator moved the tick to 6300, so the NO band is `[6000, 6300)`
- The vault holds 90 NO and no YES

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System confirms the caller owns the live position
3. System values the claim: 90 NO for the 300-tick band, and `3e23 × (700 × 10000 + 1,844,850) / 1e22 = 265,345,500` USDC units for the rest
4. System removes the position's liquidity from both ticks and from `activeLiquidity`, and deletes the position record
5. System transfers 265.3455 USDC and 90 NO to the Safe

**Outcomes:**
- The Safe's USDC balance increases by 265,345,500 units
- The Safe's NO balance increases by 90
- The vault spent `300 − 265.3455 = 34.6545` USDC on the 90 NO, an average NO price of 0.38505
- The position no longer exists

**Side Effects:**
- `PositionBurned(positionId, safe, 265345500, 265345500, noTokenId, 90000000, 90000000)` emitted
- `positions[positionId]` storage: deleted
- `ticks[5500]` and `ticks[6500]` storage: liquidity removed
- USDC transferred from vault to the Safe
- ERC-1155 NO transferred from vault to the Safe
- No call to the CTF Exchange

---

### SC-7G47: Burning the last position at a tick deinitializes it

**Given:**
- The Safe owns the only position referencing tick 6500
- Tick 6500 is initialized: `liquidityGross > 0` and its bitmap bit is set
- Tick 5500 is still referenced by another Safe's live position

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System decrements `liquidityGross` on both boundary ticks
3. System finds `ticks[6500].liquidityGross == 0`, deletes the tick's state, and clears its bitmap bit
4. System finds `ticks[5500].liquidityGross > 0` and leaves tick 5500 intact

**Outcomes:**
- Tick 6500 is deinitialized and its bitmap bit reads zero, so a later `updateTick` across it crosses nothing
- Tick 5500 stays initialized with its bitmap bit set for the other position
- The Safe receives its payout as in the tick-dependent scenarios above

**Side Effects:**
- `PositionBurned` emitted
- `ticks[6500]` storage: deleted
- Tick bitmap word containing tick 6500: bit cleared
- `ticks[5500]` storage: `liquidityGross` and `liquidityNet` decremented, tick otherwise preserved
- A later `updateTick` from 6400 to 6600 emits `TickUpdated(6400, 6600, 0)`

---

### SC-7G48: Revert when the caller is not the owner

**Given:**
- Safe A owns positionId N with a live position
- Safe B holds no claim on N

**Steps:**
1. Safe B calls `burnPosition(N)`
2. System reads `positions[N].owner` and finds A, not the caller

**Outcomes:**
- Call reverts with NotPositionOwner error
- A's position is untouched and A can still burn it
- B cannot force A's exit at a tick of B's choosing

**Side Effects:**
- No state changes
- No USDC transferred
- No ERC-1155 transferred
- No events emitted

---

### SC-7G49: Burn in WindDown and in Cancelled succeeds identically to Active

**Given:**
- Case A: the Oracle has called `startWindDown` and the vault's phase is WindDown, and the Safe owns a live in-range position identical to the one in SC-7G43
- Case B: any address has called `emergencyCancelAll` after the timelock and the vault's phase is Cancelled (3), and the Safe owns the same in-range position

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System applies no phase gate to the burn path
3. System values the claim at `currentTick`, updates tick and liquidity state, deletes the record, and pays the Safe

**Outcomes:**
- In both cases the `PositionBurned` amounts, the tick updates, and the `activeLiquidity` delta are identical to the same burn in Active phase

**Side Effects:**
- `PositionBurned` emitted, `positions[positionId]` deleted, ticks and `activeLiquidity` updated as in Active phase, USDC transferred to the Safe, in both cases
- No phase change in either case

---

### SC-7G4A: Burn succeeds with zero registered operators

**Given:**
- The Admin has removed every operator: `operators[x] == 0` for all addresses
- No emergency or cancellation has been declared; the vault is unattended
- The Safe owns a live position

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System reads no operator registry state and requires no signature
3. System values the claim, updates tick and liquidity state, and pays the Safe

**Outcomes:**
- The Safe exits in full without any Operator participation
- The path stays open with no emergency to declare, no timelock to wait out, and nobody to ask

**Side Effects:**
- `PositionBurned` emitted
- `positions[positionId]` storage: deleted
- `ticks` storage: liquidity removed from both boundary ticks
- USDC transferred from vault to the Safe
- No operator registry read
- No signature verification
- No `lastOperatorActivityTimestamp` write

---

### SC-7G4B: Revert on a nonexistent, burned, or merged-away position

**Given:**
- Case A: positionId M was never minted
- Case B: positionId M was burned in an earlier transaction and its record deleted
- Case C: positionId M was consumed by `mergePositions`, so its owner is set and its liquidity is zero

**Steps:**
1. The Safe calls `burnPosition(M)`
2. System reads `positions[M]` and finds no owner or zero liquidity

**Outcomes:**
- Call reverts with PositionNotFound error in every case
- A double burn cannot drain a second payout, and a consumed position cannot touch the ticks by zero

**Side Effects:**
- No state changes
- No USDC transferred
- No ERC-1155 transferred
- No events emitted

---

### SC-BMF1: Burn merges the vault's pairs first

**Given:**
- The Safe owns the position of SC-7G43 with the vault at the mint tick
- The vault holds 50 YES and 50 NO from earlier round trips

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System reads both balances and finds 50 pairs
3. System removes the position's liquidity and deletes the record
4. System merges the 50 pairs through the ConditionalTokens contract, then pays the Safe 300 USDC

**Outcomes:**
- The vault holds 0 YES and 0 NO after the call
- The vault's USDC balance falls by `300 − 50 = 250` USDC net: the merge added 50 and the payout took 300
- The Safe receives 300 USDC

**Side Effects:**
- `CompleteSetsMerged(safe, 50)` emitted before `PositionBurned` in the log
- `PositionBurned(positionId, safe, 300000000, 300000000, 0, 0, 0)` emitted
- `PositionsMerge` emitted by ConditionalTokens
- USDC transferred from ConditionalTokens to the vault, then from the vault to the Safe

---

### SC-DFDX: Two claims on opposite sides of the tick are both paid in full

**Given:**
- Safe A holds the R9 example minted at 6000 and Safe B the same range minted at 5500, after drift-free fills: the fall from 6000 to 5500 bought 150 YES on A's levels for 86,242,500 USDC units (`Σ t / 10000` per token over `[5500, 6000)`), and the rise from 5500 to 5700 bought 60 NO on A's levels and 60 NO on B's for 52,806,000 units (`Σ (1 − t / 10000)` over `[5500, 5700)`), the USDC leaving through the exchange's standing approval and the tokens arriving through the receiver hook
- The vault holds 150 YES, 120 NO, and 460,951,500 USDC units, and the ledger owes 90 YES, 60 NO, and 520,951,500 USDC

**Steps:**
1. Safe A calls `burnPosition`
2. The burn computes 60 free pairs before any effect, merges them, and pays 247,354,500 USDC and 90 YES
3. Safe B calls `burnPosition`
4. The burn computes 0 free pairs and pays 273,597,000 USDC and 60 NO

**Outcomes:**
- `PositionBurned` reports `paid == owed` on every leg for both burns
- The vault holds 0 YES, 0 NO, and `totalEscrowed` USDC
- On the source before R14 the same steps paid A 30 YES, B 0 NO, and left 60,000,000 USDC units with no live position (finding CV-01)

**Side Effects:**
- `CompleteSetsMerged(safeA, 60)` once, before A's `PositionBurned`
- Two `PositionBurned` events, two USDC transfers, one YES transfer, and one NO transfer

---

### SC-BMF2: Burn pays its share when the vault is short

**Given:**
- Case A: the Safe owns the position of SC-7G44 (claim 247.3545 USDC plus 90 YES), and the vault holds only 200 USDC above `totalEscrowed` and 60 YES
- Case B: the Safe owns a position whose claim is USDC only, and the vault's USDC balance is below `totalEscrowed`
- Case C: the vault holds more USDC and more of the token than the claim
- The position is the only live claim, so each asset's ratio is what is held over what this position is owed (FEAT-9BQZ FR-9BRM, FR-9BRN)

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System reads the totals and computes one ratio per asset, the smaller of 1 and held ÷ owed
3. System pays each owed amount times its ratio, rounded down, debits the totals by the full scaled claim, and never reverts on the comparison

**Outcomes:**
- Case A: the Safe receives 200 USDC and 60 YES, and the position is deleted
- Case B: the Safe receives zero USDC, the call does not revert, and the position is deleted
- Case C: the Safe receives the claim exactly
- In every case `totalUsdcOwed()` falls by the claim's USDC and the band's token total by its tokens, whatever was paid: 247,354,500 and 90,000,000 in case A

**Side Effects:**
- Case A: `PositionBurned(positionId, safe, 247354500, 200000000, yesTokenId, 90000000, 60000000)` emitted, so an indexer sees `paid < owed`
- Case B: `PositionBurned` emitted with `usdcPaid == 0`, and no USDC transfer
- `totalUsdcOwedScaled` and the band's token total storage: debited by the full scaled claim in every case
- `totalEscrowed` unchanged in every case: escrowed USDC never pays a burn
- No revert on any solvency comparison

---

### SC-BMF3: Burn of a clamped mint tick pays NO for the levels the price rose through

**Given:**
- The Operator reported tick 5000, below the range, before the mint, so the position over `[5500, 6500)` has `mintTick = 5500`
- The Operator then moved the tick to 5800, inside the range
- The vault holds 90 NO

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System finds the current tick above the mint tick and the NO band `[5500, 5800)`
3. System values 90 NO and `3e23 × (700 × 10000 + 300 × (5500 + 5800 − 1) / 2) / 1e22 = 260,845,500` USDC units
4. System pays the Safe

**Outcomes:**
- The Safe receives 260.8455 USDC and 90 NO
- A mint below its range holds an empty YES side and a NO side that is the whole range, so a rise into the range fills `[tickLower, currentTick)` with NO

**Side Effects:**
- `PositionBurned(positionId, safe, 260845500, 260845500, noTokenId, 90000000, 90000000)` emitted
- `positions[positionId]` storage: deleted
- ERC-1155 NO transferred from vault to the Safe

---

### SC-CYS7: Burn after the switch pays the winning leg in USDC

**Given:**
- The Safe owns the position of SC-7G44 (`liquidity = 3e23`, range `[5500, 6500)`, `mintTick = 6000`), the vault at 5700, and the vault held 90 YES
- The result `[1, 0]` is reported, the Oracle called `startWindDown` and `redeemOutcomeTokens`, so the vault holds 337.3545 USDC above escrow and no token

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System reads the stored payout `(1, 0)` and values the 90 YES at 90 USDC
3. System computes one USDC ratio: held 337.3545, owed 337.3545, ratio 1
4. System removes the liquidity from both ticks and deletes the record
5. System finds no token to redeem and transfers 337.3545 USDC

**Outcomes:**
- The Safe's USDC balance increases by 337,354,500 units
- The Safe receives no token

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)` emitted, where `tokenPaid` is the token leg's USDC after the switch
- One `Transfer` from the vault to the Safe, of 337,354,500 units
- No `TransferSingle`, no `PayoutRedemption`, no `OutcomeTokensRedeemed`

---

### SC-CYS8: Burn after the switch pays the losing leg nothing

**Given:**
- The same position and holdings as SC-CYS7
- The result `[0, 1]` is reported and the Oracle redeemed, so the vault holds 247.3545 USDC above escrow and no token

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System values the 90 YES at 0 USDC
3. System transfers 247.3545 USDC

**Outcomes:**
- The Safe's USDC balance increases by 247,354,500 units
- The Safe receives no token

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 0)` emitted; `tokenOwed` still reports the 90 tokens the claim held
- No `TransferSingle`

---

### SC-CYS9: Burn after a cancelled market pays half the token leg

**Given:**
- The same position and holdings as SC-CYS7
- The result `[1, 1]` is reported and the Oracle redeemed, so the vault holds 292.3545 USDC above escrow and no token

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System values the 90 YES at `90 × 1 ÷ 2 = 45` USDC
3. System transfers 292.3545 USDC

**Outcomes:**
- The Safe's USDC balance increases by 292,354,500 units

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 45000000)` emitted
- No `TransferSingle`

---

### SC-CYSA: Burn between resolution and the switch pays the token in kind

**Given:**
- The same position and holdings as SC-7G44: the vault at 5700 holds 90 YES
- The result `[1, 0]` is reported and the Oracle has not called `redeemOutcomeTokens`

**Steps:**
1. The Safe calls `burnPosition` for the position
2. System reads the stored payout `(0, 0)` and takes the pre-switch path
3. System transfers 247.3545 USDC and 90 YES

**Outcomes:**
- Identical to SC-7G44: the Safe's USDC balance increases by 247,354,500 units and its YES balance by 90
- The Safe redeems the 90 YES at the ConditionalTokens contract for 90 USDC in its own transaction, so no LP waits on the Oracle

**Side Effects:**
- `PositionBurned(positionId, safe, 247354500, 247354500, yesTokenId, 90000000, 90000000)` emitted
- `TransferSingle` from the ConditionalTokens contract as the last external call
- No `redeemPositions` call, no `OutcomeTokensRedeemed`

---

### SC-DYNJ: Burn inside the report window takes its share of the cut and leaves the fill's tokens

**Given:**
- Case A: the Safe owns the position of SC-7G44's setup (300 USDC over `[5500, 6500)` minted at 6000), the only live claim
- Case B: a second Safe also owns 300 USDC over `[5000, 6200)` minted at 6000 (`liquidity = 2.5e23`, 0.25 tokens per tick)
- In both cases the keeper's orders filled the move from 6000 to 5700 at model prices, so the fill's USDC left the vault through the exchange's allowance and its YES arrived through the receiver hook: 52,645,500 units and 90 YES in case A, 96,516,750 units and 165 YES in case B
- No `updateTick` was called, so `currentTick` is 6000 and the ledger owes USDC only

**Steps:**
1. The first Safe reads `totalYesOwed()` (0) against the vault's YES balance: the balance above the owed total is the unreported fill
2. The first Safe calls `burnPosition` for its position
3. System values the claim at 6000 (300 USDC, no band), pays 300 USDC times the USDC ratio, debits the full claim, and transfers no token
4. Case B only: the Operator reports 5700, and the second Safe calls `burnPosition`

**Outcomes:**
- Case A: the Safe receives 247,354,500 USDC units and no token, the vault holds 90,000,000 YES and no USDC above `totalEscrowed`, and every ledger total reads zero
- Case B: the first Safe receives 251,741,625 units and no token (its cut of 48,258,375 is less than its own fill's 52,645,500); after the report the second claim is owed 256,128,750 units plus 75 YES; the second Safe receives 251,741,625 units plus 75 YES, so the stayer takes the 4,387,125 units the leaver's cut did not cover; the vault holds 90,000,000 YES and no USDC above escrow, and every total reads zero
- In both cases the leftover YES belong to no claim and stay until the switch (decision C8, finding CV-08 of `audits/code-validation-round-1.md`, ADR-DYNK)

**Side Effects:**
- Case A: `PositionBurned(positionId, safe, 300000000, 247354500, 0, 0, 0)` emitted, so an indexer sees `paid < owed`
- Case A: no `TransferSingle` from the vault, and no `CompleteSetsMerged`, because the vault holds no NO
- Case B: `PositionBurned(positionA, safeA, 300000000, 251741625, 0, 0, 0)`, then `TickUpdated(6000, 5700, 1)` (the report crosses the second claim's interior mint tick), then `PositionBurned(positionB, safeB, 256128750, 251741625, yesTokenId, 75000000, 75000000)`
- `totalUsdcOwedScaled` storage: debited by the full scaled claim at each burn
- No `updateTick` before the first burn in either case

---
