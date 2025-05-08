// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Custom Errors
error UnauthorizedAccess();
error InvalidSellerAddress();
error TokenNotSupported();
error AmountTooSmall();
error IncorrectNativeTokenAmount();
error NativeTokensNotRequiredForERC20();
error EscrowNotInDisputedState();
error DisputeTimeframeExpired();
error AmountsExceedEscrowBalance();
error InvalidDisputeResolution();
error EscrowNotFunded();
error InvalidTokenOperation();
error TokenAlreadySupported();
error TokenNotWrappable();
error WrappedTokenExists();
error InvalidFeeConfiguration();
error InvalidAddress();
error DisputeNotRaised();
error EscrowAlreadyCompleted();
error InvalidTokenAmount();

// Interfaces
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IWrappedToken {
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
}

// Libraries
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20: transfer failed"
        );
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20: transferFrom failed"
        );
    }

    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20: approve failed"
        );
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        uint256 c = a / b;
        return c;
    }
}

// Main Contract
contract CryptoEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Address for address;

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
        AssetType assetType;
        address tokenAddress;
        uint256 amount;
        uint256 platformFee;
        uint256 disputeFee;
        address disputeRaisedBy;
        string disputeReason;
        string paymentDetails;
    }

    // Constants
    uint256 public constant DISPUTE_TIMEFRAME = 7 days;
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%
    uint256 public constant MIN_DISPUTE_FEE = 0.01 ether;
    uint256 public constant MIN_ESCROW_AMOUNT = 0.001 ether;

    // Platform settings
    uint256 public platformFeePercentage;
    uint256 public disputeFeeFixed;
    address public feeCollector;
    address public admin;

    // Escrow data
    uint256 public escrowCount;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256[]) public userEscrows;
    mapping(address => bool) public arbitrators;

    // Token support
    mapping(address => bool) public allowedTokens;
    mapping(address => address) public tokenToWrapper;
    mapping(address => bool) public isWrappedToken;
    address[] public supportedTokens;

    // Events
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address token,
        uint256 amount,
        string paymentDetails
    );
    event FundsDeposited(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 amount
    );
    event FundsReleased(
        uint256 indexed escrowId,
        address indexed seller,
        uint256 amount
    );
    event EscrowCancelled(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 amount
    );
    event DisputeRaised(
        uint256 indexed escrowId,
        address indexed raisedBy,
        string reason
    );
    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed arbitrator,
        bool buyerWon,
        uint256 buyerAmount,
        uint256 sellerAmount
    );
    event TokenWrapped(
        address indexed originalToken,
        address indexed wrappedToken,
        uint256 amount
    );
    event TokenUnwrapped(
        address indexed wrappedToken,
        address indexed originalToken,
        uint256 amount
    );
    event TokenSupported(address indexed token);
    event TokenSupportRemoved(address indexed token);
    event ArbitratorAdded(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event FeeCollectorUpdated(address indexed newCollector);
    event AdminUpdated(address indexed newAdmin);
    event PlatformFeeUpdated(uint256 newFee);
    event DisputeFeeUpdated(uint256 newFee);
    event DisputeEvidenceSubmitted(
        uint256 indexed escrowId,
        address indexed submittedBy,
        string evidenceURL
    );
    event DisputeArbitratorAssigned(
        uint256 indexed escrowId,
        address indexed arbitrator
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyArbitrator() {
        require(arbitrators[msg.sender], "Only arbitrator");
        _;
    }

    constructor(
        uint256 _feePercentage,
        uint256 _disputeFee,
        address _feeCollector,
        address[] memory _initialTokens,
        address _chxTokenAddress
    ) {
        require(_feePercentage <= MAX_PLATFORM_FEE, "Fee too high");
        require(_disputeFee >= MIN_DISPUTE_FEE, "Dispute fee too low");
        require(_feeCollector != address(0), "Invalid fee collector");

        platformFeePercentage = _feePercentage;
        disputeFeeFixed = _disputeFee;
        feeCollector = _feeCollector;
        admin = msg.sender;

        // Add native token support (address(0))
        allowedTokens[address(0)] = true;
        supportedTokens.push(address(0));

        // Add initial supported tokens
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            _addSupportedToken(_initialTokens[i]);
            _addSupportedToken(_chxTokenAddress);
        }
    }

    // Main Escrow Functions

    /**
     * @dev Creates a new escrow agreement
     * @param seller The seller's address
     * @param tokenAddress The token address (address(0) for native currency)
     * @param amount The amount to escrow
     * @param paymentDetails Additional payment details
     */
    function createEscrow(
        address seller,
        address tokenAddress,
        uint256 amount,
        string calldata paymentDetails
    ) external payable {
        if (seller == address(0) || seller == msg.sender)
            revert InvalidSellerAddress();
        if (amount < MIN_ESCROW_AMOUNT) revert AmountTooSmall();
        if (!allowedTokens[tokenAddress]) revert TokenNotSupported();

        // Handle native token validation
        if (tokenAddress == address(0)) {
            if (msg.value != amount) revert IncorrectNativeTokenAmount();
        } else {
            if (msg.value != 0) revert NativeTokensNotRequiredForERC20();
        }

        escrowCount++;
        uint256 currentEscrowId = escrowCount;

        Escrow storage e = escrows[currentEscrowId];
        e.buyer = msg.sender;
        e.seller = seller;
        e.status = tokenAddress == address(0)
            ? EscrowStatus.Funded
            : EscrowStatus.Pending;
        e.createdAt = block.timestamp;
        e.tokenAddress = tokenAddress;
        e.amount = amount;
        e.paymentDetails = paymentDetails;
        e.assetType = tokenAddress == address(0)
            ? AssetType.Native
            : AssetType.ERC20;

        userEscrows[msg.sender].push(currentEscrowId);
        userEscrows[seller].push(currentEscrowId);

        emit EscrowCreated(
            currentEscrowId,
            msg.sender,
            seller,
            tokenAddress,
            amount,
            paymentDetails
        );

        if (tokenAddress == address(0)) {
            emit FundsDeposited(currentEscrowId, msg.sender, amount);
        }
    }

    /**
     * @dev Funds an ERC20 token escrow
     * @param escrowId The ID of the escrow to fund
     */
    function fundEscrow(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Pending) revert EscrowNotFunded();
        if (e.buyer != msg.sender) revert UnauthorizedAccess();
        if (e.tokenAddress == address(0)) revert InvalidTokenOperation();

        IERC20 token = IERC20(e.tokenAddress);
        uint256 allowance = token.allowance(msg.sender, address(this));
        require(allowance >= e.amount, "Insufficient allowance");

        token.safeTransferFrom(msg.sender, address(this), e.amount);
        e.status = EscrowStatus.Funded;
        emit FundsDeposited(escrowId, msg.sender, e.amount);
    }

    /**
     * @dev Releases funds to the seller
     * @param escrowId The ID of the escrow to release
     */
    function releaseFunds(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert EscrowNotFunded();
        if (msg.sender != e.buyer) revert UnauthorizedAccess();

        uint256 platformFee = calculatePlatformFee(e.amount);
        uint256 sellerAmount = e.amount.sub(platformFee);

        if (e.assetType == AssetType.Native) {
            payable(e.seller).transfer(sellerAmount);
            payable(feeCollector).transfer(platformFee);
        } else {
            IERC20(e.tokenAddress).safeTransfer(e.seller, sellerAmount);
            IERC20(e.tokenAddress).safeTransfer(feeCollector, platformFee);
        }

        e.status = EscrowStatus.Released;
        emit FundsReleased(escrowId, e.seller, sellerAmount);
    }

    /**
     * @dev Cancels an escrow and returns funds to buyer
     * @param escrowId The ID of the escrow to cancel
     */
    function cancelEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert EscrowNotFunded();
        if (msg.sender != e.buyer) revert UnauthorizedAccess();

        if (e.assetType == AssetType.Native) {
            payable(e.buyer).transfer(e.amount);
        } else {
            IERC20(e.tokenAddress).safeTransfer(e.buyer, e.amount);
        }

        e.status = EscrowStatus.Cancelled;
        emit EscrowCancelled(escrowId, e.buyer, e.amount);
    }

    // Dispute Resolution Functions

    /**
     * @dev Raises a dispute on an escrow
     * @param escrowId The ID of the escrow to dispute
     * @param reason The reason for the dispute
     */
    function raiseDispute(
        uint256 escrowId,
        string memory reason
    ) external payable nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert EscrowNotFunded();
        if (msg.sender != e.buyer && msg.sender != e.seller)
            revert UnauthorizedAccess();
        if (msg.value < disputeFeeFixed) revert InvalidFeeConfiguration();

        e.status = EscrowStatus.Disputed;
        e.disputeRaisedBy = msg.sender;
        e.disputeReason = reason;
        e.disputeExpiry = block.timestamp.add(DISPUTE_TIMEFRAME);
        e.disputeFee = msg.value;
        e.arbitrator = assignArbitrator();

        emit DisputeRaised(escrowId, msg.sender, reason);
    }

    /**
     * @dev Resolves a dispute
     * @param escrowId The ID of the escrow to resolve
     * @param buyerAmount Amount to return to buyer
     * @param sellerAmount Amount to send to seller
     */
    function resolveDispute(
        uint256 escrowId,
        uint256 buyerAmount,
        uint256 sellerAmount
    ) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Disputed)
            revert EscrowNotInDisputedState();
        if (block.timestamp > e.disputeExpiry) revert DisputeTimeframeExpired();
        if (msg.sender != e.arbitrator && msg.sender != admin)
            revert UnauthorizedAccess();

        uint256 totalAmount = e.amount;
        uint256 platformFee = calculatePlatformFee(totalAmount);
        uint256 remainingAmount = totalAmount.sub(platformFee);

        if (buyerAmount.add(sellerAmount) > remainingAmount)
            revert AmountsExceedEscrowBalance();

        if (e.assetType == AssetType.Native) {
            if (buyerAmount > 0) payable(e.buyer).transfer(buyerAmount);
            if (sellerAmount > 0) payable(e.seller).transfer(sellerAmount);
            payable(feeCollector).transfer(platformFee.add(e.disputeFee));
        } else {
            if (buyerAmount > 0)
                IERC20(e.tokenAddress).safeTransfer(e.buyer, buyerAmount);
            if (sellerAmount > 0)
                IERC20(e.tokenAddress).safeTransfer(e.seller, sellerAmount);
            IERC20(e.tokenAddress).safeTransfer(feeCollector, platformFee);
            payable(feeCollector).transfer(e.disputeFee);
        }

        e.status = EscrowStatus.Resolved;
        emit DisputeResolved(
            escrowId,
            msg.sender,
            buyerAmount > 0,
            buyerAmount,
            sellerAmount
        );
    }

    // Token Wrapping Functions

    /**
     * @dev Wraps a token into a wrapped equivalent
     * @param tokenAddress The token to wrap
     * @param amount The amount to wrap
     */
    function wrapToken(
        address tokenAddress,
        uint256 amount
    ) external nonReentrant {
        if (!allowedTokens[tokenAddress]) revert TokenNotSupported();
        if (tokenAddress == address(0)) revert TokenNotWrappable();
        if (amount == 0) revert InvalidTokenAmount();

        IERC20 token = IERC20(tokenAddress);
        token.safeTransferFrom(msg.sender, address(this), amount);

        address wrappedToken = tokenToWrapper[tokenAddress];
        if (wrappedToken == address(0)) {
            wrappedToken = createWrappedToken(tokenAddress);
            tokenToWrapper[tokenAddress] = wrappedToken;
            isWrappedToken[wrappedToken] = true;
        }

        IWrappedToken(wrappedToken).mint(msg.sender, amount);
        emit TokenWrapped(tokenAddress, wrappedToken, amount);
    }

    /**
     * @dev Unwraps a token back to its original form
     * @param wrappedToken The wrapped token to unwrap
     * @param amount The amount to unwrap
     */
    function unwrapToken(
        address wrappedToken,
        uint256 amount
    ) external nonReentrant {
        if (!isWrappedToken[wrappedToken]) revert TokenNotSupported();
        if (amount == 0) revert InvalidTokenAmount();

        address originalToken;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (tokenToWrapper[supportedTokens[i]] == wrappedToken) {
                originalToken = supportedTokens[i];
                break;
            }
        }
        if (originalToken == address(0)) revert InvalidTokenOperation();

        IWrappedToken(wrappedToken).burn(msg.sender, amount);
        IERC20(originalToken).safeTransfer(msg.sender, amount);

        emit TokenUnwrapped(wrappedToken, originalToken, amount);
    }

    // Admin Functions

    function addSupportedToken(address tokenAddress) external onlyAdmin {
        if (tokenAddress == address(0)) revert InvalidAddress();
        if (allowedTokens[tokenAddress]) revert TokenAlreadySupported();

        _addSupportedToken(tokenAddress);
    }

    function removeSupportedToken(address tokenAddress) external onlyAdmin {
        if (!allowedTokens[tokenAddress]) revert TokenNotSupported();

        allowedTokens[tokenAddress] = false;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == tokenAddress) {
                supportedTokens[i] = supportedTokens[
                    supportedTokens.length - 1
                ];
                supportedTokens.pop();
                break;
            }
        }

        emit TokenSupportRemoved(tokenAddress);
    }

    function addArbitrator(address arbitrator) external onlyAdmin {
        if (arbitrator == address(0)) revert InvalidAddress();
        arbitrators[arbitrator] = true;
        emit ArbitratorAdded(arbitrator);
    }

    function removeArbitrator(address arbitrator) external onlyAdmin {
        arbitrators[arbitrator] = false;
        emit ArbitratorRemoved(arbitrator);
    }

    function updatePlatformFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_PLATFORM_FEE) revert InvalidFeeConfiguration();
        platformFeePercentage = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    function updateDisputeFee(uint256 newFee) external onlyAdmin {
        if (newFee < MIN_DISPUTE_FEE) revert InvalidFeeConfiguration();
        disputeFeeFixed = newFee;
        emit DisputeFeeUpdated(newFee);
    }

    function updateFeeCollector(address newCollector) external onlyAdmin {
        if (newCollector == address(0)) revert InvalidAddress();
        feeCollector = newCollector;
        emit FeeCollectorUpdated(newCollector);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    // Internal Functions

    function _addSupportedToken(address tokenAddress) internal {
        require(tokenAddress.isContract(), "Address is not a contract");

        allowedTokens[tokenAddress] = true;
        supportedTokens.push(tokenAddress);
        emit TokenSupported(tokenAddress);
    }

    function createWrappedToken(
        address originalToken
    ) internal returns (address) {
        if (tokenToWrapper[originalToken] != address(0))
            revert WrappedTokenExists();

        IERC20Metadata token = IERC20Metadata(originalToken);
        string memory name = string(abi.encodePacked("Wrapped ", token.name()));
        string memory symbol = string(abi.encodePacked("W", token.symbol()));

        WrappedToken wrappedToken = new WrappedToken(name, symbol);
        return address(wrappedToken);
    }

    function assignArbitrator() internal view returns (address) {
        // Simplified arbitrator assignment - in production you'd want a more robust system
        // This is just a placeholder implementation
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (arbitrators[supportedTokens[i]]) {
                return supportedTokens[i];
            }
        }
        return admin;
    }

    // View Functions

    function calculatePlatformFee(
        uint256 amount
    ) public view returns (uint256) {
        return amount.mul(platformFeePercentage).div(10000);
    }

    function getSupportedTokens() public view returns (address[] memory) {
        return supportedTokens;
    }

    function getUserEscrows(
        address user
    ) public view returns (uint256[] memory) {
        return userEscrows[user];
    }

    function getEscrowDetails(
        uint256 escrowId
    ) public view returns (Escrow memory) {
        return escrows[escrowId];
    }

    function isTokenSupported(address token) public view returns (bool) {
        return allowedTokens[token];
    }

    function getWrappedToken(
        address originalToken
    ) public view returns (address) {
        return tokenToWrapper[originalToken];
    }

    // Emergency Functions

    function emergencyWithdrawToken(
        address tokenAddress,
        uint256 amount
    ) external onlyAdmin {
        IERC20(tokenAddress).safeTransfer(feeCollector, amount);
    }

    function emergencyWithdrawNative(uint256 amount) external onlyAdmin {
        payable(feeCollector).transfer(amount);
    }
    function submitDisputeEvidence(
        uint256 escrowId,
        string memory evidenceURL
    ) external {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.Disputed, "Not in dispute");
        require(
            msg.sender == e.buyer || msg.sender == e.seller,
            "Not party to escrow"
        );
        emit DisputeEvidenceSubmitted(escrowId, msg.sender, evidenceURL);
    }
}

// Wrapped Token Implementation
contract WrappedToken is IERC20, IERC20Metadata {
    using SafeMath for uint256;

    string private _name;
    string private _symbol;
    uint8 public constant decimals = 18;
    uint256 private _totalSupply;
    address public minter;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        minter = msg.sender;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            msg.sender,
            _allowances[sender][msg.sender].sub(amount)
        );
        return true;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        require(account != address(0), "Mint to zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        require(account != address(0), "Burn from zero address");
        require(_balances[account] >= amount, "Burn amount exceeds balance");

        _balances[account] = _balances[account].sub(amount);
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(sender != address(0), "Transfer from zero address");
        require(recipient != address(0), "Transfer to zero address");

        _balances[sender] = _balances[sender].sub(amount);
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "Approve from zero address");
        require(spender != address(0), "Approve to zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}
