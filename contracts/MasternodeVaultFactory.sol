// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MasternodeVault.sol";

/**
 * @title MasternodeVaultFactory
 * @dev EIP-1167 minimal proxy factory for MasternodeVault
 * ~45,000 gas per clone deployment
 */
contract MasternodeVaultFactory {
    address public immutable implementation;

    event VaultDeployed(address indexed vault, address indexed stakingPool);

    constructor() {
        implementation = address(new MasternodeVault());
    }

    /// @dev Deploy a new MasternodeVault clone (EIP-1167)
    /// @return vault Address of the deployed clone
    function deployVault(address stakingPool) external returns (address vault) {
        bytes20 target = bytes20(implementation);
        // EIP-1167: 363d3d373d3d3d363d73 + addr + 5af43d82803e903d91602b57fd5bf3
        bytes memory bytecode = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            target,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            vault := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(vault != address(0), "Clone failed");
        MasternodeVault(payable(vault)).initialize(stakingPool);
        emit VaultDeployed(vault, stakingPool);
    }
}
