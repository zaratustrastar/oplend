// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV21, PMFIPositionVaultV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

contract BoundaryMockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PMFIOpLendingV21BoundaryTest is TestBase {
    BoundaryMockERC20 internal usdc;
    BoundaryMockERC20 internal collateral;

    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;

    address internal borrower = makeAddr("boundaryBorrower");
    address internal lender = makeAddr("boundaryLender");
    address internal feeRecipient = makeAddr("boundaryFeeRecipient");

    uint256 internal constant ONE = 1e18;
    uint256 internal constant CREATION_FEE = 0.0001 ether;

    function setUp() public {
        usdc = new BoundaryMockERC20("USD Coin", "USDC", 6);
        collateral = new BoundaryMockERC20("Collateral", "COL", 18);

        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000_000 * ONE);
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(lender, 1_000_000e6);

        vm.deal(borrower, 10 ether);
    }

    function _defaultParams(uint256 collateralAmount, uint256 raiseUsdc, uint256 repaymentUsdc)
        internal
        view
        returns (PMFIPositionFactoryV21.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: collateralAmount,
            targetRaiseUsdc: raiseUsdc,
            totalRepaymentUsdc: repaymentUsdc,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI COL",
            symbolPrefix: "pCOL"
        });
    }

    function _create(uint256 collateralAmount, uint256 raiseUsdc, uint256 repaymentUsdc)
        internal
        returns (PMFIPositionVaultV21 vault, uint256 saleId)
    {
        PMFIPositionFactoryV21.CreatePositionParams memory params =
            _defaultParams(collateralAmount, raiseUsdc, repaymentUsdc);

        vm.startPrank(borrower);
        collateral.approve(address(factory), collateralAmount);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(uint256 saleId, uint256 pAmount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, pAmount);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        marketplace.buy(saleId, pAmount, totalPayment);
        vm.stopPrank();
    }

    function test_RevertWhen_CreationFeeIsWrong() public {
        uint256 amount = 100 * ONE;

        PMFIPositionFactoryV21.CreatePositionParams memory params = _defaultParams(amount, 100e6, 120e6);

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        vm.expectRevert(PMFIPositionFactoryV21.WrongCreationFee.selector);
        factory.createPosition{value: 0}(params);

        vm.expectRevert(PMFIPositionFactoryV21.WrongCreationFee.selector);
        factory.createPosition{value: CREATION_FEE + 1}(params);

        vm.stopPrank();
    }

    function test_FundingPeriodMinimumBoundaryIsAccepted() public {
        uint256 amount = 100 * ONE;

        PMFIPositionFactoryV21.CreatePositionParams memory params = _defaultParams(amount, 100e6, 120e6);

        params.fundingDeadline = block.timestamp + factory.MIN_FUNDING_PERIOD();

        params.repaymentDeadline = params.fundingDeadline + 30 days;

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        (address vaultAddress,) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        assertTrue(factory.isVault(vaultAddress));
    }

    function test_RevertWhen_FundingPeriodIsBelowMinimum() public {
        uint256 amount = 100 * ONE;

        PMFIPositionFactoryV21.CreatePositionParams memory params = _defaultParams(amount, 100e6, 120e6);

        params.fundingDeadline = block.timestamp + factory.MIN_FUNDING_PERIOD() - 1;

        params.repaymentDeadline = params.fundingDeadline + 30 days;

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        vm.expectRevert(PMFIPositionFactoryV21.BadDeadlines.selector);
        factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();
    }

    function test_SaleExpiresAtExactFundingDeadline() public {
        uint256 amount = 100 * ONE;

        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        vm.stopPrank();

        vm.warp(vault.fundingDeadline());

        vm.expectRevert(PMFIPrimaryMarketplaceV21.SaleExpired.selector);
        vm.prank(lender);
        marketplace.buy(saleId, amount, totalPayment);

        marketplace.closeExpired(saleId);

        assertTrue(vault.fundingClosed());
        assertTrue(vault.closedWithoutOutstandingP());
        assertEq(vault.P().totalSupply(), 0);
        assertEq(vault.N().totalSupply(), 0);
    }

    function test_ExerciseAllowedAtDeadlineButRejectedAfter() public {
        uint256 amount = 2 * ONE;

        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 2e6, 3e6);

        _buy(saleId, amount);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 3e6);

        vm.warp(vault.repaymentDeadline());
        vault.exercise(ONE);

        assertEq(vault.exercisedN(), ONE);
        assertEq(vault.usdcPaid(), 1_500_000);

        vm.warp(vault.repaymentDeadline() + 1);

        vm.expectRevert(PMFIPositionVaultV21.RepaymentClosed.selector);
        vault.exercise(ONE);

        vm.stopPrank();
    }

    function test_SettleRequiresDeadlinePlusOneAndDirectRedeemWorks() public {
        uint256 amount = 100 * ONE;

        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        _buy(saleId, amount);

        vm.warp(vault.repaymentDeadline());

        vm.expectRevert(PMFIPositionVaultV21.TooEarly.selector);
        vault.settle();

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        assertTrue(vault.settled());

        vm.prank(lender);
        vault.redeemP(amount);

        assertEq(vault.P().totalSupply(), 0);
        assertEq(collateral.balanceOf(lender), amount);
    }

    function test_FeeWithdrawalsAreRestrictedAndExact() public {
        uint256 amount = 100 * ONE;

        (, uint256 saleId) = _create(amount, 100e6, 120e6);

        assertEq(address(factory).balance, CREATION_FEE);

        vm.expectRevert(PMFIPositionFactoryV21.OnlyFeeRecipient.selector);
        factory.withdrawCreationFees();

        vm.prank(feeRecipient);
        factory.withdrawCreationFees();

        assertEq(address(factory).balance, 0);
        assertEq(feeRecipient.balance, CREATION_FEE);

        _buy(saleId, amount);

        uint256 protocolFee = marketplace.accruedProtocolFees();
        assertEq(protocolFee, 100_000);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.OnlyFeeRecipient.selector);
        marketplace.withdrawProtocolFees();

        vm.prank(feeRecipient);
        marketplace.withdrawProtocolFees();

        assertEq(marketplace.accruedProtocolFees(), 0);
        assertEq(usdc.balanceOf(feeRecipient), protocolFee);
    }

    function test_LegAddressesMatchTokenGetters() public {
        (PMFIPositionVaultV21 vault,) = _create(100 * ONE, 100e6, 120e6);

        (address pToken, address nToken) = vault.legAddresses();

        assertEq(pToken, address(vault.P()));
        assertEq(nToken, address(vault.N()));
    }
}
