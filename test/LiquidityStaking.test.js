const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("XDC Liquidity Staking", function () {
    let stakingPool;
    let bxdc;
    let wxdc;
    let withdrawalNFT;
    let operatorRegistry;
    let mockValidator;
    let owner;
    let user1;
    let user2;
    let user3;

    beforeEach(async function () {
        [owner, user1, user2, user3] = await ethers.getSigners();

        const MockXDCValidator = await ethers.getContractFactory("MockXDCValidator");
        mockValidator = await MockXDCValidator.deploy();
        await mockValidator.deployed();

        const WXDC = await ethers.getContractFactory("WXDC");
        wxdc = await WXDC.deploy();
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

        it("大额 withdraw 超出 buffer 时应铸造 NFT", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            await stakingPool.connect(user1).withdraw(ethers.utils.parseEther("20")); // user1=80 bXDC
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("1") }); // user1=81 bXDC
            await stakingPool.setInstantExitBufferForTesting(ethers.utils.parseEther("80")); // buffer=80, 仅 Hardhat
            const batchIdBefore = await stakingPool.nextWithdrawalBatchId();
            await stakingPool.connect(user1).withdraw(ethers.utils.parseEther("81")); // 81 > 80 -> NFT 路径
            const batchId = await stakingPool.nextWithdrawalBatchId();
            expect(batchId).to.equal(batchIdBefore + 1);
            expect(await withdrawalNFT.balanceOf(user1.address, batchId - 1)).to.equal(
                ethers.utils.parseEther("81")
            );
            const batch = await stakingPool.withdrawalBatches(batchId - 1);
            expect(batch.xdcAmount).to.equal(ethers.utils.parseEther("81"));
            expect(batch.redeemed).to.equal(false);
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

        it("管理员应能批准 KYC（含 kycHash 存储）", async function () {
            await operatorRegistry.connect(owner).registerOperator(user1.address, 3);
            await operatorRegistry.connect(owner).approveKYC(user1.address, "ipfs://operator-kyc-hash");
            expect(await operatorRegistry.isKYCValid(user1.address)).to.equal(true);
            expect(await operatorRegistry.getKycHash(user1.address)).to.equal("ipfs://operator-kyc-hash");
        });

        it("Operator 应能 whitelist coinbase", async function () {
            await operatorRegistry.connect(owner).registerOperator(user1.address, 3);
            await operatorRegistry.connect(owner).approveKYC(user1.address, "ipfs://operator-kyc-hash");
            const coinbase = "0x1234567890123456789012345678901234567890";
            await operatorRegistry.connect(user1).whitelistCoinbase(coinbase);
            expect(await operatorRegistry.coinbaseToOperator(coinbase)).to.equal(user1.address);
        });
    });

    describe("deposit (WXDC)", function () {
        it("应允许用户通过 WXDC deposit 获得 bXDC", async function () {
            await stakingPool.connect(owner).stake({ value: ethers.utils.parseEther("1") });
            const amount = ethers.utils.parseEther("100");
            await wxdc.connect(user1).deposit({ value: amount });
            await wxdc.connect(user1).approve(stakingPool.address, amount);

            const shares = await stakingPool.connect(user1).callStatic.deposit(amount, user1.address);
            await stakingPool.connect(user1).deposit(amount, user1.address);

            expect(await bxdc.balanceOf(user1.address)).to.equal(shares);
            expect(await stakingPool.totalPooledXDC()).to.equal(ethers.utils.parseEther("101"));
        });

        it("deposit 应拒绝低于最小数量", async function () {
            const smallAmount = ethers.utils.parseEther("0.5");
            await wxdc.connect(user1).deposit({ value: smallAmount });
            await wxdc.connect(user1).approve(stakingPool.address, smallAmount);

            await expect(
                stakingPool.connect(user1).deposit(smallAmount, user1.address)
            ).to.be.revertedWith("Amount below minimum");
        });

        it("deposit 可指定 receiver 为不同地址", async function () {
            await stakingPool.connect(owner).stake({ value: ethers.utils.parseEther("1") });
            const amount = ethers.utils.parseEther("50");
            await wxdc.connect(user1).deposit({ value: amount });
            await wxdc.connect(user1).approve(stakingPool.address, amount);

            await stakingPool.connect(user1).deposit(amount, user2.address);
            expect(await bxdc.balanceOf(user2.address)).to.be.gt(0);
            expect(await bxdc.balanceOf(user1.address)).to.equal(0);
        });
    });

    describe("mint (WXDC)", function () {
        it("应允许用户通过 mint 指定 bXDC 数量", async function () {
            await stakingPool.connect(owner).stake({ value: ethers.utils.parseEther("100") });
            const shares = ethers.utils.parseEther("80");
            const assetsNeeded = await stakingPool.getXDCBybXDC(shares);
            await wxdc.connect(user1).deposit({ value: assetsNeeded });
            await wxdc.connect(user1).approve(stakingPool.address, assetsNeeded);

            await stakingPool.connect(user1).mint(shares, user1.address);
            expect(await bxdc.balanceOf(user1.address)).to.equal(shares);
        });
    });

    describe("redeem (即时赎回)", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });

        it("应允许通过 redeem 即时赎回 shares", async function () {
            const shares = ethers.utils.parseEther("20");
            const balanceBefore = await ethers.provider.getBalance(user1.address);

            const tx = await stakingPool.connect(user1).redeem(shares, user1.address, user1.address);
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);
            const balanceAfter = await ethers.provider.getBalance(user1.address);

            expect(balanceAfter).to.equal(balanceBefore.add(ethers.utils.parseEther("20")).sub(gasUsed));
            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("80"));
        });

        it("redeem 可指定 receiver 为不同地址", async function () {
            const shares = ethers.utils.parseEther("10");
            const balanceBefore = await ethers.provider.getBalance(user2.address);

            await stakingPool.connect(user1).redeem(shares, user2.address, user1.address);

            expect(await ethers.provider.getBalance(user2.address)).to.equal(
                balanceBefore.add(ethers.utils.parseEther("10"))
            );
            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("90"));
        });

        it("redeem 应拒绝低于 minWithdrawAmount", async function () {
            const tinyShares = ethers.utils.parseEther("0.05");
            await expect(
                stakingPool.connect(user1).redeem(tinyShares, user1.address, user1.address)
            ).to.be.revertedWith("Below min withdrawal");
        });
    });

    describe("管理员功能", function () {
        it("setTreasury 应仅 LSP admin 可调用", async function () {
            await stakingPool.connect(owner).setTreasury(user2.address);
            expect(await stakingPool.treasury()).to.equal(user2.address);

            await expect(
                stakingPool.connect(user1).setTreasury(user3.address)
            ).to.be.reverted;
        });

        it("setTreasury 应拒绝零地址", async function () {
            await expect(
                stakingPool.connect(owner).setTreasury(ethers.constants.AddressZero)
            ).to.be.revertedWith("Invalid treasury");
        });

        it("setRevenueSplit 必须总和为 100", async function () {
            await stakingPool.connect(owner).setRevenueSplit(80, 15, 5);
            expect(await stakingPool.bxdcShare()).to.equal(80);
            expect(await stakingPool.operatorShare()).to.equal(15);
            expect(await stakingPool.treasuryShare()).to.equal(5);

            await expect(
                stakingPool.connect(owner).setRevenueSplit(80, 15, 10)
            ).to.be.revertedWith("Must sum to 100");
        });

        it("addToInstantExitBuffer 应仅 LSP admin 可调用", async function () {
            await expect(
                stakingPool.connect(user1).addToInstantExitBuffer({ value: ethers.utils.parseEther("10") })
            ).to.be.reverted;
        });

        it("submitKYC 应仅 LSP admin 可调用", async function () {
            await expect(
                stakingPool.connect(user1).submitKYC("ipfs://hash")
            ).to.be.reverted;
        });
    });

    describe("视图函数", function () {
        it("getExchangeRate 质押后应为 1:1", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            expect(await stakingPool.getExchangeRate()).to.equal(ethers.utils.parseEther("1"));
        });

        it("getbXDCByXDC 和 getXDCBybXDC 应正确转换", async function () {
            const xdcAmount = ethers.utils.parseEther("100");
            const shares = await stakingPool.getbXDCByXDC(xdcAmount);
            const backToXdc = await stakingPool.getXDCBybXDC(shares);
            expect(backToXdc).to.equal(xdcAmount);
        });

        it("getAvailableBalance 应反映合约余额", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("50") });
            expect(await stakingPool.getAvailableBalance()).to.equal(ethers.utils.parseEther("50"));
        });

        it("getBufferHealthPercent 无质押时应为 100", async function () {
            expect(await stakingPool.getBufferHealthPercent()).to.equal(100);
        });
    });

    describe("withdraw 边界", function () {
        it("应拒绝 withdraw 低于 minWithdrawAmount", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            const tinyShares = ethers.utils.parseEther("0.05");
            await expect(
                stakingPool.connect(user1).withdraw(tinyShares)
            ).to.be.revertedWith("Below min withdrawal");
        });

        it("应拒绝 withdraw 超过余额", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            await expect(
                stakingPool.connect(user1).withdraw(ethers.utils.parseEther("150"))
            ).to.be.revertedWith("Insufficient bXDC");
        });

        it("应拒绝 withdraw 零数量", async function () {
            await expect(
                stakingPool.connect(user1).withdraw(0)
            ).to.be.revertedWith("Amount must be > 0");
        });
    });


    describe("Revenue split 默认值", function () {
        it("初始应为 90/7/3", async function () {
            expect(await stakingPool.bxdcShare()).to.equal(90);
            expect(await stakingPool.operatorShare()).to.equal(7);
            expect(await stakingPool.treasuryShare()).to.equal(3);
        });
    });
});
