# AGENTS.md — XDC Liquidity Staking

Instructions for AI coding assistants working on this codebase.

## Project Overview

XDC Liquid Staking Protocol — Lido-style staking aligned with **Spec v1.5** and **XDC 2.0**. Users stake XDC to receive liquid bXDC. Operators run masternodes (Core/Protector/Observer tiers). See [README.md](README.md) for full documentation.

## Build & Test

```bash
yarn install
yarn compile          # Hardhat compile
yarn test             # Run tests
```

**Deploy:**
```bash
yarn deploy:xdctestnet   # Testnet
yarn deploy:xdc          # Mainnet
```

## Tech Stack

- **Solidity** 0.8.23 (via Hardhat)
- **OpenZeppelin** Contracts v5
- **Hardhat** with Waffle, Ethers v5
- **Networks:** `xdc`, `xdctestnet`, `xdcparentnet`, `xdcsubnet`, `xdcdevnet`

## Project Structure

```
contracts/
├── XDCLiquidityStaking.sol   # Main coordinator
├── bXDC.sol                  # ERC-4626 liquid receipt token
├── WithdrawalRequestNFT.sol  # ERC-1155 for delayed withdrawals
├── MasternodeVault.sol       # Per-masternode proxy
├── MasternodeVaultFactory.sol
├── MasternodeManager.sol
├── OperatorRegistry.sol      # KYC lifecycle
├── RevenueDistributor.sol
├── RewardsVault.sol
├── WXDC.sol
├── interfaces/
└── mocks/
scripts/
├── liquidityStakingDeploy.js
└── liquidityStakingAdmin.js
test/
└── LiquidityStaking.test.js
```

## Code Conventions

- **Solidity:** SPDX license, NatSpec comments, OpenZeppelin patterns
- **Access control:** `LSP_ADMIN_ROLE`, `MASTERNODE_MANAGER_ROLE`
- **Security:** ReentrancyGuard, Pausable, SafeERC20 where applicable
- **JS/Config:** CommonJS (require), no TypeScript

## Key Concepts

- **Exchange rate:** `totalPooledXDC / bXDC supply` — increases as rewards are harvested
- **Revenue split:** 90% bXDC holders, 7% operators, 3% treasury (configurable)
- **Withdrawals:** Instant (if ≤ buffer) or delayed (ERC-1155 NFT, unbonding period)
- **KYC delegation:** Vault reuses operator KYC hash via `uploadKYC()` before `propose()`
- **Operator top-up:** Direct `vote()`/`unvote()` on 0x88 — no vault routing

## Security Notes

- No `emergencyWithdraw` — Pausable only
- Dual exit path: instant buffer vs delayed NFT
- Per-vault reward isolation; harvest from each vault
- KYC-expired operators: commission redirected 50/50 to bXDC + treasury

## Environment

Copy `.env.sample` to `.env`. Required: `PRIVATE_KEY`. Optional: `ALCHEMY_API_KEY`, `ETHERSCAN_API_KEY`, `XDC_VALIDATOR_ADDRESS`, `WXDC_ADDRESS`, `TREASURY_ADDRESS`.

## Gotchas

- Hardhat uses `viaIR: true` and optimizer runs 200
- XDC mainnet chainId: 50; testnet: `xdctestnet`
- `masternodeStakeAmount` default: 10M XDC
- `withdrawDelayBlocks` ≈ 30 days (1,296,000 blocks)
