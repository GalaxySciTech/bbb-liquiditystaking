// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

/**
 * @title WithdrawalRequestNFT
 * @dev ERC-1155 NFT representing a withdrawal claim during unbonding period.
 * Token ID = batchId. Amount = XDC owed. Transferable — enables secondary market for claims.
 */
contract WithdrawalRequestNFT is ERC1155Supply, AccessControl {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool");
        _;
    }

    constructor(address admin_) ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155, AccessControl) returns (bool) {
        return
            ERC1155.supportsInterface(interfaceId) ||
            AccessControl.supportsInterface(interfaceId);
    }

    function setStakingPool(
        address _pool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "Invalid address");
        address old = stakingPool;
        stakingPool = _pool;
        if (old != address(0)) _revokeRole(STAKING_POOL_ROLE, old);
        _grantRole(STAKING_POOL_ROLE, _pool);
        emit StakingPoolSet(_pool);
    }

    event StakingPoolSet(address indexed stakingPool);

    function mint(
        address to,
        uint256 id,
        uint256 amount
    ) external onlyStakingPool {
        _mint(to, id, amount, "");
    }

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) external onlyStakingPool {
        _burn(from, id, amount);
    }

    function uri(uint256) public pure override returns (string memory) {
        return "ipfs://withdrawal-request";
    }
}
