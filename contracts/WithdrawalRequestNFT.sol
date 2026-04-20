// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title WithdrawalRequestNFT
 * @dev ERC-721 claim for delayed exits (spec v1.5). One token per ticketId; transferable.
 */
contract WithdrawalRequestNFT is ERC721, AccessControl {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");

    address public stakingPool;

    constructor(address admin_) ERC721("XDC Withdrawal Request", "wXDC-EXIT") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function setStakingPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "Invalid address");
        address old = stakingPool;
        stakingPool = _pool;
        if (old != address(0)) _revokeRole(STAKING_POOL_ROLE, old);
        _grantRole(STAKING_POOL_ROLE, _pool);
        emit StakingPoolSet(_pool);
    }

    event StakingPoolSet(address indexed stakingPool);

    function mint(address to, uint256 tokenId) external onlyRole(STAKING_POOL_ROLE) {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyRole(STAKING_POOL_ROLE) {
        _burn(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "ipfs://withdrawal-request";
    }
}
