// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

/*
* @title DSCEngine
*@author Farooq 
* The system is design to be as minimal as possible  , and have the  token metain a 1 token ==  $1 peg
* This stable-coin has the properties :
* Our DSC system should always be overcollateralize.At no point is shuld be less then then *Dollor backed USD 
* -Exgenous collateral
* Dollar pegged
* -Algorimically Stable
* It is similar to DAI If DAI had no goverance no fee and it is backed by wETH && wBTC 
* @notice this contract is the core of the DSC system. It handle all the logic for mining and redeeming the DSC as well depositing and withdrawing collateral
* @notice this contract is very losly based MakerDAI  DSS (DAI) system .
*  
*/

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AggregatorV3Interface } from "@chainlink-contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////////
    //////   Error   ////
    ///////////////////
    error DSCEngine__NeedsMoreThenZero();
    error DSCEngine__TokenAddressAndPriceFeedAdressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealhFactorOk();
    error DSCEngine__healthFactorNotImprove();
    /////////////////////////
    //  State Variable   //
    ////////////////////////
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; 
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // this mean you have 200% overcollateralize    
    uint256 private constant LIQUIDATION_PRECISION =100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user=>uint256 amountDscMinted) private s_DscMinted;
    address [] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    //   Events   //
    ///////////////////
    event collateralDeposited(address indexed user,address indexed token, uint256 indexed amount);
    event collateralReedemed(address indexed redeemFrom,address indexed redeemTo,address indexed token, uint256  amount);
    ///////////////////
    //   Modifier   //
    ///////////////////

    modifier moreThenZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThenZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }
    ///////////////////
    //   Functions   //
    ///////////////////

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAdressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }
    ///////////////////////////
    //   External Functions  //
    ///////////////////////////
/*
*@param tokenCollateralAddress The Address of the token to the deposit collateral
*@param amountCollateral The amount of the collateral to deposit
*@param amountDscToMint The amount of Decentralised stablecoin to mint
* @notice This function will deposit your collateral and mint DSC in one transaction
*/
    function depositCollaterAndMintDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        uint256 amountDscToMint) external {
            depositCollateral(tokenCollateralAddress, amountCollateral);
            mintDsc(amountDscToMint);
        }
    /*
    * fellow CEI patten
    * @param tokenCollateralAddress The Address of the token to the deposit collateral
    * @param amountCollateral The amount of the collateral to deposit
    */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThenZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit collateralDeposited(msg.sender,tokenCollateralAddress,amountCollateral);
        bool sucess=IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(! sucess){
            revert DSCEngine_TransferFailed();
        }
    }
    /*
    * @param tokenCollateralAddress The Address  collateral to redeem
    * @param amountCollateral The amount of the collateral to redeem
    * @param amountCollateralToBurn The amount of DSC to burn
    * @notice This function will redeem your collateral and burn DSC in one transaction
    */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral,uint256 amountCollateralToBurn) external  {
        burnDsc(amountCollateralToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already has a check for health factor
    }
    // In order to redeem collateral, 
    // 1. the user must have a health factor of 1 or greater after collateral polled
    // It based on DRY
    // CEI pattern
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThenZero(amountCollateral) nonReentrant {
        
        _redeemCollateral(msg.sender,msg.sender,tokenCollateralAddress,amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


// check if the colleteral value > Dsc amount *$1 etc PriceFeed, checking value
/*
* @notice fellow CEI
* @param amountDscToMint The amount of Decentralised stablecoin to mint.
* @notice They must have minimum value then the therashold
*
*/
    function mintDsc(uint256 amountDscToMint) public moreThenZero(amountDscToMint) { 
            s_DscMinted[msg.sender]+=amountDscToMint;
            // if they mint too much ($150 DSC, $100 ETH)
            _revertIfHealthFactorIsBroken(msg.sender);
            bool minted= i_dsc.mint(msg.sender, amountDscToMint);
            if(!minted){
                revert DSCEngine__MintFailed();
            }

    }

    function burnDsc(uint256 amount) public  moreThenZero(amount)  {
        _burnDsc(amount,msg.sender,msg.sender);
            _revertIfHealthFactorIsBroken(msg.sender);
    }
    // if someone is undercollateralized, we will pay you to be liquidated them
    /*
    * @param collateral The erc20  collateral address to liquidate from the user
    *@param user The user who has broken the health factor,The health factor is below MIN_HEALTH_FACTOR
    *@param debtToCover The amount of DSC you want to burn to improve the health factor 
    *@notice : You can partially liquidate the user
    * @notice : You will get the liquidation bonus for taking users funds 
    * @notice : this function assumes  that this protocal is overcollateralize by 200% in order  this to wok
    */
    function liquidate(address collateral, address user , uint256 debtToCover) external moreThenZero(debtToCover) nonReentrant {
        //cheak the health factor of the user
        uint256 startingUserHealthFactor=_healthFactor(user);
        //burn the DSC
        if(startingUserHealthFactor>=MIN_HEALTH_FACTOR){
            revert DSCEngine__HealhFactorOk();
        }

        // we want to burn thier debt DSC and take thier collateral
        // Bad user $140 ETH , $100 DSC
        // debtToCover=100
        // 100 of DSC  = ?? ETH
        // .05ETH

        uint256 tokenAmountFromDebtCovered=getTokenAmountFromUsd(collateral, debtToCover);
        //and we should give 10% bonus
            // so we should give $110 for 100DSC
            uint256 bonusCollateral=(tokenAmountFromDebtCovered*LIQUIDATION_BONUS)/LIQUIDATION_PRECISION;
            uint256 totalCollateralToRedeem=tokenAmountFromDebtCovered+bonusCollateral;
            _redeemCollateral(user,msg.sender,collateral,totalCollateralToRedeem);
             // we need to burn the dsc
             _burnDsc(debtToCover,user,msg.sender);

             uint256 endingUserHealthFactor=_healthFactor(user);
             if(endingUserHealthFactor<=startingUserHealthFactor){
                 revert DSCEngine__healthFactorNotImprove();
             }
             _revertIfHealthFactorIsBroken(msg.sender);

    }

    function getHealthFactor() external view {
        
    }
    //////////////////////////////////////
    //   Private & Internal Functions  //
    //////////////////////////////////////
    /*
    * @dev low-level internal  function, do not call unless the function calling is checking for the health factor being broken  
    */
    function _burnDsc(uint256 amountDscToBurn ,address onBehalfOf, address dscFrom)private{
        s_DscMinted[onBehalfOf]-=amountDscToBurn;
        bool success=i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success){
            revert DSCEngine__MintFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
function _redeemCollateral(
    address from ,
    address to,
    address tokenCollateralAddress,
    uint256 amountCollateral
    ) private {
            s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralReedemed(from,to, tokenCollateralAddress, amountCollateral);
        bool sucess=IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!sucess){
            revert DSCEngine_TransferFailed();
        }
}

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collatearlValueInUsd)
    {
        totalDscMinted=s_DscMinted[user];
        collatearlValueInUsd=getAccountCollateralValue(user);
    }
    /*
    * Returns how close to liquidation user is
    * if user goes go below 1 then they get liquidated 
    */
    function _healthFactor(address user) private view returns(uint256){
        // total Dsc minted
        // Total collateral Value
         (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
         // we want to go over collateralize
        //  return (collateralValueInUsd/totalDscMinted);
        uint256 collateralAjustedForThreshold=(collateralValueInUsd*LIQUIDATION_THRESHOLD)/LIQUIDATION_PRECISION;
        //1000 ETH  * 50=50000/100=500
        //$150 ETH/100 DCS=1.5
        // 150*50=7500/100=75  this is below 100
        // second example
        // 1000 ETH / 100DSC
        //1000*50=50000/100=500/100=5>1
        return (collateralAjustedForThreshold*PRECISION)/totalDscMinted;         
    }
    function _revertIfHealthFactorIsBroken(address user)internal view {
    // 1. Check the health factor (do they have enough collateral)
    //  2. Revert if they dont have good health factor
        uint256 userHealthFactor=_healthFactor(user);
        if(userHealthFactor<MIN_HEALTH_FACTOR){
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }
     //////////////////////////////////////
    //   Public, External & View Functions  //
    //////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 amountInWei) public view returns(uint256){
        AggregatorV3Interface priceFeed= AggregatorV3Interface(s_priceFeeds[token]);
            (,int256 price,,,) = priceFeed.latestRoundData();
            return ((amountInWei*PRECISION)/uint256(price)*ADDITIONAL_FEED_PRECISION);    
            
    }
    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        //loop through each collateral token ,get the amount they deposit and map it to 
        // the price , to get USD value
        uint256 i;
        for( i =0;i<s_collateralTokens.length;i++){
            address token=s_collateralTokens[ i];
            uint256 amount=s_collateralDeposited[user][token];
           totalCollateralValueInUsd+=getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }   
    function getUsdValue(address token, uint256 amount) public view returns(uint256 ){
        AggregatorV3Interface priceFeed= AggregatorV3Interface(s_priceFeeds[token]);
            (,int256 price,,,) = priceFeed.latestRoundData();
            return ((uint256 (price)*ADDITIONAL_FEED_PRECISION)* amount)/PRECISION;    
    }
}
