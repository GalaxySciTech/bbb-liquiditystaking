# XDC Liquidity Staking

XDC Liquidity Staking Protocol — a Lido-style staking system. Users stake XDC to receive liquid bXDC tokens. Operators run masternodes to earn rewards, which automatically increase bXDC value.

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
npx hardhat run scripts/liquidityStakingV2Deploy.js --network xdctestnet
```

**Mainnet (xdc):**
```bash
yarn deploy:xdc
# or
npx hardhat run scripts/liquidityStakingV2Deploy.js --network xdc
```

---

## Project Structure

```
bbb-liquiditystaking/
├── contracts/              # Solidity contracts
│   ├── liquditystaking.sol # Main contracts (bXDC, WithdrawalRequestNFT, XDCLiquidityStaking)
│   ├── WXDC.sol
│   ├── MasternodeVault.sol
│   ├── MasternodeVaultFactory.sol
│   ├── MasternodeManager.sol
│   ├── OperatorRegistry.sol
│   ├── RevenueDistributor.sol
│   ├── interfaces/
│   └── mocks/
├── scripts/
│   ├── liquidityStakingV2Deploy.js
│   ├── liquidityStakingDeploy.js
│   ├── liquidityStakingDemo.js
│   └── liquidityStakingAdmin.js
├── test/
│   └── LiquidityStaking.test.js
├── deployments/            # Deployment outputs
├── hardhat.config.js
├── network.config.json
└── package.json
```

---

## V2 Post-Deployment Configuration

1. **LSP admin**: `submitKYC(kycHash)`
2. **OperatorRegistry**: `registerOperator(admin, maxMasternodes)`, `approveKYC(admin)`
3. **Operators**: `whitelistCoinbase(coinbase)` for each masternode
4. **Users**: `stake()` XDC to receive bXDC; MasternodeManager auto-proposes when buffer is healthy
5. **Keeper**: `harvestRewards()` collects rewards from vault, distributes 90/7/3
6. **Operators**: `RevenueDistributor.claimCommission()` to claim commission

---

## Core Features

### User Features

- **Stake XDC** — Receive bXDC at the current exchange rate
- **Request Withdrawal** — Submit a withdrawal request (requires admin approval)
- **Hold for Yield** — bXDC value grows automatically as staking rewards increase

### Admin Features

- **Approve/Reject Withdrawals** — Approve or reject user withdrawal requests
- **Batch Operations** — Batch approve multiple requests
- **Withdraw for Validator** — Withdraw XDC to run validator nodes
- **Return Principal** — Return principal from validator nodes to the contract
- **Deposit Rewards** — Deposit staking rewards and update exchange rate
- **Parameter Management** — Adjust min stake/withdraw amounts, max withdrawable ratio
- **Pause Control** — Pause contract in emergencies

---

## Exchange Rate Mechanism

### Initial State

- 1 bXDC = 1 XDC (1:1)

### Yield Growth

When rewards are deposited, the exchange rate increases. Example:

- Initial: 100 XDC staked → 100 bXDC minted
- Rewards: 10 XDC deposited
- New rate: 1 bXDC = 1.1 XDC
- 10% value increase for holders

### Formula

```
Exchange Rate = Total Pooled XDC / bXDC Total Supply

bXDC Amount = XDC Amount × bXDC Total Supply / Total Pooled XDC

XDC Amount = bXDC Amount × Total Pooled XDC / bXDC Total Supply
```

---

## Usage Examples

### User: Stake XDC

```javascript
// Web3.js
const amount = web3.utils.toWei('100', 'ether');
await stakingPoolContract.methods.stake().send({ from: userAddress, value: amount });

// Ethers.js
await stakingPool.stake({ value: ethers.utils.parseEther("100") });
```

### User: Query bXDC Balance

```javascript
const balance = await bxdcContract.methods.balanceOf(userAddress).call();
console.log('bXDC balance:', web3.utils.fromWei(balance, 'ether'));
```

### User: Query Exchange Rate

```javascript
const rate = await stakingPoolContract.methods.getExchangeRate().call();
console.log('1 bXDC =', web3.utils.fromWei(rate, 'ether'), 'XDC');
```

### User: Request Withdrawal

```javascript
// 1. Approve
await bxdcContract.methods.approve(stakingPoolAddress, bxdcAmount).send({ from: userAddress });
// 2. Request
await stakingPoolContract.methods.requestWithdrawal(bxdcAmount).send({ from: userAddress });
```

### Admin: Interactive Tool

```bash
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc
```

Menu options:

1. View contract status
2. View pending withdrawals
3. Approve withdrawal
4. Batch approve
5. Reject withdrawal
6. Withdraw XDC for validator
7. Return principal
8. Deposit rewards
9. Update parameters
10. Pause/Resume

### Admin: Common Commands

```bash
npx hardhat console --network xdc
> const pool = await ethers.getContractAt("XDCLiquidityStaking", "0x...")
> await pool.getPendingWithdrawalIds()
> await pool.approveWithdrawal(0)
> await pool.withdrawForValidator(ethers.utils.parseEther("1000"))
```

---

## Workflow: Correct Fund Management

**Correct flow:**

1. Withdraw XDC → `withdrawForValidator(amount)`
2. Run validator and earn rewards
3. Return principal → Direct transfer to contract address
4. Deposit rewards → `depositRewards(rewardAmount)` (rewards only)

**Common mistake:**

❌ Depositing principal + rewards together via `depositRewards` — this incorrectly increases `totalPooledXDC`.

**Reason:**

- `withdrawForValidator` only withdraws XDC; it does not change `totalPooledXDC`
- Withdrawn XDC still belongs to the pool, just temporarily outside the contract
- `depositRewards` increases `totalPooledXDC`, so only net rewards should be passed

---

## APY Calculation

```javascript
APY = (newRate / oldRate - 1) × (365 / days) × 100%

// Example:
// Initial: 1.0, After 30 days: 1.1
// APY = (1.1 / 1.0 - 1) × (365 / 30) × 100% = 121.67%
```

---

## Security Features

- **ReentrancyGuard** — Prevents reentrancy attacks
- **Pausable** — Pause in emergencies
- **Ownable** — Admin-only operations
- **Withdrawal approval** — Withdrawals require admin approval
- **Liquidity protection** — Max withdrawable ratio limit

---

## Configurable Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| minStakeAmount | 1 XDC | Minimum stake amount |
| minWithdrawAmount | 0.1 XDC | Minimum withdrawal amount |
| maxWithdrawablePercentage | 80% | Maximum withdrawable ratio |

---

## Events

- `Staked` — User staked
- `WithdrawalRequested` — Withdrawal requested
- `WithdrawalApproved` — Withdrawal approved
- `WithdrawalRejected` — Withdrawal rejected
- `ValidatorFundsWithdrawn` — Funds withdrawn for validator
- `RewardsDeposited` — Rewards deposited

---

## FAQ

**Q: Can users withdraw immediately?**  
A: No. Withdrawals require admin approval to ensure sufficient liquidity.

**Q: How does the exchange rate increase?**  
A: When rewards are deposited, total pooled XDC increases while bXDC supply stays the same, so the rate increases.

**Q: How much XDC can be withdrawn?**  
A: Default max 80%, configurable by admin.

**Q: Can bXDC be traded?**  
A: Yes. bXDC is a standard ERC20 token and can be transferred and traded on DEXes.

---

## Quick Command Reference

```bash
# Deploy
npx hardhat run scripts/liquidityStakingV2Deploy.js --network xdc

# Admin tool
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc

# Demo
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingDemo.js --network xdc

# Console
npx hardhat console --network xdc
```

---

## License

MIT License
