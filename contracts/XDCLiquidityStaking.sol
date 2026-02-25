// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IXDCValidator.sol";
import "./WXDC.sol";
import "./MasternodeVault.sol";
import "./MasternodeVaultFactory.sol";
import "./OperatorRegistry.sol";
import "./RevenueDistributor.sol";
import "./MasternodeManager.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./bXDC.sol";
import "./WithdrawalRequestNFT.sol";

/**
 * @title XDCLiquidityStaking
 * @dev XDC Liquid Staking Protocol v1.3 - Per-vault reward isolation, OperatorRegistry, Revenue split
 * MasternodeVault per masternode. Harvest from each vault. Three-way revenue split.
 */
contract XDCLiquidityStaking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant LSP_ADMIN_ROLE = keccak256("LSP_ADMIN_ROLE");
    bytes32 public constant MASTERNODE_MANAGER_ROLE = keccak256("MASTERNODE_MANAGER_ROLE");

    bXDC public bxdcToken;
    WXDC public wxdc;
    WithdrawalRequestNFT public withdrawalNFT;
    MasternodeVaultFactory public vaultFactory;
    OperatorRegistry public operatorRegistry;
    RevenueDistributor public revenueDistributor;
    MasternodeManager public masternodeManager;
    IXDCValidator public validator;

    uint256 public constant DEFAULT_MASTERNODE_CAP = 10_000_000 ether;
    uint256 public masternodeStakeAmount = 10_000_000 ether;
    uint256 public withdrawDelayBlocks = 1_296_000;

    uint256 public totalPooledXDC;
    uint256 public totalStakedInMasternodes;
    uint256 public totalInUnbonding;

    uint256 public nextWithdrawalBatchId;
    uint256 public instantExitBuffer;

    address[] public activeVaults;
    mapping(address => address) public vaultToOperator;
    mapping(address => address) public vaultToCoinbase;
    mapping(address => address) public coinbaseToVault;

    mapping(uint256 => WithdrawalBatch) public withdrawalBatches;
    mapping(address => uint256[]) public userWithdrawalBatches;

    struct WithdrawalBatch {
        uint256 xdcAmount;
        uint256 unlockBlock;
        bool redeemed;
    }

    uint256 public minStakeAmount = 1 ether;
    uint256 public minWithdrawAmount = 0.1 ether;
    uint256 public maxWithdrawablePercentage = 80;

    uint256 public minBufferPercent = 5;
    uint256 public criticalBufferPercent = 2;

    uint256 public bxdcShare = 90;
    uint256 public operatorShare = 7;
    uint256 public treasuryShare = 3;
    address public treasury;

    bool public lspKYCSubmitted;

    uint256 public timelockDelay = 1 days;
    uint256 public emergencyTimelockDelay = 1 hours;
    mapping(bytes32 => PendingChange) public pendingChanges;
    uint256 public pendingPauseAt;
    uint256 public pendingUnpauseAt;

    struct PendingChange {
        uint256 value;
        uint256 executableAt;
        bool isAddress;
        address addressValue;
    }

    mapping(address => uint256) public pendingResignAmount;

    event Staked(address indexed user, uint256 xdcAmount, uint256 bxdcAmount, uint256 exchangeRate);
    event WithdrawalNFTMinted(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event WithdrawalRedeemed(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event MasternodeProposed(address indexed vault, address indexed coinbase, address indexed operator);
    event MasternodeResigned(address indexed vault, address indexed coinbase);
    event RewardsHarvested(uint256 total, uint256 bxdcShare, uint256 operatorShare, uint256 treasuryShare);
    event LSPKYCSubmitted(string kycHash);
    event InstantExit(address indexed user, uint256 xdcAmount);
    event InstantExitBufferToppedUp(uint256 amount);
    event VaultCollected(address indexed vault, address indexed coinbase, address indexed operator, uint256 amount);
    event CommissionAccrued(address indexed operator, uint256 amount);
    event CommissionRedirected(address indexed operator, uint256 amount, uint256 bxdcPortion, uint256 treasuryPortion);

    constructor(address _validator, address _wxdc, address _lspAdmin, address _treasury) {
        require(_validator != address(0), "Invalid validator");
        require(_wxdc != address(0), "Invalid WXDC");
        require(_lspAdmin != address(0), "Invalid LSP admin");
        require(_treasury != address(0), "Invalid treasury");
        validator = IXDCValidator(_validator);
        wxdc = WXDC(payable(_wxdc));
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, _lspAdmin);
        _grantRole(LSP_ADMIN_ROLE, _lspAdmin);

        bxdcToken = new bXDC(IERC20(_wxdc), address(this));
        bxdcToken.setStakingPool(address(this));
        withdrawalNFT = new WithdrawalRequestNFT(address(this));
        withdrawalNFT.setStakingPool(address(this));
        vaultFactory = new MasternodeVaultFactory();
        operatorRegistry = new OperatorRegistry(address(this));
        operatorRegistry.setStakingPool(address(this));
        operatorRegistry.grantRole(operatorRegistry.OPERATOR_ADMIN_ROLE(), _lspAdmin);
        revenueDistributor = new RevenueDistributor(address(this));
        revenueDistributor.setStakingPool(address(this));
        masternodeManager = new MasternodeManager(address(this), address(operatorRegistry), _validator);
        _grantRole(MASTERNODE_MANAGER_ROLE, address(masternodeManager));
    }

    function getBufferHealthPercent() public view returns (uint256) {
        if (totalPooledXDC == 0) return 100;
        return (instantExitBuffer * 100) / totalPooledXDC;
    }

    function getExchangeRate() public view returns (uint256) {
        uint256 supply = bxdcToken.totalSupply();
        if (supply == 0) return 1e18;
        return (totalPooledXDC * 1e18) / supply;
    }

    function getbXDCByXDC(uint256 xdcAmount) public view returns (uint256) {
        return bxdcToken.convertToShares(xdcAmount);
    }

    function getXDCBybXDC(uint256 bxdcAmount) public view returns (uint256) {
        return bxdcToken.convertToAssets(bxdcAmount);
    }

    function getAvailableBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function submitKYC(string calldata kycHash) external onlyRole(LSP_ADMIN_ROLE) {
        validator.uploadKYC(kycHash);
        lspKYCSubmitted = true;
        emit LSPKYCSubmitted(kycHash);
    }

    function setTreasury(address _treasury) external onlyRole(LSP_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    function setRevenueSplit(uint256 _bxdc, uint256 _operator, uint256 _treasury) external onlyRole(LSP_ADMIN_ROLE) {
        require(_bxdc + _operator + _treasury == 100, "Must sum to 100");
        bxdcShare = _bxdc;
        operatorShare = _operator;
        treasuryShare = _treasury;
    }

    function setMasternodeStakeAmount(uint256 _amount) external onlyRole(LSP_ADMIN_ROLE) {
        require(_amount >= 1 ether, "Amount too low");
        masternodeStakeAmount = _amount;
    }

    function addToInstantExitBuffer() external payable onlyRole(LSP_ADMIN_ROLE) {
        require(msg.value > 0, "Amount must be > 0");
        instantExitBuffer += msg.value;
        emit InstantExitBufferToppedUp(msg.value);
    }

    function deployAndPropose(address coinbase) external onlyRole(MASTERNODE_MANAGER_ROLE) nonReentrant whenNotPaused {
        require(lspKYCSubmitted, "LSP must submit KYC first");
        require(operatorRegistry.coinbaseToVault(coinbase) == address(0), "Already proposed");
        require(!validator.isCandidate(coinbase), "Already candidate");
        require(address(this).balance >= masternodeStakeAmount, "Insufficient balance");
        require(instantExitBuffer >= masternodeStakeAmount, "Buffer too low");

        address operator = operatorRegistry.coinbaseToOperator(coinbase);
        require(operator != address(0), "Coinbase not registered");
        require(operatorRegistry.isKYCValid(operator), "Operator KYC invalid");

        address vault = vaultFactory.deployVault(address(this));
        MasternodeVault(payable(vault)).propose{value: masternodeStakeAmount}(coinbase);

        activeVaults.push(vault);
        vaultToOperator[vault] = operator;
        vaultToCoinbase[vault] = coinbase;
        coinbaseToVault[coinbase] = vault;
        totalStakedInMasternodes += masternodeStakeAmount;
        instantExitBuffer -= masternodeStakeAmount;

        operatorRegistry.linkVault(coinbase, vault);
        operatorRegistry.recordProposal(coinbase);
        emit MasternodeProposed(vault, coinbase, operator);
    }

    function initiateResign(address coinbase) external onlyRole(MASTERNODE_MANAGER_ROLE) nonReentrant {
        address vault = coinbaseToVault[coinbase];
        require(vault != address(0), "No vault");
        require(validator.isCandidate(coinbase), "Not candidate");

        MasternodeVault(payable(vault)).resign(coinbase);
        pendingResignAmount[vault] = masternodeStakeAmount;
        emit MasternodeResigned(vault, coinbase);
    }

    function claimFromValidator(address vault) external nonReentrant {
        require(pendingResignAmount[vault] > 0, "No pending resign");
        uint256 collected = MasternodeVault(payable(vault)).collectRewards();
        require(collected > 0, "Nothing to collect");
        uint256 toDeduct = collected > pendingResignAmount[vault] ? pendingResignAmount[vault] : collected;
        totalStakedInMasternodes -= toDeduct;
        pendingResignAmount[vault] -= toDeduct;
        instantExitBuffer += collected;

        address coinbase = vaultToCoinbase[vault];
        address operator = vaultToOperator[vault];
        if (collected >= masternodeStakeAmount) {
            _removeVault(vault, coinbase, operator);
            operatorRegistry.recordResignation(coinbase);
        }
    }

    function _removeVault(address vault, address coinbase, address /*operator*/) internal {
        for (uint256 i = 0; i < activeVaults.length; i++) {
            if (activeVaults[i] == vault) {
                activeVaults[i] = activeVaults[activeVaults.length - 1];
                activeVaults.pop();
                break;
            }
        }
        delete vaultToOperator[vault];
        delete vaultToCoinbase[vault];
        delete coinbaseToVault[coinbase];
    }

    function harvestRewards() external nonReentrant {
        address[] memory earningVaults = new address[](activeVaults.length);
        uint256 earningCount = 0;
        uint256 totalCollected = 0;

        for (uint256 i = 0; i < activeVaults.length; i++) {
            address vault = activeVaults[i];
            if (pendingResignAmount[vault] > 0) continue;
            uint256 amt = MasternodeVault(payable(vault)).collectRewards();
            if (amt > 0) {
                totalCollected += amt;
                earningVaults[earningCount] = vault;
                earningCount++;
                address coinbase = vaultToCoinbase[vault];
                address operator = vaultToOperator[vault];
                emit VaultCollected(vault, coinbase, operator, amt);
            }
        }

        if (totalCollected == 0) return;

        uint256 bxdcPortion = (totalCollected * bxdcShare) / 100;
        uint256 operatorPortion = (totalCollected * operatorShare) / 100;
        uint256 treasuryPortion = (totalCollected * treasuryShare) / 100;

        totalPooledXDC += bxdcPortion;

        if (earningCount > 0) {
            uint256 perVaultCommission = operatorPortion / earningCount;
            address[] memory operatorAdmins = new address[](earningCount);
            address[] memory coinbases = new address[](earningCount);
            uint256[] memory amounts = new uint256[](earningCount);
            uint256 validCount = 0;
            uint256 totalToDeposit = 0;

            for (uint256 i = 0; i < earningCount; i++) {
                address vault = earningVaults[i];
                address operator = vaultToOperator[vault];
                address coinbase = vaultToCoinbase[vault];
                if (operatorRegistry.isKYCValid(operator)) {
                    operatorAdmins[validCount] = operator;
                    coinbases[validCount] = coinbase;
                    amounts[validCount] = perVaultCommission;
                    validCount++;
                    totalToDeposit += perVaultCommission;
                    emit CommissionAccrued(operator, perVaultCommission);
                } else {
                    uint256 half = perVaultCommission / 2;
                    totalPooledXDC += half;
                    (bool ok, ) = payable(treasury).call{value: half}("");
                    require(ok, "Treasury transfer failed");
                    emit CommissionRedirected(operator, perVaultCommission, half, half);
                }
            }

            if (validCount > 0 && totalToDeposit > 0) {
                address[] memory ops = new address[](validCount);
                address[] memory cbs = new address[](validCount);
                uint256[] memory amts = new uint256[](validCount);
                for (uint256 i = 0; i < validCount; i++) {
                    ops[i] = operatorAdmins[i];
                    cbs[i] = coinbases[i];
                    amts[i] = amounts[i];
                }
                revenueDistributor.depositBatch{value: totalToDeposit}(ops, cbs, amts);
            }
        }

        if (treasuryPortion > 0) {
            (bool ok, ) = payable(treasury).call{value: treasuryPortion}("");
            require(ok, "Treasury transfer failed");
        }

        emit RewardsHarvested(totalCollected, bxdcPortion, operatorPortion, treasuryPortion);
    }

    function stake() external payable nonReentrant whenNotPaused {
        require(msg.value >= minStakeAmount, "Amount below minimum");
        uint256 shares = bxdcToken.previewDeposit(msg.value);
        require(shares > 0, "Invalid bXDC amount");

        totalPooledXDC += msg.value;
        instantExitBuffer += msg.value;
        bxdcToken.mint(msg.sender, shares);

        emit Staked(msg.sender, msg.value, shares, getExchangeRate());
        _tryAutoDeployMasternode();
    }

    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        instantExitBuffer += assets;
        uint256 shares = bxdcToken.previewDeposit(assets);
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        _tryAutoDeployMasternode();
        return shares;
    }

    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = bxdcToken.previewMint(shares);
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        instantExitBuffer += assets;
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        _tryAutoDeployMasternode();
        return assets;
    }

    function _tryAutoDeployMasternode() internal {
        if (!lspKYCSubmitted || address(this).balance < masternodeStakeAmount) return;
        if (getBufferHealthPercent() < minBufferPercent) return;
        masternodeManager.selectAndPropose();
    }

    function withdraw(uint256 bxdcAmount) external nonReentrant whenNotPaused {
        require(bxdcAmount > 0, "Amount must be > 0");
        require(bxdcToken.balanceOf(msg.sender) >= bxdcAmount, "Insufficient bXDC");
        uint256 xdcAmount = bxdcToken.convertToAssets(bxdcAmount);
        require(xdcAmount >= minWithdrawAmount, "Below min withdrawal");

        bxdcToken.burn(msg.sender, bxdcAmount);
        totalPooledXDC -= xdcAmount;

        if (xdcAmount <= instantExitBuffer) {
            instantExitBuffer -= xdcAmount;
            (bool ok, ) = payable(msg.sender).call{value: xdcAmount}("");
            require(ok, "Transfer failed");
            emit InstantExit(msg.sender, xdcAmount);
        } else {
            uint256 batchId = nextWithdrawalBatchId++;
            uint256 unlockBlock = block.number + withdrawDelayBlocks;
            withdrawalBatches[batchId] = WithdrawalBatch({
                xdcAmount: xdcAmount,
                unlockBlock: unlockBlock,
                redeemed: false
            });
            totalInUnbonding += xdcAmount;
            userWithdrawalBatches[msg.sender].push(batchId);
            withdrawalNFT.mint(msg.sender, batchId, xdcAmount);
            emit WithdrawalNFTMinted(batchId, msg.sender, xdcAmount);
        }
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = bxdcToken.convertToAssets(shares);
        require(assets <= instantExitBuffer, "Use withdraw for delayed redemption");
        require(assets >= minWithdrawAmount, "Below min withdrawal");

        if (msg.sender != owner) {
            IERC20(address(bxdcToken)).safeTransferFrom(owner, address(this), shares);
            bxdcToken.burn(address(this), shares);
        } else {
            bxdcToken.burn(owner, shares);
        }
        totalPooledXDC -= assets;
        instantExitBuffer -= assets;

        (bool ok, ) = payable(receiver).call{value: assets}("");
        require(ok, "Transfer failed");
        emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
        emit InstantExit(receiver, assets);
        return assets;
    }

    function redeemWithdrawal(uint256 batchId) external nonReentrant {
        WithdrawalBatch storage batch = withdrawalBatches[batchId];
        require(!batch.redeemed, "Already redeemed");
        require(block.number >= batch.unlockBlock, "Still unbonding");
        uint256 amount = withdrawalNFT.balanceOf(msg.sender, batchId);
        require(amount >= batch.xdcAmount, "Insufficient NFT balance");

        batch.redeemed = true;
        totalInUnbonding -= batch.xdcAmount;
        withdrawalNFT.burn(msg.sender, batchId, batch.xdcAmount);

        (bool ok, ) = payable(msg.sender).call{value: batch.xdcAmount}("");
        require(ok, "Transfer failed");
        emit WithdrawalRedeemed(batchId, msg.sender, batch.xdcAmount);
    }

    receive() external payable {
        for (uint256 i = 0; i < activeVaults.length; i++) {
            address vault = activeVaults[i];
            if (msg.sender == vault && pendingResignAmount[vault] > 0) {
                uint256 amount = msg.value;
                uint256 toDeduct = amount > pendingResignAmount[vault] ? pendingResignAmount[vault] : amount;
                totalStakedInMasternodes -= toDeduct;
                pendingResignAmount[vault] -= toDeduct;
                break;
            }
        }
    }
}
