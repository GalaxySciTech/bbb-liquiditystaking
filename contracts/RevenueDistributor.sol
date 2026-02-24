// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RevenueDistributor
 * @dev Pull-based operator commission accumulation and distribution.
 *
 * StakingPool deposits operator commissions here after each harvest via depositBatch().
 * Operators (identified by their adminAddress) claim at any time via claimCommission().
 *
 * Per-vault accounting enables per-coinbase earnings reporting for operators.
 * KYC-expired operators cannot earn new commissions (handled in StakingPool),
 * but may still claim any previously earned commission.
 *
 * Revenue split (configured in StakingPool):
 *   - bXDC holders: e.g. 90% — added to totalPooledXDC, raises exchange rate
 *   - Operators:    e.g. 7%  — deposited here, claimed by operator adminAddress
 *   - Treasury:     e.g. 3%  — sent directly to treasury address by StakingPool
 */
contract RevenueDistributor is AccessControl, ReentrancyGuard {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");

    /// @dev Unclaimed XDC per operator admin address
    mapping(address => uint256) public pendingCommission;
    /// @dev Lifetime claimed XDC per operator admin address
    mapping(address => uint256) public totalDistributed;
    /// @dev Lifetime commission earned per coinbase (per-node reporting)
    mapping(address => uint256) public perCoinbaseEarned;

    event CommissionDeposited(address indexed operator, address indexed coinbase, uint256 amount);
    event CommissionClaimed(address indexed operator, uint256 amount, uint256 timestamp);
    event StakingPoolGranted(address indexed pool);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @dev Grant StakingPool role. Called by admin after StakingPool is deployed.
     */
    function setStakingPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pool != address(0), "Invalid address");
        _grantRole(STAKING_POOL_ROLE, pool);
        emit StakingPoolGranted(pool);
    }

    /**
     * @dev Batch deposit commissions from a harvest. Called by StakingPool after
     * per-vault collection. msg.value must equal sum of all amounts.
     *
     * @param operatorAdmins Array of operator admin addresses to credit
     * @param coinbases      Array of coinbase addresses (for per-node reporting)
     * @param amounts        Array of XDC commission amounts per vault
     */
    function depositBatch(
        address[] calldata operatorAdmins,
        address[] calldata coinbases,
        uint256[] calldata amounts
    ) external payable onlyRole(STAKING_POOL_ROLE) {
        require(
            operatorAdmins.length == coinbases.length &&
                coinbases.length == amounts.length,
            "Length mismatch"
        );

        uint256 totalExpected = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalExpected += amounts[i];
        }
        require(msg.value == totalExpected, "Value mismatch");

        for (uint256 i = 0; i < operatorAdmins.length; i++) {
            if (amounts[i] == 0) continue;
            pendingCommission[operatorAdmins[i]] += amounts[i];
            perCoinbaseEarned[coinbases[i]] += amounts[i];
            emit CommissionDeposited(operatorAdmins[i], coinbases[i], amounts[i]);
        }
    }

    /**
     * @dev Operator pulls all pending commission to their address.
     * KYC-expired operators may still claim previously earned commission.
     */
    function claimCommission() external nonReentrant {
        uint256 amount = pendingCommission[msg.sender];
        require(amount > 0, "Nothing to claim");

        pendingCommission[msg.sender] = 0;
        totalDistributed[msg.sender] += amount;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");

        emit CommissionClaimed(msg.sender, amount, block.timestamp);
    }

    /// @dev Accepts XDC from StakingPool via depositBatch
    receive() external payable {}
}
