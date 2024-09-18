const hre = require("hardhat")
const { expect } = require("chai")

const ERC20 = require('@openzeppelin/contracts/build/contracts/ERC20.json')

describe("FlashLoanTemplate", function () {
  const VAULT_ADDRESS = "0xBA12222222228d8Ba445958a75a0704d566BF2C8"
  const TOKEN_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  let deployer // <-- Accounts
  let token, flashLoanTemplate // <-- Contracts

  beforeEach(async () => {
    [deployer] = await hre.ethers.getSigners()

    flashLoanTemplate = await hre.ethers.deployContract("FlashLoanTemplate")

    token = new ethers.Contract(TOKEN_ADDRESS, ERC20.abi, hre.ethers.provider)
  })

  describe("Performing Flash Loan...", () => {
    it('Borrows and Emits Event', async () => {
      const SYMBOL = await token.symbol()
      const DECIMALS = await token.decimals()
      const AMOUNT = await token.balanceOf(VAULT_ADDRESS)

      console.log(`Flash loaning ${ethers.formatUnits(AMOUNT, DECIMALS)} ${SYMBOL}`)

      expect(await flashLoanTemplate.connect(deployer).getFlashloan(TOKEN_ADDRESS, AMOUNT))
        .to.emit(flashLoanTemplate, "FlashLoan").withArgs(TOKEN_ADDRESS, AMOUNT)
    })
  })
})
