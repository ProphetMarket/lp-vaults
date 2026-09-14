---
id: UC-JXQW
name: Emergency Cancel All
feature: FEAT-JXQO
status: implemented
version: 8
actor: Any Wallet
---

# UC-JXQW: Emergency Cancel All

> Any address freezes the vault after the Operator has been silent beyond the vault's emergency-cancel timelock. The freeze sets the phase to Cancelled, a terminal state, and changes nothing else, so each LP exits alone through the burn, the collect, or the reclaim, which pay in full.

## Preconditions

- Vault has been deployed and initialized (phase == Active or WindDown)
- `lastOperatorActivityTimestamp` was set during the most recent successful Operator action
- `emergencyCancelTimelock` was copied from the factory's default at `createVault` (FEAT-REPZ SC-REQ6)

## Trigger

Any address calls `emergencyCancelAll()` on the vault.

The silence timer this use case reads is refreshed by every successful Operator-gated call -- `mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`, and the dedicated `heartbeat()`. A call that reverts does not refresh it. On a quiet Active market the keeper's report with the unchanged tick refreshes the timer and does not revert (SC-TVS7). `heartbeat()` exists for a vault that is paused or wound down, where `updateTick` reverts, and for an Operator with no report to send. Every later Operator function carries `touchesHeartbeat` (`CLAUDE.md`, hard rules).

---

### SC-JXQX: The freeze after the silence timelock changes only the phase

**Given:**
- Vault is in Active phase with one in-range LP position (1,000 USDC over [0, 100)) with accrued fees, and one pending escrow of 600 USDC
- `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock`

**Steps:**
1. The position's Safe calls `emergencyCancelAll()` on the vault
2. System checks that the phase is not already Cancelled
3. System checks that the operator-silence timelock has elapsed
4. System sets the phase to Cancelled (3)

**Outcomes:**
- Vault phase is Cancelled (3)
- `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, and `totalEscrowed` are unchanged
- The position record, both boundary tick records, and their bitmap bits are unchanged
- The escrow record is unchanged
- The vault's USDC balance is unchanged

**Side Effects:**
- `EmergencyCancelExecuted(caller)` emitted
- No USDC transferred and no outcome token transferred
- No position or tick written
- No new positions created

---

### SC-JXQY: Revert before timelock elapses

**Given:**
- Vault is in Active phase with at least one position
- `block.timestamp - lastOperatorActivityTimestamp < emergencyCancelTimelock`, the value the vault copied at creation

**Steps:**
1. Any address calls `emergencyCancelAll()`
2. System checks the timelock
3. System reverts

**Outcomes:**
- Transaction reverts `TimelockNotElapsed`

**Side Effects:**
- No state change
- No event emitted

---

### SC-BZBW: Any address freezes the vault, with or without a position

**Given:**
- Vault is in Active phase with two positions owned by two Safes
- `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock`
- The caller is an address with no position and no role (an arbitrary EOA); a second case uses the Operator address

**Steps:**
1. The caller calls `emergencyCancelAll()`
2. System checks the phase and the timelock, and reads no position
3. System sets the phase to Cancelled (3)

**Outcomes:**
- The call succeeds
- `phase == 3`
- Both positions and `activeLiquidity` are unchanged

**Side Effects:**
- `EmergencyCancelExecuted(caller)` emitted with the caller's address
- No transfer
- No position or tick written
- No total of the solvency ledger written, and no `noSideLiquidity` write (FEAT-9BQZ SC-COEP)

---

### SC-BZBX: An in-range burn after the freeze pays in full

**Given:**
- Vault holds three positions owned by two Safes, all minted with the vault at tick 6000: Safe A owns an in-range position (300 USDC over [5500, 6500)) and an out-of-range position (500 USDC over [7000, 8000)), and Safe B owns an in-range position (1,000 USDC over [5000, 7000))
- Fees of 500 USDC were reported
- The vault is frozen after the timelock (SC-JXQX)

**Steps:**
1. Safe A calls `burnPosition` for its in-range position
2. System values the claim at the frozen tick, subtracts the position's liquidity from `activeLiquidity` and from both ticks, deletes the record, and pays Safe A
3. Safe B calls `collect` for its position
4. System pays Safe B its accrued fees
5. Safe A calls `burnPosition` for its out-of-range position (500 USDC over [7000, 8000), minted with the vault at 6000, so its mint tick is 7000 and every level is still USDC)
6. Safe B calls `burnPosition` for its position

**Outcomes:**
- Safe A receives 300 USDC plus its share of the fees for the first burn, and the 500 USDC principal of the second
- Safe B receives its fees from the collect, then its principal from the burn
- After the first burn `activeLiquidity` equals Safe B's liquidity, and after every exit it is zero
- The phase stays 3

**Side Effects:**
- `PositionBurned` three times and `FeesCollected` once
- All three positions deleted and their ticks updated
- No `EmergencyCancelExecuted`

---

### SC-JXR1: Terminal state gates off trading, and every exit stays open

**Given:**
- Vault phase is Cancelled (3) after a successful `emergencyCancelAll()`
- The LP's position has 499 USDC of accrued fees (500 reported over its liquidity, rounded down)
- One escrow of 600 USDC is pending
- The vault holds 10 YES and 10 NO

**Steps:**
1. Operator calls `mintPositionFor(...)` -- reverts
2. LP's Safe calls `collect(positionId)` -- succeeds and pays the 499 USDC of fees
3. Operator calls `notifyFees(amount)` -- reverts
4. Operator calls `updateTick(newTick)` -- reverts
5. Operator calls `mergePositions(...)` -- reverts
6. Operator calls `heartbeat()` -- reverts
7. Oracle calls `startWindDown()` -- reverts
8. Any address calls `emergencyCancelAll()` again -- reverts
9. Any wallet calls `mergeCompleteSets()` -- succeeds and merges the 10 pairs
10. The escrow's Safe calls `reclaimDeposit(intentId)` -- succeeds and refunds 600 USDC
11. The Operator calls `depositForIntent(...)` -- reverts

**Outcomes:**
- Every trading call reverts with the phase error
- The collect, the merge, and the reclaim succeed and pay in full

**Side Effects:**
- No state change from the trading calls, and no event from them
- `FeesCollected(positionId, safe, 499)` from the collect
- `CompleteSetsMerged(caller, 10)` emitted by the merge, and the vault gains 10 USDC
- `DepositReclaimed(intentId, safe, 600)` from the reclaim

---

### SC-JXR2: Operator activity resets timelock

**Given:**
- Vault is in Active phase
- `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock` (timelock would have elapsed)

**Steps:**
1. Operator calls `notifyFees(amount)` (resets `lastOperatorActivityTimestamp`)
2. Position holder immediately calls `emergencyCancelAll()`
3. System checks timelock -- it has NOT elapsed since the recent `notifyFees`
4. System reverts

**Outcomes:**
- Transaction reverts with timelock error
- `lastOperatorActivityTimestamp` reflects the `notifyFees` call time

**Side Effects:**
- Fee distribution from `notifyFees` succeeded
- No emergency cancel occurred
- No `EmergencyCancelExecuted` event emitted

---

### SC-3XTZ: Heartbeat defers emergency cancel on a quiet market

**Given:**
- Vault is in Active phase, not paused, with at least one position
- The market is quiet and stable: the tick has not moved and no fee revenue has arrived, so `notifyFees` would revert with `ZeroAmount`
- `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock` (timelock would have elapsed)

**Steps:**
1. Operator calls `heartbeat()`
2. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
3. Position holder immediately calls `emergencyCancelAll()`
4. System checks the timelock -- it has NOT elapsed since the `heartbeat()`
5. System reverts
6. Time advances past the timelock again
7. Operator calls `updateTick(currentTick)`, the keeper's normal 60-second report
8. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp` and returns without a crossing or an event (SC-TVS7)
9. Position holder immediately calls `emergencyCancelAll()`
10. System checks the timelock -- it has NOT elapsed since the report
11. System reverts

**Outcomes:**
- `heartbeat()` and `updateTick(currentTick)` both succeeded
- Neither reverts on a quiet Active market
- Each `emergencyCancelAll()` reverts with the timelock error
- A healthy Operator on a market with no other work to do is no longer indistinguishable from a silent one

**Side Effects:**
- `lastOperatorActivityTimestamp` updated to `block.timestamp` on each of the two Operator calls
- No change to `activeLiquidity`, `currentTick`, `feeGrowthGlobalX128`, `nextPositionId`, `phase`, or any position or tick record
- No `TickUpdated` event emitted
- No USDC transferred
- No emergency cancel occurred and no `EmergencyCancelExecuted` event emitted

---

### SC-3XU0: Position minting and merging reset the timelock

**Given:**
- Vault is in Active phase
- `block.timestamp - lastOperatorActivityTimestamp >= emergencyCancelTimelock` (timelock would have elapsed)

**Steps:**
1. Operator calls `mintPositionFor(...)` for an LP
2. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
3. Position holder calls `emergencyCancelAll()` and the call reverts on the timelock
4. Time advances past the timelock again
5. Operator calls `mergePositions(...)` on two same-range positions
6. System refreshes `lastOperatorActivityTimestamp` to `block.timestamp`
7. Position holder calls `emergencyCancelAll()` and the call reverts on the timelock

**Outcomes:**
- Both Operator actions refreshed the silence timer
- Active deposit processing and position housekeeping now count as proof of life, where previously neither did

**Side Effects:**
- `lastOperatorActivityTimestamp` updated on each of the two Operator calls
- The mint and merge produced their own normal side effects
- No emergency cancel occurred and no `EmergencyCancelExecuted` event emitted

---

### SC-3XU1: Non-Operator cannot call heartbeat

**Given:**
- Vault is in Active phase
- Caller is an LP, Admin, Oracle, or arbitrary address -- not a registered Operator

**Steps:**
1. Non-Operator calls `heartbeat()`
2. System checks the `onlyOperator` gate

**Outcomes:**
- The call reverts with an access control error
- `lastOperatorActivityTimestamp` is unchanged, so a non-Operator cannot hold off `emergencyCancelAll`

**Side Effects:**
- No state changes
- No events emitted

---

### SC-3XUO: Heartbeat still works while trading is paused or the vault is wound down

**Given:**
- Case A: Vault is in Active phase and an Admin has called `pauseTrading()`, so `paused == true`. Every other Operator-gated function (`mintPositionFor`, `notifyFees`, `updateTick`, `mergePositions`) reverts on the `whenNotPaused` gate
- Case B: the Oracle has called `startWindDown()`, so `phase == 2`, and `updateTick` reverts with `VaultNotActive`, so the keeper's unchanged report cannot refresh the timer

**Steps:**
1. Operator calls `heartbeat()`
2. System checks the Operator gate and the Cancelled-phase guard, but not the pause flag and not the Active phase

**Outcomes:**
- In both cases the call succeeds and `lastOperatorActivityTimestamp == block.timestamp`
- A pause is an Admin decision about trading, and a wind-down is an Oracle decision about the market. Neither says whether the Operator is alive, so neither state drifts toward emergency cancellation while its Operator is still responding
- The keeper calls `heartbeat()` in both states

**Side Effects:**
- `lastOperatorActivityTimestamp` updated to `block.timestamp`
- No change to any other vault state
- No events emitted

---

### SC-3XU2: Heartbeat reverts once the vault is Cancelled

**Given:**
- Vault phase is Cancelled (3) after a successful `emergencyCancelAll()`

**Steps:**
1. Operator calls `heartbeat()`
2. System checks the Cancelled-phase guard

**Outcomes:**
- The call reverts `VaultCancelled`
- The freeze is terminal, so the silence timer has no further reader

**Side Effects:**
- No state changes
- No events emitted

---
