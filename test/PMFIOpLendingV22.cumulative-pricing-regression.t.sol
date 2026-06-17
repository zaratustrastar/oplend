// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22CumulativePricingToken is ERC20 {
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

contract PMFIOpLendingV22CumulativePricingRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 6 * ONE;
    uint256 internal constant TARGET_RAISE = 10;
    uint256 internal constant TOTAL_REPAYMENT = 11;

    V22CumulativePricingToken internal usdc;
    V22CumulativePricingToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22CumulativeBorrower");

    address internal lender = makeAddr("v22CumulativeLender");

    address internal feeRecipient = makeAddr("v22CumulativeFees");

    function setUp() public {
        usdc = new V22CumulativePricingToken("USD Coin", "USDC", 6);

        collateral = new V22CumulativePricingToken("V2.2 Cumulative Collateral", "V22CUM", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 100 * ONE);
        usdc.mint(lender, 1_000);

        vm.deal(borrower, 1 ether);
    }

    function _create() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 CUMULATIVE",
            symbolPrefix: "V22CUM"
        });

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

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

    function _cancel(uint256 saleId) internal {
        vm.prank(borrower);
        marketplace.cancel(saleId);
    }

    function test_FragmentedPartialFillsCollectCumulativeSellerPrice() public {
        (, uint256 saleId) = _create();

        uint256 borrowerBefore = usdc.balanceOf(borrower);

        _buy(saleId, ONE);
        _buy(saleId, ONE);
        _buy(saleId, ONE);

        uint256 raised = usdc.balanceOf(borrower) - borrowerBefore;

        // floor(10 × 3 / 6) = 5.
        assertEq(raised, 5);

        _cancel(saleId);
    }

    function test_QuoteSequenceUsesCumulativeSellerEntitlement() public {
        (, uint256 saleId) = _create();

        // Cumulative targets after 1, 2 and 3 sold units
        // are floor(10/6)=1, floor(20/6)=3 and
        // floor(30/6)=5. Incremental quotes are 1, 2, 2.
        assertEq(marketplace.quoteUsdc(saleId, ONE), 1);

        _buy(saleId, ONE);

        assertEq(marketplace.quoteUsdc(saleId, ONE), 2);

        _buy(saleId, ONE);

        assertEq(marketplace.quoteUsdc(saleId, ONE), 2);

        _cancel(saleId);
    }

    function test_SplitAndSinglePartialFillsRaiseSameAmount() public {
        (, uint256 singleSaleId) = _create();

        uint256 beforeSingle = usdc.balanceOf(borrower);

        _buy(singleSaleId, 3 * ONE);

        uint256 singleRaised = usdc.balanceOf(borrower) - beforeSingle;

        _cancel(singleSaleId);

        (, uint256 splitSaleId) = _create();

        uint256 beforeSplit = usdc.balanceOf(borrower);

        _buy(splitSaleId, ONE);
        _buy(splitSaleId, ONE);
        _buy(splitSaleId, ONE);

        uint256 splitRaised = usdc.balanceOf(borrower) - beforeSplit;

        assertEq(singleRaised, 5);
        assertEq(splitRaised, singleRaised);

        _cancel(splitSaleId);
    }

    function test_FragmentedFullFillStillCollectsExactTarget() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        uint256 borrowerBefore = usdc.balanceOf(borrower);

        for (uint256 i = 0; i < 6; i++) {
            _buy(saleId, ONE);
        }

        assertEq(usdc.balanceOf(borrower) - borrowerBefore, TARGET_RAISE);

        assertTrue(vault.fundingClosed());
        assertEq(vault.P().totalSupply(), COLLATERAL_AMOUNT);
    }
}
