---
id: UC-JGEE
name: Start Wind Down
feature: FEAT-JGE7
status: implemented
version: 4
actor: Oracle
---

# UC-JGEE: Start Wind Down

> Oracle transitions a vault from Active to WindDown phase when its underlying market resolves, preventing new position mints while allowing existing LPs to exit.

## Preconditions

- Vault has been deployed and initialized via `createVault()` (phase == Active)
- Oracle address is set on the factory contract

## Trigger

Oracle calls `startWindDown()` on the vault.

---

### SC-JGEF: Successful wind-down transition

**Given:**
- Vault is in Active phase

**Steps:**
1. Oracle calls `startWindDown()` on the vault
2. System validates the vault's phase is Active
3. System transitions phase from Active to WindDown

**Outcomes:**
- Vault phase is WindDown

**Side Effects:**
- `VaultWindDownStarted(bytes32 indexed marketId)` event emitted
- No position state changes
- No USDC transfers

---

### SC-JGEG: Revert when phase is not Active

**Given:**
- Vault phase is WindDown (already transitioned via a prior `startWindDown()` call)

**Steps:**
1. Oracle calls `startWindDown()` on the vault
2. System validates the vault's phase is Active
3. System reverts

**Outcomes:**
- Transaction reverts with phase error

**Side Effects:**
- No state change
- No event emitted

---

### SC-JGEH: Revert when non-Oracle calls

**Given:**
- Vault is in Active phase
- Caller is not the Oracle (LP, Operator, Admin, or arbitrary address)

**Steps:**
1. Non-Oracle address calls `startWindDown()` on the vault
2. System validates caller is the Oracle
3. System reverts

**Outcomes:**
- Transaction reverts with access control error

**Side Effects:**
- No state change
- No event emitted

---

### SC-JGEI: depositForIntent reverts in WindDown

**Given:**
- Vault phase is WindDown
- The owner key signed a valid MintIntent, and the Safe holds and approved the USDC

**Steps:**
1. Operator calls `depositForIntent(lp, tickLower, tickUpper, usdcAmount, intentId, deadline, signature)` on the vault
2. System checks vault phase
3. System reverts

**Outcomes:**
- Transaction reverts with VaultNotActive

**Side Effects:**
- No escrow recorded
- No USDC transferred
- No position created

---

### SC-JGEJ: mintPositionFor reverts in WindDown

**Given:**
- Vault phase is WindDown
- The Operator escrowed an intent before the wind-down, so `pendingDeposits[intentId]` names the Safe

**Steps:**
1. Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, deadline)` on the vault
2. System checks vault phase
3. System reverts

**Outcomes:**
- Transaction reverts with VaultNotActive

**Side Effects:**
- No position created
- No intent consumed (`intentId` not marked as used)
- The escrow stays in place, so the Safe can reclaim it (SC-JGEK)
- No USDC transferred

---

### SC-JGEK: Exit paths succeed in WindDown

**Given:**
- Vault phase is WindDown
- LP has an existing position with accumulated fees

**Steps:**
1. The LP's Safe calls `collect(positionId)` on the vault
2. The vault merges any pairs, computes the fees owed, and transfers USDC to the Safe
3. The Safe calls `burnPosition(positionId)` on the vault
4. The vault removes the position's liquidity from both ticks, deletes the position, merges any pairs, and pays the Safe the claim's USDC plus its one outcome token

**Outcomes:**
- Fees collected and the position burned, the same as in Active phase
- The Safe receives the USDC and any token

**Side Effects:**
- Position `tokensOwed` zeroed after collect
- Position liquidity removed from tick state after burn, and `activeLiquidity` reduced by it
- The position record is deleted after the burn
- USDC transferred to the Safe
- `reclaimDeposit(intentId)` and `reclaimDepositFor` also succeed in WindDown, and `depositForIntent` reverts `VaultNotActive` (no new escrow after the wind-down)
- No new positions created

---
