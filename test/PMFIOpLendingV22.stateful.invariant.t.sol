// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22StatefulMockERC20 is ERC20 {
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

contract PMFIV22LifecycleHandler is TestBase {
    struct SaleSnapshot {
        address vault;
        address seller;
        IERC20Metadata pToken;
        uint256 amountInitial;
        uint256 amountRemaining;
        uint256 usdcTotal;
        uint256 usdcRemaining;
        uint256 usdcRaisedToSeller;
        uint256 feeAccrued;
        uint256 expiry;
        bool active;
    }

    PMFIPositionVaultV22 public immutable vault;

    PMFIPrimaryMarketplaceV22 public immutable marketplace;

    V22StatefulMockERC20 public immutable usdc;
    V22StatefulMockERC20 public immutable collateral;

    ERC20 public immutable pToken;
    ERC20 public immutable nToken;

    uint256 public immutable saleId;
    address public immutable borrower;

    address[] internal actors;

    bool public ghostFundingClosed;
    bool public ghostSettled;

    uint256 public ghostPurchasedP;
    uint256 public ghostPairRedeemedP;
    uint256 public ghostRedeemedP;

    uint256 public ghostRefundClaimed;
    uint256 public ghostFullRepaymentUsdc;

    uint256 public ghostCollateralDonated;
    uint256 public ghostUsdcDonated;

    uint256 public buyCalls;
    uint256 public cancelCalls;
    uint256 public closeExpiredCalls;
    uint256 public advanceTimeCalls;
    uint256 public transferPCalls;
    uint256 public redeemPairCalls;
    uint256 public repayInFullCalls;
    uint256 public claimRefundCalls;
    uint256 public settleCalls;
    uint256 public redeemPCalls;
    uint256 public donateCollateralCalls;
    uint256 public donateUsdcCalls;

    modifier syncState() {
        _;

        if (vault.fundingClosed()) {
            ghostFundingClosed = true;
        }

        if (vault.settled()) {
            ghostSettled = true;
        }
    }

    constructor(
        PMFIPositionVaultV22 vault_,
        PMFIPrimaryMarketplaceV22 marketplace_,
        V22StatefulMockERC20 usdc_,
        V22StatefulMockERC20 collateral_,
        uint256 saleId_,
        address borrower_,
        address[] memory actors_
    ) {
        vault = vault_;
        marketplace = marketplace_;
        usdc = usdc_;
        collateral = collateral_;
        saleId = saleId_;
        borrower = borrower_;
        actors = actors_;

        pToken = ERC20(address(vault_.P()));

        nToken = ERC20(address(vault_.N()));
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _otherActor(uint256 fromIndex, uint256 seed) internal view returns (address) {
        uint256 offset = 1 + (seed % (actors.length - 1));

        return actors[(fromIndex + offset) % actors.length];
    }

    function _sale() internal view returns (SaleSnapshot memory s) {
        (bool success, bytes memory data) =
            address(marketplace).staticcall(abi.encodeWithSignature("sales(uint256)", saleId));

        require(success, "sales getter failed");

        s = abi.decode(data, (SaleSnapshot));
    }

    function buy(uint256 amountSeed, uint256 actorSeed) external syncState {
        SaleSnapshot memory s = _sale();

        if (
            !s.active || block.timestamp >= s.expiry || vault.fundingClosed() || vault.settled()
                || s.amountRemaining == 0
        ) {
            return;
        }

        address actor = _actor(actorSeed);

        uint256 amount = bound(amountSeed, 1, s.amountRemaining);

        (uint256 sellerPrice,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        if (sellerPrice == 0 || totalPayment == 0 || usdc.balanceOf(actor) < totalPayment) {
            return;
        }

        vm.prank(actor);

        marketplace.buy(saleId, amount, totalPayment);

        ghostPurchasedP += amount;
        buyCalls++;
    }

    function cancel() external syncState {
        SaleSnapshot memory s = _sale();

        if (!s.active) {
            return;
        }

        vm.prank(borrower);

        marketplace.cancel(saleId);

        cancelCalls++;
    }

    function closeExpired(uint256 actorSeed) external syncState {
        SaleSnapshot memory s = _sale();

        if (!s.active || block.timestamp < s.expiry) {
            return;
        }

        vm.prank(_actor(actorSeed));

        marketplace.closeExpired(saleId);

        closeExpiredCalls++;
    }

    function advanceTime(uint256 seed) external syncState {
        uint256 maximumTimestamp = vault.repaymentDeadline() + 2 days;

        if (block.timestamp >= maximumTimestamp) {
            return;
        }

        uint256 maximumDelta = maximumTimestamp - block.timestamp;

        uint256 delta = bound(seed, 1, maximumDelta);

        vm.warp(block.timestamp + delta);

        advanceTimeCalls++;
    }

    function transferP(uint256 amountSeed, uint256 fromSeed, uint256 toSeed) external syncState {
        uint256 fromIndex = fromSeed % actors.length;

        address from = actors[fromIndex];

        address to = _otherActor(fromIndex, toSeed);

        uint256 balance = pToken.balanceOf(from);

        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(from);

        bool transferred = pToken.transfer(to, amount);

        require(transferred, "P transfer failed");

        transferPCalls++;
    }

    function redeemPair(uint256 amountSeed) external syncState {
        if (!vault.fundingClosed() || vault.settled()) {
            return;
        }

        uint256 pBalance = pToken.balanceOf(borrower);

        uint256 nBalance = nToken.balanceOf(borrower);

        uint256 maximum = pBalance < nBalance ? pBalance : nBalance;

        if (maximum == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, maximum);

        vm.prank(borrower);

        vault.redeemPair(amount);

        ghostPairRedeemedP += amount;
        redeemPairCalls++;
    }

    function repayInFull() external syncState {
        if (!vault.fundingClosed() || vault.settled() || block.timestamp > vault.repaymentDeadline()) {
            return;
        }

        uint256 nSupply = nToken.totalSupply();

        uint256 pSupply = pToken.totalSupply();

        if (
            nSupply == 0 || pSupply == 0 || nToken.balanceOf(borrower) != nSupply
                || vault.accountedCollateral() != nSupply || vault.exercisedN() != 0 || vault.usdcPaid() != 0
        ) {
            return;
        }

        uint256 required = vault.repaymentRequiredUsdc();

        if (required == 0 || usdc.balanceOf(borrower) < required) {
            return;
        }

        vm.prank(borrower);

        vault.repayInFull();

        ghostFullRepaymentUsdc = required;

        repayInFullCalls++;
    }

    function claimCollateralRefund(uint256 recipientSeed) external syncState {
        uint256 claim = vault.collateralRefundClaim();

        if (claim == 0) {
            return;
        }

        address recipient = _actor(recipientSeed);

        vm.prank(borrower);

        vault.claimCollateralRefund(recipient);

        ghostRefundClaimed += claim;
        claimRefundCalls++;
    }

    function settle(uint256 actorSeed) external syncState {
        if (!vault.fundingClosed() || vault.settled() || pToken.totalSupply() == 0) {
            return;
        }

        if (!vault.canSettleEarly() && block.timestamp <= vault.repaymentDeadline()) {
            return;
        }

        vm.prank(_actor(actorSeed));

        vault.settle();

        settleCalls++;
    }

    function redeemP(uint256 amountSeed, uint256 actorSeed) external syncState {
        if (!vault.settled()) {
            return;
        }

        address actor = _actor(actorSeed);

        uint256 balance = pToken.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(actor);

        vault.redeemP(amount);

        ghostRedeemedP += amount;
        redeemPCalls++;
    }

    function donateCollateral(uint256 amountSeed, uint256 actorSeed) external syncState {
        address actor = _actor(actorSeed);

        uint256 balance = collateral.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(actor);

        bool transferred = collateral.transfer(address(vault), amount);

        require(transferred, "collateral donation failed");

        ghostCollateralDonated += amount;

        donateCollateralCalls++;
    }

    function donateUsdc(uint256 amountSeed, uint256 actorSeed) external syncState {
        address actor = _actor(actorSeed);

        uint256 balance = usdc.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(actor);

        bool transferred = usdc.transfer(address(vault), amount);

        require(transferred, "USDC donation failed");

        ghostUsdcDonated += amount;
        donateUsdcCalls++;
    }
}

contract PMFIOpLendingV22StatefulInvariantTest is TestBase {
    struct SaleSnapshot {
        address vault;
        address seller;
        IERC20Metadata pToken;
        uint256 amountInitial;
        uint256 amountRemaining;
        uint256 usdcTotal;
        uint256 usdcRemaining;
        uint256 usdcRaisedToSeller;
        uint256 feeAccrued;
        uint256 expiry;
        bool active;
    }

    V22StatefulMockERC20 internal usdc;
    V22StatefulMockERC20 internal collateral;

    PMFIPositionFactoryV22 internal factory;

    PMFIPrimaryMarketplaceV22 internal marketplace;

    PMFIPositionVaultV22 internal vault;

    PMFIV22LifecycleHandler internal handler;

    ERC20 internal pToken;
    ERC20 internal nToken;

    address internal borrower = makeAddr("v22StatefulBorrower");

    address internal lender1 = makeAddr("v22StatefulLender1");

    address internal lender2 = makeAddr("v22StatefulLender2");

    address internal trader = makeAddr("v22StatefulTrader");

    address internal feeRecipient = makeAddr("v22StatefulFees");

    address[] internal actors;

    uint256 internal saleId;

    uint256 internal constant INITIAL_COLLATERAL = 1_000e18;

    uint256 internal constant ACTOR_COLLATERAL_RESERVE = 100e18;

    uint256 internal constant TARGET_RAISE = 1_000_000_003;

    uint256 internal constant TOTAL_REPAYMENT = 1_234_567_891;

    uint256 internal constant ACTOR_USDC = 10_000e6;

    uint256 internal initialCollateralSupply;

    uint256 internal initialUsdcSupply;

    function setUp() public {
        usdc = new V22StatefulMockERC20("USD Coin", "USDC", 6);

        collateral = new V22StatefulMockERC20("V2.2 Stateful Collateral", "V22STATE", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        actors.push(borrower);
        actors.push(lender1);
        actors.push(lender2);
        actors.push(trader);

        collateral.mint(borrower, INITIAL_COLLATERAL);

        for (uint256 index = 0; index < actors.length; index++) {
            address actor = actors[index];

            collateral.mint(actor, ACTOR_COLLATERAL_RESERVE);

            usdc.mint(actor, ACTOR_USDC);
        }

        vm.deal(borrower, 10 ether);

        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: INITIAL_COLLATERAL,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 STATEFUL",
            symbolPrefix: "V22S"
        });

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), INITIAL_COLLATERAL);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;

        pToken = ERC20(address(vault.P()));

        nToken = ERC20(address(vault.N()));

        for (uint256 index = 0; index < actors.length; index++) {
            address actor = actors[index];

            vm.startPrank(actor);

            usdc.approve(address(marketplace), type(uint256).max);

            usdc.approve(address(vault), type(uint256).max);

            vm.stopPrank();
        }

        initialCollateralSupply = collateral.totalSupply();

        initialUsdcSupply = usdc.totalSupply();

        handler = new PMFIV22LifecycleHandler(vault, marketplace, usdc, collateral, saleId, borrower, actors);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);

        targets[0] = address(handler);
    }

    function _sale() internal view returns (SaleSnapshot memory s) {
        (bool success, bytes memory data) =
            address(marketplace).staticcall(abi.encodeWithSignature("sales(uint256)", saleId));

        require(success, "sales getter failed");

        s = abi.decode(data, (SaleSnapshot));
    }

    function _sumActorBalance(ERC20 token) internal view returns (uint256 total) {
        for (uint256 index = 0; index < actors.length; index++) {
            total += token.balanceOf(actors[index]);
        }
    }

    function invariant_NAccountingAndCustody() public view {
        assertEq(vault.pairedN() + vault.exercisedN() + nToken.totalSupply(), INITIAL_COLLATERAL);

        assertEq(nToken.balanceOf(borrower), nToken.totalSupply());

        for (uint256 index = 0; index < actors.length; index++) {
            address actor = actors[index];

            if (actor != borrower) {
                assertEq(nToken.balanceOf(actor), 0);
            }
        }

        assertEq(nToken.balanceOf(address(marketplace)), 0);

        assertEq(nToken.balanceOf(address(vault)), 0);
    }

    function invariant_PSupplyMatchesClaims() public view {
        assertEq(pToken.totalSupply() + handler.ghostRedeemedP() + vault.pairedN(), INITIAL_COLLATERAL);

        if (vault.settled()) {
            assertEq(vault.pSupplyAtSettle() + vault.pairedN(), INITIAL_COLLATERAL);

            assertEq(pToken.totalSupply() + handler.ghostRedeemedP(), vault.pSupplyAtSettle());
        }
    }

    function invariant_AllLegTokensRemainKnown() public view {
        uint256 knownP = _sumActorBalance(pToken) + pToken.balanceOf(address(marketplace));

        uint256 knownN = _sumActorBalance(nToken);

        assertEq(knownP, pToken.totalSupply());

        assertEq(knownN, nToken.totalSupply());
    }

    function invariant_TokenConservationAndBacking() public view {
        uint256 knownCollateral = _sumActorBalance(collateral) + collateral.balanceOf(address(vault));

        assertEq(knownCollateral, initialCollateralSupply);

        uint256 knownUsdc = _sumActorBalance(usdc) + usdc.balanceOf(address(vault))
            + usdc.balanceOf(address(marketplace)) + usdc.balanceOf(feeRecipient);

        assertEq(knownUsdc, initialUsdcSupply);

        assertEq(
            collateral.balanceOf(address(vault)),
            vault.accountedCollateral() + vault.collateralRefundClaim() + handler.ghostCollateralDonated()
        );

        uint256 trackedVaultUsdc = vault.settled() ? vault.usdcPoolRemaining() : vault.usdcPaid();

        assertEq(usdc.balanceOf(address(vault)), trackedVaultUsdc + handler.ghostUsdcDonated());
    }

    function invariant_MarketplaceCumulativeAccounting() public view {
        SaleSnapshot memory s = _sale();

        assertEq(s.vault, address(vault));

        assertEq(s.seller, borrower);

        assertEq(address(s.pToken), address(pToken));

        assertEq(s.amountInitial, INITIAL_COLLATERAL);

        assertEq(s.usdcTotal, TARGET_RAISE);

        uint256 purchased = handler.ghostPurchasedP();

        assertLe(purchased, INITIAL_COLLATERAL);

        uint256 expectedRaised = Math.mulDiv(TARGET_RAISE, purchased, INITIAL_COLLATERAL);

        assertEq(s.usdcRaisedToSeller, expectedRaised);

        uint256 expectedFee = Math.mulDiv(expectedRaised, marketplace.SALE_FEE_BPS(), marketplace.BPS_DENOMINATOR());

        assertEq(s.feeAccrued, expectedFee);

        assertEq(marketplace.accruedProtocolFees(), expectedFee);

        assertEq(usdc.balanceOf(address(marketplace)), expectedFee);

        if (s.active) {
            assertFalse(vault.fundingClosed());

            assertEq(s.amountRemaining, INITIAL_COLLATERAL - purchased);

            assertEq(s.usdcRemaining, TARGET_RAISE - expectedRaised);

            assertEq(pToken.balanceOf(address(marketplace)), s.amountRemaining);
        } else {
            assertTrue(vault.fundingClosed());

            assertEq(s.amountRemaining, 0);

            assertEq(s.usdcRemaining, 0);

            assertEq(pToken.balanceOf(address(marketplace)), 0);

            uint256 unsold = INITIAL_COLLATERAL - purchased;

            assertEq(vault.collateralRefundClaim() + handler.ghostRefundClaimed(), unsold);

            assertEq(vault.pairedN(), unsold + handler.ghostPairRedeemedP());
        }
    }

    function invariant_BinarySettlementAndRepayment() public view {
        uint256 required = vault.repaymentRequiredUsdc();

        assertLe(vault.usdcPaid(), required);

        assertLe(handler.repayInFullCalls(), 1);

        assertLe(handler.claimRefundCalls(), 1);

        if (handler.repayInFullCalls() == 0) {
            assertEq(vault.usdcPaid(), 0);

            assertEq(handler.ghostFullRepaymentUsdc(), 0);
        } else {
            assertEq(handler.ghostFullRepaymentUsdc(), required);

            assertEq(vault.usdcPaid(), required);

            assertEq(nToken.totalSupply(), 0);

            assertEq(vault.accountedCollateral(), 0);

            assertTrue(vault.exercisedN() > 0);
        }

        if (vault.settled()) {
            assertTrue(vault.fundingClosed());

            assertTrue(vault.pSupplyAtSettle() > 0);

            bool hasCollateralPool = vault.collateralPoolAtSettle() > 0;

            bool hasUsdcPool = vault.usdcPoolAtSettle() > 0;

            assertTrue(hasCollateralPool != hasUsdcPool);

            assertLe(vault.accountedCollateral(), vault.collateralPoolAtSettle());

            assertLe(vault.usdcPoolRemaining(), vault.usdcPoolAtSettle());

            if (hasUsdcPool) {
                assertEq(vault.collateralPoolAtSettle(), 0);

                assertEq(vault.usdcPoolAtSettle(), vault.usdcPaid());

                assertEq(vault.accountedCollateral(), 0);

                assertTrue(vault.exercisedN() > 0);
            } else {
                assertEq(vault.usdcPoolAtSettle(), 0);

                assertEq(vault.usdcPaid(), 0);

                assertEq(vault.exercisedN(), 0);

                assertEq(vault.collateralPoolAtSettle(), vault.pSupplyAtSettle());
            }
        }
    }

    function invariant_DonationsCreateNoClaims() public view {
        assertLe(vault.collateralPoolAtSettle(), INITIAL_COLLATERAL);

        assertLe(vault.usdcPoolAtSettle(), TOTAL_REPAYMENT);

        if (!vault.settled()) {
            assertEq(vault.collateralPoolAtSettle(), 0);

            assertEq(vault.usdcPoolAtSettle(), 0);

            assertEq(vault.usdcPoolRemaining(), 0);
        }
    }

    function invariant_ClosedStatesNeverReopen() public view {
        if (handler.ghostFundingClosed()) {
            assertTrue(vault.fundingClosed());
        }

        if (handler.ghostSettled()) {
            assertTrue(vault.settled());
        }

        if (vault.settled()) {
            assertTrue(vault.fundingClosed());
        }

        if (vault.closedWithoutOutstandingP()) {
            assertEq(pToken.totalSupply(), 0);
        }
    }
}
