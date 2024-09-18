const hre = require("hardhat")

async function main() {
  const baseFeePerGas = 127656143

  const leveragedYieldFarm = await hre.ethers.deployContract("LeveragedYieldFarm", { maxFeePerGas: baseFeePerGas })
  await leveragedYieldFarm.waitForDeployment()

  console.log(`Leveraged Yield Farm deployed to ${await leveragedYieldFarm.getAddress()}`)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});