//SPDX-License-Identifier:MIT

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author anurag agarwal
 * the system is desgined to be as minimal as possible ,and have the tokens maintain a 1==1 peg
 * this stablecoin has the properties
 * -exogenous collateral
 * -dollor pegged if possible we will try to make it rupee pegged
 * -algorithmic stable
 *
 * It is similar to DAI had no governance .no fees. and was only backed by WETH and WBTC.
 *
 * @notice this contract is the core of the DSC Engine system . It handles all the logic for minting and redeeming DSC .as well as depositing and withdrawing collateral
 * @notice this contract is very loosely based on the MakerDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {
    ////////errors////////
    error DSCEngine_MustBeMoreThanZero();
    error DSCEngine_TokenAddressNotAllowed();
    error DSCEngine_TokenAddressLengthNotMatchPriceFeedAdressesLength();
    error DSCEngine_TransferFailed();
    error DSCEngine_HealthFactorIsBroken();
    error DSCEngine_MintFailed();
    error DSCEngine_UserHealthFactorIsNotBelowMinimumThreshold();
    error DSCEngine_UserHealthFactorIsNotImproved();
    /////////state variables//////////

    uint256 private constant PRECISION_FEED = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BOUNS=10;

    mapping(address token => address priceFeed) public s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) public s_collateralDeposited;
    mapping(address user => uint256 amountCollateral) public s_DscToMint;
    address[] public s_collateralTokens;

    DecentralizedStableCoin public immutable i_dsc;

    ////////events/////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed uscCollateral,address indexed token, uint256  amount);
    ///////modifiers///////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine_TokenAddressNotAllowed();
        }
        _;
    }

    //////////constructor///////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeeds, address dscAddress) {
        if (tokenAddresses.length != priceFeeds.length) {
            revert DSCEngine_TokenAddressLengthNotMatchPriceFeedAdressesLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeeds[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////external functions/////////

    /**
     *
     * @param tokenCollateralAddress to deposit the token collateral
     * @param amountCollateral to store the collateral amount
     * @param amountDscToMint to mint the given dsc
     *
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }
    // to mint the Dsc we have to check a lot of things pricefeeds ,collaterals,etc
    /**
     * @notice follows CEI
     * @param amountDscToMint the amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscToMint[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }
    
    /**
     * 
     * @param tokenCollateral the token collateral to redeem 
     * @param amountCollateral the collateral amount of the token 
     * @param amountDscToBurn the amount of the dsc to redeem 
     * this function redeem the collateral and burn the dsc minted
     * first we burn the dsc and then we call the redeem collateral function
     */
    function redeemCollateralForDsc(address tokenCollateral,uint256 amountCollateral,uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateral,amountCollateral);

    }

    // in order to redeem collateral the health factor must be greater than one after redeeming collateral
    //dry: don't repeat yourself

    function redeemCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateral,amountCollateral,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amountBurn) public moreThanZero(amountBurn) nonReentrant {
        
        _burnDsc(amountBurn,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    /**
     * @param collateral the erc 20 token address to liqudate from the user
     * @param user The user who has broken the health factor .their _healthFactor should be below minimum threshold
     * @param debtToCover the amount of dsc you want to burn to improve the users health factor 
     * @notice we can partially liquidate the user
     * @notice we will get a liquidation bonus for taking the users funds overcollateralized in order for this to work 
     * @notice A known bug would be if the protocol were 100% or less collateralized, then the we woun't be able to liquidate the user as not able toh incentive the liquidator for the work 
     * 
     */
    function liquidate(address collateral,address user,uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine_UserHealthFactorIsNotBelowMinimumThreshold();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral,debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered*LIQUIDATION_BOUNS)/PRECISION;
        uint256 totalCollateralToRedeem =tokenAmountFromDebtCovered+bonusCollateral;
        _redeemCollateral(collateral,totalCollateralToRedeem,user,msg.sender);
        _burnDsc(debtToCover,user,msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine_UserHealthFactorIsNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
        
    }
    function getTokenAmountFromUsd(address token,uint256 debtToCover)public view returns (uint256 tokenAmountFromDebtCovered){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,)= priceFeed.latestRoundData();
        uint256 priceInUsd = uint256(price);
        tokenAmountFromDebtCovered = (debtToCover*PRECISION /(priceInUsd*PRECISION_FEED));
    }
    function getHealthFactor() external view {}

    ////private and internal view functions/////
    function _redeemCollateral(address tokenCollateral ,uint256 amountCollateral,address from ,address to) public {
        s_collateralDeposited[from][tokenCollateral] -= amountCollateral;
        emit CollateralRedeemed(from, to,tokenCollateral, amountCollateral);
        bool success = IERC20(tokenCollateral).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }
    function _burnDsc(uint256 amountDscToBurn,address onBehalfOf,address dscFrom) private {
        s_DscToMint[dscFrom]-=amountDscToBurn;
        bool success = i_dsc.transferFrom(onBehalfOf, address(this), amountDscToBurn);
        if(!success){
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);

    }
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalDscMinted)
    {
        //1. get the value of total dscMinted
        //2. get total collateral value
        totalCollateralValueInUsd = getAccountCollateralValue(user);
        totalDscMinted = s_DscToMint[user];
    }

    /**
     * returns how close to liquidation the user is
     * if a user goes below 1 they can liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        //1. get the value of total dscMinted
        //2. get total collateral value
        (uint256 totalCollateralValueInUsd,) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((totalCollateralValueInUsd * PRECISION) / collateralAdjustedForThreshold);
    }

    //1.check health factor do they have enough collateral
    //2.revert if they don't have enough collateral
    function _revertIfHealthFactorIsBroken(address user) private view {
        
    }

    ///////////public and external view functions//////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral tokens, get the amount they have deposited, and map it to the price , to get the usd value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //get the price of the token form the AggregatorV3Interface
        //multiply the price by the amount
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * PRECISION_FEED * amount) / PRECISION);
    }
    function getAccountInfo(address user) public view returns (uint256 totalCollateralValueInUsd, uint256 totalDscMinted) {
        (totalCollateralValueInUsd,totalDscMinted)= _getAccountInformation(user);
    }
    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }
    function getPrecisionFeed() public pure returns (uint256) {
        return PRECISION_FEED;
    }
    function calculateHealthFactor(address user) public view returns (uint256){
        return _healthFactor(user);
    }
}
