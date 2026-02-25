// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IXDCVault {
    function totalPooledXDC() external view returns (uint256);
}
