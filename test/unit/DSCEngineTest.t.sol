//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFromToken.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";


contract DSCEngineTest is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;
    DeployDsc deployer;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public amountToMint ;
    function setUp() public {
        deployer = new DeployDsc();

        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = helperConfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] token;
    address[] priceFeedAddresses;

    //////constructor test///////

    function testRevertIfTokenAddressesAreNotEqual() public {
        token.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(
            DSCEngine
                .DSCEngine_TokenAddressLengthNotMatchPriceFeedAdressesLength
                .selector
        );
        new DSCEngine(token, priceFeedAddresses, address(dsce));
    }

    //////price test////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedValue = 30000e18;
        uint256 actualValue = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedValue, actualValue);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 2000 ether;
        uint256 expectedValue = 1 ether;
        uint256 actualValue = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedValue, actualValue);
    }

    ////////deposit collateral///////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnApprovedCollateral() public {
        ERC20Mock fanToken = new ERC20Mock(
            "FAN",
            "FAN",
            USER,
            AMOUNT_COLLATERAL
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressNotAllowed.selector);
        dsce.depositCollateral(address(fanToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositAmountAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalCollateralValueInUsd, uint256 totalDscMinted) = dsce
            .getAccountInfo(USER);
        uint256 expectedTotalCollateralValue = dsce.getTokenAmountFromUsd(
            weth,
            totalCollateralValueInUsd
        );
        uint256 expectedTotalDscMinted = 0;
        assertEq(expectedTotalCollateralValue, AMOUNT_COLLATERAL);
        assertEq(expectedTotalDscMinted, totalDscMinted);
    }
    function testRevertsIfTransferFromFails() public {
        //arrange setup
        address owner =msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        token = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(token, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER,AMOUNT_COLLATERAL);
        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    function testCanDepositCollateralWithoutMinting() public depositedCollateral{
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance,0);
        
    }
    ////////deposit collateralandmintdsc test///////

    /*function testRevertsIfMintDscBreaksHealthFactor() public{
        (,int256 price,,,)=MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint=(AMOUNT_COLLATERAL*(uint256(price))*dsce.getPrecisionFeed())/dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(USER);
       

    }*/
}
