# Tech Stack

## Modules

### contracts
- **Directory:** `.`
- **Language:** Solidity 0.8.20
- **Framework:** Foundry (forge, cast, anvil)
- **Build:** `forge build`
- **Key libraries:** forge-std, OpenZeppelin (IERC20, IERC1155, IERC1155Receiver — interfaces only)
- **Testing:** forge test (unit + fuzz + invariant)
- **Running tests:** `forge test`
- **Coverage:** `forge coverage`
- **Lint/Format:** `forge fmt`

## Runtime
- **Type:** host-native
- **Start command:** `forge build`
- **Stop command:** N/A

## Services

N/A — pure contract project with no runtime services.

## Applications

| Application | Type | Port/Target | Run Command | Notes |
|-------------|------|-------------|-------------|-------|
| contracts | smart contracts | Polygon | `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast` | EIP-1167 factory + vault clones |

## External Services
- Polygon (deployment target chain)
- ProphetCTFExchange (Polymarket fork CLOB — the exchange the vault pre-approves and interacts with)
- Gnosis ConditionalTokens (ERC-1155 contract managing YES/NO outcome tokens)

## Repository Structure
- **Type:** single-repo
- **Package manager:** N/A (Foundry manages dependencies via git submodules in `lib/`)

## Tooling

| Module | Root | Language | Format Command | Lint Command |
|--------|------|----------|----------------|--------------|
| contracts | `.` | Solidity | `forge fmt` | `forge fmt --check` |

## Environment
- **Env file:** `.env`
- **Key variables:** `RPC_URL`, `ETHERSCAN_API_KEY`
- **Seed data:** N/A

## Conventions
- All contracts use exact Solidity compiler version `pragma solidity 0.8.20;`
- Interface-only imports from OpenZeppelin; all implementations inlined (see CLAUDE.md pattern policy)
- Test files follow `{ContractName}.t.sol` naming in `test/`
- Deploy scripts follow `{Name}.s.sol` naming in `script/`
- Fixed-point math uses Q128 (2^128 scaling) for fee accumulators
