# XDC Liquidity Staking

XDC Liquid Staking Protocol — a Lido-style staking system aligned with **Spec v1.5** and **XDC 2.0 Staking, Rewards and Burning Upgrade**. Users stake XDC to receive liquid bXDC tokens. Operators run masternodes across Core/Protector/Observer tiers to earn rewards, which automatically increase bXDC value.

📄 **[Technical Specification (xdc-liquid-staking-spec-v1.5.docx)](xdc-liquid-staking-spec-v1.5.docx)**

## Design Principles (Spec v1.5)

- **Scale-first**: Deploy masternodes across all tiers. Observer Nodes are the growth engine.
- **Simplified vault**: MasternodeVault handles `setupAndPropose`, `collectRewards`, `resign` only.
- **Operator top-up direct**: Operators call `vote()`/`unvote()` on 0x88 from their own EOA — bypasses vault.
- **KYC delegation**: Vault reuses operator's KYC hash via `uploadKYC()` before `propose()`. One-time per vault.
- **Blended yield**: bXDC exchange rate reflects weighted average across all tiers.
- **No oracle**: Per-vault on-chain balance is performance data. Zero off-chain infrastructure.

---

## Quick Start

### 1. Install Dependencies

```bash
yarn install
# or
npm install
```

### 2. Configure Environment

```bash
cp .env.sample .env
# Edit .env and add PRIVATE_KEY, etc.
```

### 3. Compile Contracts

```bash
yarn compile
# or
npx hardhat compile
```

### 4. Run Tests

```bash
yarn test
# or
npx hardhat test
```

### 5. Deploy

**Testnet (xdctestnet):**
```bash
yarn deploy:xdctestnet
# or
npx hardhat run scripts/liquidityStakingDeploy.js --network xdctestnet
```

**Mainnet (xdc):**
```bash
yarn deploy:xdc
# or
npx hardhat run scripts/liquidityStakingDeploy.js --network xdc
```

---

## XDC 2.0 Three-Tier Architecture

Under XDC 2.0, masternodes participate in a three-tier system:

| Tier | Count | Reward/Node/Epoch | Annual (approx) |
|------|-------|-------------------|-----------------|
| Core Validator | 108 | ~55.56 XDC | ~973,333 XDC |
| Protector Node | 216 | ~46.30 XDC | ~811,111 XDC |
| Observer Node | Unlimited | ~23.15 XDC | ~405,555 XDC |

**Scale economics**: At 1,000 masternodes the protocol earns ~28.5× more than a 20-node deployment. Volume dominates tier.

**Epoch timing**: 1 epoch = 900 blocks. 1 block ≈ 2 seconds. ~48 epochs/day.

---

## Project Structure

```
bbb-liquiditystaking/
├── contracts/
│   ├── XDCLiquidityStaking.sol   # Main coordinator
│   ├── bXDC.sol                 # ERC-4626 liquid receipt token
│   ├── WithdrawalRequestNFT.sol  # ERC-1155 NFT for delayed withdrawals
│   ├── WXDC.sol
│   ├── MasternodeVault.sol      # Per-masternode proxy (setupAndPropose, collectRewards, resign)
│   ├── MasternodeVaultFactory.sol
│   ├── MasternodeManager.sol
│   ├── OperatorRegistry.sol     # KYC lifecycle, kycHash storage for vault delegation
│   ├── RevenueDistributor.sol
│   ├── interfaces/
│   └── mocks/
├── scripts/
├── test/
├── hardhat.config.js
└── network.config.json
```

---

## Post-Deployment Configuration

1. **OperatorRegistry**: `registerOperator(admin, maxMasternodes)`, `approveKYC(admin, kycHash)` — stores kycHash for vault delegation
2. **Operators**: `whitelistCoinbase(coinbase)` for each masternode
3. **Users**: `stake()` XDC to receive bXDC; MasternodeManager auto-proposes when buffer is healthy
4. **Keeper**: `harvestRewards()` collects from all vaults, distributes 90/7/3 (bXDC/operator/treasury)
5. **Operators**: `RevenueDistributor.claimCommission()` to claim commission
6. **Optional**: LSP admin `submitKYC(kycHash)` for protocol-level registration

---

## KYC Delegation Flow

Per spec v1.5, each vault reuses the operator's KYC hash:

1. **Operator onboards**: Completes KYC off-chain. Admin calls `approveKYC(operatorAdmin, kycHash)` — hash stored in OperatorRegistry.
2. **Vault deployed**: StakingPool deploys EIP-1167 proxy vault.
3. **Vault calls `setupAndPropose(kycHash, coinbase)`**: Uploads KYC to 0x88, then proposes with 10M XDC. Vault becomes masternode owner.
4. **Rewards flow**: 0x88 sends epoch rewards to vault. Keeper calls `harvestRewards()` → vault `collectRewards()` → StakingPool.

---

## Operator Top-Up (Direct to 0x88)

Operators can top up their masternodes **directly** via 0x88 — no vault routing:

- `vote(coinbase)` — Operator sends XDC from EOA. No KYC needed.
- `unvote(coinbase, amount)` — Partial withdrawal. `voterWithdrawDelay` applies.
- Capital separation is automatic at 0x88 level. Protocol 10M and operator top-up are tracked separately.

---

## Core Features

### User Features

- **Stake XDC** — Receive bXDC at current exchange rate (native or WXDC)
- **Instant Exit** — Withdraw immediately if amount ≤ `instantExitBuffer`
- **Delayed Withdrawal** — Larger amounts get ERC-1155 NFT; redeem after unbonding
- **Hold for Yield** — bXDC value grows as staking rewards accrue

### Admin Features

- **Revenue Split** — Configure bXDC/operator/treasury (default 90/7/3)
- **Buffer Management** — `addToInstantExitBuffer()`, `minBufferPercent`, `criticalBufferPercent`
- **Parameter Management** — `minStakeAmount`, `minWithdrawAmount`, `masternodeStakeAmount`
- **Pause Control** — Pause in emergencies (no emergencyWithdraw)

---

## Exchange Rate Mechanism

### Formula

```
Exchange Rate = totalPooledXDC / bXDC Total Supply

bXDC Amount = XDC Amount × bXDC Total Supply / totalPooledXDC

XDC Amount = bXDC Amount × totalPooledXDC / bXDC Total Supply
```

### Yield Growth

- Initial: 1 bXDC = 1 XDC
- As rewards are harvested, `totalPooledXDC` increases → 1 bXDC > 1 XDC over time
- Blended yield across Core/Protector/Observer tiers

---

## Revenue Distribution

| Recipient | Range | Description |
|-----------|-------|-------------|
| bXDC Holders | 85–92% | Added to totalPooledXDC |
| Operator Commission | 5–10% | Per-vault, claimed via RevenueDistributor |
| Protocol Treasury | 2–5% | Development, audits |

**KYC-expired operators**: Commission redirected 50% bXDC + 50% treasury. Reversible on renewal.

---

## Usage Examples

### User: Stake XDC

```javascript
await stakingPool.stake({ value: ethers.utils.parseEther("100") });
```

### User: Withdraw (Instant or NFT)

```javascript
// Instant if amount ≤ buffer
await stakingPool.withdraw(bxdcAmount);

// Or redeem ERC-4626 shares directly (instant only)
await stakingPool.redeem(shares, receiver, owner);
```

### User: Redeem Delayed Withdrawal NFT

```javascript
await stakingPool.redeemWithdrawal(batchId);
```

### Keeper: Harvest Rewards

```javascript
await stakingPool.harvestRewards();
```

### Operator: Claim Commission

```javascript
await revenueDistributor.claimCommission();
```

---

## Buffer & Withdrawal Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| minStakeAmount | 1 XDC | Minimum stake |
| minWithdrawAmount | 0.1 XDC | Minimum withdrawal |
| minBufferPercent | 5% | Below: no new masternode proposals |
| criticalBufferPercent | 2% | Below: resignations triggered |
| withdrawDelayBlocks | 1,296,000 | ~30 days unbonding for NFT path |

---

## Security Features

- **ReentrancyGuard** — Prevents reentrancy
- **Pausable** — Emergency pause only (no emergencyWithdraw)
- **AccessControl** — LSP_ADMIN_ROLE, MASTERNODE_MANAGER_ROLE
- **Dual exit path** — Instant (buffer) or delayed (NFT)

---

## Events

- `Staked` — User staked
- `WithdrawalNFTMinted` — Delayed withdrawal requested
- `WithdrawalRedeemed` — NFT redeemed after unbonding
- `InstantExit` — Immediate withdrawal
- `MasternodeProposed` / `MasternodeResigned`
- `RewardsHarvested` — Harvest completed
- `VaultCollected` — Per-vault reward collection
- `CommissionAccrued` / `CommissionRedirected`

---

## FAQ

**Q: Can users withdraw immediately?**  
A: Yes, if the amount is within `instantExitBuffer`. Otherwise they receive an ERC-1155 NFT and redeem after unbonding.

**Q: How does the exchange rate increase?**  
A: When `harvestRewards()` collects from vaults, the bXDC share is added to `totalPooledXDC`. bXDC supply stays constant → rate increases.

**Q: Can operators top up their masternodes?**  
A: Yes. Operators call `vote(coinbase)` directly on 0x88 from their EOA. No vault routing.

**Q: Can bXDC be traded?**  
A: Yes. bXDC is ERC-4626 compatible and can be used in DeFi.

---

## Quick Command Reference

```bash
# Deploy
npx hardhat run scripts/liquidityStakingDeploy.js --network xdc

# Admin tool
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc

# Console
npx hardhat console --network xdc
```

---

## License

MIT License
