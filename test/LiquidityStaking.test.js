const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("XDC Liquidity Staking V2", function () {
    let stakingPool;
    let bxdc;
    let withdrawalNFT;
    let operatorRegistry;
    let mockValidator;
    let owner;
    let user1;
    let user2;

    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();

        const MockXDCValidator = await ethers.getContractFactory("MockXDCValidator");
        mockValidator = await MockXDCValidator.deploy();
        await mockValidator.deployed();

        const WXDC = await ethers.getContractFactory("WXDC");
        const wxdc = await WXDC.deploy();
        await wxdc.deployed();

        const XDCLiquidityStaking = await ethers.getContractFactory("XDCLiquidityStaking");
        stakingPool = await XDCLiquidityStaking.deploy(
            mockValidator.address,
            wxdc.address,
            owner.address,
            owner.address
        );
        await stakingPool.deployed();

        bxdc = await ethers.getContractAt("bXDC", await stakingPool.bxdcToken());
        withdrawalNFT = await ethers.getContractAt("WithdrawalRequestNFT", await stakingPool.withdrawalNFT());
        operatorRegistry = await ethers.getContractAt("OperatorRegistry", await stakingPool.operatorRegistry());
    });

    describe("部署", function () {
        it("应该正确设置初始状态", async function () {
            expect(await stakingPool.totalPooledXDC()).to.equal(0);
            expect(await bxdc.totalSupply()).to.equal(0);
            expect(await stakingPool.minStakeAmount()).to.equal(ethers.utils.parseEther("1"));
            expect(await stakingPool.minWithdrawAmount()).to.equal(ethers.utils.parseEther("0.1"));
            expect(await stakingPool.maxWithdrawablePercentage()).to.equal(80);
        });

        it("应该正确设置 bXDC 的质押池地址", async function () {
            expect(await bxdc.stakingPool()).to.equal(stakingPool.address);
        });
    });

    describe("质押功能", function () {
        it("应该允许用户质押 XDC 并获得 bXDC", async function () {
            const stakeAmount = ethers.utils.parseEther("100");

            await stakingPool.connect(user1).stake({ value: stakeAmount });

            expect(await bxdc.balanceOf(user1.address)).to.equal(stakeAmount);
            expect(await stakingPool.totalPooledXDC()).to.equal(stakeAmount);
        });

        it("初始兑换比例应该是 1:1", async function () {
            const exchangeRate = await stakingPool.getExchangeRate();
            expect(exchangeRate).to.equal(ethers.utils.parseEther("1"));
        });

        it("应该拒绝低于最小数量的质押", async function () {
            const smallAmount = ethers.utils.parseEther("0.5");

            await expect(
                stakingPool.connect(user1).stake({ value: smallAmount })
            ).to.be.revertedWith("Amount below minimum");
        });

        it("多个用户应该能够质押", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            await stakingPool.connect(user2).stake({ value: ethers.utils.parseEther("50") });

            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("100"));
            expect(await bxdc.balanceOf(user2.address)).to.equal(ethers.utils.parseEther("50"));
            expect(await stakingPool.totalPooledXDC()).to.equal(ethers.utils.parseEther("150"));
        });
    });

    describe("赎回功能 - 即时退出", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });

        it("有即时缓冲时应立即赎回", async function () {
            const withdrawAmount = ethers.utils.parseEther("10");
            const balanceBefore = await ethers.provider.getBalance(user1.address);

            const tx = await stakingPool.connect(user1).withdraw(withdrawAmount);
            await tx.wait();

            const balanceAfter = await ethers.provider.getBalance(user1.address);
            const received = balanceAfter.sub(balanceBefore);
            expect(received).to.be.closeTo(ethers.utils.parseEther("10"), ethers.utils.parseEther("0.01"));
            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("90"));
        });

        it("addToInstantExitBuffer 应增加缓冲", async function () {
            await stakingPool.connect(owner).addToInstantExitBuffer({ value: ethers.utils.parseEther("50") });
            expect(await stakingPool.getBufferHealthPercent()).to.be.gt(0);
        });
    });

    describe("赎回功能 - NFT 退出", function () {
        it("withdrawalBatches 结构应存在", async function () {
            // NFT 路径需 withdraw > instantExitBuffer（通常需 masternode 占用资金），此处仅验证结构
            expect(await stakingPool.nextWithdrawalBatchId()).to.equal(0);
        });
    });

    describe("KYC", function () {
        it("LSP 应能提交 KYC", async function () {
            await stakingPool.connect(owner).submitKYC("ipfs://kyc-hash");
            expect(await stakingPool.lspKYCSubmitted()).to.equal(true);
        });
    });

    describe("OperatorRegistry", function () {
        it("管理员应能注册 operator", async function () {
            await operatorRegistry.connect(owner).registerOperator(user1.address, 3);
            const info = await operatorRegistry.operators(user1.address);
            expect(info.exists).to.equal(true);
            expect(info.maxMasternodes).to.equal(3);
        });

        it("管理员应能批准 KYC", async function () {
            await operatorRegistry.connect(owner).registerOperator(user1.address, 3);
            await operatorRegistry.connect(owner).approveKYC(user1.address);
            expect(await operatorRegistry.isKYCValid(user1.address)).to.equal(true);
        });

        it("Operator 应能 whitelist coinbase", async function () {
            await operatorRegistry.connect(owner).registerOperator(user1.address, 3);
            await operatorRegistry.connect(owner).approveKYC(user1.address);
            const coinbase = "0x1234567890123456789012345678901234567890";
            await operatorRegistry.connect(user1).whitelistCoinbase(coinbase);
            expect(await operatorRegistry.coinbaseToOperator(coinbase)).to.equal(user1.address);
        });
    });
});
