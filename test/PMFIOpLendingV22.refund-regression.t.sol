// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22RefundToken is ERC20 {
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

contract V22RefundBlockingCollateral is V22RefundToken {
    address public blockedSender;
    bool public blocked;

    error OutboundBlocked();

    constructor() V22RefundToken("V2.2 Blocking Collateral", "V22BC", 18) {}

    function configure(address sender, bool value) external {
        blockedSender = sender;
        blocked = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked && from == blockedSender && from != address(0) && to != address(0)) {
            revert OutboundBlocked();
        }

        super._update(from, to, value);
    }
}

contract PMFIOpLendingV22RefundRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;

    V22RefundToken internal usdc;
    V22RefundBlockingCollateral internal collateral;
    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22RefundBorrower");
    address internal lender = makeAddr("v22RefundLender");
    address internal feeRecipient = makeAddr("v22RefundFees");

    function setUp() public {
        usdc = new V22RefundToken("USD Coin", "USDC", 6);
        collateral = new V22RefundBlockingCollateral();

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));
        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);
        usdc.mint(lender, 1_000e6);
        vm.deal(borrower, 1 ether);
    }

    function _create() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 REFUND",
            symbolPrefix: "V22R"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), 100 * ONE);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(uint256 saleId, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        marketplace.buy(saleId, amount, totalPayment);
        vm.stopPrank();
    }

    function test_BlockedCollateralDoesNotBlockCancellation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();
        _buy(saleId, 40 * ONE);

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        collateral.configure(address(vault), true);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);

        // Closing records a claim and performs no outbound collateral transfer.
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(collateral.balanceOf(address(vault)), 100 * ONE);
    }

    function test_BlockedCollateralDoesNotBlockExpiredClosure() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();
        _buy(saleId, 40 * ONE);

        collateral.configure(address(vault), true);
        vm.warp(vault.fundingDeadline());

        marketplace.closeExpired(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 100 * ONE);
    }

    function test_FailedRefundClaimRemainsSafelyClaimable() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();
        _buy(saleId, 40 * ONE);

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        // Cancellation must only record the 60-token claim.
        assertTrue(vault.fundingClosed());
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(collateral.balanceOf(address(vault)), 100 * ONE);

        collateral.configure(address(vault), true);

        vm.prank(borrower);
        (bool blockedClaimSucceeded,) =
            address(vault).call(abi.encodeWithSignature("claimCollateralRefund(address)", borrower));

        assertFalse(blockedClaimSucceeded);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(collateral.balanceOf(address(vault)), 100 * ONE);

        collateral.configure(address(vault), false);

        vm.prank(borrower);
        (bool retrySucceeded,) =
            address(vault).call(abi.encodeWithSignature("claimCollateralRefund(address)", borrower));

        assertTrue(retrySucceeded);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore + 60 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);

        // The same refund cannot be claimed twice.
        vm.prank(borrower);
        (bool duplicateClaimSucceeded,) =
            address(vault).call(abi.encodeWithSignature("claimCollateralRefund(address)", borrower));

        assertFalse(duplicateClaimSucceeded);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore + 60 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);
    }

    function test_CancellationAfterPartialPurchaseRemainsAllowed() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        _buy(saleId, 40 * ONE);

        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore + 40e6);
        assertEq(vault.P().balanceOf(lender), 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(vault.pairedN(), 60 * ONE);
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);
        assertEq(vault.P().balanceOf(lender), 40 * ONE);
        assertEq(vault.N().balanceOf(borrower), 40 * ONE);

        // Funds already raised from the partial purchase remain with borrower.
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore + 40e6);
    }
}
