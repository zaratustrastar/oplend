// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22Pass2OutboundFeeToken is ERC20 {
    enum OutboundMode {
        None,
        RecipientTax,
        SenderSurcharge
    }

    uint8 private immutable _tokenDecimals;

    address public feeSender;
    OutboundMode public outboundMode;
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureOutboundFee(address sender, OutboundMode mode, uint256 bps) external {
        feeSender = sender;
        outboundMode = mode;
        feeBps = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        bool applyFee = from != address(0) && to != address(0) && from == feeSender && outboundMode != OutboundMode.None;

        if (!applyFee) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * feeBps / 10_000;

        if (fee == 0 || outboundMode == OutboundMode.None) {
            super._update(from, to, amount);
            return;
        }

        if (outboundMode == OutboundMode.RecipientTax) {
            super._update(from, address(0), fee);

            super._update(from, to, amount - fee);

            return;
        }

        super._update(from, to, amount);

        super._update(from, address(0), fee);
    }
}

contract PMFIOpLendingV22ManualReviewPass2RegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;

    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    uint256 internal constant TARGET_RAISE = 100e6;

    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    uint256 internal constant DONATION = 1e6;

    address internal borrower = makeAddr("v22Pass2Borrower");

    address internal lender = makeAddr("v22Pass2Lender");

    address internal feeRecipient = makeAddr("v22Pass2FeeRecipient");

    function _deployAndCreate()
        internal
        returns (
            V22Pass2OutboundFeeToken usdc,
            V22Pass2OutboundFeeToken collateral,
            PMFIPositionFactoryV22 factory,
            PMFIPrimaryMarketplaceV22 marketplace,
            PMFIPositionVaultV22 vault,
            uint256 saleId
        )
    {
        usdc = new V22Pass2OutboundFeeToken("USD Coin", "USDC", 6);

        collateral = new V22Pass2OutboundFeeToken("Collateral", "COL", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(lender, 1_000e6);

        vm.deal(borrower, 10 ether);

        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 PASS2",
            symbolPrefix: "V22P2"
        });

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;

        vm.prank(lender);

        usdc.approve(address(marketplace), type(uint256).max);
    }

    function _quote(PMFIPrimaryMarketplaceV22 marketplace, uint256 saleId)
        internal
        view
        returns (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment)
    {
        return marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);
    }

    function _buyNormally(PMFIPrimaryMarketplaceV22 marketplace, uint256 saleId)
        internal
        returns (uint256 sellerPrice, uint256 feeAmount)
    {
        uint256 totalPayment;

        (sellerPrice, feeAmount, totalPayment) = _quote(marketplace, saleId);

        vm.prank(lender);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);
    }

    function _saleAccounting(PMFIPrimaryMarketplaceV22 marketplace, uint256 saleId)
        internal
        view
        returns (
            uint256 amountRemaining,
            uint256 usdcRemaining,
            uint256 usdcRaisedToSeller,
            uint256 feeAccrued,
            bool active
        )
    {
        (,,,, amountRemaining,, usdcRemaining, usdcRaisedToSeller, feeAccrued,, active) = marketplace.sales(saleId);
    }

    function _assertInitialSaleState(
        V22Pass2OutboundFeeToken usdc,
        PMFIPrimaryMarketplaceV22 marketplace,
        PMFIPositionVaultV22 vault,
        uint256 saleId
    ) internal view {
        assertEq(usdc.balanceOf(borrower), 0);

        assertEq(vault.P().balanceOf(lender), 0);

        assertEq(vault.P().balanceOf(address(marketplace)), COLLATERAL_AMOUNT);

        assertEq(marketplace.accruedProtocolFees(), 0);

        (uint256 amountRemaining, uint256 usdcRemaining, uint256 raised, uint256 feeAccrued, bool active) =
            _saleAccounting(marketplace, saleId);

        assertEq(amountRemaining, COLLATERAL_AMOUNT);

        assertEq(usdcRemaining, TARGET_RAISE);

        assertEq(raised, 0);

        assertEq(feeAccrued, 0);

        assertTrue(active);
    }

    function test_SellerRecipientTaxCannotUnderpayOrAdvanceSale() public {
        (
            V22Pass2OutboundFeeToken usdc,,,
            PMFIPrimaryMarketplaceV22 marketplace,
            PMFIPositionVaultV22 vault,
            uint256 saleId
        ) = _deployAndCreate();

        (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) = _quote(marketplace, saleId);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.RecipientTax, 100);

        vm.prank(lender);

        (bool bought,) = address(marketplace)
            .call(
                abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, COLLATERAL_AMOUNT, totalPayment)
            );

        assertFalse(bought);

        _assertInitialSaleState(usdc, marketplace, vault, saleId);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.None, 0);

        vm.prank(lender);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        assertEq(usdc.balanceOf(borrower), sellerPrice);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);
    }

    function test_SellerSenderSurchargeCannotConsumeProtocolFees() public {
        (
            V22Pass2OutboundFeeToken usdc,,,
            PMFIPrimaryMarketplaceV22 marketplace,
            PMFIPositionVaultV22 vault,
            uint256 saleId
        ) = _deployAndCreate();

        (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) = _quote(marketplace, saleId);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.SenderSurcharge, 5);

        vm.prank(lender);

        (bool bought,) = address(marketplace)
            .call(
                abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, COLLATERAL_AMOUNT, totalPayment)
            );

        assertFalse(bought);

        _assertInitialSaleState(usdc, marketplace, vault, saleId);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.None, 0);

        vm.prank(lender);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        assertEq(usdc.balanceOf(borrower), sellerPrice);

        assertEq(usdc.balanceOf(address(marketplace)), feeAmount);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);
    }

    function test_FeeWithdrawalRecipientTaxRemainsRetryable() public {
        (V22Pass2OutboundFeeToken usdc,,, PMFIPrimaryMarketplaceV22 marketplace,, uint256 saleId) = _deployAndCreate();

        (, uint256 feeAmount) = _buyNormally(marketplace, saleId);

        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        uint256 marketplaceBefore = usdc.balanceOf(address(marketplace));

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.RecipientTax, 100);

        vm.prank(feeRecipient);

        (bool withdrawn,) =
            address(marketplace).call(abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.withdrawProtocolFees.selector));

        assertFalse(withdrawn);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);

        assertEq(usdc.balanceOf(feeRecipient), recipientBefore);

        assertEq(usdc.balanceOf(address(marketplace)), marketplaceBefore);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.None, 0);

        vm.prank(feeRecipient);

        marketplace.withdrawProtocolFees();

        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, feeAmount);

        assertEq(marketplace.accruedProtocolFees(), 0);
    }

    function test_FeeWithdrawalSenderSurchargeCannotConsumeDonation() public {
        (V22Pass2OutboundFeeToken usdc,,, PMFIPrimaryMarketplaceV22 marketplace,, uint256 saleId) = _deployAndCreate();

        (, uint256 feeAmount) = _buyNormally(marketplace, saleId);

        usdc.mint(address(marketplace), DONATION);

        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        uint256 marketplaceBefore = usdc.balanceOf(address(marketplace));

        assertEq(marketplaceBefore, feeAmount + DONATION);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.SenderSurcharge, 100);

        vm.prank(feeRecipient);

        (bool withdrawn,) =
            address(marketplace).call(abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.withdrawProtocolFees.selector));

        assertFalse(withdrawn);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);

        assertEq(usdc.balanceOf(feeRecipient), recipientBefore);

        assertEq(usdc.balanceOf(address(marketplace)), marketplaceBefore);

        usdc.configureOutboundFee(address(marketplace), V22Pass2OutboundFeeToken.OutboundMode.None, 0);

        vm.prank(feeRecipient);

        marketplace.withdrawProtocolFees();

        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, feeAmount);

        assertEq(usdc.balanceOf(address(marketplace)), DONATION);

        assertEq(marketplace.accruedProtocolFees(), 0);
    }
}
