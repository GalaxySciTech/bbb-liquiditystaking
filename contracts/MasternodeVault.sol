// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IXDCValidator.sol";

/**
 * @title MasternodeVault
 * @dev EIP-1167 minimal proxy template. Each masternode gets its own vault instance.
 *
 * The vault calls validator.propose(coinbase) with 10M XDC, making *this vault*
 * the masternode owner on 0x88. Epoch rewards from 0x88 are sent directly to the
 * vault's address. StakingPool collects via collectRewards() during harvestRewards().
 *
 * After resign + 30-day unbonding, 0x88 returns the principal to this vault.
 * StakingPool calls collectRewards() again via claimFromValidator().
 *
 * No admin functions. No upgradability. Immutably owned by StakingPool.
 * ~45,000 gas to deploy via EIP-1167 clone.
 */
contract MasternodeVault {
    IXDCValidator private constant VALIDATOR =
        IXDCValidator(0x0000000000000000000000000000000000000088);

    address public stakingPool;
    bool private _initialized;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only StakingPool");
        _;
    }

    /**
     * @dev Initialize the vault. Called exactly once by StakingPool immediately after
     * EIP-1167 clone deployment. Replaces constructor for minimal proxies.
     */
    function initialize(address _stakingPool) external {
        require(!_initialized, "Already initialized");
        require(_stakingPool != address(0), "Invalid StakingPool");
        _initialized = true;
        stakingPool = _stakingPool;
    }

    /**
     * @dev One-time setup: upload operator's KYC hash to 0x88, then propose coinbase.
     * Per spec v1.5 — KYC delegation: vault reuses operator's kycHash from OperatorRegistry.
     * Each vault needs uploadKYC() before propose() to pass onlyKYCWhitelisted on 0x88.
     * @param kycHash Operator's KYC hash (from OperatorRegistry.getKycHash)
     * @param coinbase Masternode coinbase/validator key address
     */
    function setupAndPropose(string calldata kycHash, address coinbase) external payable onlyStakingPool {
        require(bytes(kycHash).length > 0, "KYC hash required");
        VALIDATOR.uploadKYC(kycHash);
        VALIDATOR.propose{value: msg.value}(coinbase);
    }

    /**
     * @dev Legacy propose (no KYC). Use setupAndPropose for new deployments.
     * Kept for backward compatibility when vault already has KYC via ownerToCandidate.
     */
    function propose(address coinbase) external payable onlyStakingPool {
        VALIDATOR.propose{value: msg.value}(coinbase);
    }

    /**
     * @dev Resign coinbase from masternode. Initiates 30-day unbonding on 0x88.
     * After the unbonding period, 0x88 returns the staked principal to this vault.
     * Keeper must call StakingPool.claimFromValidator(vault) after unbonding completes.
     */
    function resign(address coinbase) external onlyStakingPool {
        VALIDATOR.resign(coinbase);
    }

    /**
     * @dev Drain entire vault balance (rewards + returned principal) to StakingPool.
     * Called during harvestRewards() for reward collection and during
     * claimFromValidator() for principal recovery after resign unbonding.
     * @return amount XDC collected and sent to StakingPool
     */
    function collectRewards() external onlyStakingPool returns (uint256) {
        uint256 amount = address(this).balance;
        if (amount > 0) {
            (bool ok, ) = payable(stakingPool).call{value: amount}("");
            require(ok, "Transfer failed");
        }
        return amount;
    }

    /**
     * @dev Accepts XDC from 0x88: epoch rewards during active phase and
     * returned principal after resign + 30-day unbonding.
     */
    receive() external payable {}
}
