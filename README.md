# PMFI OP-Lending V2.1 — security-hardened draft

## Architecture

One protocol deployment:

- `PMFIPositionFactoryV21`
  - deploys one immutable `PMFIPrimaryMarketplaceV21` in its constructor
  - creates one vault per borrower position
  - charges `0.0001 ETH` per position
  - fixes the official USDC address for that deployment
  - registers verified vaults
  - defaults to an allowlisted collateral policy

Per borrower position, the factory deploys automatically:

- `PMFIPositionVaultV21`
- one transferable P payout token
- one N reclaim token

The borrower does not deploy those contracts manually.

## Main V2.1 changes

- One vault equals one borrower position.
- One initial collateral deposit and one initial P/N mint.
- Full P supply is escrowed in the verified marketplace.
- N cannot transfer while funding is open, so unsold P can always be paired and refunded.
- Marketplace terms are derived from a verified factory vault; users cannot list arbitrary tokens as PMFI P.
- Only the immutable official USDC is accepted.
- Sale expiry is the vault funding deadline.
- Partial fills are supported.
- Cancelling or expiring a partially filled sale atomically burns unsold P + matching N and refunds unfunded collateral.
- Cumulative repayment accounting prevents under-collection when repayment is split across multiple exercises.
- Cumulative marketplace fee accounting prevents fill-splitting fee errors.
- Early repayment is allowed after funding closes.
- Early settlement is allowed only when all remaining N is exercised, P remains outstanding, and exact required USDC has been paid.
- After the final repayment deadline, P holders can settle and redeem USDC, collateral, or a mixture.
- New-position creation and new purchases can be paused; repayment, cancellation, settlement, and redemption are never paused.
- Collateral allowlist is enabled by default. Permissionless collateral must be explicitly enabled by the owner.

## Borrower flow

1. Approve the exact collateral amount to the factory.
2. Call `createPosition(params)` with `0.0001 ETH`.

The second transaction atomically:

1. deploys the vault;
2. transfers collateral;
3. mints P to marketplace escrow;
4. mints N to borrower;
5. registers the verified primary P sale.

If the sale is partially funded, the borrower may cancel it. Unsold P/N is burned and the unfunded collateral is returned in the same transaction.

## Lender flow

1. Read a verified active sale from the marketplace.
2. Call `quoteTotalPayment(saleId, pAmount)`.
3. Approve the exact quoted USDC amount.
4. Call `buy(saleId, pAmount, maxTotalPayment)`.

The lender receives P. The borrower receives the exact seller price. The protocol fee is charged on top and accrued in the marketplace.

## Resolution

- Repay early: N holder approves USDC and calls `exercise(amount)` after funding closes.
- Fully repaid: anyone can call `settle()`, or a P holder calls `settleAndRedeemP(amount)`.
- Default: after `repaymentDeadline`, anyone can call `settle()`, then P holders call `redeemP(amount)`.
- Before settlement, a holder of matching P + N can call `redeemPair(amount)` after funding closes.

## Install and test on VPS

```bash
cd /root
rm -rf pmfi-op-lending-v21
unzip -o pmfi-op-lending-v21.zip -d /root
cd /root/pmfi-op-lending-v21

rm -rf lib
mkdir -p lib

git clone --depth 1 --branch v5.0.2 \
  https://github.com/OpenZeppelin/openzeppelin-contracts.git \
  lib/openzeppelin-contracts

forge fmt --check
forge clean
forge build --sizes
forge test -vvv
forge test --fuzz-runs 10000
```

Run invariant tests with the configured Foundry settings:

```bash
forge test --match-contract PMFIOpLendingV21InvariantTest -vvv
```

Run static analysis before any deployment:

```bash
python3 -m pip install slither-analyzer
slither . --exclude-dependencies
```

Do not continue if Slither reports unresolved reentrancy, unchecked returns, arbitrary delegatecall/selfdestruct, or unprotected state-changing functions.

## Deployment order

Deploy only the factory:

```text
PMFIPositionFactoryV21(
  officialUsdc,
  feeRecipient,
  initialOwner
)
```

The factory constructor deploys its marketplace automatically. Read it with:

```solidity
factory.marketplace()
```

Production recommendations:

- `officialUsdc`: verified USDC address for the selected chain;
- `feeRecipient`: Safe multisig;
- `initialOwner`: Safe multisig;
- keep `permissionlessCollateral == false` initially;
- allowlist only reviewed collateral tokens;
- verify every deployed contract on the block explorer;
- test a full tiny-value lifecycle before opening access.

## Important limitations

- Rebasing, pausable, blocklisting, or malicious collateral can still create operational failures. The allowlist is the primary mitigation.
- USDC itself can pause or blocklist addresses.
- Nothing runs automatically. P holders or a keeper must call `closeExpired` and `settle` when needed.
- N is transferable after funding closes. Extremely small N fragments may quote zero USDC because USDC has 6 decimals; those fragments must be aggregated before exercise.
- Contracts are immutable. Fixes require a new deployment.
- This package is not an audit.
