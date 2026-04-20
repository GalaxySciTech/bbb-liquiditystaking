// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockXDCValidator
 * @dev Simulates 0x88: propose/vote/resign with owner stake in withdrawsState until withdraw() after delay (spec v1.5).
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

    struct OwnerWithdrawal {
        uint256 withdrawBlockNumber;
        uint256 withdrawIndex;
        uint256 amount;
        address candidate;
        bool active;
    }

    /// @dev Simulates withdrawsState[msg.sender] — one pending owner withdrawal at a time
    mapping(address => OwnerWithdrawal) private _ownerWithdrawal;

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

    /**
     * @dev Only the owner's (vault's) stake moves to withdrawsState; other voters unchanged (spec v1.5).
     */
    function resign(address _candidate) external {
        require(isCandidate[_candidate], "Not candidate");
        uint256 cap = voterCap[_candidate][msg.sender];
        require(cap > 0, "No owner stake");

        candidateCap[_candidate] -= cap;
        voterCap[_candidate][msg.sender] = 0;

        if (candidateCap[_candidate] == 0) {
            isCandidate[_candidate] = false;
            candidateOwner[_candidate] = address(0);
        }

        uint256 unlock = block.number + candidateWithdrawDelay;
        _ownerWithdrawal[msg.sender] = OwnerWithdrawal({
            withdrawBlockNumber: unlock,
            withdrawIndex: 0,
            amount: cap,
            candidate: _candidate,
            active: true
        });
    }

    function withdraw(uint256 _blockNumber, uint256 _index) external {
        OwnerWithdrawal storage w = _ownerWithdrawal[msg.sender];
        require(w.active, "No pending withdraw");
        require(block.number >= w.withdrawBlockNumber, "Delay not elapsed");
        require(_blockNumber == w.withdrawBlockNumber && _index == w.withdrawIndex, "Bad key");

        uint256 amt = w.amount;
        delete _ownerWithdrawal[msg.sender];

        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "Withdraw transfer failed");
    }

    function getOwnerWithdrawal(address owner)
        external
        view
        returns (uint256 withdrawBlockNumber, uint256 withdrawIndex, uint256 amount, bool ready)
    {
        OwnerWithdrawal storage w = _ownerWithdrawal[owner];
        if (!w.active) return (0, 0, 0, false);
        withdrawBlockNumber = w.withdrawBlockNumber;
        withdrawIndex = w.withdrawIndex;
        amount = w.amount;
        ready = block.number >= w.withdrawBlockNumber;
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
