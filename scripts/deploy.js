require("dotenv").config();  // Load environment variables from .env file
const { ethers } = require("hardhat");

async function main() {
  // Load sensitive information from environment variables
  const TOKEN_ADDRESS = process.env.TOKEN_ADDRESS;  // Read from .env
  const PLATFORM_FEE = process.env.PLATFORM_FEE || 100; // Default to 100 if not set in .env

  if (!TOKEN_ADDRESS) {
    console.error("❌ Missing TOKEN_ADDRESS in environment variables!");
    process.exit(1);
  }

  console.log("\n=== Escrow Contract Deployment ===");
  console.log("Network:", network.name);
  console.log("Token Address:", TOKEN_ADDRESS);
  console.log("Platform Fee:", PLATFORM_FEE, "basis points");

  try {
    // 1. Get contract factory
    console.log("\n[1/4] Getting contract factory...");
    const Escrow = await ethers.getContractFactory("Escrow");
    console.log("✓ Contract factory obtained");

    // 2. Deploy contract
    console.log("\n[2/4] Deploying contract...");
    const escrow = await Escrow.deploy(TOKEN_ADDRESS, PLATFORM_FEE);
    console.log("✓ Deployment transaction sent");

    // 3. Wait for deployment
    console.log("\n[3/4] Waiting for deployment confirmation...");
    await escrow.waitForDeployment();
    console.log("✓ Contract deployed");

    // 4. Verification
    console.log("\n[4/4] Deployment details:");
    console.log("✅ Contract deployed to:", await escrow.getAddress());
    console.log("Deployer address:", (await ethers.provider.getTransaction(escrow.deploymentTransaction().hash)).from);
  } catch (error) {
    console.error("\n❌ Deployment failed!");
    console.error("Error:", error.message);
    
    if (error.transactionHash) {
      console.error("Transaction hash:", error.transactionHash);
    }
    
    process.exit(1);
  }
}

main();
