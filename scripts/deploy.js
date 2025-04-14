const fs = require("fs");
const path = require("path");
const { ethers } = require("hardhat");

async function main() {
  // Get signers (first 4 accounts from local node)
  const [deployer, , , arbitrator] = await ethers.getSigners();

  console.log("Deploying contracts with:", deployer.address);
  console.log("Arbitrator address:", arbitrator.address);

  // Configuration parameters
  const platformFeePercentage = 1; // 1% platform fee
  const disputeFee = ethers.parseEther("0.01"); // 0.01 ETH dispute fee

  // Deploy CryptoEscrow
  console.log("\nDeploying CryptoEscrow...");
  const CryptoEscrow = await ethers.getContractFactory("CryptoEscrow");
  const cryptoEscrow = await CryptoEscrow.deploy(
    platformFeePercentage,
    disputeFee,
    { gasLimit: 5000000 } // Add gas limit to prevent out of gas errors
  );
  await cryptoEscrow.waitForDeployment();
  const cryptoEscrowAddress = await cryptoEscrow.getAddress();
  console.log("CryptoEscrow deployed to:", cryptoEscrowAddress);

  // Deploy FiatEscrow
  console.log("\nDeploying FiatEscrow...");
  const FiatEscrow = await ethers.getContractFactory("FiatEscrow");
  const fiatEscrow = await FiatEscrow.deploy(
    arbitrator.address,
    platformFeePercentage,
    disputeFee,
    { gasLimit: 5000000 } // Add gas limit to prevent out of gas errors
  );
  await fiatEscrow.waitForDeployment();
  const fiatEscrowAddress = await fiatEscrow.getAddress();
  console.log("FiatEscrow deployed to:", fiatEscrowAddress);

  // Prepare deployment data
  const deployedAddresses = {
    network: hre.network.name,
    contracts: {
      CryptoEscrow: {
        address: cryptoEscrowAddress,
        platformFeePercentage: platformFeePercentage,
        disputeFee: disputeFee.toString()
      },
      FiatEscrow: {
        address: fiatEscrowAddress,
        platformFeePercentage: platformFeePercentage,
        disputeFee: disputeFee.toString()
      }
    },
    roles: {
      deployer: deployer.address,
      arbitrator: arbitrator.address
    },
    timestamp: new Date().toISOString()
  };

  // Create deployment directory if it doesn't exist
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir);
  }

  // Save to network-specific file
  const outputPath = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(deployedAddresses, null, 2));

  console.log("\n✅ Deployment details saved to:", outputPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});