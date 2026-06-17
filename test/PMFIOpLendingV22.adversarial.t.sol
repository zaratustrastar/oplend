// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22AdversarialToken is ERC20 {
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

/// @dev Legacy-style ERC-20 whose transfer functions return no value.
contract V22NoReturnCollateral {
    string public name = "V2.2 No Return Collateral";
    string public symbol = "V22NORET";
    uint8 public immutable decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 permitted = allowance[from][msg.sender];

        if (permitted != type(uint256).max) {
            allowance[from][msg.sender] = permitted - amount;
        }

        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract V22FalseReturnCollateral is V22AdversarialToken {
    constructor() V22AdversarialToken("V2.2 False Return", "V22FALSE", 18) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract V22FeeOnTransferToken is V22AdversarialToken {
    uint256 public feeBps = 100;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        V22AdversarialToken(name_, symbol_, decimals_)
    {}

    function setFeeBps(uint256 value) external {
        feeBps = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;

            if (fee != 0) {
                super._update(from, address(0), fee);

                super._update(from, to, amount - fee);

                return;
            }
        }

        super._update(from, to, amount);
    }
}

contract V22BlocklistUsdc is V22AdversarialToken {
    mapping(address => bool) public blocked;

    error BlockedAddress();

    constructor() V22AdversarialToken("V2.2 Blocklist USDC", "V22BUSDC", 6) {}

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if ((from != address(0) && blocked[from]) || (to != address(0) && blocked[to])) {
            revert BlockedAddress();
        }

        super._update(from, to, amount);
    }
}

contract V22SlashableCollateral is V22AdversarialToken {
    constructor() V22AdversarialToken("V2.2 Slashable Collateral", "V22SLASH", 18) {}

    function slash(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract PMFIOpLendingV22AdversarialTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    uint256 internal constant TARGET_RAISE = 100e6;

    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    address internal borrower = makeAddr("v22AdversarialBorrower");

    address internal lender = makeAddr("v22AdversarialLender");

    address internal feeRecipient = makeAddr("v22AdversarialFees");

    function setUp() public {
        vm.deal(borrower, 10 ether);
    }

    function _deployFactory(IERC20Metadata usdc)
        internal
        returns (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace)
    {
        factory = new PMFIPositionFactoryV22(usdc, feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());
    }

    function _params(IERC20Metadata collateral, uint256 collateralAmount)
        internal
        view
        returns (PMFIPositionFactoryV22.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: collateral,
            collateralAmount: collateralAmount,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 ADVERSARIAL",
            symbolPrefix: "V22ADV"
        });
    }

    function _createStandard(PMFIPositionFactoryV22 factory, IERC20Metadata collateral, uint256 amount)
        internal
        returns (PMFIPositionVaultV22 vault, uint256 saleId)
    {
        PMFIPositionFactoryV22.CreatePositionParams memory params = _params(collateral, amount);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), amount);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;
    }

    function _buy(PMFIPrimaryMarketplaceV22 marketplace, IERC20Metadata usdc, uint256 saleId, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, amount, totalPayment);

        vm.stopPrank();
    }

    function test_NoReturnCollateralSupportsPullRefundAndDefaultRedemption() public {
        V22AdversarialToken usdc = new V22AdversarialToken("USD Coin", "USDC", 6);

        V22NoReturnCollateral collateral = new V22NoReturnCollateral();

        (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(lender, 1_000e6);

        PMFIPositionFactoryV22.CreatePositionParams memory params =
            _params(IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 saleId) = factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        PMFIPositionVaultV22 vault = PMFIPositionVaultV22(vaultAddress);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());

        assertEq(vault.collateralRefundClaim(), 60 * ONE);

        assertEq(vault.accountedCollateral(), 40 * ONE);

        vm.prank(borrower);

        vault.claimCollateralRefund(borrower);

        assertEq(collateral.balanceOf(borrower), 60 * ONE);

        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);

        assertEq(vault.collateralRefundClaim(), 0);

        vm.warp(vault.repaymentDeadline() + 1);

        vault.settle();

        vm.prank(lender);

        vault.redeemP(40 * ONE);

        assertEq(collateral.balanceOf(lender), 40 * ONE);

        assertEq(collateral.balanceOf(address(vault)), 0);

        assertEq(vault.accountedCollateral(), 0);

        assertEq(vault.P().totalSupply(), 0);
    }

    function test_FalseReturnCollateralIsRejectedAtomically() public {
        V22AdversarialToken usdc = new V22AdversarialToken("USD Coin", "USDC", 6);

        V22FalseReturnCollateral collateral = new V22FalseReturnCollateral();

        (PMFIPositionFactoryV22 factory,) = _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        PMFIPositionFactoryV22.CreatePositionParams memory params =
            _params(IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (bool created,) = address(factory).call{value: creationFee}(
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, params)
        );

        vm.stopPrank();

        assertFalse(created);

        assertEq(collateral.balanceOf(borrower), COLLATERAL_AMOUNT);

        assertEq(factory.allVaultsLength(), 0);
    }

    function test_FeeOnTransferCollateralIsRejectedAtomically() public {
        V22AdversarialToken usdc = new V22AdversarialToken("USD Coin", "USDC", 6);

        V22FeeOnTransferToken collateral = new V22FeeOnTransferToken("Fee Collateral", "V22FEE", 18);

        (PMFIPositionFactoryV22 factory,) = _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        PMFIPositionFactoryV22.CreatePositionParams memory params =
            _params(IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (bool created,) = address(factory).call{value: creationFee}(
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, params)
        );

        vm.stopPrank();

        assertFalse(created);

        assertEq(collateral.balanceOf(borrower), COLLATERAL_AMOUNT);

        assertEq(factory.allVaultsLength(), 0);
    }

    function test_BlocklistedBorrowerMakesPurchaseRevertAtomically() public {
        V22BlocklistUsdc usdc = new V22BlocklistUsdc();

        V22AdversarialToken collateral = new V22AdversarialToken("Collateral", "V22COL", 18);

        (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV22 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) =
            marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        vm.prank(lender);

        usdc.approve(address(marketplace), totalPayment);

        usdc.setBlocked(borrower, true);

        uint256 lenderBefore = usdc.balanceOf(lender);

        vm.prank(lender);

        (bool purchased,) = address(marketplace)
            .call(
                abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, COLLATERAL_AMOUNT, totalPayment)
            );

        assertFalse(purchased);

        assertEq(usdc.balanceOf(lender), lenderBefore);

        assertEq(usdc.balanceOf(address(marketplace)), 0);

        assertEq(usdc.balanceOf(borrower), 0);

        assertEq(marketplace.accruedProtocolFees(), 0);

        assertEq(vault.P().balanceOf(address(marketplace)), COLLATERAL_AMOUNT);

        assertEq(vault.P().balanceOf(lender), 0);

        assertFalse(vault.fundingClosed());

        usdc.setBlocked(borrower, false);

        vm.prank(lender);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        assertEq(usdc.balanceOf(borrower), sellerPrice);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);

        assertTrue(vault.fundingClosed());
    }

    function test_FeeOnTransferUsdcPurchaseRevertsAtomicallyAndCanRetry() public {
        V22FeeOnTransferToken usdc = new V22FeeOnTransferToken("Fee USDC", "V22FUSDC", 6);

        V22AdversarialToken collateral = new V22AdversarialToken("Collateral", "V22COL", 18);

        (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV22 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) =
            marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        vm.prank(lender);

        usdc.approve(address(marketplace), totalPayment);

        uint256 lenderBefore = usdc.balanceOf(lender);

        vm.prank(lender);

        (bool purchased,) = address(marketplace)
            .call(
                abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, COLLATERAL_AMOUNT, totalPayment)
            );

        assertFalse(purchased);

        assertEq(usdc.balanceOf(lender), lenderBefore);

        assertEq(usdc.balanceOf(address(marketplace)), 0);

        assertEq(usdc.balanceOf(borrower), 0);

        assertEq(marketplace.accruedProtocolFees(), 0);

        assertEq(vault.P().balanceOf(address(marketplace)), COLLATERAL_AMOUNT);

        assertFalse(vault.fundingClosed());

        usdc.setFeeBps(0);

        vm.prank(lender);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        assertEq(usdc.balanceOf(borrower), sellerPrice);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);

        assertTrue(vault.fundingClosed());
    }

    function test_SlashedCollateralRedemptionFailsAtomicallyAndCanRetry() public {
        V22AdversarialToken usdc = new V22AdversarialToken("USD Coin", "USDC", 6);

        V22SlashableCollateral collateral = new V22SlashableCollateral();

        (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV22 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, COLLATERAL_AMOUNT);

        collateral.slash(address(vault), 10 * ONE);

        vm.warp(vault.repaymentDeadline() + 1);

        vault.settle();

        vm.prank(lender);

        (bool redeemed,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.redeemP.selector, COLLATERAL_AMOUNT));

        assertFalse(redeemed);

        assertEq(vault.P().balanceOf(lender), COLLATERAL_AMOUNT);

        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(address(vault)), 90 * ONE);

        assertEq(collateral.balanceOf(lender), 0);

        collateral.mint(address(vault), 10 * ONE);

        vm.prank(lender);

        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(lender), COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(address(vault)), 0);

        assertEq(vault.accountedCollateral(), 0);
    }

    function test_BlocklistedUsdcRedemptionFailsAtomicallyAndCanRetry() public {
        V22BlocklistUsdc usdc = new V22BlocklistUsdc();

        V22AdversarialToken collateral = new V22AdversarialToken("Collateral", "V22COL", 18);

        (PMFIPositionFactoryV22 factory, PMFIPrimaryMarketplaceV22 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);

        usdc.mint(borrower, 1_000e6);

        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV22 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), COLLATERAL_AMOUNT);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);

        vault.repayInFull();

        vm.stopPrank();

        vault.settle();

        usdc.setBlocked(lender, true);

        uint256 lenderBefore = usdc.balanceOf(lender);

        vm.prank(lender);

        (bool redeemed,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.redeemP.selector, COLLATERAL_AMOUNT));

        assertFalse(redeemed);

        assertEq(vault.P().balanceOf(lender), COLLATERAL_AMOUNT);

        assertEq(vault.usdcPoolRemaining(), required);

        assertEq(usdc.balanceOf(address(vault)), required);

        assertEq(usdc.balanceOf(lender), lenderBefore);

        usdc.setBlocked(lender, false);

        vm.prank(lender);

        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender) - lenderBefore, required);

        assertEq(vault.usdcPoolRemaining(), 0);

        assertEq(vault.P().totalSupply(), 0);
    }
}
