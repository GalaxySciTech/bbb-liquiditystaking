// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IWithdrawalPayout {
    function payoutWithdrawalTicket(uint256 ticketId) external returns (uint256 paid);
}

/**
 * @title WithdrawalManager
 * @dev FIFO queue of delayed withdrawal ticketIds. Pays NFT holder when mature and buffer allows.
 * Anyone may call processWithdrawalQueue (keeper). Holder may claim when their ticket is at head.
 */
contract WithdrawalManager is ReentrancyGuard {
    address public immutable stakingPool;
    IERC721 public immutable withdrawalNFT;

    uint256[] private _queue;
    uint256 public queueHead;

    event Queued(uint256 indexed ticketId);
    event WithdrawalProcessed(uint256 indexed ticketId, address indexed recipient, uint256 xdcAmount);

    constructor(address _stakingPool, address _withdrawalNFT) {
        require(_stakingPool != address(0) && _withdrawalNFT != address(0), "Invalid address");
        stakingPool = _stakingPool;
        withdrawalNFT = IERC721(_withdrawalNFT);
    }

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only StakingPool");
        _;
    }

    /// @dev Append ticket (FIFO tail). Called when user requests delayed exit.
    function enqueue(uint256 ticketId) external onlyStakingPool {
        _queue.push(ticketId);
        emit Queued(ticketId);
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function getTicketIdAt(uint256 index) external view returns (uint256) {
        require(index < _queue.length, "Out of range");
        return _queue[index];
    }

    function nextTicketId() external view returns (uint256) {
        if (queueHead >= _queue.length) return type(uint256).max;
        return _queue[queueHead];
    }

    /**
     * @dev Fulfill up to `maxItems` from the front of the queue when mature and pool has liquidity.
     */
    function processWithdrawalQueue(uint256 maxItems) external nonReentrant returns (uint256 processed) {
        require(maxItems > 0, "maxItems=0");
        while (processed < maxItems && queueHead < _queue.length) {
            uint256 ticketId = _queue[queueHead];
            address recipient = withdrawalNFT.ownerOf(ticketId);
            uint256 paid = IWithdrawalPayout(stakingPool).payoutWithdrawalTicket(ticketId);
            if (paid == 0) break;
            processed++;
            queueHead++;
            emit WithdrawalProcessed(ticketId, recipient, paid);
        }
    }

    /**
     * @dev Current holder claims when their ticket is at head (same as one step of processWithdrawalQueue).
     */
    function claimIfHead(uint256 ticketId) external nonReentrant returns (uint256 paid) {
        require(queueHead < _queue.length, "Empty queue");
        require(_queue[queueHead] == ticketId, "Not FIFO head");
        require(withdrawalNFT.ownerOf(ticketId) == msg.sender, "Not NFT holder");
        paid = IWithdrawalPayout(stakingPool).payoutWithdrawalTicket(ticketId);
        require(paid > 0, "Not payable");
        queueHead++;
        emit WithdrawalProcessed(ticketId, msg.sender, paid);
    }
}
