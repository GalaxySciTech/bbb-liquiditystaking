# XDC Liquidity Staking

XDC 流动性质押协议 - 独立项目，可在本目录直接运行。

## 快速开始

### 1. 安装依赖

```bash
cd /Users/galaxy/GitHub/bbb-liquiditystaking
yarn install
# 或
npm install
```

### 2. 配置环境变量

```bash
cp .env.sample .env
# 编辑 .env 填入 PRIVATE_KEY 等
```

### 3. 编译合约

```bash
yarn compile
# 或
npx hardhat compile
```

### 4. 运行测试

```bash
yarn test
# 或
npx hardhat test
```

### 5. 部署

**测试网 (xdctestnet):**
```bash
yarn deploy:xdctestnet
# 或
npx hardhat run scripts/liquidityStakingV2Deploy.js --network xdctestnet
```

**主网 (xdc):**
```bash
yarn deploy:xdc
# 或
npx hardhat run scripts/liquidityStakingV2Deploy.js --network xdc
```

## 项目结构

```
bbb-liquiditystaking/
├── contracts/           # Solidity 合约
│   ├── liquditystaking.sol   # 主合约 (bXDC, WithdrawalRequestNFT, XDCLiquidityStaking)
│   ├── WXDC.sol
│   ├── MasternodeVault.sol
│   ├── MasternodeVaultFactory.sol
│   ├── MasternodeManager.sol
│   ├── OperatorRegistry.sol
│   ├── RevenueDistributor.sol
│   ├── interfaces/
│   └── mocks/
├── scripts/
│   └── liquidityStakingV2Deploy.js
├── test/
│   └── LiquidityStaking.test.js
├── deployments/         # 部署输出
├── hardhat.config.js
├── network.config.json
└── package.json
```

## V2 部署后配置流程

1. **LSP admin**: `submitKYC(kycHash)`
2. **OperatorRegistry**: `registerOperator(admin, maxMasternodes)`, `approveKYC(admin)`
3. **Operators**: `whitelistCoinbase(coinbase)` 为每个 masternode
4. **Users**: `stake()` 质押 XDC 获得 bXDC，buffer 健康时 MasternodeManager 自动 propose
5. **Keeper**: `harvestRewards()` 从 vault 收取奖励，按 90/7/3 分配
6. **Operators**: `RevenueDistributor.claimCommission()` 领取佣金
