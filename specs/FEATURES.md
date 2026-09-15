# Feature Inventory

> The permanent catalog of all product features.
> Features are never removed -- they accumulate use cases over their lifetime.

## Status Key

- `pending` -- Spec written, not yet implemented
- `implemented` -- Code exists that fulfills this spec
- `dirty` -- Spec changed after implementation; code needs to catch up
- `deprecated` -- No longer active; retained for audit trail

## @vault

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-REPZ | Deploy LP Vault for a Market | Factory pattern and role registry for deploying per-market LP vaults as EIP-1167 clones with factory-delegated authorization, holding the Safe derivation inputs as immutables and the default emergency-cancel timelock that each vault copies at creation | implemented |
| FEAT-J92H | Deploy Contracts | Foundry deploy script that deploys LPVault implementation and LPVaultFactory with env-var-driven configuration for Polygon Amoy and mainnet, reading the Safe proxy bytecode hash from the live Safe factory | implemented |
| FEAT-JGE7 | Vault Wind-Down Lifecycle | Oracle-driven phase transition from Active to WindDown that gates off new mints while keeping exit paths open for existing LPs | implemented |
| FEAT-JXQO | Emergency Cancel All Positions | Any-address freeze after the vault's operator-silence timelock that sets the terminal Cancelled phase and changes nothing else, so every LP exits alone through the paths that work in every phase | implemented |
| FEAT-K1MD | Pause Trading | Admin-callable circuit breaker that halts trading entry points while keeping LP exit paths live | implemented |
| FEAT-KX5N | Upgradeable Vault Implementation Pointer | Admin-driven two-step timelocked upgrade of the factory's implementation pointer with per-clone version tracking | implemented |
| FEAT-6HBN | Complete-Set Merge and Resolution Redemption | Any wallet merges the vault's matched YES and NO tokens into USDC held by the vault, in every phase, and every payout merges first; after the market resolves the Oracle redeems the vault's tokens, and that first call switches every later payout to USDC at the reported payout | implemented |
| FEAT-9BQZ | Vault Solvency Ledger | Running totals of what the vault owes per asset in the claim's pre-division unit, moved on every mint, burn, merge, and segment of a tick move under the claim model (decision C26), and a per-asset ratio that every burn applies, so a shortfall is a cut every claimant takes alike (decision O2) | implemented |
| FEAT-C0DJ | Vault Order Authorization | EIP-1271 vouching that lets a registered Operator author orders naming the vault as maker, answered to the exchange only and only while the vault is Active and not paused, so vault-held capital is filled without leaving the vault and a paused, wound-down, or frozen vault takes no new fill (decision C22) | implemented |

## @positions

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-T7AF | Mint LP Position | Operator-gated concentrated-liquidity position creation that consumes a per-intent escrow, with v3-style tick initialization and a clamped mint tick on every position | implemented |
| FEAT-U079 | Collect Fees on a Position | LP withdraws accumulated trading fees from a position, by the Safe or relayed with the owner key's CollectIntent, using the v3 feeGrowthInside accumulator, merging the vault's pairs first, and paying its share of what the vault holds above escrow at the ledger's USDC ratio | deprecated |
| FEAT-7G40 | Burn LP Position | LP-initiated closure of a position, by the Safe or relayed with the owner key's BurnIntent, that values the claim from its mint tick (decision C26), merges the vault's pairs, removes the liquidity from both ticks, and pays USDC plus one outcome token, each asset's owed amount times its ratio from the solvency ledger | implemented |
| FEAT-JAIJ | LP Escape Hatch | LP-initiated recovery of the USDC escrowed against a mint intent that the Operator did not mint, in one call by the LP's Safe or one relayed call with the owner key's signature, in every vault phase | implemented |
| FEAT-3ZRI | Escrow Deposit for Mint Intent | Operator-gated escrow of an LP's USDC from the LP's Safe against a signed mint intent, recorded per intentId with the Safe, the amount, and the intent hash, so the mint and the reclaim spend exactly what was recorded | implemented |
| FEAT-K1M2 | Merge Positions | Operator-called housekeeping to combine distinct same-range same-owner same-mint-tick positions into a single record preserving total liquidity | implemented |

## @fees

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TOGR | Notify and Distribute Fees | Operator-driven Q128 fee accumulator update that distributes trading fee revenue proportionally across in-range LP positions and takes that revenue from the Operator wallet in the same call | deprecated |

## @ticks

| ID | Feature | Description | Status |
|----|---------|-------------|--------|
| FEAT-TVS0 | Update Tick and Cross Ticks | Operator-driven tick synchronization that crosses initialized ticks between the vault's current price and the CLOB mid-price, adjusting active liquidity and the NO-side liquidity so the claim model values every position at the reported price | implemented |
