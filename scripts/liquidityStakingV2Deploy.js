const hre = require("hardhat");

async function main() {
    console.log("Deploying XDC Liquid Staking V2 (Spec v1.3)...");

    const [deployer] = await hre.ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Balance:", hre.ethers.utils.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "XDC");

    const validatorAddress = process.env.XDC_VALIDATOR_ADDRESS || "0x0000000000000000000000000000000000000088";
    const WXDC_MAINNET = "0x951857744785E80e2De051c32EE7b25f9c458C42";
    let wxdcAddress;
    if (hre.network.name === "xdc" || hre.network.name === "xdc-mainnet") {
        wxdcAddress = process.env.WXDC_ADDRESS || WXDC_MAINNET;
        console.log("\nUsing WXDC:", wxdcAddress);
    } else {
        const WXDC = await hre.ethers.getContractFactory("WXDC");
        const wxdc = await WXDC.deploy();
        await wxdc.deployed();
        wxdcAddress = wxdc.address;
        console.log("WXDC deployed:", wxdcAddress);
    }

    const treasuryAddress = process.env.TREASURY_ADDRESS || deployer.address;
    console.log("Treasury:", treasuryAddress);

    console.log("\nDeploying XDCLiquidityStaking...");
    const XDCLiquidityStaking = await hre.ethers.getContractFactory("XDCLiquidityStaking");
    const stakingPool = await XDCLiquidityStaking.deploy(
        validatorAddress,
        wxdcAddress,
        deployer.address,
        treasuryAddress
    );
    await stakingPool.deployed();
    const stakingPoolAddress = stakingPool.address;
    console.log("XDCLiquidityStaking:", stakingPoolAddress);

    const bxdcAddress = await stakingPool.bxdcToken();
    const withdrawalNFTAddress = await stakingPool.withdrawalNFT();
    const operatorRegistryAddress = await stakingPool.operatorRegistry();
    const revenueDistributorAddress = await stakingPool.revenueDistributor();
    const masternodeManagerAddress = await stakingPool.masternodeManager();
    const vaultFactoryAddress = await stakingPool.vaultFactory();

    console.log("\nDeployed contracts:");
    console.log("- bXDC:", bxdcAddress);
    console.log("- WithdrawalRequestNFT:", withdrawalNFTAddress);
    console.log("- OperatorRegistry:", operatorRegistryAddress);
    console.log("- RevenueDistributor:", revenueDistributorAddress);
    console.log("- MasternodeManager:", masternodeManagerAddress);
    console.log("- MasternodeVaultFactory:", vaultFactoryAddress);

    console.log("\nV2 Setup (Spec v1.3):");
    console.log("1. LSP admin: submitKYC(kycHash)");
    console.log("2. OperatorRegistry: registerOperator(admin, maxMasternodes), approveKYC(admin)");
    console.log("3. Operators: whitelistCoinbase(coinbase) for each masternode");
    console.log("4. Users stake() -> bXDC. MasternodeManager auto-proposes when buffer healthy");
    console.log("5. Keeper: harvestRewards() collects from vaults, splits 90/7/3");
    console.log("6. Operators: RevenueDistributor.claimCommission()");

    const deploymentInfo = {
        network: hre.network.name,
        deployer: deployer.address,
        contracts: {
            XDCLiquidityStaking: stakingPoolAddress,
            WXDC: wxdcAddress,
            bXDC: bxdcAddress,
            WithdrawalRequestNFT: withdrawalNFTAddress,
            OperatorRegistry: operatorRegistryAddress,
            RevenueDistributor: revenueDistributorAddress,
            MasternodeManager: masternodeManagerAddress,
            MasternodeVaultFactory: vaultFactoryAddress
        },
        validatorAddress,
        treasuryAddress,
        timestamp: new Date().toISOString()
    };

    const fs = require("fs");
    const path = require("path");
    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
    const filename = `liquidity-staking-v2-${hre.network.name}-${Date.now()}.json`;
    fs.writeFileSync(path.join(deploymentsDir, filename), JSON.stringify(deploymentInfo, null, 2));
    console.log(`\nSaved: deployments/${filename}`);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });
