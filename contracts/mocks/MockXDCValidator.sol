// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockXDCValidator
 * @dev Mirrors mainnet XDCValidator (0x88) withdrawsState / resign / withdraw per verified source on XDCScan.
 */
contract MockXDCValidator {
    uint256 public minCandidateCap = 10_000_000 ether;
    uint256 public minVoterCap = 1 ether;

    function setMinCandidateCap(uint256 _cap) external {
        minCandidateCap = _cap;
    }

    uint256 public candidateWithdrawDelay = 1_296_000;
    uint256 public voterWithdrawDelay = 1_296_000;

    function setCandidateWithdrawDelay(uint256 d) external {
        candidateWithdrawDelay = d;
    }

    mapping(address => bool) public isCandidate;
    mapping(address => address) public candidateOwner;
    mapping(address => uint256) public candidateCap;
    mapping(address => mapping(address => uint256)) public voterCap;

    mapping(address => uint256) public kycHashCount;

    struct WithdrawState {
        mapping(uint256 => uint256) caps;
        uint256[] blockNumbers;
    }

    mapping(address => WithdrawState) private _withdraws;

    function uploadKYC(string calldata) external {
        kycHashCount[msg.sender]++;
    }

    function getHashCount(address addr) external view returns (uint256) {
        return kycHashCount[addr];
    }

    function propose(address _candidate) external payable {
        require(msg.value >= minCandidateCap, "Below min cap");
        require(!isCandidate[_candidate], "Already candidate");
        isCandidate[_candidate] = true;
        candidateOwner[_candidate] = msg.sender;
        candidateCap[_candidate] = msg.value;
        voterCap[_candidate][msg.sender] = msg.value;
    }

    function vote(address _candidate) external payable {
        require(msg.value >= minVoterCap, "Below min voter cap");
        require(isCandidate[_candidate], "Not candidate");
        candidateCap[_candidate] += msg.value;
        voterCap[_candidate][msg.sender] += msg.value;
    }

    function unvote(address _candidate, uint256 _cap) external {}

    function resign(address _candidate) external {
        require(isCandidate[_candidate], "Not candidate");
        require(candidateOwner[_candidate] == msg.sender, "Not owner");

        uint256 cap = voterCap[_candidate][msg.sender];
        require(cap > 0, "No owner stake");

        isCandidate[_candidate] = false;
        candidateCap[_candidate] -= cap;
        voterCap[_candidate][msg.sender] = 0;
        candidateOwner[_candidate] = address(0);

        uint256 withdrawBlockNumber = block.number + candidateWithdrawDelay;
        WithdrawState storage w = _withdraws[msg.sender];
        w.caps[withdrawBlockNumber] += cap;
        w.blockNumbers.push(withdrawBlockNumber);
    }

    function getWithdrawBlockNumbers() external view returns (uint256[] memory) {
        return _withdraws[msg.sender].blockNumbers;
    }

    function getWithdrawCap(uint256 _blockNumber) external view returns (uint256) {
        return _withdraws[msg.sender].caps[_blockNumber];
    }

    function withdraw(uint256 _blockNumber, uint256 _index) external {
        require(_blockNumber > 0, "bad block");
        require(block.number >= _blockNumber, "not yet");
        WithdrawState storage w = _withdraws[msg.sender];
        require(w.caps[_blockNumber] > 0, "no cap");
        require(_index < w.blockNumbers.length, "bad index");
        require(w.blockNumbers[_index] == _blockNumber, "block index mismatch");

        uint256 cap = w.caps[_blockNumber];
        delete w.caps[_blockNumber];
        delete w.blockNumbers[_index];

        (bool ok, ) = payable(msg.sender).call{value: cap}("");
        require(ok, "Withdraw transfer failed");
    }

    function getCandidateOwner(address _candidate) external view returns (address) {
        return candidateOwner[_candidate];
    }

    function getCandidateCap(address _candidate) external view returns (uint256) {
        return candidateCap[_candidate];
    }

    function getVoterCap(address _candidate, address _voter) external view returns (uint256) {
        return voterCap[_candidate][_voter];
    }
}
