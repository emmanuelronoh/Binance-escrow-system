// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract Escrow {
    enum Status { Pending, Funded, Released, Refunded, Disputed }
    
    struct Transaction {
        address initiator;
        address counterparty;
        address token;
        uint256 amount;
        Status status;
        string terms;
        string releaseConditions;
    }
    
    mapping(bytes32 => Transaction) public transactions;
    address public admin;
    address public platformToken;
    uint256 public platformFee; // in basis points (1% = 100 basis points)
    
    event EscrowCreated(bytes32 indexed txId, address indexed initiator, address indexed counterparty);
    event FundsDeposited(bytes32 indexed txId);
    event FundsReleased(bytes32 indexed txId);
    event FundsRefunded(bytes32 indexed txId);
    event DisputeInitiated(bytes32 indexed txId);
    
    constructor(address _platformToken, uint256 _platformFee) {
        admin = msg.sender;
        platformToken = _platformToken;
        platformFee = _platformFee;
    }
    
    function createEscrow(
        address _counterparty,
        address _token,
        uint256 _amount,
        string memory _terms,
        string memory _releaseConditions
    ) external returns (bytes32) {
        bytes32 txId = keccak256(abi.encodePacked(
            msg.sender,
            _counterparty,
            _token,
            _amount,
            block.timestamp
        ));
        
        transactions[txId] = Transaction({
            initiator: msg.sender,
            counterparty: _counterparty,
            token: _token,
            amount: _amount,
            status: Status.Pending,
            terms: _terms,
            releaseConditions: _releaseConditions
        });
        
        emit EscrowCreated(txId, msg.sender, _counterparty);
        return txId;
    }
    
    function depositFunds(bytes32 _txId) external {
        Transaction storage txn = transactions[_txId];
        require(txn.initiator == msg.sender, "Only initiator can deposit");
        require(txn.status == Status.Pending, "Invalid status");
        
        IERC20 token = IERC20(txn.token);
        uint256 feeAmount = (txn.amount * platformFee) / 10000;
        uint256 totalAmount = txn.amount + feeAmount;
        
        require(token.allowance(msg.sender, address(this)) >= totalAmount, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), txn.amount), "Transfer failed");
        
        // Transfer fee to platform
        if (feeAmount > 0 && txn.token == platformToken) {
            require(token.transferFrom(msg.sender, admin, feeAmount), "Fee transfer failed");
        }
        
        txn.status = Status.Funded;
        emit FundsDeposited(_txId);
    }
    
    function releaseFunds(bytes32 _txId) external {
        Transaction storage txn = transactions[_txId];
        require(txn.counterparty == msg.sender, "Only counterparty can release");
        require(txn.status == Status.Funded, "Invalid status");
        
        IERC20 token = IERC20(txn.token);
        require(token.transfer(txn.counterparty, txn.amount), "Transfer failed");
        
        txn.status = Status.Released;
        emit FundsReleased(_txId);
    }
    
    function refundFunds(bytes32 _txId) external {
        Transaction storage txn = transactions[_txId];
        require(txn.initiator == msg.sender, "Only initiator can refund");
        require(txn.status == Status.Funded, "Invalid status");
        
        IERC20 token = IERC20(txn.token);
        require(token.transfer(txn.initiator, txn.amount), "Transfer failed");
        
        txn.status = Status.Refunded;
        emit FundsRefunded(_txId);
    }
    
    function initiateDispute(bytes32 _txId) external {
        Transaction storage txn = transactions[_txId];
        require(
            txn.initiator == msg.sender || txn.counterparty == msg.sender,
            "Only parties can dispute"
        );
        require(
            txn.status == Status.Pending || txn.status == Status.Funded,
            "Invalid status"
        );
        
        txn.status = Status.Disputed;
        emit DisputeInitiated(_txId);
    }
    
    // Admin function to resolve disputes
    function resolveDispute(
        bytes32 _txId,
        bool _releaseToCounterparty
    ) external {
        require(msg.sender == admin, "Only admin");
        Transaction storage txn = transactions[_txId];
        require(txn.status == Status.Disputed, "Not disputed");
        
        IERC20 token = IERC20(txn.token);
        if (_releaseToCounterparty) {
            require(token.transfer(txn.counterparty, txn.amount), "Transfer failed");
            txn.status = Status.Released;
            emit FundsReleased(_txId);
        } else {
            require(token.transfer(txn.initiator, txn.amount), "Transfer failed");
            txn.status = Status.Refunded;
            emit FundsRefunded(_txId);
        }
    }
}