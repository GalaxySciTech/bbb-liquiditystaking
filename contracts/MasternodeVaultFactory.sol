// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./MasternodeVault.sol";

/**
 * @title MasternodeVaultFactory
 * @dev EIP-1167 minimal proxy factory for MasternodeVault (OpenZeppelin Clones)
 */
contract MasternodeVaultFactory {
    using Clones for address;

    address public immutable implementation;

    event VaultDeployed(address indexed vault, address indexed stakingPool);

    constructor(address validator) {
        implementation = address(new MasternodeVault(validator));
    }

    /// @dev Deploy a new MasternodeVault clone (EIP-1167)
    /// @return vault Address of the deployed clone
    function deployVault(address stakingPool) external returns (address vault) {
        vault = implementation.clone();
        MasternodeVault(payable(vault)).initialize(stakingPool);
        emit VaultDeployed(vault, stakingPool);
    }
}
