// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV21, PMFIPositionVaultV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

interface ICircleUsdc is IERC20Metadata {
    function masterMinter() external view returns (address);

    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);

    function mint(address to, uint256 amount) external returns (bool);

    function isMinter(address account) external view returns (bool);

    function minterAllowance(address minter) external view returns (uint256);
}

contract BaseForkCollateral is ERC20 {
    constructor() ERC20("Base Fork Collateral", "BFORK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PMFIOpLendingV21BaseForkTest is TestBase {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 internal constant BASE_CHAIN_ID = 8453;

    uint256 internal constant COLLATERAL_AMOUNT = 100e18;
    uint256 internal constant TARGET_RAISE = 100e6;
    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    address internal borrower = makeAddr("baseForkBorrower");
    address internal lender = makeAddr("baseForkLender");
    address internal feeRecipient = makeAddr("baseForkFeeRecipient");

    ICircleUsdc internal usdc;
    BaseForkCollateral internal collateral;
    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;

    function _skipWithoutBaseFork() internal {
        vm.skip(block.chainid != BASE_CHAIN_ID || BASE_USDC.code.length == 0);
    }

    function _deployProtocolAgainstBaseUsdc() internal {
        usdc = ICircleUsdc(BASE_USDC);

        assertEq(block.chainid, BASE_CHAIN_ID);
        assertTrue(BASE_USDC.code.length > 0);
        assertEq(usdc.decimals(), 6);

        factory = new PMFIPositionFactoryV21(IERC20Metadata(BASE_USDC), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());

        assertEq(address(factory.USDC()), BASE_USDC);
        assertEq(address(marketplace.USDC()), BASE_USDC);

        collateral = new BaseForkCollateral();
        factory.setCollateralAllowed(address(collateral), true);
    }

    function _mintForkUsdc() internal {
        address masterMinter = usdc.masterMinter();

        assertTrue(masterMinter != address(0));

        vm.prank(masterMinter);
        bool configured = usdc.configureMinter(address(this), 2_000e6);

        assertTrue(configured);
        assertTrue(usdc.isMinter(address(this)));
        assertEq(usdc.minterAllowance(address(this)), 2_000e6);

        assertTrue(usdc.mint(lender, 1_000e6));
        assertTrue(usdc.mint(borrower, 20e6));
    }

    function test_Fork_OfficialBaseUsdcMetadataAndBindings() public {
        _skipWithoutBaseFork();
        _deployProtocolAgainstBaseUsdc();

        assertEq(usdc.decimals(), 6);
        assertEq(address(factory.USDC()), BASE_USDC);
        assertEq(address(marketplace.USDC()), BASE_USDC);
        assertEq(factory.CREATION_FEE(), 0.0001 ether);
    }

    function test_Fork_FullLifecycleWithOfficialBaseUsdc() public {
        _skipWithoutBaseFork();
        _deployProtocolAgainstBaseUsdc();
        _mintForkUsdc();

        collateral.mint(borrower, COLLATERAL_AMOUNT);
        vm.deal(borrower, 1 ether);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI BASE",
            symbolPrefix: "pBASE"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 saleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        PMFIPositionVaultV21 vault = PMFIPositionVaultV21(vaultAddress);

        assertEq(address(vault.usdc()), BASE_USDC);
        assertEq(collateral.balanceOf(address(vault)), COLLATERAL_AMOUNT);
        assertEq(address(factory).balance, factory.CREATION_FEE());

        (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) =
            marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        assertEq(sellerPrice, TARGET_RAISE);
        assertEq(feeAmount, (TARGET_RAISE * marketplace.SALE_FEE_BPS()) / marketplace.BPS_DENOMINATOR());
        assertEq(totalPayment, sellerPrice + feeAmount);

        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        vm.stopPrank();

        assertTrue(vault.fundingClosed());
        assertEq(vault.P().balanceOf(lender), COLLATERAL_AMOUNT);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore + sellerPrice);
        assertEq(marketplace.accruedProtocolFees(), feeAmount);
        assertEq(usdc.balanceOf(address(marketplace)), feeAmount);

        vm.startPrank(borrower);
        usdc.approve(address(vault), TOTAL_REPAYMENT);
        vault.exercise(COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(vault.N().totalSupply(), 0);
        assertEq(vault.usdcPaid(), TOTAL_REPAYMENT);
        assertEq(usdc.balanceOf(address(vault)), TOTAL_REPAYMENT);
        assertEq(collateral.balanceOf(borrower), COLLATERAL_AMOUNT);
        assertTrue(vault.canSettleEarly());

        vm.prank(lender);
        vault.settleAndRedeemP(COLLATERAL_AMOUNT);

        assertTrue(vault.settled());
        assertEq(vault.P().totalSupply(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(collateral.balanceOf(address(vault)), 0);

        assertEq(usdc.balanceOf(lender), lenderUsdcBefore - totalPayment + TOTAL_REPAYMENT);

        vm.prank(feeRecipient);
        marketplace.withdrawProtocolFees();

        assertEq(usdc.balanceOf(feeRecipient), feeAmount);
        assertEq(marketplace.accruedProtocolFees(), 0);
        assertEq(usdc.balanceOf(address(marketplace)), 0);

        vm.prank(feeRecipient);
        factory.withdrawCreationFees();

        assertEq(feeRecipient.balance, factory.CREATION_FEE());
        assertEq(address(factory).balance, 0);
    }
}
