import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log(
    "Account balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "AVAX"
  );

  // 1. Deploy SasukaTreasury
  const Treasury = await ethers.getContractFactory("SasukaTreasury");
  const treasury = await Treasury.deploy(deployer.address);
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("SasukaTreasury deployed to:", treasuryAddress);

  // 2. Deploy SasukaGame with treasury address
  const Game = await ethers.getContractFactory("SasukaGame");
  const game = await Game.deploy(treasuryAddress);
  await game.waitForDeployment();
  const gameAddress = await game.getAddress();
  console.log("SasukaGame deployed to:", gameAddress);

  console.log("\n--- Deployment Summary ---");
  console.log("Treasury:", treasuryAddress);
  console.log("Game:    ", gameAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
