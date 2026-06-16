# Project

> On-chain Solidity contracts for Prophet's LP provisioning engine.

Prophet runs a CLOB prediction market built on top of the Polymarket CTF Exchange contracts. Today the only liquidity provider is the house. This project builds the on-chain layer that lets external LPs pool capital into specific markets, each LP picking their own price range (concentrated liquidity), earning trading fees proportional to their active liquidity within that range.

The architecture is per-market vaults deployed via a factory (EIP-1167 minimal-proxy clones), with Uniswap v3-style position records per LP. Each vault holds USDC and ERC-1155 outcome tokens for one market, maintains per-tick fee accumulators (`feeGrowthOutsideX128`) and a global fee accumulator (`feeGrowthGlobalX128`), and supports operator-driven position crediting (the "deposit-then-credit" 4-step UI flow) alongside direct `mintPosition` calls. The contracts are the on-chain foundation — the off-chain keeper, event listener, and server integrations live in separate repositories.
