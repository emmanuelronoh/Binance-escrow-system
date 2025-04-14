// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract FiatEscrow is Ownable, ReentrancyGuard {
    enum FiatEscrowStatus { Pending, Collateralized, Completed, Disputed, Resolved, Cancelled }
    
    struct FiatTrade {
        address token;
        address buyer;
        address seller;
        uint256 collateralAmount;
        uint256 platformFee;
        uint256 disputeFee;
        FiatEscrowStatus status;
        string fiatCurrency;
        uint256 fiatAmount;
    }

    uint256 public tradeCounter;
    address public arbitrator;
    uint256 public platformFeePercentage;
    uint256 public disputeFeeFixed;
    
    mapping(uint256 => FiatTrade) public trades;
    mapping(address => bool) public allowedTokens;
    mapping(address => bool) public arbitrators;

    event TradeCreated(uint256 tradeId, address buyer, address seller);
    event CollateralLocked(uint256 tradeId);
    event TradeCompleted(uint256 tradeId);
    event DisputeRaised(uint256 tradeId);
    event DisputeResolved(uint256 tradeId, bool buyerWins);
    event TradeCancelled(uint256 tradeId);

    modifier onlyArbitrator() {
        require(arbitrators[msg.sender], "Not authorized arbitrator");
        _;
    }

    constructor(
        address initialArbitrator,
        uint256 initialFeePercentage,
        uint256 initialDisputeFee
    ) {
        require(initialArbitrator != address(0), "Invalid arbitrator address");
        require(initialFeePercentage <= 100, "Fee percentage too high");
        
        arbitrator = initialArbitrator;
        arbitrators[initialArbitrator] = true;
        platformFeePercentage = initialFeePercentage;
        disputeFeeFixed = initialDisputeFee;
        
        // Initialize with common stablecoins
        allowedTokens[0x1e0125b823dcDE430578068532E2dc400c56Fa82] = true; // CHX
        allowedTokens[0x55d398326f99059fF775485246999027B3197955] = true; // USDT
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
    }

    function addArbitrator(address newArbitrator) external onlyOwner {
        require(newArbitrator != address(0), "Invalid arbitrator address");
        arbitrators[newArbitrator] = true;
    }

    function removeArbitrator(address arbitratorToRemove) external onlyOwner {
        arbitrators[arbitratorToRemove] = false;
        if (arbitrator == arbitratorToRemove) {
            arbitrator = address(0);
        }
    }

    function updateFees(uint256 newFeePercentage, uint256 newDisputeFee) external onlyOwner {
        require(newFeePercentage <= 100, "Fee percentage too high");
        platformFeePercentage = newFeePercentage;
        disputeFeeFixed = newDisputeFee;
    }

    function createTrade(
        address token,
        address seller,
        uint256 collateralAmount,
        string memory fiatCurrency,
        uint256 fiatAmount
    ) external returns (uint256) {
        require(allowedTokens[token], "Token not allowed");
        require(collateralAmount > 0, "Collateral must be positive");
        require(seller != address(0), "Invalid seller address");
        require(seller != msg.sender, "Seller cannot be buyer");
        
        uint256 platformFee = (collateralAmount * platformFeePercentage) / 100;
        
        tradeCounter++;
        trades[tradeCounter] = FiatTrade({
            token: token,
            buyer: msg.sender,
            seller: seller,
            collateralAmount: collateralAmount,
            platformFee: platformFee,
            disputeFee: disputeFeeFixed,
            status: FiatEscrowStatus.Pending,
            fiatCurrency: fiatCurrency,
            fiatAmount: fiatAmount
        });
        
        emit TradeCreated(tradeCounter, msg.sender, seller);
        return tradeCounter;
    }

    function lockCollateral(uint256 tradeId) external nonReentrant {
        FiatTrade storage t = trades[tradeId];
        require(msg.sender == t.buyer, "Only buyer can lock");
        require(t.status == FiatEscrowStatus.Pending, "Invalid status");
        
        uint256 totalAmount = t.collateralAmount + t.platformFee + t.disputeFee;
        require(
            IERC20(t.token).transferFrom(msg.sender, address(this), totalAmount),
            "Token transfer failed"
        );
        
        t.status = FiatEscrowStatus.Collateralized;
        emit CollateralLocked(tradeId);
    }

    function releaseCollateral(uint256 tradeId) external nonReentrant {
        FiatTrade storage t = trades[tradeId];
        require(msg.sender == t.seller, "Only seller can release");
        require(t.status == FiatEscrowStatus.Collateralized, "Invalid status");
        
        // Transfer collateral to seller
        require(IERC20(t.token).transfer(t.seller, t.collateralAmount), "Transfer failed");
        
        // Transfer platform fee to owner
        require(IERC20(t.token).transfer(owner(), t.platformFee), "Fee transfer failed");
        
        // Return dispute fee to buyer
        require(IERC20(t.token).transfer(t.buyer, t.disputeFee), "Dispute fee return failed");
        
        t.status = FiatEscrowStatus.Completed;
        emit TradeCompleted(tradeId);
    }

    function cancelTrade(uint256 tradeId) external nonReentrant {
        FiatTrade storage t = trades[tradeId];
        require(msg.sender == t.buyer, "Only buyer can cancel");
        require(t.status == FiatEscrowStatus.Pending || t.status == FiatEscrowStatus.Collateralized, "Cannot cancel");
        
        if (t.status == FiatEscrowStatus.Collateralized) {
            uint256 totalAmount = t.collateralAmount + t.platformFee + t.disputeFee;
            require(IERC20(t.token).transfer(t.buyer, totalAmount), "Refund failed");
        }
        
        t.status = FiatEscrowStatus.Cancelled;
        emit TradeCancelled(tradeId);
    }

    function raiseDispute(uint256 tradeId) external {
        FiatTrade storage t = trades[tradeId];
        require(msg.sender == t.buyer || msg.sender == t.seller, "Not participant");
        require(t.status == FiatEscrowStatus.Collateralized, "Invalid status");
        
        t.status = FiatEscrowStatus.Disputed;
        emit DisputeRaised(tradeId);
    }

    function resolveDispute(uint256 tradeId, bool buyerWins) external onlyArbitrator nonReentrant {
        FiatTrade storage t = trades[tradeId];
        require(t.status == FiatEscrowStatus.Disputed, "Not in dispute");
        
        if (buyerWins) {
            require(
                IERC20(t.token).transfer(t.buyer, t.collateralAmount + t.disputeFee),
                "Buyer refund failed"
            );
        } else {
            require(
                IERC20(t.token).transfer(t.seller, t.collateralAmount),
                "Seller payment failed"
            );
            require(
                IERC20(t.token).transfer(msg.sender, t.disputeFee),
                "Arbitrator fee failed"
            );
        }
        
        require(
            IERC20(t.token).transfer(owner(), t.platformFee),
            "Platform fee transfer failed"
        );
        
        t.status = FiatEscrowStatus.Resolved;
        emit DisputeResolved(tradeId, buyerWins);
    }
}