const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CryptoEscrow", function () {
  let CryptoEscrow;
  let escrow;
  let owner, buyer, seller, arbitrator, other;
  
  before(async function () {
    [owner, buyer, seller, arbitrator, other] = await ethers.getSigners();
    
    // Deploy mock tokens for testing
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    this.chx = await ERC20Mock.deploy("CHX Token", "CHX");
    this.usdt = await ERC20Mock.deploy("Tether USD", "USDT");
    await this.chx.mint(buyer.address, ethers.parseEther("1000"));
    await this.usdt.mint(buyer.address, ethers.parseEther("1000"));
    
    // Deploy CryptoEscrow
    CryptoEscrow = await ethers.getContractFactory("CryptoEscrow");
    escrow = await CryptoEscrow.deploy(100, ethers.parseEther("0.1")); // 1% fee, 0.1 ETH dispute fee
    
    // Add supported tokens
    await escrow.addSupportedToken(await this.chx.getAddress());
    await escrow.addSupportedToken(await this.usdt.getAddress());
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await escrow.owner()).to.equal(owner.address);
    });
    
    it("Should set correct initial fees", async function () {
      expect(await escrow.platformFeePercentage()).to.equal(100);
      expect(await escrow.disputeFeeFixed()).to.equal(ethers.parseEther("0.1"));
    });
    
    it("Should have supported tokens", async function () {
      expect(await escrow.allowedTokens(ethers.ZeroAddress)).to.be.true; // Native token
      expect(await escrow.allowedTokens(await this.chx.getAddress())).to.be.true;
      expect(await escrow.allowedTokens(await this.usdt.getAddress())).to.be.true;
    });
  });

  describe("Native Token Escrow", function () {
    let escrowId;
    const amount = ethers.parseEther("1.0");
    
    it("Should create escrow with native token", async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ethers.ZeroAddress,
        amount,
        "Test payment",
        { value: amount }
      );
      
      const receipt = await tx.wait();
      escrowId = await escrow.escrowCount();
      
      await expect(tx)
        .to.emit(escrow, "EscrowCreated")
        .withArgs(escrowId, buyer.address, seller.address, ethers.ZeroAddress, amount, "Test payment");
      
      await expect(tx)
        .to.emit(escrow, "FundsDeposited")
        .withArgs(escrowId, buyer.address, amount);
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(1); // Funded
      expect(escrowData.amount).to.equal(amount);
    });
    
    it("Should release funds to seller", async function () {
      const initialSellerBalance = await ethers.provider.getBalance(seller.address);
      const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
      
      const sellerAmount = amount * 99n / 100n; // 1% fee
      const feeAmount = amount / 100n;
      
      const tx = await escrow.connect(buyer).releaseFunds(escrowId);
      await tx.wait();
      
      await expect(tx)
        .to.emit(escrow, "FundsReleased")
        .withArgs(escrowId, seller.address, sellerAmount);
      
      const finalSellerBalance = await ethers.provider.getBalance(seller.address);
      const finalOwnerBalance = await ethers.provider.getBalance(owner.address);
      
      expect(finalSellerBalance).to.be.closeTo(
        initialSellerBalance + sellerAmount,
        ethers.parseEther("0.01")
      );
      
      expect(finalOwnerBalance).to.be.closeTo(
        initialOwnerBalance + feeAmount,
        ethers.parseEther("0.01")
      );
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(2); // Released
    });
  });

  describe("ERC20 Token Escrow", function () {
    let escrowId;
    const amount = ethers.parseEther("100");
    
    it("Should create escrow with ERC20 token", async function () {
      // Approve escrow to spend tokens
      await this.chx.connect(buyer).approve(await escrow.getAddress(), amount);
      
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        await this.chx.getAddress(),
        amount,
        "Test ERC20 payment"
      );
      
      const receipt = await tx.wait();
      escrowId = await escrow.escrowCount();
      
      await expect(tx)
        .to.emit(escrow, "EscrowCreated")
        .withArgs(escrowId, buyer.address, seller.address, await this.chx.getAddress(), amount, "Test ERC20 payment");
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(0); // Pending
    });
    
    it("Should fund the escrow", async function () {
      const tx = await escrow.connect(buyer).fundEscrow(escrowId);
      await tx.wait();
      
      await expect(tx)
        .to.emit(escrow, "FundsDeposited")
        .withArgs(escrowId, buyer.address, amount);
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(1); // Funded
      
      expect(await this.chx.balanceOf(await escrow.getAddress())).to.equal(amount);
    });
    
    it("Should release ERC20 funds to seller", async function () {
      const initialSellerBalance = await this.chx.balanceOf(seller.address);
      const initialOwnerBalance = await this.chx.balanceOf(owner.address);
      
      const sellerAmount = amount * 99n / 100n; // 1% fee
      const feeAmount = amount / 100n;
      
      const tx = await escrow.connect(buyer).releaseFunds(escrowId);
      await tx.wait();
      
      await expect(tx)
        .to.emit(escrow, "FundsReleased")
        .withArgs(escrowId, seller.address, sellerAmount);
      
      expect(await this.chx.balanceOf(seller.address)).to.equal(
        initialSellerBalance + sellerAmount
      );
      
      expect(await this.chx.balanceOf(owner.address)).to.equal(
        initialOwnerBalance + feeAmount
      );
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(2); // Released
    });
  });

  describe("Dispute Resolution", function () {
    let escrowId;
    const amount = ethers.parseEther("5.0");
    
    beforeEach(async function () {
      // Create and fund escrow
      await this.usdt.connect(buyer).approve(await escrow.getAddress(), amount);
      
      await escrow.connect(buyer).createEscrow(
        seller.address,
        await this.usdt.getAddress(),
        amount,
        "Dispute test"
      );
      
      escrowId = await escrow.escrowCount();
      await escrow.connect(buyer).fundEscrow(escrowId);
    });
    
    it("Should raise a dispute", async function () {
      const tx = await escrow.connect(buyer).raiseDispute(
        escrowId,
        "Product not delivered",
        { value: ethers.parseEther("0.1") }
      );
      
      await expect(tx)
        .to.emit(escrow, "DisputeRaised")
        .withArgs(escrowId, buyer.address, "Product not delivered");
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(4); // Disputed
      expect(escrowData.disputeRaisedBy).to.equal(buyer.address);
      expect(escrowData.disputeFee).to.equal(ethers.parseEther("0.1"));
    });
    
    it("Should resolve dispute (buyer wins)", async function () {
      // Raise dispute first
      await escrow.connect(buyer).raiseDispute(
        escrowId,
        "Product not delivered",
        { value: ethers.parseEther("0.1") }
      );
      
      const initialBuyerBalance = await this.usdt.balanceOf(buyer.address);
      const initialSellerBalance = await this.usdt.balanceOf(seller.address);
      const initialOwnerBalance = await this.usdt.balanceOf(owner.address);
      
      const buyerAmount = amount * 99n / 100n; // 1% fee
      
      const tx = await escrow.connect(owner).resolveDispute(
        escrowId,
        true, // buyer wins
        buyerAmount,
        0 // nothing to seller
      );
      
      await expect(tx)
        .to.emit(escrow, "DisputeResolved")
        .withArgs(escrowId, owner.address, true, buyerAmount, 0);
      
      expect(await this.usdt.balanceOf(buyer.address)).to.equal(
        initialBuyerBalance + buyerAmount
      );
      
      expect(await this.usdt.balanceOf(seller.address)).to.equal(
        initialSellerBalance
      );
      
      expect(await this.usdt.balanceOf(owner.address)).to.equal(
        initialOwnerBalance + (amount / 100n)
      );
      
      const escrowData = await escrow.getEscrowDetails(escrowId);
      expect(escrowData.status).to.equal(5); // Resolved
    });
  });

  describe("Edge Cases", function () {
    let escrowId;
    const amount = ethers.parseEther("1.0");
    
    beforeEach(async function () {
      // Create and fund a new escrow for each test
      await escrow.connect(buyer).createEscrow(
        seller.address,
        ethers.ZeroAddress,
        amount,
        "Edge case test",
        { value: amount }
      );
      escrowId = await escrow.escrowCount();
    });
    
    it("Should prevent unauthorized access", async function () {
      // Test release funds
      await expect(
        escrow.connect(other).releaseFunds(escrowId)
      ).to.be.revertedWithCustomError(escrow, "UnauthorizedAccess");
      
      // Test cancel escrow
      await expect(
        escrow.connect(other).cancelEscrow(escrowId)
      ).to.be.revertedWithCustomError(escrow, "UnauthorizedAccess");
      
      // Test resolve dispute
      await expect(
        escrow.connect(other).resolveDispute(escrowId, true, 0, 0)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
    
    it("Should prevent invalid operations", async function () {
      await expect(
        escrow.connect(buyer).createEscrow(
          buyer.address, // seller = buyer
          ethers.ZeroAddress,
          ethers.parseEther("1"),
          "Invalid",
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidSellerAddress");
      
      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          "0x0000000000000000000000000000000000000001", // Unsupported token
          ethers.parseEther("1"),
          "Invalid"
        )
      ).to.be.revertedWithCustomError(escrow, "TokenNotSupported");
    });
  });
});