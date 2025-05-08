const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { ethers } = hre;

async function main() {
  // Check if environment variables are loaded
  console.log("Using private key from env:", process.env.PRIVATE_KEY ? "***loaded***" : "NOT FOUND");
  console.log("Using CHX token address:", process.env.TOKEN_ADDRESS || "NOT FOUND");

  // Get signer from configured private key
  const [deployer] = await ethers.getSigners();
  
  // Use the same address for all roles (or modify as needed)
  const feeCollector = deployer.address;
  const admin = deployer.address;

  console.log("🚀 Starting deployment...");
  console.log(`📌 Deployer: ${deployer.address}`);
  console.log(`💰 Fee Collector: ${feeCollector}`);
  console.log(`🛡️ Admin: ${admin}`);

  // Check deployer balance
  const balance = await deployer.provider.getBalance(deployer.address);
  console.log(`💰 Deployer balance: ${ethers.formatEther(balance)} ETH`);

  // Configuration - using environment variables
  const config = {
    platformFeePercentage: 100, // 1% in basis points (100 = 1%)
    disputeFee: ethers.parseEther("0.1"), // 0.1 ETH (or BNB depending on network)
    gasLimit: 6_000_000,
    initialTokens: [
      process.env.TOKEN_ADDRESS, // CHX token from env
      "0x55d398326f99059fF775485246999027B3197955", // USDT
      "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB
    ],
    chxTokenAddress: process.env.TOKEN_ADDRESS // CHX token from env
  };

  // Validate configuration
  if (config.platformFeePercentage > 500) {
    throw new Error("Platform fee percentage cannot exceed 5% (500 basis points)");
  }
  if (config.disputeFee < ethers.parseEther("0.01")) {
    throw new Error("Dispute fee must be at least 0.01 ETH/BNB");
  }

  // Deploy CryptoEscrow
  console.log("\n🔨 Deploying CryptoEscrow contract...");
  const CryptoEscrow = await ethers.getContractFactory("CryptoEscrow");

  const escrow = await CryptoEscrow.deploy(
    config.platformFeePercentage,
    config.disputeFee,
    feeCollector,
    config.initialTokens,
    config.chxTokenAddress,
    { gasLimit: config.gasLimit }
  );

  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  console.log(`✅ CryptoEscrow deployed to: ${escrowAddress}`);

  // Verify token support
  console.log("\n🔍 Verifying token support...");
  for (const token of config.initialTokens) {
    try {
      const isSupported = await escrow.isTokenSupported(token);
      console.log(`   ${isSupported ? '✔' : '❌'} Token ${token} supported: ${isSupported}`);
    } catch (error) {
      console.log(`   ❌ Error checking token ${token}: ${error.message}`);
    }
  }

  // Verify native token support
  try {
    const nativeSupported = await escrow.isTokenSupported(ethers.ZeroAddress);
    console.log(`   ${nativeSupported ? '✔' : '❌'} Native token supported: ${nativeSupported}`);
  } catch (error) {
    console.log(`   ❌ Error checking native token support: ${error.message}`);
  }

  // Prepare deployment artifacts
  const deploymentData = {
    network: hre.network.name,
    chainId: (await ethers.provider.getNetwork()).chainId,
    contract: {
      name: "CryptoEscrow",
      address: escrowAddress,
      abi: JSON.parse(CryptoEscrow.interface.formatJson()),
      constructorArgs: {
        platformFeePercentage: config.platformFeePercentage,
        disputeFee: config.disputeFee.toString(),
        feeCollector: feeCollector,
        initialTokens: config.initialTokens,
        chxTokenAddress: config.chxTokenAddress
      }
    },
    deploymentConfig: config,
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    admin: admin,
    feeCollector: feeCollector
  };

  // Save deployment artifacts
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const outputPath = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(deploymentData, null, 2));

  console.log(`\n📦 Deployment artifacts saved to: ${outputPath}`);

  // Verify contract (if on live network)
  if (!["hardhat", "localhost"].includes(hre.network.name)) {
    console.log("\n🔍 Verifying contract on Etherscan...");
    try {
      await hre.run("verify:verify", {
        address: escrowAddress,
        constructorArguments: [
          config.platformFeePercentage,
          config.disputeFee,
          feeCollector,
          config.initialTokens,
          config.chxTokenAddress
        ]
      });
      console.log("✅ Verification successful!");
    } catch (error) {
      console.log("⚠️ Verification failed:", error.message);
    }
  }

  console.log("\n🎉 Deployment completed successfully!");
}

main().catch((error) => {
  console.error("💥 Deployment failed:", error);
  process.exitCode = 1;
});