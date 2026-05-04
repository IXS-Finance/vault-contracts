# PoolDynamic vs TokenizedVaultAsyncWithdrawals

Scope: NAV calculation and redemption flow comparison.

- `PoolDynamic`: [`PoolDynamic.sol`](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol)
- `TokenizedVaultAsyncWithdrawals`: [`TokenizedVaultAsyncWithdrawals.sol`](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol)

## 1) NAV / Pricing Model

### PoolDynamic

- Uses an explicit `exchangeRate()` model as the core pricing primitive.
- `convertToAssets(shares) = exchangeRate * shares / 1e18` ([PoolDynamic.sol:516](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:516)).
- `exchangeRate()` can be:
  - Dynamic (manual set),
  - Linear drift,
  - Compounding,
  - Term interpolation ([PoolDynamic.sol:464](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:464)).
- Pricing is rate-driven, not directly derived from onchain liquid balance.

### TokenizedVaultAsyncWithdrawals

- Uses accountant-reported `managedAssets` as total asset source ([TokenizedVaultAsyncWithdrawals.sol:140](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:140)).
- Share/asset conversion is derived from `managedAssets` and `totalSupply` with virtual offsets ([TokenizedVaultAsyncWithdrawals.sol:381](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:381)).
- No separate exchange-rate mode machine; one valuation input (`reportManagedAssets`).

## 2) Redemption Request Economics

### PoolDynamic

- On request, it computes and stores `assets = convertToAssets(shares)` at request time ([PoolDynamic.sol:648](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:648), [PoolDynamic.sol:669](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:669)).
- Redemptions move through stages:
  - `Requested` -> `Accepted` -> `Repay` ([PoolDynamic.sol:360](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:360), [PoolDynamic.sol:383](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:383)).
- Repayment amount is passed in at repay call (`repayment`, `fees`) and may differ from originally expected assets (event includes both) ([PoolDynamic.sol:377](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:377), [PoolDynamic.sol:399](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:399)).

### TokenizedVaultAsyncWithdrawals

- On request, it stores shares + fee snapshot, not locked gross asset amount ([TokenizedVaultAsyncWithdrawals.sol:237](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:237)).
- On finalize, it recomputes gross from current conversion:
  - `grossAssets = _convertToAssets(request.shares, Floor)` ([TokenizedVaultAsyncWithdrawals.sol:254](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:254)).
- Fee bps is locked at request (`feeBpsAtRequest`) and applied at finalize ([TokenizedVaultAsyncWithdrawals.sol:241](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:241), [TokenizedVaultAsyncWithdrawals.sol:255](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:255)).
- Net effect: pending redeemers keep NAV exposure until finalization.

## 3) Liquidity and Settlement

### PoolDynamic

- Repayment is explicit admin/manager workflow with accepted requests.
- Supports destination changes and staged acceptance before settlement ([PoolDynamic.sol:341](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:341), [PoolDynamic.sol:356](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:356)).
- Burns shares at repayment step (`_burn`) and then transfers funds ([PoolDynamic.sol:413](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:413)).

### TokenizedVaultAsyncWithdrawals

- Simpler two-step lifecycle:
  - request (`Pending`)
  - finalize or reject
- Finalize requires current liquidity check:
  - `availableAssets() >= grossAssets` ([TokenizedVaultAsyncWithdrawals.sol:260](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:260)).
- Burns escrowed shares and pays receiver + fee recipient in one finalize tx ([TokenizedVaultAsyncWithdrawals.sol:273](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:273)).

## 4) ERC-4626 Behavior

### PoolDynamic

- Implements `convertToAssets/convertToShares/totalAssets` style methods but is not your strict OZ-4626 inheritance model here.
- Transfer-to-pool can trigger request-redeem side effect via `_beforeTokenTransfer` ([PoolDynamic.sol:704](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:704)).

### TokenizedVaultAsyncWithdrawals

- Inherits OZ `ERC4626`.
- Sync `withdraw/redeem` intentionally disabled:
  - `maxWithdraw/maxRedeem = 0` ([TokenizedVaultAsyncWithdrawals.sol:315](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:315))
  - `_withdraw` reverts ([TokenizedVaultAsyncWithdrawals.sol:363](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:363))
- Async redemptions are custom path.

## 5) Practical Difference Summary

- If you want request-time asset lock semantics: `PoolDynamic` style is closer.
- If you want simpler maintenance and finalize-time pricing: your `TokenizedVaultAsyncWithdrawals` style is cleaner.
- Your current vault is operationally simpler, but operator/UI must recompute payout estimates at finalization time.

## 6) ExchangeRate vs ManagedAssets (Why They Feel Very Different)

### PoolDynamic `exchangeRate` model (more complex)

- Admin/controller sets a base rate and parameters via `setExchangeRate(...)` ([PoolDynamic.sol:443](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:443)).
- Runtime price is computed from mode + elapsed days in `exchangeRate()` ([PoolDynamic.sol:464](/Users/geric/Documents/code/ixs-api/contracts/contracts/PoolDynamic.sol:464)).
- Supports multiple curve types (dynamic/linear/compounding/term), which adds flexibility but also more moving parts and edge cases.

Why `block.timestamp / 1 days`:

- It converts timestamp to integer day buckets.
- Goal is to apply rate progression in day steps, not per-second noise.
- This makes accrual deterministic and easier to reason about for products priced in daily periods.
- Tradeoff: coarse granularity; behavior changes at day boundaries.

### TokenizedVaultAsyncWithdrawals `managedAssets` model (simpler)

- Accountant reports total assets directly via `reportManagedAssets(...)` ([TokenizedVaultAsyncWithdrawals.sol:201](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:201)).
- Price is derived from reported assets and supply (`_convertToAssets/_convertToShares`) ([TokenizedVaultAsyncWithdrawals.sol:388](/Users/geric/Documents/code/ixs-api/contracts/contracts/TokenizedVaultAsyncWithdrawals.sol:388)).
- Fewer parameters and fewer curve bugs; easier backend + UI maintenance.

## 7) Scalability / Maintainability / Manipulation Surface

### Scalability

- PoolDynamic scales in product expressiveness (many pricing modes), but operational complexity scales faster.
- ManagedAssets scales better for straightforward RWA operations because valuation is a single input stream.

### Maintainability

- PoolDynamic requires stronger discipline around:
  - rate mode selection,
  - day rollover behavior,
  - parameter updates and reconciliation.
- ManagedAssets model is easier to test, monitor, and explain to operators and auditors.

### Manipulation/Abuse Surface

Neither model is trustless; both depend on privileged actors.

- PoolDynamic risk: bad/mistimed `setExchangeRate` inputs or mode misuse can misprice conversions.
- ManagedAssets risk: bad/stale `reportManagedAssets` can misprice conversions.

In practice, manipulation resistance comes from governance and controls, not formula complexity:

- multisig/role separation
- valuation policy and sign-off
- update frequency and audit trail
- monitoring around unusual price jumps

## 8) Practical Recommendation for Your Current Vault

- You are not "stupid" for choosing the simpler model.
- For your stated goal (async redemption + operator workflow + clear UI), `TokenizedVaultAsyncWithdrawals` is the more maintainable baseline.
- Only move toward PoolDynamic-style exchange-rate curves if you have a hard product requirement for deterministic scheduled accrual logic onchain.

## 9) Direct Answer to “How NAV is calculated and how redemption works”

### PoolDynamic

- NAV/price proxy is `exchangeRate()` with configurable accrual model.
- Redemption request records expected assets at request.
- Settlement is staged (request -> accept -> repay), with repayment inputs provided at settlement.

### TokenizedVaultAsyncWithdrawals

- NAV/price proxy is derived from `managedAssets` vs supply.
- Redemption request records shares (plus fee snapshot), not fixed assets.
- Settlement computes assets at finalize-time conversion and pays immediately if liquid.
