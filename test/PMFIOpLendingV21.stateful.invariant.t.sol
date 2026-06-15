// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    PMFILegTokenV21,
    PMFIPositionFactoryV21,
    PMFIPositionVaultV21,
    PMFIPrimaryMarketplaceV21
} from "../src/PMFIOpLendingV21.sol";

contract StatefulMockERC20 is ERC20 {
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

contract PMFILifecycleHandler is TestBase {
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

    PMFIPositionVaultV21 public immutable vault;
    PMFIPrimaryMarketplaceV21 public immutable marketplace;
    StatefulMockERC20 public immutable usdc;
    PMFILegTokenV21 public immutable pToken;
    PMFILegTokenV21 public immutable nToken;

    uint256 public immutable saleId;
    address public immutable borrower;

    address[] internal actors;

    bool public ghostFundingClosed;
    bool public ghostSettled;

    uint256 public buyCalls;
    uint256 public cancelCalls;
    uint256 public closeExpiredCalls;
    uint256 public transferPCalls;
    uint256 public transferNCalls;
    uint256 public redeemPairCalls;
    uint256 public exerciseCalls;
    uint256 public settleCalls;
    uint256 public redeemPCalls;
    uint256 public ghostRedeemedP;
    uint256 public advanceTimeCalls;

    modifier syncState() {
        _;
        if (vault.fundingClosed()) ghostFundingClosed = true;
        if (vault.settled()) ghostSettled = true;
    }

    constructor(
        PMFIPositionVaultV21 vault_,
        PMFIPrimaryMarketplaceV21 marketplace_,
        StatefulMockERC20 usdc_,
        uint256 saleId_,
        address borrower_,
        address[] memory actors_
    ) {
        vault = vault_;
        marketplace = marketplace_;
        usdc = usdc_;
        saleId = saleId_;
        borrower = borrower_;
        actors = actors_;

        pToken = vault_.P();
        nToken = vault_.N();
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
        ) return;

        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, s.amountRemaining);

        (uint256 sellerPrice,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        // Tiny partial fills can round the seller payment down to zero.
        // Such a generated action is invalid and must be skipped.
        if (sellerPrice == 0 || totalPayment == 0) return;
        if (usdc.balanceOf(actor) < totalPayment) return;

        buyCalls++;

        vm.prank(actor);
        marketplace.buy(saleId, amount, totalPayment);
    }

    function cancel() external syncState {
        SaleSnapshot memory s = _sale();
        if (!s.active) return;

        cancelCalls++;

        vm.prank(borrower);
        marketplace.cancel(saleId);
    }

    function closeExpired(uint256 actorSeed) external syncState {
        SaleSnapshot memory s = _sale();

        if (!s.active || block.timestamp < s.expiry) return;

        closeExpiredCalls++;

        vm.prank(_actor(actorSeed));
        marketplace.closeExpired(saleId);
    }

    function advanceTime(uint256 seed) external syncState {
        uint256 maximumTimestamp = vault.repaymentDeadline() + 2 days;

        if (block.timestamp >= maximumTimestamp) return;

        uint256 maximumDelta = maximumTimestamp - block.timestamp;
        uint256 delta = bound(seed, 1, maximumDelta);

        advanceTimeCalls++;
        vm.warp(block.timestamp + delta);
    }

    function transferP(uint256 amountSeed, uint256 fromSeed, uint256 toSeed) external syncState {
        uint256 fromIndex = fromSeed % actors.length;
        address from = actors[fromIndex];
        address to = _otherActor(fromIndex, toSeed);

        uint256 balance = pToken.balanceOf(from);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);

        transferPCalls++;

        vm.prank(from);
        pToken.transfer(to, amount);
    }

    function transferN(uint256 amountSeed, uint256 fromSeed, uint256 toSeed) external syncState {
        if (!nToken.transfersEnabled()) return;

        uint256 fromIndex = fromSeed % actors.length;
        address from = actors[fromIndex];
        address to = _otherActor(fromIndex, toSeed);

        uint256 balance = nToken.balanceOf(from);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);

        transferNCalls++;

        vm.prank(from);
        nToken.transfer(to, amount);
    }

    function redeemPair(uint256 amountSeed, uint256 actorSeed) external syncState {
        if (!vault.fundingClosed() || vault.settled()) return;

        address actor = _actor(actorSeed);

        uint256 pBalance = pToken.balanceOf(actor);
        uint256 nBalance = nToken.balanceOf(actor);
        uint256 maximum = pBalance < nBalance ? pBalance : nBalance;

        if (maximum == 0) return;

        uint256 amount = bound(amountSeed, 1, maximum);

        redeemPairCalls++;

        vm.prank(actor);
        vault.redeemPair(amount);
    }

    function exercise(uint256 amountSeed, uint256 actorSeed) external syncState {
        if (!vault.fundingClosed() || vault.settled() || block.timestamp > vault.repaymentDeadline()) return;

        address actor = _actor(actorSeed);
        uint256 nBalance = nToken.balanceOf(actor);

        if (nBalance == 0) return;

        uint256 amount = bound(amountSeed, 1, nBalance);
        uint256 owed = vault.usdcOwed(amount);

        if (owed == 0) {
            amount = nBalance;
            owed = vault.usdcOwed(amount);
        }

        if (owed == 0 || usdc.balanceOf(actor) < owed) return;

        exerciseCalls++;

        vm.prank(actor);
        vault.exercise(amount);
    }

    function settle(uint256 actorSeed) external syncState {
        if (!vault.fundingClosed() || vault.settled() || pToken.totalSupply() == 0) return;

        if (!vault.canSettleEarly() && block.timestamp <= vault.repaymentDeadline()) return;

        settleCalls++;

        vm.prank(_actor(actorSeed));
        vault.settle();
    }

    function redeemP(uint256 amountSeed, uint256 actorSeed) external syncState {
        if (!vault.settled()) return;

        address actor = _actor(actorSeed);
        uint256 balance = pToken.balanceOf(actor);

        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);

        redeemPCalls++;

        vm.prank(actor);
        vault.redeemP(amount);

        ghostRedeemedP += amount;
    }
}

contract PMFIOpLendingV21StatefulInvariantTest is TestBase {
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

    StatefulMockERC20 internal usdc;
    StatefulMockERC20 internal collateral;

    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;
    PMFIPositionVaultV21 internal vault;
    PMFILifecycleHandler internal handler;

    PMFILegTokenV21 internal pToken;
    PMFILegTokenV21 internal nToken;

    address internal borrower = makeAddr("statefulBorrower");
    address internal lender1 = makeAddr("statefulLender1");
    address internal lender2 = makeAddr("statefulLender2");
    address internal trader = makeAddr("statefulTrader");
    address internal feeRecipient = makeAddr("statefulFeeRecipient");

    address[] internal actors;

    uint256 internal saleId;

    uint256 internal constant INITIAL_COLLATERAL = 1_000e18;
    uint256 internal constant TARGET_RAISE = 1_000e6;
    uint256 internal constant TOTAL_REPAYMENT = 1_234_567_891;
    uint256 internal constant ACTOR_USDC = 10_000e6;

    uint256 internal initialUsdcSupply;

    function setUp() public {
        usdc = new StatefulMockERC20("USD Coin", "USDC", 6);
        collateral = new StatefulMockERC20("Collateral", "COL", 18);

        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        actors.push(borrower);
        actors.push(lender1);
        actors.push(lender2);
        actors.push(trader);

        collateral.mint(borrower, INITIAL_COLLATERAL);
        vm.deal(borrower, 10 ether);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: INITIAL_COLLATERAL,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI STATE",
            symbolPrefix: "pSTATE"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), INITIAL_COLLATERAL);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = createdSaleId;
        pToken = vault.P();
        nToken = vault.N();

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            usdc.mint(actor, ACTOR_USDC);

            vm.startPrank(actor);
            usdc.approve(address(marketplace), type(uint256).max);
            usdc.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        initialUsdcSupply = ACTOR_USDC * actors.length;

        handler = new PMFILifecycleHandler(vault, marketplace, usdc, saleId, borrower, actors);
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
        for (uint256 i = 0; i < actors.length; i++) {
            total += token.balanceOf(actors[i]);
        }
    }

    function invariant_NAccountingAlwaysBalances() public view {
        assertEq(vault.pairedN() + vault.exercisedN() + nToken.totalSupply(), INITIAL_COLLATERAL);
    }

    function invariant_PSupplyMatchesOutstandingClaims() public view {
        uint256 outstandingPBeforeRedemption = INITIAL_COLLATERAL - vault.pairedN();

        if (!vault.settled()) {
            assertEq(pToken.totalSupply(), outstandingPBeforeRedemption);
        } else {
            assertEq(vault.pSupplyAtSettle(), outstandingPBeforeRedemption);

            assertEq(pToken.totalSupply() + handler.ghostRedeemedP(), vault.pSupplyAtSettle());
        }
    }

    function invariant_AllLegTokensRemainWithKnownAddresses() public view {
        uint256 knownP = _sumActorBalance(pToken) + pToken.balanceOf(address(marketplace));

        uint256 knownN = _sumActorBalance(nToken);

        assertEq(knownP, pToken.totalSupply());
        assertEq(knownN, nToken.totalSupply());
    }

    function invariant_CollateralIsConserved() public view {
        uint256 knownCollateral = _sumActorBalance(collateral) + collateral.balanceOf(address(vault));

        assertEq(knownCollateral, INITIAL_COLLATERAL);
    }

    function invariant_UsdcIsConserved() public view {
        uint256 knownUsdc = _sumActorBalance(usdc) + usdc.balanceOf(address(vault))
            + usdc.balanceOf(address(marketplace)) + usdc.balanceOf(feeRecipient);

        assertEq(knownUsdc, initialUsdcSupply);
    }

    function invariant_MarketplaceAccountingIsConsistent() public view {
        SaleSnapshot memory s = _sale();

        assertEq(s.vault, address(vault));
        assertEq(s.seller, borrower);
        assertEq(address(s.pToken), address(pToken));
        assertEq(s.amountInitial, INITIAL_COLLATERAL);
        assertEq(s.usdcTotal, TARGET_RAISE);

        assertLe(s.amountRemaining, s.amountInitial);
        assertLe(s.usdcRemaining, s.usdcTotal);
        assertLe(s.usdcRaisedToSeller, s.usdcTotal);

        uint256 expectedFee = (s.usdcRaisedToSeller * marketplace.SALE_FEE_BPS()) / marketplace.BPS_DENOMINATOR();

        assertEq(s.feeAccrued, expectedFee);
        assertEq(marketplace.accruedProtocolFees(), s.feeAccrued);
        assertEq(usdc.balanceOf(address(marketplace)), s.feeAccrued);

        if (s.active) {
            assertFalse(vault.fundingClosed());

            assertEq(s.amountRemaining, pToken.balanceOf(address(marketplace)));

            assertEq(s.usdcRaisedToSeller + s.usdcRemaining, s.usdcTotal);
        } else {
            assertTrue(vault.fundingClosed());
            assertEq(s.amountRemaining, 0);
            assertEq(s.usdcRemaining, 0);
            assertEq(pToken.balanceOf(address(marketplace)), 0);
        }
    }

    function invariant_VaultBackingAndRepaymentRemainValid() public view {
        assertLe(vault.usdcPaid(), vault.repaymentRequiredUsdc());

        if (!vault.settled()) {
            assertEq(collateral.balanceOf(address(vault)) + vault.exercisedN(), pToken.totalSupply());

            assertEq(usdc.balanceOf(address(vault)), vault.usdcPaid());
        } else {
            assertTrue(vault.fundingClosed());
            assertTrue(vault.pSupplyAtSettle() > 0);

            assertLe(pToken.totalSupply(), vault.pSupplyAtSettle());

            assertLe(collateral.balanceOf(address(vault)), vault.collateralPoolAtSettle());

            assertLe(usdc.balanceOf(address(vault)), vault.usdcPoolAtSettle());
        }

        if (vault.closedWithoutOutstandingP()) {
            assertEq(pToken.totalSupply(), 0);
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
    }
}
