// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IXDCValidator.sol";
import "./OperatorRegistry.sol";

/**
 * @title MasternodeManager
 * @dev Decision engine for masternode selection and resignation
 * Uses OperatorRegistry.selectBestOperator() for capacity-balanced selection
 */
interface IStakingPool {
    function deployAndPropose(address coinbase) external;
    function initiateResign(address coinbase) external;
}

contract MasternodeManager {
    address public stakingPool;
    OperatorRegistry public operatorRegistry;
    IXDCValidator public validator;

    event ProposalAttempted(address indexed coinbase, bool success);
    event ResignationInitiated(address indexed coinbase);

    constructor(address _stakingPool, address _operatorRegistry, address _validator) {
        require(_stakingPool != address(0), "Invalid staking pool");
        require(_operatorRegistry != address(0), "Invalid registry");
        require(_validator != address(0), "Invalid validator");
        stakingPool = _stakingPool;
        operatorRegistry = OperatorRegistry(payable(_operatorRegistry));
        validator = IXDCValidator(_validator);
    }

    /// @dev Select coinbase via OperatorRegistry and propose
    function selectAndPropose() external returns (bool) {
        (, address coinbase) = operatorRegistry.selectBestOperator();
        if (coinbase == address(0)) return false;
        if (validator.isCandidate(coinbase)) return false;

        try IStakingPool(stakingPool).deployAndPropose(coinbase) {
            emit ProposalAttempted(coinbase, true);
            return true;
        } catch {
            emit ProposalAttempted(coinbase, false);
            return false;
        }
    }

    /// @dev Initiate resignation
    function initiateResign(address coinbase) external {
        require(operatorRegistry.coinbaseToVault(coinbase) != address(0), "No vault");
        require(validator.isCandidate(coinbase), "Not a candidate");
        IStakingPool(stakingPool).initiateResign(coinbase);
        emit ResignationInitiated(coinbase);
    }

    function getNextCoinbase() external view returns (address) {
        (, address coinbase) = operatorRegistry.selectBestOperator();
        return coinbase;
    }
}
