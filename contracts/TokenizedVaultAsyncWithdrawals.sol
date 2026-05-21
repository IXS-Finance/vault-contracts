// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

/**
 * @title TokenizedVaultAsyncWithdrawals
 * @notice ERC-4626 tokenized vault with:
 *   - Async (queued) redemptions — no synchronous withdraw/redeem
 *   - Hybrid NAV: lazy accrual via declaredApyBps + periodic correction via reportManagedAssets
 *   - NAV staleness guard — new deposits blocked if NAV not confirmed within navStalenessThreshold
 *   - NAV deviation guard — reportManagedAssets reverts if change exceeds maxNavChangeBps
 *   - Optional whitelist — toggled at deploy time; operator manages per-address access
 *   - Sweep guard — vault asset and vault shares cannot be swept
 *
 * @dev Deploy one instance per vault strategy. All vaults share this bytecode.
 *
 * NAV / Accrual Model:
 *   managedAssets    — crystallized principal. Always includes all accrued yield up to last
 *                      crystallization. This is the source of truth for share pricing.
 *   declaredApyBps   — annualized yield rate in BPS (0 = pure push mode, no accrual)
 *   navLastConfirmed — timestamp of last crystallization (deposit, finalize, or reportManagedAssets)
 *   totalAssets()    — managedAssets + _accruedSinceLastConfirmed() (view only, not stored)
 *
 *   CRITICAL INVARIANT: managedAssets must be crystallized (via _crystallize()) before any
 *   operation that changes it. This prevents new deposits from retroactively earning past yield
 *   and prevents finalizations from destroying yield owed to remaining shareholders.
 *
 * Accountant workflow:
 *   Normal period  → reportManagedAssets(totalAssets(), sameApy)  — confirm + reset clock
 *   APY change     → reportManagedAssets(totalAssets(), newApy)
 *   Strategy loss  → reportManagedAssets(realOffChainNAV, adjustedApy)
 *   Freeze accrual → reportManagedAssets(totalAssets(), 0)
 *   Full freeze    → pause() — blocks deposits + new redeem requests
 *                    NOTE: finalizeRedeem/rejectRedeem remain executable while paused
 *                    so the existing redemption queue is never stranded.
 *
 * Whitelist:
 *   - Enabled/disabled at deploy via constructor param enableWhitelist_
 *   - Can be toggled post-deploy by DEFAULT_ADMIN_ROLE
 *   - OPERATOR_ROLE manages per-address entries (single + batch)
 *   - Checked on: deposit receiver, mint receiver, requestRedeem owner
 *   - NOT checked on: finalizeRedeem, rejectRedeem — must always be executable
 */
contract TokenizedVaultAsyncWithdrawals is
  ERC20,
  ERC4626,
  AccessControl,
  Pausable,
  ReentrancyGuard
{
  using Math for uint256;
  using SafeERC20 for IERC20;

  // =========================================================
  // Constants
  // =========================================================

  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');
  bytes32 public constant ACCOUNTANT_ROLE = keccak256('ACCOUNTANT_ROLE');
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  uint256 public constant MAX_BPS = 10_000;

  /// @notice Maximum declarable APY — 100%. Sanity cap only.
  uint256 public constant MAX_APY_BPS = 10_000;

  /// @notice Default NAV staleness threshold: 48 hours.
  ///         Deposits blocked if NAV unconfirmed beyond this window.
  ///         Redemptions are NOT blocked — users must always be able to exit.
  uint256 public constant DEFAULT_NAV_STALENESS = 48 hours;

  /// @notice Default max NAV change per reportManagedAssets call: 50%.
  ///         Guards against fat-finger or compromised accountant.
  ///         Only enforced when managedAssets > 0 (no guard on first report).
  uint256 public constant DEFAULT_MAX_NAV_CHANGE_BPS = 5_000;

  // =========================================================
  // Types
  // =========================================================

  enum RequestStatus {
    None,
    Pending,
    Finalized,
    Rejected
  }

  struct RedeemRequest {
    address owner;
    address receiver;
    uint256 shares;
    uint256 assetsAtRequest; // snapshot of totalAssets() at request time — audit trail only
    uint256 feeBpsAtRequest; // frozen at request — exit fee immune to future fee changes
    uint256 requestedAt;
    uint256 processedAt;
    RequestStatus status;
  }

  // =========================================================
  // Immutables
  // =========================================================

  uint8 private immutable decimalsOffsetValue;

  // =========================================================
  // State — custody & fees
  // =========================================================

  address public custody;
  address public feeRecipient;
  uint256 public feeBps;
  uint256 public totalFeesAccrued;

  // =========================================================
  // State — NAV (hybrid lazy accrual)
  // =========================================================

  /// @notice Crystallized principal. Accrued yield is baked in here on every crystallization.
  ///         totalAssets() = managedAssets + _accruedSinceLastConfirmed().
  ///         NEVER modify managedAssets directly without calling _crystallize() first.
  uint256 public managedAssets;

  /// @notice Annualized yield rate in BPS. 0 = no accrual (pure push mode).
  ///         Example: 600 = 6% APY.
  uint256 public declaredApyBps;

  /// @notice Timestamp of last crystallization. Accrual clock starts here.
  ///         Set by _crystallize() and reportManagedAssets(). Never set directly.
  uint256 public navLastConfirmed;

  /// @notice Deposits blocked if block.timestamp - navLastConfirmed > this value.
  ///         Set to 0 to disable staleness check (not recommended for production).
  uint256 public navStalenessThreshold;

  /// @notice Max allowed NAV change (up or down) per reportManagedAssets call, in BPS.
  uint256 public maxNavChangeBps;

  // =========================================================
  // State — whitelist
  // =========================================================

  /// @notice When true, deposit/mint/requestRedeem enforce whitelist membership.
  bool public whitelistEnabled;

  /// @notice Per-address whitelist status. Managed by OPERATOR_ROLE.
  mapping(address => bool) public whitelist;

  // =========================================================
  // State — deposit / redeem limits
  // =========================================================

  uint256 public minDepositAssets;
  uint256 public minRedeemAssets;

  // =========================================================
  // State — redemption queue
  // =========================================================

  uint256 public nextRedeemRequestId;
  uint256 public pendingRedeemCount;

  // =========================================================
  // State — accounting totals
  // =========================================================

  uint256 public totalRedeemRequestCount;
  uint256 public totalRedeemFinalized;
  uint256 public totalRedeemRejected;
  uint256 public totalDepositedAssets;
  uint256 public totalMintedShares;
  uint256 public totalWithdrawnAssets;
  uint256 public totalRedeemedShares;

  mapping(uint256 => RedeemRequest) public redeemRequests;

  // =========================================================
  // Events
  // =========================================================

  event CustodyUpdated(address indexed previousCustody, address indexed newCustody);
  event AssetsForwardedToCustody(address indexed custody, uint256 assets);
  event FeeBpsUpdated(uint256 previousFeeBps, uint256 newFeeBps);
  event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);
  event MinDepositAssetsUpdated(uint256 previousMinDepositAssets, uint256 newMinDepositAssets);
  event MinRedeemAssetsUpdated(uint256 previousMinRedeemAssets, uint256 newMinRedeemAssets);
  event TokenSweptToCustody(address indexed token, address indexed custody, uint256 amount);
  event NavStalenessThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);
  event MaxNavChangeBpsUpdated(uint256 previousMax, uint256 newMax);

  event WhitelistEnabled();
  event WhitelistDisabled();
  event WhitelistUpdated(address indexed account, bool status);

  /// @notice Emitted whenever managedAssets or declaredApyBps changes.
  ///         accruedSinceLastConfirmed = yield crystallized into managedAssets in this call.
  event ManagedAssetsUpdated(
    uint256 previousManagedAssets,
    uint256 newManagedAssets,
    uint256 previousDeclaredApyBps,
    uint256 newDeclaredApyBps,
    uint256 accruedSinceLastConfirmed
  );

  event RedeemRequested(
    uint256 indexed id,
    address indexed owner,
    address indexed receiver,
    uint256 shares,
    uint256 assetsAtRequest,
    uint256 feeBpsAtRequest
  );
  event RedeemRequestFinalized(
    uint256 indexed id,
    address indexed owner,
    address indexed receiver,
    uint256 shares,
    uint256 grossAssets,
    uint256 feeAssets,
    uint256 netAssets,
    uint256 feeBpsAtRequest
  );
  event RedeemRequestRejected(
    uint256 indexed id,
    address indexed owner,
    address indexed receiver,
    uint256 shares
  );

  // =========================================================
  // Constructor
  // =========================================================

  /**
   * @param asset_             Underlying ERC-20 asset (e.g. USDC).
   * @param name_              Vault share token name.
   * @param symbol_            Vault share token symbol.
   * @param admin_             Address granted DEFAULT_ADMIN_ROLE and all sub-roles.
   * @param custody_           Address assets are forwarded to on deposit.
   * @param enableWhitelist_   If true, deposit/mint/requestRedeem enforce whitelist from day one.
   */
  constructor(
    IERC20 asset_,
    string memory name_,
    string memory symbol_,
    address admin_,
    address custody_,
    bool enableWhitelist_
  ) ERC20(name_, symbol_) ERC4626(asset_) {
    require(address(asset_) != address(0), 'asset is zero');
    require(bytes(name_).length > 0, 'name is empty');
    require(bytes(symbol_).length > 0, 'symbol is empty');
    require(admin_ != address(0), 'admin is zero');
    require(custody_ != address(0), 'custody is zero');

    uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
    require(assetDecimals <= 18, 'asset decimals > 18');

    _validateCustody(custody_, asset_);

    decimalsOffsetValue = 18 - assetDecimals;
    custody = custody_;
    feeRecipient = custody_;
    minDepositAssets = 1;
    minRedeemAssets = 1;
    navStalenessThreshold = DEFAULT_NAV_STALENESS;
    maxNavChangeBps = DEFAULT_MAX_NAV_CHANGE_BPS;
    whitelistEnabled = enableWhitelist_;

    // navLastConfirmed = 0 intentionally — vault is in "uninitialized" state.
    // maxDeposit returns 0 until accountant calls reportManagedAssets(0, apyBps).

    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    _grantRole(PAUSER_ROLE, admin_);
    _grantRole(ACCOUNTANT_ROLE, admin_);
    _grantRole(OPERATOR_ROLE, admin_);

    if (enableWhitelist_) emit WhitelistEnabled();
  }

  // =========================================================
  // Admin — pause
  // =========================================================

  /// @notice Pause blocks: deposits, mints, new redeem requests.
  ///         Does NOT block: finalizeRedeem, rejectRedeem — existing queue must always drain.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  // =========================================================
  // Admin — config
  // =========================================================

  function setCustody(address newCustody) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newCustody != address(0), 'custody is zero');
    _validateCustody(newCustody, IERC20(asset()));
    address previousCustody = custody;
    custody = newCustody;
    emit CustodyUpdated(previousCustody, newCustody);
  }

  function setFeeBps(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newFeeBps <= MAX_BPS, 'fee bps too high');
    uint256 previousFeeBps = feeBps;
    feeBps = newFeeBps;
    emit FeeBpsUpdated(previousFeeBps, newFeeBps);
  }

  function setFeeRecipient(address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newFeeRecipient != address(0), 'fee recipient is zero');
    address previousFeeRecipient = feeRecipient;
    feeRecipient = newFeeRecipient;
    emit FeeRecipientUpdated(previousFeeRecipient, newFeeRecipient);
  }

  function setMinDepositAssets(uint256 newMinDepositAssets) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 prev = minDepositAssets;
    minDepositAssets = newMinDepositAssets;
    emit MinDepositAssetsUpdated(prev, newMinDepositAssets);
  }

  function setMinRedeemAssets(uint256 newMinRedeemAssets) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 prev = minRedeemAssets;
    minRedeemAssets = newMinRedeemAssets;
    emit MinRedeemAssetsUpdated(prev, newMinRedeemAssets);
  }

  function setNavStalenessThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 prev = navStalenessThreshold;
    navStalenessThreshold = newThreshold;
    emit NavStalenessThresholdUpdated(prev, newThreshold);
  }

  function setMaxNavChangeBps(uint256 newMaxNavChangeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newMaxNavChangeBps <= MAX_BPS * 10, 'unreasonably high');
    uint256 prev = maxNavChangeBps;
    maxNavChangeBps = newMaxNavChangeBps;
    emit MaxNavChangeBpsUpdated(prev, newMaxNavChangeBps);
  }

  // =========================================================
  // Admin — whitelist toggle
  // =========================================================

  function setWhitelistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
    whitelistEnabled = enabled;
    if (enabled) emit WhitelistEnabled();
    else emit WhitelistDisabled();
  }

  // =========================================================
  // Operator — whitelist management
  // =========================================================

  function setWhitelisted(address account, bool status) external onlyRole(OPERATOR_ROLE) {
    require(account != address(0), 'account is zero');
    whitelist[account] = status;
    emit WhitelistUpdated(account, status);
  }

  function setWhitelistedBatch(
    address[] calldata accounts,
    bool status
  ) external onlyRole(OPERATOR_ROLE) {
    for (uint256 i = 0; i < accounts.length; i++) {
      require(accounts[i] != address(0), 'account is zero');
      whitelist[accounts[i]] = status;
      emit WhitelistUpdated(accounts[i], status);
    }
  }

  // =========================================================
  // Accountant — NAV reporting
  // =========================================================

  /**
   * @notice Confirm current NAV and set going-forward APY. Resets accrual clock.
   *
   * @dev Deviation guard compares newManagedAssets against totalAssets() (live NAV,
   *      includes accrual since last confirmation). This means:
   *        - Normal report: reportManagedAssets(totalAssets(), sameApy) → ~0% delta, always passes
   *        - Long reporting gap: still ~0% delta because baseline includes accrual
   *        - Actual loss: newManagedAssets materially below currentNav → trips guard
   *        - Fat-finger / malicious inflation: trips guard
   *
   *      Loss events that exceed maxNavChangeBps must either:
   *        a) Admin raises maxNavChangeBps temporarily, or
   *        b) Loss is reported in multiple steps
   *
   * Workflow:
   *   Strategy on track → reportManagedAssets(totalAssets(), sameApy)
   *   APY change        → reportManagedAssets(totalAssets(), newApy)
   *   Strategy loss     → reportManagedAssets(realOffChainNAV, adjustedApy)
   *   Freeze accrual    → reportManagedAssets(totalAssets(), 0)
   *
   * @param newManagedAssets  New confirmed principal. Replaces crystallized managedAssets.
   * @param newDeclaredApyBps Going-forward APY in BPS. 0 = no accrual until next report.
   */
  function reportManagedAssets(
    uint256 newManagedAssets,
    uint256 newDeclaredApyBps
  ) external onlyRole(ACCOUNTANT_ROLE) whenNotPaused {
    require(newDeclaredApyBps <= MAX_APY_BPS, 'apy too high');

    // Deviation guard — baseline is totalAssets() (live NAV including accrual).
    // Honest report of totalAssets() always yields ~0% delta regardless of reporting gap.
    // Only trips on genuinely anomalous inputs or real loss events.
    uint256 currentNav = totalAssets();
    if (currentNav > 0) {
      uint256 changeBps;
      if (newManagedAssets >= currentNav) {
        changeBps = (newManagedAssets - currentNav).mulDiv(MAX_BPS, currentNav, Math.Rounding.Ceil);
      } else {
        changeBps = (currentNav - newManagedAssets).mulDiv(MAX_BPS, currentNav, Math.Rounding.Ceil);
      }
      require(changeBps <= maxNavChangeBps, 'nav change too large');
    }

    uint256 previousManagedAssets = managedAssets;
    uint256 previousApyBps = declaredApyBps;
    uint256 accrued = _accruedSinceLastConfirmed();

    // Accountant's newManagedAssets fully replaces the crystallized value.
    // The accrued amount since last confirmation is implicitly included when the
    // accountant passes totalAssets() — which is the standard workflow.
    managedAssets = newManagedAssets;
    declaredApyBps = newDeclaredApyBps;
    navLastConfirmed = block.timestamp;

    emit ManagedAssetsUpdated(
      previousManagedAssets,
      newManagedAssets,
      previousApyBps,
      newDeclaredApyBps,
      accrued
    );
  }

  // =========================================================
  // Admin — emergency sweep
  // =========================================================

  /**
   * @notice Sweep any third-party ERC-20 to custody.
   *
   * Blocked:
   *   - vault asset  — earmarked for redemption settlements; stray amounts absorbed as excess liquidity
   *   - vault shares — escrowed pending redeem requests live here; sweeping breaks finalization
   *
   * @param token     Token to sweep.
   * @param minAmount Minimum balance required. Pass 1 to sweep any amount, higher to ignore dust.
   */
  function sweepTokenToCustody(
    address token,
    uint256 minAmount
  ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    require(token != address(0), 'token is zero');
    require(token != asset(), 'cannot sweep vault asset');
    require(token != address(this), 'cannot sweep vault shares');

    uint256 balance = IERC20(token).balanceOf(address(this));
    require(balance >= minAmount, 'below min sweep');

    IERC20(token).safeTransfer(custody, balance);
    emit TokenSweptToCustody(token, custody, balance);
  }

  // =========================================================
  // User — redeem queue
  // =========================================================

  /**
   * @notice Queue a redemption request. Shares escrowed until finalized or rejected.
   *
   * @dev feeBpsAtRequest frozen — exit fee locked at request time.
   *      assetsAtRequest is audit trail only — finalization prices at live NAV.
   *      Queue is indefinite — no timeout, no on-chain FIFO enforcement.
   *      Whitelist checked on msg.sender (the regulated party), not receiver.
   *
   * @param shares    Vault shares to redeem.
   * @param receiver  Address to receive assets on finalization.
   * @return id       Request ID (1-indexed).
   */
  function requestRedeem(
    uint256 shares,
    address receiver
  ) external whenNotPaused nonReentrant returns (uint256 id) {
    require(shares > 0, 'shares is zero');
    require(receiver != address(0), 'receiver is zero');
    require(previewRedeem(shares) >= minRedeemAssets, 'below min redeem');

    _checkWhitelist(msg.sender);

    _transfer(msg.sender, address(this), shares);

    id = ++nextRedeemRequestId;
    pendingRedeemCount += 1;
    totalRedeemRequestCount += 1;

    uint256 snapshotAssets = totalAssets();

    redeemRequests[id] = RedeemRequest({
      owner: msg.sender,
      receiver: receiver,
      shares: shares,
      assetsAtRequest: snapshotAssets,
      feeBpsAtRequest: feeBps,
      requestedAt: block.timestamp,
      processedAt: 0,
      status: RequestStatus.Pending
    });

    emit RedeemRequested(id, msg.sender, receiver, shares, snapshotAssets, feeBps);
  }

  /**
   * @notice Finalize a pending redeem request.
   *         Burns escrowed shares, sends net assets to receiver, fee to feeRecipient.
   *
   * @dev NOT gated by whenNotPaused — existing queue must remain drainable during a pause.
   *
   *      Pricing: crystallizes accrual first, then prices at updated managedAssets.
   *      This ensures the exiting shareholder receives exactly their pro-rata share of
   *      all yield earned up to this moment, and remaining shareholders are not shorted.
   *
   *      ERC-4626 Withdraw event emits grossAssets (full assets burned against shares),
   *      not netAssets, per spec. Fee is an implementation detail visible in
   *      RedeemRequestFinalized which includes both gross, fee, and net breakdowns.
   */
  function finalizeRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) nonReentrant {
    RedeemRequest storage request = redeemRequests[id];
    require(request.status == RequestStatus.Pending, 'redeem not pending');

    // Crystallize accrual before changing managedAssets.
    // This bakes earned yield into managedAssets so the exiting shareholder
    // gets their correct pro-rata share and remaining shareholders are not shorted.
    _crystallize();

    // Price against crystallized managedAssets — totalAssets() == managedAssets now.
    uint256 grossAssets = request.shares.mulDiv(
      managedAssets + 1,
      totalSupply() + 10 ** _decimalsOffset(),
      Math.Rounding.Floor
    );
    uint256 feeAssets = _feeOnRaw(grossAssets, request.feeBpsAtRequest);
    uint256 netAssets = grossAssets - feeAssets;

    require(grossAssets > 0, 'gross assets is zero');
    require(managedAssets >= grossAssets, 'managed assets insufficient');
    require(availableAssets() >= grossAssets, 'insufficient liquidity');

    request.processedAt = block.timestamp;
    request.status = RequestStatus.Finalized;
    pendingRedeemCount -= 1;
    totalRedeemFinalized += 1;
    totalFeesAccrued += feeAssets;
    totalWithdrawnAssets += netAssets;
    totalRedeemedShares += request.shares;

    managedAssets = managedAssets - grossAssets;
    // navLastConfirmed was just set by _crystallize() — no reset needed here.

    _burn(address(this), request.shares);
    IERC20(asset()).safeTransfer(request.receiver, netAssets);
    if (feeAssets > 0) {
      IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
    }

    emit RedeemRequestFinalized(
      id,
      request.owner,
      request.receiver,
      request.shares,
      grossAssets,
      feeAssets,
      netAssets,
      request.feeBpsAtRequest
    );
    // emit grossAssets per ERC-4626 spec — full assets burned against shares.
    // Fee breakdown is visible in RedeemRequestFinalized above.
    emit Withdraw(msg.sender, request.receiver, request.owner, grossAssets, request.shares);
  }

  /**
   * @notice Reject a pending redeem request. Returns escrowed shares to owner.
   * @dev NOT gated by whenNotPaused — queue must remain drainable during a pause.
   */
  function rejectRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) nonReentrant {
    RedeemRequest storage request = redeemRequests[id];
    require(request.status == RequestStatus.Pending, 'redeem not pending');

    request.processedAt = block.timestamp;
    request.status = RequestStatus.Rejected;
    pendingRedeemCount -= 1;
    totalRedeemRejected += 1;

    _transfer(address(this), request.owner, request.shares);

    emit RedeemRequestRejected(id, request.owner, request.receiver, request.shares);
  }

  // =========================================================
  // ERC-4626 overrides
  // =========================================================

  function decimals() public view override(ERC20, ERC4626) returns (uint8) {
    return super.decimals();
  }

  /**
   * @notice Live NAV = crystallized principal + accrued yield since last crystallization.
   * @dev This is a VIEW — accrual is not stored until _crystallize() is called.
   *      When declaredApyBps = 0, returns managedAssets exactly (pure push mode).
   */
  function totalAssets() public view override returns (uint256) {
    return managedAssets + _accruedSinceLastConfirmed();
  }

  /**
   * @notice Returns 0 (blocking deposits) when: paused, NAV stale, or receiver not whitelisted.
   */
  function maxDeposit(address receiver) public view override returns (uint256) {
    if (paused()) return 0;
    if (!_isNavFresh()) return 0;
    if (whitelistEnabled && !whitelist[receiver]) return 0;
    return type(uint256).max;
  }

  function maxMint(address receiver) public view override returns (uint256) {
    if (paused()) return 0;
    if (!_isNavFresh()) return 0;
    if (whitelistEnabled && !whitelist[receiver]) return 0;
    return type(uint256).max;
  }

  function maxWithdraw(address) public pure override returns (uint256) {
    return 0; // synchronous withdraw disabled — use requestRedeem
  }

  function maxRedeem(address) public pure override returns (uint256) {
    return 0; // synchronous redeem disabled — use requestRedeem
  }

  function previewWithdraw(uint256 assets) public view override returns (uint256) {
    uint256 fee = _feeOnRaw(assets, feeBps);
    return super.previewWithdraw(assets + fee);
  }

  function previewRedeem(uint256 shares) public view override returns (uint256) {
    uint256 assets = super.previewRedeem(shares);
    return assets - _feeOnRaw(assets, feeBps);
  }

  // =========================================================
  // Views
  // =========================================================

  /// @notice Asset balance currently held in this contract.
  ///         Normally near-zero. Non-zero when custody has funded pending redemptions.
  function availableAssets() public view returns (uint256) {
    return IERC20(asset()).balanceOf(address(this));
  }

  /// @notice Yield accrued since last crystallization, not yet stored in managedAssets.
  function accruedYield() external view returns (uint256) {
    return _accruedSinceLastConfirmed();
  }

  /// @notice True if NAV confirmed within navStalenessThreshold.
  function isNavFresh() external view returns (bool) {
    return _isNavFresh();
  }

  /// @notice Preview exit fee for a share count at current feeBps.
  function previewRedeemFee(uint256 shares) external view returns (uint256) {
    uint256 grossAssets = super.previewRedeem(shares);
    return _feeOnRaw(grossAssets, feeBps);
  }

  /// @notice Preview exit fee for an asset amount at current feeBps.
  function previewWithdrawFee(uint256 assets) external view returns (uint256) {
    return _feeOnRaw(assets, feeBps);
  }

  /**
   * @notice Preview what a pending request would receive if finalized right now.
   * @dev Simulates crystallization inline — does not modify state.
   */
  function previewFinalizeRedeem(
    uint256 id
  ) external view returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets) {
    RedeemRequest storage request = redeemRequests[id];
    require(request.status == RequestStatus.Pending, 'redeem not pending');

    // Simulate crystallized state
    uint256 crystallizedAssets = managedAssets + _accruedSinceLastConfirmed();

    grossAssets = request.shares.mulDiv(
      crystallizedAssets + 1,
      totalSupply() + 10 ** _decimalsOffset(),
      Math.Rounding.Floor
    );
    feeAssets = _feeOnRaw(grossAssets, request.feeBpsAtRequest);
    netAssets = grossAssets - feeAssets;
  }

  // =========================================================
  // ERC-4626 deposit / mint
  // =========================================================

  /// @notice Deposit assets, receive shares. Receiver must be whitelisted if whitelist is enabled.
  function deposit(
    uint256 assets,
    address receiver
  ) public override whenNotPaused nonReentrant returns (uint256 shares) {
    require(assets >= minDepositAssets, 'below min deposit');
    _checkWhitelist(receiver);
    shares = super.deposit(assets, receiver);
  }

  /// @notice Mint exact shares, paying required assets. Receiver must be whitelisted if enabled.
  function mint(
    uint256 shares,
    address receiver
  ) public override whenNotPaused nonReentrant returns (uint256 assets) {
    assets = previewMint(shares);
    require(assets >= minDepositAssets, 'below min deposit');
    _checkWhitelist(receiver);
    assets = super.mint(shares, receiver);
  }

  // =========================================================
  // Internal overrides
  // =========================================================

  function _withdraw(address, address, address, uint256, uint256) internal pure override {
    revert('queued withdrawals only');
  }

  /**
   * @dev Called by OZ ERC4626 after transferring assets in.
   *
   *      _crystallize() before managedAssets += assets.
   *      Without this, the new deposit would retroactively earn yield from navLastConfirmed
   *      to now — yield it never actually earned. Crystallizing first bakes existing
   *      accrual into managedAssets, resets the clock, then adds the new deposit cleanly.
   */
  function _deposit(
    address caller,
    address receiver,
    uint256 assets,
    uint256 shares
  ) internal override {
    require(_isNavFresh(), 'nav is stale');

    // Crystallize before adding deposit to principal.
    _crystallize();

    super._deposit(caller, receiver, assets, shares);

    uint256 previousManagedAssets = managedAssets;
    managedAssets += assets;
    totalDepositedAssets += assets;
    totalMintedShares += shares;

    emit ManagedAssetsUpdated(
      previousManagedAssets,
      managedAssets,
      declaredApyBps,
      declaredApyBps,
      0 // accrued was already emitted inside _crystallize
    );

    IERC20(asset()).safeTransfer(custody, assets);
    emit AssetsForwardedToCustody(custody, assets);
  }

  function _convertToShares(
    uint256 assets,
    Math.Rounding rounding
  ) internal view override returns (uint256) {
    return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
  }

  function _convertToAssets(
    uint256 shares,
    Math.Rounding rounding
  ) internal view override returns (uint256) {
    return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
  }

  function _decimalsOffset() internal view override returns (uint8) {
    return decimalsOffsetValue;
  }

  // =========================================================
  // Internal — crystallization
  // =========================================================

  /**
   * @notice Bake accrued yield into managedAssets and reset the accrual clock.
   *
   * @dev MUST be called before any operation that modifies managedAssets:
   *        - _deposit (before adding new assets)
   *        - finalizeRedeem (before subtracting gross assets)
   *
   *      After _crystallize():
   *        - managedAssets includes all yield earned up to this block
   *        - navLastConfirmed = block.timestamp
   *        - _accruedSinceLastConfirmed() returns 0
   *        - totalAssets() == managedAssets
   *
   *      No-op if: APY = 0, no principal, or vault uninitialized (navLastConfirmed = 0).
   *      In those cases navLastConfirmed is still updated so the clock starts correctly.
   */
  function _crystallize() internal {
    uint256 accrued = _accruedSinceLastConfirmed();

    uint256 previousManagedAssets = managedAssets;
    if (accrued > 0) {
      managedAssets += accrued;
    }

    navLastConfirmed = block.timestamp;

    if (accrued > 0) {
      emit ManagedAssetsUpdated(
        previousManagedAssets,
        managedAssets,
        declaredApyBps,
        declaredApyBps,
        accrued
      );
    }
  }

  // =========================================================
  // Internal — whitelist
  // =========================================================

  function _checkWhitelist(address account) internal view {
    if (whitelistEnabled) {
      require(whitelist[account], 'not whitelisted');
    }
  }

  // =========================================================
  // Internal — NAV helpers
  // =========================================================

  /// @dev Yield accrued on managedAssets since navLastConfirmed.
  ///      Pure view — does not modify state. Call _crystallize() to store it.
  function _accruedSinceLastConfirmed() internal view returns (uint256) {
    if (declaredApyBps == 0 || managedAssets == 0 || navLastConfirmed == 0) {
      return 0;
    }
    uint256 elapsed = block.timestamp - navLastConfirmed;
    return managedAssets.mulDiv(declaredApyBps * elapsed, MAX_BPS * 365 days, Math.Rounding.Floor);
  }

  /// @dev NAV is fresh if staleness check disabled OR confirmed within threshold.
  ///      navLastConfirmed = 0 is always stale.
  function _isNavFresh() internal view returns (bool) {
    if (navStalenessThreshold == 0) return true;
    if (navLastConfirmed == 0) return false;
    return block.timestamp - navLastConfirmed <= navStalenessThreshold;
  }

  // =========================================================
  // Internal — fee math
  // =========================================================

  function _feeOnRaw(uint256 assets, uint256 feeBpsValue) internal pure returns (uint256) {
    return assets.mulDiv(feeBpsValue, MAX_BPS, Math.Rounding.Ceil);
  }

  // =========================================================
  // Internal — validation
  // =========================================================

  function _validateCustody(address custody_, IERC20 asset_) private view {
    require(custody_ != address(this), 'custody is vault');
    require(custody_ != address(asset_), 'custody is asset');
  }
}
