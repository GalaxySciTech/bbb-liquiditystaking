// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Optional view on 0x88 for resign principal keys (mock implements; mainnet may use adapter)
interface IValidatorResignView {
    function getOwnerWithdrawal(address owner)
        external
        view
        returns (
            uint256 withdrawBlockNumber,
            uint256 withdrawIndex,
            uint256 amount,
            bool ready
        );
}
