---
id: UC-JGEE
name: Start Wind Down
feature: FEAT-JGE7
status: implemented
version: 1
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

### SC-JGEI: mintPosition reverts in WindDown

**Given:**
- Vault phase is WindDown

**Steps:**
1. Operator calls `mintPosition(tickLower, tickUpper, usdcAmount)` on the vault
2. System checks vault phase
3. System reverts

**Outcomes:**
- Transaction reverts with phase error

**Side Effects:**
- No position created
- No tick state modified
- No USDC transferred

---

### SC-JGEJ: mintPositionFor reverts in WindDown

**Given:**
- Vault phase is WindDown
- Operator has a valid LP-signed EIP-712 mint intent

**Steps:**
1. Operator calls `mintPositionFor(lp, tickLower, tickUpper, usdcAmount, intentId, ...)` on the vault
2. System checks vault phase
3. System reverts

**Outcomes:**
- Transaction reverts with phase error

**Side Effects:**
- No position created
- No intent consumed (`intentId` not marked as used)
- No USDC transferred

---

### SC-JGEK: Exit paths succeed in WindDown

**Given:**
- Vault phase is WindDown
- LP has an existing position with accumulated fees

**Steps:**
1. LP calls `collect(positionId)` on the vault
2. System computes owed fees and transfers USDC to LP
3. LP calls `burnPosition(positionId)` on the vault
4. System removes position liquidity and returns capital to LP

**Outcomes:**
- Fees collected and position burned successfully -- same behavior as Active phase
- LP receives owed USDC

**Side Effects:**
- Position `tokensOwed` zeroed after collect
- Position liquidity removed from tick state after burn
- USDC transferred to LP
- `reclaimDeposit` also succeeds in WindDown (same phase-agnostic behavior)
- No new positions created

---
