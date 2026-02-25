// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "./interfaces/IXDCVault.sol";

/**
 * @title bXDC
 * @dev ERC-4626 tokenized vault — liquid staking receipt token for XDC.
 * Asset: WXDC (wrapped XDC). Shares: bXDC. Exchange rate grows as staking rewards accrue.
 * Share-based (non-rebasing): 1 bXDC > 1 XDC over time, fully DeFi-composable.
 */
contract bXDC is ERC4626, AccessControl {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool can call");
        _;
    }

    constructor(
        IERC20 asset_,
        address admin_
    ) ERC4626(asset_) ERC20("Staked XDC", "bXDC") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function setStakingPool(
        address _stakingPool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingPool != address(0), "Invalid address");
        address old = stakingPool;
        stakingPool = _stakingPool;
        if (old != address(0)) _revokeRole(STAKING_POOL_ROLE, old);
        _grantRole(STAKING_POOL_ROLE, _stakingPool);
        emit StakingPoolSet(_stakingPool);
    }

    event StakingPoolSet(address indexed stakingPool);

    /// @dev totalAssets proxies to StakingPool.totalPooledXDC for share conversions
    function totalAssets() public view virtual override returns (uint256) {
        if (stakingPool == address(0))
            return IERC20(asset()).balanceOf(address(this));
        return IXDCVault(stakingPool).totalPooledXDC();
    }

    function mint(address to, uint256 amount) external onlyStakingPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyStakingPool {
        _burn(from, amount);
    }

    function deposit(uint256, address) public pure override returns (uint256) {
        revert("Use XDCLiquidityStaking.deposit or stake");
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert("Use XDCLiquidityStaking.mint or stake");
    }
}
