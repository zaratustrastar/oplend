// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22FuzzToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PMFIOpLendingV22FuzzTest is TestBase {
    uint256 internal constant ONE = 1e18;

    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    // Deliberately non-round values exercise cumulative rounding.
    uint256 internal constant TARGET_RAISE = 100_000_003;

    uint256 internal constant TOTAL_REPAYMENT = 120_000_007;

    V22FuzzToken internal usdc;
    V22FuzzToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22FuzzBorrower");

    address internal lender1 = makeAddr("v22FuzzLender1");

    address internal lender2 = makeAddr("v22FuzzLender2");

    address internal feeRecipient = makeAddr("v22FuzzFees");

    function setUp() public {
        usdc = new V22FuzzToken("USD Coin", "USDC", 6);

        collateral = new V22FuzzToken("V2.2 Fuzz Collateral", "V22FUZZ", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 20_000 * ONE);

        usdc.mint(borrower, 20_000e6);

        usdc.mint(lender1, 20_000e6);

        usdc.mint(lender2, 20_000e6);

        vm.deal(borrower, 100 ether);
    }

    function _create() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 FUZZ",
            symbolPrefix: "V22F"
        });

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;
    }

    function _buy(uint256 saleId, address buyer, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(buyer);

        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, amount, totalPayment);

        vm.stopPrank();
    }

    function _cancel(uint256 saleId) internal {
        vm.prank(borrower);
        marketplace.cancel(saleId);
    }

    function testFuzz_SplitPurchasesMatchSinglePurchase(uint8 totalSeed, uint8 splitSeed) public {
        uint256 totalTokens = bound(uint256(totalSeed), 2, 99);

        uint256 firstTokens = bound(uint256(splitSeed), 1, totalTokens - 1);

        uint256 totalAmount = totalTokens * ONE;

        uint256 firstAmount = firstTokens * ONE;

        uint256 secondAmount = totalAmount - firstAmount;

        (, uint256 singleSaleId) = _create();

        uint256 borrowerBeforeSingle = usdc.balanceOf(borrower);

        uint256 feesBeforeSingle = marketplace.accruedProtocolFees();

        _buy(singleSaleId, lender1, totalAmount);

        uint256 singleSellerProceeds = usdc.balanceOf(borrower) - borrowerBeforeSingle;

        uint256 singleFee = marketplace.accruedProtocolFees() - feesBeforeSingle;

        uint256 expectedSellerProceeds = Math.mulDiv(TARGET_RAISE, totalAmount, COLLATERAL_AMOUNT);

        assertEq(singleSellerProceeds, expectedSellerProceeds);

        _cancel(singleSaleId);

        (, uint256 splitSaleId) = _create();

        uint256 borrowerBeforeSplit = usdc.balanceOf(borrower);

        uint256 feesBeforeSplit = marketplace.accruedProtocolFees();

        _buy(splitSaleId, lender1, firstAmount);

        _buy(splitSaleId, lender2, secondAmount);

        uint256 splitSellerProceeds = usdc.balanceOf(borrower) - borrowerBeforeSplit;

        uint256 splitFee = marketplace.accruedProtocolFees() - feesBeforeSplit;

        assertEq(splitSellerProceeds, singleSellerProceeds);

        assertEq(splitFee, singleFee);

        _cancel(splitSaleId);
    }

    function testFuzz_PartialCancellationAccounting(uint8 soldSeed) public {
        uint256 soldTokens = bound(uint256(soldSeed), 1, 99);

        uint256 soldAmount = soldTokens * ONE;

        uint256 unsoldAmount = COLLATERAL_AMOUNT - soldAmount;

        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, soldAmount);

        _cancel(saleId);

        assertTrue(vault.fundingClosed());

        assertEq(vault.collateralRefundClaim(), unsoldAmount);

        assertEq(vault.accountedCollateral(), soldAmount);

        assertEq(vault.P().totalSupply(), soldAmount);

        assertEq(vault.N().totalSupply(), soldAmount);

        uint256 borrowerBeforeClaim = collateral.balanceOf(borrower);

        vm.prank(borrower);

        vault.claimCollateralRefund(borrower);

        assertEq(collateral.balanceOf(borrower) - borrowerBeforeClaim, unsoldAmount);

        assertEq(vault.collateralRefundClaim(), 0);

        assertEq(collateral.balanceOf(address(vault)), soldAmount);
    }

    function testFuzz_DefaultSplitRedemptionsConserveCollateral(uint8 splitSeed) public {
        uint256 lender2Tokens = bound(uint256(splitSeed), 1, 99);

        uint256 lender2Amount = lender2Tokens * ONE;

        uint256 lender1Amount = COLLATERAL_AMOUNT - lender2Amount;

        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);

        IERC20 pToken = IERC20(address(vault.P()));

        vm.prank(lender1);

        assertTrue(pToken.transfer(lender2, lender2Amount));

        vm.warp(vault.repaymentDeadline() + 1);

        vault.settle();

        uint256 lender1Before = collateral.balanceOf(lender1);

        uint256 lender2Before = collateral.balanceOf(lender2);

        vm.prank(lender1);

        vault.redeemP(lender1Amount);

        vm.prank(lender2);

        vault.redeemP(lender2Amount);

        assertEq(collateral.balanceOf(lender1) - lender1Before, lender1Amount);

        assertEq(collateral.balanceOf(lender2) - lender2Before, lender2Amount);

        assertEq(vault.accountedCollateral(), 0);

        assertEq(vault.collateralPoolAtSettle(), COLLATERAL_AMOUNT);

        assertEq(vault.usdcPoolRemaining(), 0);

        assertEq(vault.P().totalSupply(), 0);
    }

    function testFuzz_PartialFundingFullRepaymentConservesUsdc(uint8 soldSeed, uint8 splitSeed) public {
        uint256 soldTokens = bound(uint256(soldSeed), 2, 100);

        uint256 lender2Tokens = bound(uint256(splitSeed), 1, soldTokens - 1);

        uint256 soldAmount = soldTokens * ONE;

        uint256 lender2Amount = lender2Tokens * ONE;

        uint256 lender1Amount = soldAmount - lender2Amount;

        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, soldAmount);

        if (soldAmount < COLLATERAL_AMOUNT) {
            _cancel(saleId);
        }

        IERC20 pToken = IERC20(address(vault.P()));

        vm.prank(lender1);

        assertTrue(pToken.transfer(lender2, lender2Amount));

        uint256 required = vault.repaymentRequiredUsdc();

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);

        vault.repayInFull();

        vm.stopPrank();

        vault.settle();

        uint256 lender1UsdcBefore = usdc.balanceOf(lender1);

        uint256 lender2UsdcBefore = usdc.balanceOf(lender2);

        uint256 lender1CollateralBefore = collateral.balanceOf(lender1);

        uint256 lender2CollateralBefore = collateral.balanceOf(lender2);

        vm.prank(lender1);

        vault.redeemP(lender1Amount);

        vm.prank(lender2);

        vault.redeemP(lender2Amount);

        uint256 totalUsdcReceived =
            (usdc.balanceOf(lender1) - lender1UsdcBefore) + (usdc.balanceOf(lender2) - lender2UsdcBefore);

        assertEq(totalUsdcReceived, required);

        assertEq(collateral.balanceOf(lender1) - lender1CollateralBefore, 0);

        assertEq(collateral.balanceOf(lender2) - lender2CollateralBefore, 0);

        assertEq(vault.usdcPoolRemaining(), 0);

        assertEq(vault.accountedCollateral(), 0);

        assertEq(vault.P().totalSupply(), 0);

        assertEq(vault.N().totalSupply(), 0);

        if (soldAmount < COLLATERAL_AMOUNT) {
            uint256 expectedRefund = COLLATERAL_AMOUNT - soldAmount;

            assertEq(vault.collateralRefundClaim(), expectedRefund);

            uint256 borrowerBeforeClaim = collateral.balanceOf(borrower);

            vm.prank(borrower);

            vault.claimCollateralRefund(borrower);

            assertEq(collateral.balanceOf(borrower) - borrowerBeforeClaim, expectedRefund);

            assertEq(vault.collateralRefundClaim(), 0);
        }
    }
}
