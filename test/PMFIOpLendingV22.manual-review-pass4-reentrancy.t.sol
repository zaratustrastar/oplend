// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22ReentrantCallbackToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    address public callbackTarget;
    address public callbackFrom;
    address public callbackTo;

    bytes public callbackData;

    bool public callbackEnabled;
    bool public lastCallbackSucceeded;
    bool private _insideCallback;

    uint256 public callbackCount;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function configureCallback(address target, bytes calldata data, address from, address to, bool enabled) external {
        callbackTarget = target;
        callbackData = data;
        callbackFrom = from;
        callbackTo = to;
        callbackEnabled = enabled;

        lastCallbackSucceeded = false;
        callbackCount = 0;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        if (
            !callbackEnabled || _insideCallback || from == address(0) || to == address(0)
                || (callbackFrom != address(0) && from != callbackFrom)
                || (callbackTo != address(0) && to != callbackTo)
        ) {
            return;
        }

        _insideCallback = true;

        (bool succeeded,) = callbackTarget.call(callbackData);

        lastCallbackSucceeded = succeeded;
        callbackCount += 1;

        _insideCallback = false;
    }
}

contract PMFIOpLendingV22ManualReviewPass4ReentrancyTest is TestBase {
    uint256 internal constant ONE = 1e18;

    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    uint256 internal constant TARGET_RAISE = 100e6;

    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    address internal borrower = makeAddr("v22Pass4Borrower");

    address internal lender = makeAddr("v22Pass4Lender");

    address internal feeRecipient = makeAddr("v22Pass4FeeRecipient");

    V22ReentrantCallbackToken internal usdc;
    V22ReentrantCallbackToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;
    PMFIPositionVaultV22 internal vault;

    uint256 internal saleId;

    function setUp() public {
        usdc = new V22ReentrantCallbackToken("USD Coin", "USDC", 6);

        collateral = new V22ReentrantCallbackToken("Collateral", "COL", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);

        usdc.mint(borrower, 1_000e6);

        usdc.mint(lender, 1_000e6);

        vm.deal(borrower, 10 ether);
    }

    function _params() internal view returns (PMFIPositionFactoryV22.CreatePositionParams memory params) {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 PASS4",
            symbolPrefix: "V22P4"
        });
    }

    function _createPosition() internal {
        vm.startPrank(borrower);

        collateral.approve(address(factory), type(uint256).max);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(_params());

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;
    }

    function _buyFull() internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), type(uint256).max);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        vm.stopPrank();
    }

    function test_ReentrantCollateralCannotReenterCreatePosition() public {
        PMFIPositionFactoryV22.CreatePositionParams memory params = _params();

        collateral.configureCallback(
            address(factory),
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, params),
            borrower,
            address(0),
            true
        );

        _createPosition();

        assertEq(collateral.callbackCount(), 1);

        assertFalse(collateral.lastCallbackSucceeded());

        assertEq(factory.allVaultsLength(), 1);

        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
    }

    function test_ReentrantUsdcCannotReenterBuy() public {
        _createPosition();

        (, uint256 feeAmount, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        usdc.configureCallback(
            address(marketplace),
            abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, ONE, type(uint256).max),
            lender,
            address(marketplace),
            true
        );

        _buyFull();

        assertEq(usdc.callbackCount(), 1);

        assertFalse(usdc.lastCallbackSucceeded());

        assertEq(vault.P().balanceOf(lender), COLLATERAL_AMOUNT);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);

        assertTrue(vault.fundingClosed());

        totalPayment;
    }

    function test_ReentrantCollateralCannotReenterRepayInFull() public {
        _createPosition();
        _buyFull();

        uint256 required = vault.repaymentRequiredUsdc();

        collateral.configureCallback(
            address(vault),
            abi.encodeWithSelector(PMFIPositionVaultV22.repayInFull.selector),
            address(vault),
            borrower,
            true
        );

        vm.startPrank(borrower);

        usdc.approve(address(vault), type(uint256).max);

        vault.repayInFull();

        vm.stopPrank();

        assertEq(collateral.callbackCount(), 1);

        assertFalse(collateral.lastCallbackSucceeded());

        assertEq(vault.usdcPaid(), required);

        assertEq(vault.accountedCollateral(), 0);

        assertEq(vault.N().totalSupply(), 0);
    }

    function test_ReentrantCollateralCannotReenterRedeemP() public {
        _createPosition();
        _buyFull();

        vm.warp(vault.repaymentDeadline() + 1);

        vault.settle();

        collateral.configureCallback(
            address(vault),
            abi.encodeWithSelector(PMFIPositionVaultV22.redeemP.selector, ONE),
            address(vault),
            lender,
            true
        );

        uint256 lenderBefore = collateral.balanceOf(lender);

        vm.prank(lender);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(collateral.callbackCount(), 1);

        assertFalse(collateral.lastCallbackSucceeded());

        assertEq(collateral.balanceOf(lender) - lenderBefore, COLLATERAL_AMOUNT);

        assertEq(vault.P().totalSupply(), 0);

        assertEq(vault.accountedCollateral(), 0);
    }

    function test_ReentrantCollateralCannotReenterRedeemPair() public {
        _createPosition();
        _buyFull();

        uint256 pairAmount = 20 * ONE;

        address pToken = address(vault.P());

        vm.prank(lender);

        (bool transferred, bytes memory result) =
            pToken.call(abi.encodeWithSignature("transfer(address,uint256)", borrower, pairAmount));

        assertTrue(transferred);
        assertTrue(abi.decode(result, (bool)));

        collateral.configureCallback(
            address(vault),
            abi.encodeWithSelector(PMFIPositionVaultV22.redeemPair.selector, ONE),
            address(vault),
            borrower,
            true
        );

        uint256 borrowerBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        vault.redeemPair(pairAmount);

        assertEq(collateral.callbackCount(), 1);

        assertFalse(collateral.lastCallbackSucceeded());

        assertEq(collateral.balanceOf(borrower) - borrowerBefore, pairAmount);

        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT - pairAmount);
    }
}
