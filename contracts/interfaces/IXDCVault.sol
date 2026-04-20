// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IXDCVault {
    function totalPooledXDC() external view returns (uint256);

    /// @dev Callback when vault reclaims owner principal after resign + delay (0x88 withdraw)
    function receiveVaultPrincipal() external payable;
}
