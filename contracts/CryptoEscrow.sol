// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract CryptoEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum EscrowStatus {
        Pending,
        Funded,
        Released,
        Cancelled,
        Disputed,
        Resolved
    }

    enum AssetType {
        Native,
        ERC20,
        Wrapped
    }

    struct Escrow {
        address buyer;
        address seller;
        EscrowStatus status;
        uint256 createdAt;
        uint256 disputeExpiry;
        address arbitrator;
        AssetType primaryAssetType;
        address primaryToken;
        uint256 primaryAmount;
        AssetType counterAssetType;
        address counterToken;
        string counterCurrency;
        uint256 counterAmount;
        uint256 platformFee;
        uint256 disputeFee;
        address disputeRaisedBy;
        string disputeReason;
    }

    struct Candidate {
        address addr;
        uint256 reputation;
        uint256 workload;
        uint256 specializationScore;
        uint256 totalScore;
    }

    // Arbitrator state
    address[] public arbitratorAddresses;
    uint256 public arbitratorCount;
    uint256 public arbitratorMinReputation;
    uint256 public arbitratorMaxActiveDisputes;

    mapping(address => bool) public arbitrators;
    mapping(address => bool) public arbitratorAvailable;
    mapping(address => uint256) public arbitratorReputation;
    mapping(address => uint256) public arbitratorAvgResponseTime;
    mapping(address => uint256) public arbitratorActiveDisputes;
    mapping(address => uint256) public arbitratorLastAssignment;
    mapping(address => mapping(uint256 => uint256)) public arbitratorSpecialization;
    mapping(address => mapping(address => bool)) public arbitratorBlacklist;

    // Platform settings
    uint256 public constant DISPUTE_TIMEFRAME = 7 days;
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%
    uint256 public constant MIN_DISPUTE_FEE = 0.01 ether;

    uint256 public platformFeePercentage;
    uint256 public disputeFeeFixed;

    // Escrow data
    uint256 public escrowCount;
    mapping(uint256 => Escrow) public escrows;

    // Token support
    mapping(address => bool) public allowedTokens;
    mapping(address => address) public wrappedAssets;

    // Events
    event Disputed(uint256 indexed escrowId, address indexed raisedBy, string reason);
    event ArbitratorSelected(address indexed selectedArbitrator, address indexed disputeInitiator, address indexed disputeResponder);

    constructor(uint256 _feePercentage, uint256 _disputeFee) Ownable() {
        require(_feePercentage <= MAX_PLATFORM_FEE, "Fee too high");
        require(_disputeFee >= MIN_DISPUTE_FEE, "Dispute fee too low");

        platformFeePercentage = _feePercentage;
        disputeFeeFixed = _disputeFee;

        // Sample tokens
        allowedTokens[0x1e0125b823dcDE430578068532E2dc400c56Fa82] = true; // CHX
        allowedTokens[0x55d398326f99059fF775485246999027B3197955] = true; // USDT
        allowedTokens[0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = true; // WBNB
        allowedTokens[0xB03b6d3D2bA12fA380aD04A79D80Aa58cc693299] = true; // Your token
    }

    modifier onlyParticipant(uint256 escrowId) {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.buyer || msg.sender == e.seller, "Not a participant");
        _;
    }

    function raiseDispute(uint256 escrowId, string memory reason) external onlyParticipant(escrowId) {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.Funded, "Not in funded state");

        e.status = EscrowStatus.Disputed;
        e.disputeRaisedBy = msg.sender;
        e.disputeReason = reason;
        e.disputeExpiry = block.timestamp + DISPUTE_TIMEFRAME;
        e.arbitrator = _selectArbitrator(
            msg.sender,
            e.buyer == msg.sender ? e.seller : e.buyer,
            e.primaryAmount
        );

        emit Disputed(escrowId, msg.sender, reason);
    }

    function _selectArbitrator(address disputeInitiator, address disputeResponder, uint256 disputeAmount) internal returns (address) {
        uint256 candidateCount = 0;
        Candidate[] memory candidates = new Candidate[](arbitratorAddresses.length);

        for (uint256 i = 0; i < arbitratorAddresses.length; i++) {
            address arbitrator = arbitratorAddresses[i];

            if (
                !arbitrators[arbitrator] ||
                arbitratorReputation[arbitrator] < arbitratorMinReputation ||
                arbitratorActiveDisputes[arbitrator] >= arbitratorMaxActiveDisputes ||
                !arbitratorAvailable[arbitrator] ||
                arbitratorBlacklist[arbitrator][disputeInitiator] ||
                arbitratorBlacklist[arbitrator][disputeResponder]
            ) {
                continue;
            }

            uint256 specializationScore = _calculateSpecializationScore(arbitrator, disputeAmount);
            uint256 totalScore = (
                arbitratorReputation[arbitrator] * 40 +
                (arbitratorMaxActiveDisputes - arbitratorActiveDisputes[arbitrator]) * 30 +
                specializationScore * 20 +
                _getArbitratorResponseTimeScore(arbitrator) * 10
            );

            candidates[candidateCount] = Candidate({
                addr: arbitrator,
                reputation: arbitratorReputation[arbitrator],
                workload: arbitratorActiveDisputes[arbitrator],
                specializationScore: specializationScore,
                totalScore: totalScore
            });

            candidateCount++;
            if (candidateCount >= 10) break;
        }

        require(candidateCount > 0, "No eligible arbitrators available");

        address selectedArbitrator = candidates[0].addr;
        uint256 highestScore = candidates[0].totalScore;

        for (uint256 i = 1; i < candidateCount; i++) {
            if (candidates[i].totalScore > highestScore) {
                selectedArbitrator = candidates[i].addr;
                highestScore = candidates[i].totalScore;
            }
        }

        arbitratorActiveDisputes[selectedArbitrator]++;
        arbitratorLastAssignment[selectedArbitrator] = block.timestamp;
        _updateArbitratorAssignmentHistory(selectedArbitrator);

        emit ArbitratorSelected(selectedArbitrator, disputeInitiator, disputeResponder);
        return selectedArbitrator;
    }

    function _calculateSpecializationScore(address arbitrator, uint256 amount) internal view returns (uint256) {
        if (amount < 1 ether) {
            return arbitratorSpecialization[arbitrator][0]; // small
        } else if (amount < 10 ether) {
            return arbitratorSpecialization[arbitrator][1]; // medium
        } else {
            return arbitratorSpecialization[arbitrator][2]; // large
        }
    }

    function _getArbitratorResponseTimeScore(address arbitrator) internal view returns (uint256) {
        uint256 avgResponseTime = arbitratorAvgResponseTime[arbitrator];
        if (avgResponseTime < 1 hours) return 100;
        if (avgResponseTime < 4 hours) return 80;
        if (avgResponseTime < 12 hours) return 50;
        return 20;
    }

    function _updateArbitratorAssignmentHistory(address arbitrator) internal {
        // Optional: implement fair assignment tracking if desired
        // For example: rotating assignment list, average load balancer
    }
}
