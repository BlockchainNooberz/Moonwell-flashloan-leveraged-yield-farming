// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";

/// @dev Interface for Moonwell's mERC20 Token (Similar to Compound's cTokens)
interface IMToken {
    function mint(uint mintAmount) external returns (uint);

    function borrow(uint borrowAmount) external returns (uint);

    function repayBorrow(uint repayAmount) external returns (uint);

    function redeem(uint redeemTokens) external returns (uint);

    function borrowBalanceCurrent(address account) external returns (uint);

    function balanceOf(address owner) external view returns (uint);
}

interface IMultiRewardDistributor {
    struct RewardInfo {
        address emissionToken;
        uint totalAmount;
        uint supplySide;
        uint borrowSide;
    }

    function getOutstandingRewardsForUser(
        IMToken _mToken,
        address _user
    ) external view returns (RewardInfo[] memory);
}

/// @dev Interface for Moonwell's Comptroller (Similar to Compound)
interface IComptroller {
    function enterMarkets(
        address[] calldata
    ) external returns (uint256[] memory);

    function claimReward(address holder) external;

    function claimReward(address holder, address[] memory mTokens) external;
}

contract LeveragedYieldFarm is IFlashLoanRecipient {
    // USDC Token
    address constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    IERC20 constant USDC = IERC20(USDC_ADDRESS);

    // Moonwell's mUSDC Token
    address constant MOONWELL_USDC_ADDRESS =
        0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    IMToken constant MOONWELL_USDC = IMToken(MOONWELL_USDC_ADDRESS);

    // Moonwell's WELL ERC-20 token
    IERC20 constant WELL = IERC20(0xA88594D404727625A9437C3f886C7643872296AE);

    // Moonwell's Base Mainnet Comptroller
    IComptroller constant comptroller =
        IComptroller(0xfBb21d0380beE3312B33c4353c8936a0F13EF26C);

    // Moonwell's Base Reward Distributor
    IMultiRewardDistributor constant multiRewardDistributor =
        IMultiRewardDistributor(0xe9005b078701e2A0948D2EaC43010D35870Ad9d2);

    // Balancer Contract
    IVault constant vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Contract owner
    address immutable owner;

    struct MyFlashData {
        address flashToken;
        uint256 flashAmount;
        uint256 totalAmount;
        bool isDeposit;
    }

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "LeveragedYieldFarm: caller is not the owner!"
        );
        _;
    }

    constructor() {
        owner = msg.sender;

        // Enter the mUSDC market so you can borrow another type of asset
        address[] memory mTokens = new address[](1);
        mTokens[0] = MOONWELL_USDC_ADDRESS;
        uint256[] memory errors = comptroller.enterMarkets(mTokens);
        if (errors[0] != 0) {
            revert("Comptroller.enterMarkets failed.");
        }
    }

    /// @notice Don't allow contract to receive Ether by mistake
    fallback() external {
        revert();
    }

    /**
     * Deposit into the market and begin farm.
     * @param initialAmount The amount of personal USDC to be used in the farm.
     * @notice You must first send USDC to this contract before you can call this function.
     * @notice Always keep extra USDC in the contract.
     */
    function deposit(uint256 initialAmount) external onlyOwner returns (bool) {
        // Total deposit: 30% initial amount, 70% flash loan
        uint256 totalAmount = (initialAmount * 10) / 3;

        // loan is 70% of total deposit
        uint256 flashLoanAmount = totalAmount - initialAmount;

        // Get USDC Flash Loan for "DEPOSIT"
        bool isDeposit = true;
        getFlashLoan(USDC_ADDRESS, flashLoanAmount, totalAmount, isDeposit); // execution goes to `receiveFlashLoan`

        // Handle remaining execution inside handleDeposit() function

        return true;
    }

    /**
     * Withdraw from the market, and claim outstanding rewards.
     * @param initialAmount The amount the user transferred.
     * @notice Always keep extra USDC in the contract.
     */
    function withdraw(uint256 initialAmount) external onlyOwner returns (bool) {
        // Total deposit: 30% initial amount, 70% flash loan
        uint256 totalAmount = (initialAmount * 10) / 3;

        // Loan is 70% of total deposit
        uint256 flashLoanAmount = totalAmount - initialAmount;

        // Use flash loan to payback borrowed amount
        bool isDeposit = false; //false means withdraw
        getFlashLoan(USDC_ADDRESS, flashLoanAmount, totalAmount, isDeposit); // execution goes to `receiveFlashLoan`

        // Handle repayment inside handleWithdraw() function

        // Claim WELL tokens
        address[] memory mTokens = new address[](1);
        mTokens[0] = MOONWELL_USDC_ADDRESS;

        comptroller.claimReward(address(this), mTokens);

        // Withdraw COMP tokens
        WELL.transfer(owner, WELL.balanceOf(address(this)));

        // Withdraw USDC to the wallet
        USDC.transfer(owner, USDC.balanceOf(address(this)));

        return true;
    }

    /**
     * Responsible for getting the flash loan.
     * @param flashToken The token being flash loaned.
     * @param flashAmount The amount to flash loan.
     * @param totalAmount The amount flash loaned + user amount transferred.
     * @param isDeposit True for depositing, false for withdrawing.
     */
    function getFlashLoan(
        address flashToken,
        uint256 flashAmount,
        uint256 totalAmount,
        bool isDeposit
    ) internal {
        // Encode MyFlashData for `receiveFlashLoan`
        bytes memory userData = abi.encode(
            MyFlashData({
                flashToken: flashToken,
                flashAmount: flashAmount,
                totalAmount: totalAmount,
                isDeposit: isDeposit
            })
        );

        // Token to flash loan, by default we are flash loaning 1 token.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(flashToken);

        // Flash loan amount.
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        vault.flashLoan(this, tokens, amounts, userData); // execution goes to `receiveFlashLoan()`
    }

    /**
     * @dev This is the function that will be called postLoan
     * i.e. Encode the logic to handle your flashloaned funds here
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        require(
            msg.sender == address(vault),
            "LeveragedYieldFarm: Not Balancer!"
        );

        MyFlashData memory data = abi.decode(userData, (MyFlashData));
        uint256 flashTokenBalance = IERC20(data.flashToken).balanceOf(
            address(this)
        );

        require(
            flashTokenBalance >= data.flashAmount + feeAmounts[0],
            "LeveragedYieldFarm: Not enough funds to repay Balancer loan!"
        );

        if (data.isDeposit == true) {
            handleDeposit(data.totalAmount, data.flashAmount);
        }

        if (data.isDeposit == false) {
            handleWithdraw();
        }

        IERC20(data.flashToken).transfer(
            address(vault),
            (data.flashAmount + feeAmounts[0])
        );
    }

    /**
     * Handle supplying and borrowing USDC
     * @param totalAmount The total amount of USDC to supply.
     * @param flashLoanAmount The flash amount to borrow.
     */
    function handleDeposit(
        uint256 totalAmount,
        uint256 flashLoanAmount
    ) internal returns (bool) {
        // Approve USDC tokens as collateral
        USDC.approve(MOONWELL_USDC_ADDRESS, totalAmount);

        // Provide collateral by minting mUSDC tokens
        MOONWELL_USDC.mint(totalAmount);

        // Borrow USDC (to pay back the flash loan)
        MOONWELL_USDC.borrow(flashLoanAmount);

        return true;
    }

    /**
     * Handle repaying borrowed amount and
     * redeeming what was supplied.
     */
    function handleWithdraw() internal returns (bool) {
        uint256 balance;

        // Get curent borrow Balance
        balance = MOONWELL_USDC.borrowBalanceCurrent(address(this));

        // Approve tokens for repayment
        USDC.approve(address(MOONWELL_USDC), balance);

        // Repay tokens
        MOONWELL_USDC.repayBorrow(balance);

        // Get mUSDC balance
        balance = MOONWELL_USDC.balanceOf(address(this));

        // Redeem USDC
        MOONWELL_USDC.redeem(balance);

        return true;
    }

    /**
     * Withdraw any tokens accidentally sent or extra balance remaining.
     * @param _tokenAddress Token address to withdraw.
     */
    function withdrawToken(address _tokenAddress) public onlyOwner {
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(owner, balance);
    }

    /**
     * Claim any outstanding rewards.
     * @param _tokenAddress Token address to claim rewards.
     * @dev Implemented as an extra safe guard for redeeming any
     * outstanding rewards. Keep in mind rewards are automatically
     * claimed in withdraw(). You can also call getOutstandingRewards()
     * to determine if you may want to call this function.
     */
    function claimRewards(address _tokenAddress) public onlyOwner {
        address[] memory mTokens = new address[](1);
        mTokens[0] = _tokenAddress;

        comptroller.claimReward(address(this), mTokens);
    }

    /* --- PUBLIC VIEW FUNCTIONS --- */

    /**
     * Check rewards for a market.
     * @param _tokenAddress Token address to check rewards for.
     */
    function getOutstandingRewards(
        address _tokenAddress
    ) public view returns (IMultiRewardDistributor.RewardInfo[] memory) {
        return
            multiRewardDistributor.getOutstandingRewardsForUser(
                IMToken(_tokenAddress),
                address(this)
            );
    }
}
