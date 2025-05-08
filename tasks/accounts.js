const { task } = require("hardhat/config");

task("accounts", "Prints the list of accounts with private keys", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  // Hardhat's default mnemonic for deterministic accounts
  const mnemonic = "test test test test test test test test test test test junk";
  const derivationPath = "m/44'/60'/0'/0/";

  for (let i = 0; i < accounts.length; i++) {
    const wallet = hre.ethers.HDNodeWallet.fromMnemonic(
      hre.ethers.Mnemonic.fromPhrase(mnemonic),
      derivationPath + i
    );
    console.log(`Address: ${accounts[i].address}`);
    console.log(`Private Key: ${wallet.privateKey}`);
    console.log("------------------------");
  }
});