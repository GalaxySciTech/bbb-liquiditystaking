// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OperatorRegistry
 * @dev Two-tier operator identity, KYC lifecycle, and coinbase management.
 *
 * Tier 1 (OPERATOR_ADMIN_ROLE / multi-sig):
 *   - Register operators with a capacity cap
 *   - Approve/renew/revoke KYC
 *   - Adjust per-operator maxMasternodes
 *
 * Tier 2 (Operators — self-service via their adminAddress):
 *   - Whitelist new coinbase addresses for upcoming masternodes
 *   - Delist coinbase addresses (retiring hardware)
 *
 * KYC Lifecycle:
 *   NONE → (registerOperator) → NONE → (approveKYC) → VALID
 *   VALID → (30d before expiry) → WARNING → (at expiry) → EXPIRED
 *   EXPIRED → (approveKYC renewal) → VALID
 *
 * On KYC expiry: masternodes keep running, commission redirected 50% bXDC / 50% treasury.
 * No 30-day unbonding. Instantly reversible on KYC renewal.
 */
contract OperatorRegistry is AccessControl {
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");

    uint256 public constant KYC_WARNING_WINDOW = 30 days;
    uint256 public constant KYC_VALID_DURATION = 365 days;

    enum KYCStatus {
        NONE,
        VALID,
        WARNING,
        EXPIRED
    }

    struct OperatorInfo {
        address adminAddress;
        bool kycApproved;
        uint256 kycExpiryTimestamp;
        string kycHash; // Stored for vault delegation: vault calls uploadKYC(kycHash) before propose()
        uint256 maxMasternodes;
        uint256 activeMasternodes;
        bool exists;
    }

    mapping(address => OperatorInfo) public operators;
    mapping(address => address[]) private _coinbaseAddresses; // operator => coinbases
    mapping(address => address) public coinbaseToOperator; // coinbase => operator admin
    mapping(address => address) public coinbaseToVault; // coinbase => MasternodeVault (set by StakingPool)

    address[] public operatorAdmins;
    address public stakingPool;

    event OperatorRegistered(address indexed adminAddress, uint256 maxMasternodes);
    event OperatorRemoved(address indexed adminAddress);
    event KYCApproved(address indexed operator, uint256 expiryTimestamp);
    event KYCRevoked(address indexed operator);
    event MaxMasternodesUpdated(address indexed operator, uint256 maxMasternodes);
    event CoinbaseWhitelisted(address indexed operator, address indexed coinbase);
    event CoinbaseDelisted(address indexed operator, address indexed coinbase);
    event VaultLinked(address indexed coinbase, address indexed vault);
    event MasternodeActivated(address indexed operator, address indexed coinbase);
    event MasternodeDeactivated(address indexed operator, address indexed coinbase);
    event StakingPoolSet(address indexed stakingPool);

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only StakingPool");
        _;
    }

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ADMIN_ROLE, admin);
    }

    function setStakingPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "Invalid address");
        stakingPool = _pool;
        emit StakingPoolSet(_pool);
    }

    // ===== Tier 1: Admin Functions =====

    /**
     * @dev Register a new operator. KYC must be approved separately via approveKYC().
     * @param operatorAdmin The operator's wallet address (also used for commission claims)
     * @param maxMasternodes Hard ceiling on masternodes this operator can run
     */
    function registerOperator(
        address operatorAdmin,
        uint256 maxMasternodes
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(operatorAdmin != address(0), "Invalid address");
        require(!operators[operatorAdmin].exists, "Already registered");
        require(maxMasternodes > 0, "Invalid cap");

        operators[operatorAdmin] = OperatorInfo({
            adminAddress: operatorAdmin,
            kycApproved: false,
            kycExpiryTimestamp: 0,
            kycHash: "",
            maxMasternodes: maxMasternodes,
            activeMasternodes: 0,
            exists: true
        });
        operatorAdmins.push(operatorAdmin);
        emit OperatorRegistered(operatorAdmin, maxMasternodes);
    }

    /**
     * @dev Approve or renew KYC for an operator. Stores kycHash for vault delegation.
     * When StakingPool deploys a vault for this operator's coinbase, it passes kycHash
     * to vault.setupAndPropose(). Sets expiry to now + 365 days.
     */
    function approveKYC(address operatorAdmin, string calldata kycHash) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(operators[operatorAdmin].exists, "Not registered");
        require(bytes(kycHash).length > 0, "KYC hash required");
        operators[operatorAdmin].kycApproved = true;
        operators[operatorAdmin].kycExpiryTimestamp = block.timestamp + KYC_VALID_DURATION;
        operators[operatorAdmin].kycHash = kycHash;
        emit KYCApproved(operatorAdmin, operators[operatorAdmin].kycExpiryTimestamp);
    }

    /**
     * @dev Revoke KYC immediately. Commission redirected on next harvest.
     */
    function revokeKYC(address operatorAdmin) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(operators[operatorAdmin].exists, "Not registered");
        operators[operatorAdmin].kycApproved = false;
        operators[operatorAdmin].kycExpiryTimestamp = 0;
        delete operators[operatorAdmin].kycHash;
        emit KYCRevoked(operatorAdmin);
    }

    /**
     * @dev Returns the stored KYC hash for vault delegation. Used by StakingPool
     * when calling vault.setupAndPropose(kycHash, coinbase).
     */
    function getKycHash(address operatorAdmin) external view returns (string memory) {
        return operators[operatorAdmin].kycHash;
    }

    /**
     * @dev Update operator capacity cap.
     */
    function setMaxMasternodes(
        address operatorAdmin,
        uint256 max
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(operators[operatorAdmin].exists, "Not registered");
        require(max >= operators[operatorAdmin].activeMasternodes, "Below active count");
        operators[operatorAdmin].maxMasternodes = max;
        emit MaxMasternodesUpdated(operatorAdmin, max);
    }

    /**
     * @dev Remove an operator. Requires no active masternodes.
     */
    function removeOperator(address operatorAdmin) external onlyRole(OPERATOR_ADMIN_ROLE) {
        OperatorInfo storage op = operators[operatorAdmin];
        require(op.exists, "Not registered");
        require(op.activeMasternodes == 0, "Has active masternodes");

        op.exists = false;
        op.kycApproved = false;

        // Remove from list
        for (uint256 i = 0; i < operatorAdmins.length; i++) {
            if (operatorAdmins[i] == operatorAdmin) {
                operatorAdmins[i] = operatorAdmins[operatorAdmins.length - 1];
                operatorAdmins.pop();
                break;
            }
        }
        emit OperatorRemoved(operatorAdmin);
    }

    // ===== Tier 2: Operator Self-Service =====

    /**
     * @dev Register a coinbase address for an upcoming masternode.
     * Caller must be a registered operator with valid or warning KYC.
     * @param coinbase The coinbase/validator key address for the new masternode
     */
    function whitelistCoinbase(address coinbase) external {
        address caller = msg.sender;
        OperatorInfo storage op = operators[caller];
        require(op.exists, "Not registered");

        KYCStatus status = getKYCStatus(caller);
        require(status == KYCStatus.VALID || status == KYCStatus.WARNING, "KYC required");
        require(coinbase != address(0), "Invalid coinbase");
        require(coinbaseToOperator[coinbase] == address(0), "Coinbase already registered");
        require(
            _coinbaseAddresses[caller].length < op.maxMasternodes,
            "At capacity"
        );

        _coinbaseAddresses[caller].push(coinbase);
        coinbaseToOperator[coinbase] = caller;
        emit CoinbaseWhitelisted(caller, coinbase);
    }

    /**
     * @dev Remove a coinbase address. If a vault is active for this coinbase,
     * the StakingPool should resign the masternode first.
     * @param coinbase The coinbase address to delist
     */
    function delistCoinbase(address coinbase) external {
        address caller = msg.sender;
        require(coinbaseToOperator[coinbase] == caller, "Not your coinbase");
        _delistCoinbase(caller, coinbase);
    }

    // ===== StakingPool Callbacks =====

    /**
     * @dev Record the vault address for a proposed masternode.
     * Called by StakingPool after deploying and proposing a vault.
     */
    function linkVault(address coinbase, address vault) external onlyStakingPool {
        coinbaseToVault[coinbase] = vault;
        emit VaultLinked(coinbase, vault);
    }

    /**
     * @dev Increment operator's active masternode count after proposal.
     */
    function recordProposal(address coinbase) external onlyStakingPool {
        address operatorAdmin = coinbaseToOperator[coinbase];
        if (operatorAdmin != address(0) && operators[operatorAdmin].exists) {
            operators[operatorAdmin].activeMasternodes++;
            emit MasternodeActivated(operatorAdmin, coinbase);
        }
    }

    /**
     * @dev Decrement operator's active masternode count after resignation confirmed.
     * Clears coinbaseToVault so the coinbase can be reused for a new proposal.
     */
    function recordResignation(address coinbase) external onlyStakingPool {
        address operatorAdmin = coinbaseToOperator[coinbase];
        if (
            operatorAdmin != address(0) &&
            operators[operatorAdmin].exists &&
            operators[operatorAdmin].activeMasternodes > 0
        ) {
            operators[operatorAdmin].activeMasternodes--;
            delete coinbaseToVault[coinbase];
            emit MasternodeDeactivated(operatorAdmin, coinbase);
        }
    }

    // ===== View Functions =====

    /**
     * @dev Returns the KYC status of an operator at the current block timestamp.
     */
    function getKYCStatus(address operatorAdmin) public view returns (KYCStatus) {
        OperatorInfo storage op = operators[operatorAdmin];
        if (!op.exists || !op.kycApproved || op.kycExpiryTimestamp == 0) {
            return KYCStatus.NONE;
        }
        if (block.timestamp >= op.kycExpiryTimestamp) return KYCStatus.EXPIRED;
        if (block.timestamp >= op.kycExpiryTimestamp - KYC_WARNING_WINDOW)
            return KYCStatus.WARNING;
        return KYCStatus.VALID;
    }

    /**
     * @dev Returns true if operator KYC is VALID or WARNING (masternodes may operate).
     */
    function isKYCValid(address operatorAdmin) external view returns (bool) {
        KYCStatus status = getKYCStatus(operatorAdmin);
        return status == KYCStatus.VALID || status == KYCStatus.WARNING;
    }

    /**
     * @dev Returns all registered coinbase addresses for an operator.
     */
    function getCoinbases(address operatorAdmin) external view returns (address[] memory) {
        return _coinbaseAddresses[operatorAdmin];
    }

    /**
     * @dev Returns the first unproposed coinbase for an operator (no vault deployed yet).
     * Returns address(0) if none available.
     */
    function getUnproposedCoinbase(address operatorAdmin) external view returns (address) {
        address[] storage cbs = _coinbaseAddresses[operatorAdmin];
        for (uint256 i = 0; i < cbs.length; i++) {
            if (coinbaseToVault[cbs[i]] == address(0)) {
                return cbs[i];
            }
        }
        return address(0);
    }

    /**
     * @dev Returns all registered operator admin addresses.
     */
    function getAllOperators() external view returns (address[] memory) {
        return operatorAdmins;
    }

    /**
     * @dev Returns the operator with the most remaining capacity (lowest fill ratio).
     * Used by StakingPool for capacity-balanced masternode selection.
     * Returns (address(0), address(0)) if no eligible operator found.
     */
    function selectBestOperator() external view returns (address operatorAdmin, address coinbase) {
        uint256 bestNumerator = type(uint256).max; // lowest activeMasternodes / maxMasternodes
        uint256 bestDenominator = 1;

        for (uint256 i = 0; i < operatorAdmins.length; i++) {
            address op = operatorAdmins[i];
            OperatorInfo storage info = operators[op];

            if (!info.exists) continue;

            KYCStatus status = getKYCStatus(op);
            if (status != KYCStatus.VALID && status != KYCStatus.WARNING) continue;
            if (info.activeMasternodes >= info.maxMasternodes) continue;

            // Find an unproposed coinbase
            address cb = address(0);
            address[] storage cbs = _coinbaseAddresses[op];
            for (uint256 j = 0; j < cbs.length; j++) {
                if (coinbaseToVault[cbs[j]] == address(0)) {
                    cb = cbs[j];
                    break;
                }
            }
            if (cb == address(0)) continue; // No available coinbase

            // Capacity ratio: activeMasternodes / maxMasternodes (lower = more room)
            // Compare as cross-multiply to avoid decimals: a/b < c/d ⟺ a*d < c*b
            uint256 num = info.activeMasternodes;
            uint256 den = info.maxMasternodes;
            bool isBetter = operatorAdmin == address(0) || (num * bestDenominator < bestNumerator * den);
            if (isBetter) {
                bestNumerator = num;
                bestDenominator = den;
                operatorAdmin = op;
                coinbase = cb;
            }
        }
    }

    // ===== Internal =====

    function _delistCoinbase(address operatorAdmin, address coinbase) internal {
        coinbaseToOperator[coinbase] = address(0);
        address[] storage cbs = _coinbaseAddresses[operatorAdmin];
        for (uint256 i = 0; i < cbs.length; i++) {
            if (cbs[i] == coinbase) {
                cbs[i] = cbs[cbs.length - 1];
                cbs.pop();
                break;
            }
        }
        emit CoinbaseDelisted(operatorAdmin, coinbase);
    }
}
