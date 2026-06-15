# V2.1 security review status

## Applied in code

- OpenZeppelin ERC20, Ownable2Step, SafeERC20, ReentrancyGuard, and Math.
- Checks-effects-interactions ordering on value-moving functions.
- `nonReentrant` on factory creation, vault exits, marketplace buys/closes, and fee withdrawals.
- Exact balance-delta checks for collateral and USDC transfers.
- Official immutable USDC per deployment; USDC decimals must equal 6.
- Collateral code, decimal, zero-address, amount, deadline, and prefix validation.
- Collateral allowlist on by default.
- Verified-vault-only marketplace registration.
- Marketplace derives P, borrower, amount, target price, and expiry from the vault.
- N transfers disabled during funding.
- One vault / one borrower / one initialization.
- Cumulative repayment and fee accounting with final-action dust settlement.
- Partial fill and cancellation accounting.
- Limited pause scope: only new positions and buys.
- Exit paths remain available while paused.
- Two-step ownership transfer.
- No oracle, DEX price, delegatecall, selfdestruct, proxy, or arbitrary external execution.
- Events for material state transitions.
- Runtime bytecode size checked below the EIP-170 limit with Solidity 0.8.24, optimizer 200, viaIR false.

## Validation completed here

- Solidity 0.8.24 compilation succeeded with optimizer enabled, 200 runs, viaIR false.
- Source and Foundry tests compile successfully. Test-contract size warnings are irrelevant because test contracts are not deployed to production.
- Local Ganache lifecycle checks passed for:
  - full funding;
  - split repayment with exact cumulative collection;
  - early settlement;
  - partial funding and cancellation;
  - automatic unfunded collateral refund;
  - pro-rata repayment after partial funding;
  - split purchases with cumulative fee accounting.

## Still required before deployment

- Execute the Foundry unit/fuzz/invariant suites with native Forge.
- Run at least 10,000 fuzz iterations.
- Run Slither with native solc/Foundry and resolve findings.
- Add Base fork tests using the real official USDC contract.
- Test fee-on-transfer, rebasing, pausable, blocklisting, false-return, no-return, and malicious ERC20 behavior.
- Separate independent security review or audit.
- Deploy to Base Sepolia first and test with two or more wallets.
- Verify source code on the explorer.
- Transfer owner and fee recipient roles to a Safe multisig before production.

## Residual design risks

- Collateral token behavior cannot be made safe for every arbitrary ERC20. Keep the allowlist enabled.
- A blocked borrower cannot receive USDC sale proceeds; a blocked lender may not redeem USDC.
- A negative rebase can make collateral insufficient.
- Permissionless maintenance calls rely on economically interested users or a keeper.
- Tiny N fragments may need aggregation due to 6-decimal USDC precision.
- Pausing is a trust assumption; ownership should be disclosed and controlled by multisig.
