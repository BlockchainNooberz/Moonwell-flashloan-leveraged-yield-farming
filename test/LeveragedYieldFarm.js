const hre = require("hardhat")
const { mine } = require("@nomicfoundation/hardhat-network-helpers")
const { expect } = require("chai")

const ERC20 = require('@openzeppelin/contracts/build/contracts/ERC20.json')

describe('LeveragedYieldFarm', () => {
  const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  const MOONWELL_USDC = "0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22"
  const WELL = "0xA88594D404727625A9437C3f886C7643872296AE"

  let deployer
  let usdc, mUSDC, well, leveragedYieldFarm

  beforeEach(async () => {
    [deployer] = await hre.ethers.getSigners()

    // Setup ERC20 (USDC) contract...
    usdc = new hre.ethers.Contract(USDC, ERC20.abi, deployer)

    // Setup Moonwell ERC20 contracts mUSDC & WELL...
    mUSDC = new hre.ethers.Contract(MOONWELL_USDC, ERC20.abi, deployer)
    well = new hre.ethers.Contract(WELL, ERC20.abi, deployer)

    // Deploy LeveragedYieldFarm...
    leveragedYieldFarm = await hre.ethers.deployContract("LeveragedYieldFarm")
  })

  describe('Impersonating an account to acquire USDC', () => {
    it('Sends USDC to deployer', async () => {
      const usdcBalanceBefore = await usdc.connect(deployer).balanceOf(deployer.address)

      // Account to impersonate
      const UNLOCKED_ACCOUNT = "0xaac391f166f33CdaEfaa4AfA6616A3BEA66B694d"

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [UNLOCKED_ACCOUNT],
      })

      const signer = await hre.ethers.getSigner(UNLOCKED_ACCOUNT)

      // Transfer USDC to owner of LeveragedYieldFarm
      await (await usdc.connect(signer).transfer(deployer.address, hre.ethers.parseUnits('1000', 6))).wait()

      const usdcBalanceAfter = await usdc.balanceOf(deployer.address)
      expect(usdcBalanceAfter).to.be.above(usdcBalanceBefore)
    })
  })

  describe('Sending ETH to LeveragedYieldFarm', () => {
    // Ensure that ETH cannot be sent to the LeveragedYieldFarm contract

    it('Reverts if ETH is sent by accident', async () => {
      await expect(deployer.sendTransaction({
        to: await leveragedYieldFarm.getAddress(),
        value: hre.ethers.parseUnits('1', 'ether')
      })).to.be.reverted
    })
  })

  describe('Withdrawing', () => {
    // Ensure extra tokens can be withdrawn if need be

    it('Withdraws token balances', async () => {
      const AMOUNT = hre.ethers.parseUnits('1', 6)
      const DEPLOYER_BALANCE = await usdc.balanceOf(deployer.address)

      // Transfer 1 USDC to contract
      await (await usdc.connect(deployer).transfer(
        await leveragedYieldFarm.getAddress(),
        AMOUNT
      )).wait()

      expect(await usdc.balanceOf(await leveragedYieldFarm.getAddress())).to.equal(AMOUNT)
      await (await leveragedYieldFarm.withdrawToken(USDC)).wait()

      expect(await usdc.balanceOf(await leveragedYieldFarm.getAddress())).to.equal(0)
      expect(await usdc.balanceOf(deployer.address)).to.equal(DEPLOYER_BALANCE)
    })
  })

  describe('Leveraged Yield Farming on Moonwell boosted with Balancer flash loan...', () => {
    // This is the amount to pass in deposit & withdraw
    const AMOUNT = hre.ethers.parseUnits('1', 6)

    beforeEach(async () => {
      // Deposit 1.1 USDC to contract (.1 for additional headroom when withdrawing)
      await (await usdc.connect(deployer).transfer(
        await leveragedYieldFarm.getAddress(),
        hre.ethers.parseUnits('1.1', 6)
      )).wait()

      // Supplying 1 USDC with flash loan to Moonwell
      await leveragedYieldFarm.connect(deployer).deposit(AMOUNT)
    })

    it('Deposits/Waits/Withdraws/Takes Profit...', async () => {
      const ethBalanceBefore = await hre.ethers.provider.getBalance(deployer.address)
      const usdcBalanceBefore = await usdc.balanceOf(deployer.address)
      const mUSDCBalanceBefore = await mUSDC.balanceOf(await leveragedYieldFarm.getAddress())
      const wellBalanceBefore = await well.balanceOf(deployer.address)

      // Fast forward 1 block... (Feel free to customize for estimates)
      const BLOCKS_TO_MINE = 1

      console.log(`\nFast forwarding ${BLOCKS_TO_MINE} Block...\n`)

      // New blocks are validated roughly every ~ 2 seconds
      await mine(BLOCKS_TO_MINE, { interval: 2 })

      // Taking profits
      await leveragedYieldFarm.connect(deployer).withdraw(AMOUNT)

      const ethBalanceAfter = await hre.ethers.provider.getBalance(deployer.address)
      const usdcBalanceAfter = await usdc.balanceOf(deployer.address)
      const mUSDCBalanceAfter = await mUSDC.balanceOf(await leveragedYieldFarm.getAddress())
      const wellBalanceAfter = await well.balanceOf(deployer.address)

      expect(ethBalanceBefore).to.be.above(ethBalanceAfter) // Due to gas fee
      expect(usdcBalanceAfter).to.be.above(usdcBalanceBefore) // Interest for supplying
      expect(mUSDCBalanceBefore).to.be.above(mUSDCBalanceAfter) // Swapping mUSDC => USDC
      expect(wellBalanceAfter).to.be.above(wellBalanceBefore) // Successful yield farm

      const results = {
        "ETH   Balance Before": hre.ethers.formatUnits(ethBalanceBefore, 18),
        "ETH   Balance After": hre.ethers.formatUnits(ethBalanceAfter, 18),
        "USDC  Balance Before": hre.ethers.formatUnits(usdcBalanceBefore, 6),
        "USDC  Balance After": hre.ethers.formatUnits(usdcBalanceAfter, 6),
        "mUSDC Balance Before": hre.ethers.formatUnits(mUSDCBalanceBefore, 8),
        "mUSDC Balance After": hre.ethers.formatUnits(mUSDCBalanceAfter, 8),
        "WELL  Balance After": hre.ethers.formatUnits(wellBalanceAfter, 18)
      }

      console.table(results)
    })
  })
})