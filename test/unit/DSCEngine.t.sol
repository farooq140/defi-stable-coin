// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { Test, console } from "forge-std/Test.sol";
import{HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
contract DSCEngineTest is Test {
    HelperConfig config;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    
    address ethUsdPriceFeed;
    address weth;
    address user=makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine,config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
    }
 ///////////////////////
//////// Price Tests //
///////////////////////

function testGetUsdValue() public {
    uint256 ethAmount=15e18;
    // 15 * 2000 = 30000
    uint256 expectedUsd = 30000e18;
    uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
    assertEq(expectedUsd, actualUsd);
}
/////////////////////////////////////
//// Deposit Collateral Tests /////
////////////////////////////////////
function testRevertIfCollateralZero() public {
    vm.startPrank(user);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThenZero.selector)  ; 
    engine.depositCollateral(weth, 0);
    vm.stopPrank();
}

}