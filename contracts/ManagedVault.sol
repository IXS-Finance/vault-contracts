// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ManagedVault
 * @notice ERC-4626 tokenized vault with:
 *   - Externally managed NAV — share price set by NAV_MANAGER via setNAV()
 *   - No on-chain yield computation — fund admin reports NAV off-chain, backend calls setNAV
 *   - Async (queued) redemptions — no synchronous withdraw/redeem
 *   - NAV staleness guard — deposits blocked if price not updated within navStalenessThreshold
 *   - NAV deviation guard — setNAV reverts if change exceeds maxNavChangeBps
 *   - Optional whitelist — toggled at deploy; OPERATOR_ROLE manages per-address access
 *   - Sweep guard — vault asset and vault shares cannot be swept
 *   - UUPS upgradeable — upgrade authorised by DEFAULT_ADMIN_ROLE
 *
 * @dev NAV Model:
 *   pricePerShare  — price of 1 vault share in asset units (asset decimals precision).
 *                    e.g. USDC: 1_000_000 = 1.000000 USDC per share.
 *   totalAssets()  — totalSupply() × pricePerShare / 10^decimals (pure read, no state written).
 *   setNAV()       — only entry point for price updates. Called by NAV_MANAGER (backend cron).
 *
 *   No crystallization. No APY accrual. The vault does not know or care whether yield came
 *   from price appreciation (same tokens, higher price) or additional tokens in custody.
 *   Both cases reduce to: fund admin computes NAV off-chain → backend calls setNAV(newPrice).
 *
 * Workflow (backend cron, ~1 min cadence):
 *   Read NAV from fund admin API / Chainlink / CoinGecko (off-chain, no gas) →
 *   call setNAV(pricePerShare) → vault stores it.
 *
 * Vault is uninitialised (deposits blocked) until NAV_MANAGER calls setNAV for the first time.
 *
 * Accountant workflow:
 *   Normal update → setNAV(currentPricePerShare)
 *   Yield accreted → setNAV(higherPricePerShare)
 *   Loss event     → setNAV(lowerPricePerShare) — may require admin to raise maxNavChangeBps
 *   Freeze pricing → setNavStalenessThreshold(0) + pause()
 *
 * Redemption finalization (NOT gated by whenNotPaused):
 *   Operator calls finalizeRedeem(id) after custody funds the vault.
 *   Payout priced at live NAV (pricePerShare at finalization time). NAV at request is indicative only.
 */
contract ManagedVault is
    ERC20Upgradeable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    // =========================================================
    // Constants
    // =========================================================

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Default NAV staleness threshold: 48 hours.
    uint256 public constant DEFAULT_NAV_STALENESS = 48 hours;

    /// @notice Default max NAV change per setNAV call: 50%.
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
        uint256 priceAtRequest; // indicative price at request — audit trail only; finalization uses live NAV
        uint256 feeBpsAtRequest; // frozen at request — exit fee immune to future fee changes
        uint256 requestedAt;
        uint256 processedAt;
        RequestStatus status;
    }

    // =========================================================
    // State — decimals offset (set once in initialize)
    // =========================================================

    uint8 private _decimalsOffsetVal;

    // =========================================================
    // State — custody & fees
    // =========================================================

    address public custody;
    address public feeRecipient;
    uint256 public feeBps;
    uint256 public totalFeesAccrued;

    // =========================================================
    // State — NAV
    // =========================================================

    /// @notice Price of 1 vault share in asset units (asset decimals precision).
    ///         0 = uninitialised. Deposits blocked until NAV_MANAGER calls setNAV once.
    uint256 public pricePerShare;

    /// @notice Timestamp of last setNAV call. Deposits blocked if stale.
    uint256 public priceUpdatedAt;

    /// @notice Deposits blocked if block.timestamp - priceUpdatedAt > this value.
    ///         Set to 0 to disable staleness check (not recommended for production).
    uint256 public navStalenessThreshold;

    /// @notice Max allowed price change (up or down) per setNAV call, in BPS.
    uint256 public maxNavChangeBps;

    // =========================================================
    // State — whitelist
    // =========================================================

    bool public whitelistEnabled;
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
    uint256 public totalNetWithdrawnAssets;
    uint256 public totalRedeemedShares;

    mapping(uint256 => RedeemRequest) public redeemRequests;

    // =========================================================
    // State — token metadata overrides
    // =========================================================

    string private _customName;
    string private _customSymbol;

    // =========================================================
    // Upgrade storage gap — reserve slots for future state vars
    // =========================================================

    uint256[48] private __gap;

    // =========================================================
    // Events
    // =========================================================

    event CustodyUpdated(address indexed previousCustody, address indexed newCustody);
    event AssetsForwardedToCustody(address indexed custody, uint256 assets);
    event FeeBpsUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);
    event MinDepositAssetsUpdated(uint256 previousMin, uint256 newMin);
    event MinRedeemAssetsUpdated(uint256 previousMin, uint256 newMin);
    event TokenSweptToCustody(address indexed token, address indexed custody, uint256 amount);
    event NavStalenessThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);
    event MaxNavChangeBpsUpdated(uint256 previousMax, uint256 newMax);

    event WhitelistEnabled();
    event WhitelistDisabled();
    event WhitelistUpdated(address indexed account, bool status);

    /// @notice Emitted on every setNAV call.
    event NavUpdated(uint256 previousPricePerShare, uint256 newPricePerShare);

    event RedeemRequested(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 priceAtRequest,
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
    event RedeemRequestRejected(uint256 indexed id, address indexed owner, address indexed receiver, uint256 shares);

    // =========================================================
    // Constructor — disable initializers on implementation contract
    // =========================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================
    // Initializer — called once on proxy deployment
    // =========================================================

    /**
     * @param asset_             Underlying ERC-20 asset (e.g. USDC).
     * @param name_              Vault share token name.
     * @param symbol_            Vault share token symbol.
     * @param admin_             Address granted DEFAULT_ADMIN_ROLE and all sub-roles.
     * @param custody_           Address assets are forwarded to on deposit.
     * @param enableWhitelist_   If true, deposit/mint/requestRedeem enforce whitelist from day one.
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address custody_,
        bool enableWhitelist_
    ) public initializer {
        require(address(asset_) != address(0), "asset is zero");
        require(bytes(name_).length > 0, "name is empty");
        require(bytes(symbol_).length > 0, "symbol is empty");
        require(admin_ != address(0), "admin is zero");
        require(custody_ != address(0), "custody is zero");

        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        require(assetDecimals <= 18, "asset decimals > 18");
        _validateCustody(custody_, asset_);

        // Must be set before __ERC4626_init so _decimalsOffset() returns correct value
        // when decimals() is first called. Gives vault shares 18 decimals regardless of asset.
        _decimalsOffsetVal = 18 - assetDecimals;

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        custody = custody_;
        feeRecipient = custody_;
        minDepositAssets = 1;
        minRedeemAssets = 1;
        navStalenessThreshold = DEFAULT_NAV_STALENESS;
        maxNavChangeBps = DEFAULT_MAX_NAV_CHANGE_BPS;
        whitelistEnabled = enableWhitelist_;

        // pricePerShare = 0 intentionally — vault is uninitialised.
        // Deposits blocked until NAV_MANAGER calls setNAV() for the first time.

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(NAV_MANAGER_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);

        if (enableWhitelist_) emit WhitelistEnabled();
    }

    // =========================================================
    // UUPS — upgrade authorization
    // =========================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

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
        require(newCustody != address(0), "custody is zero");
        _validateCustody(newCustody, IERC20(asset()));
        address prev = custody;
        custody = newCustody;
        emit CustodyUpdated(prev, newCustody);
    }

    function setFeeBps(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= MAX_BPS, "fee bps too high");
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeRecipient != address(0), "fee recipient is zero");
        address prev = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(prev, newFeeRecipient);
    }

    function setMinDepositAssets(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = minDepositAssets;
        minDepositAssets = newMin;
        emit MinDepositAssetsUpdated(prev, newMin);
    }

    function setMinRedeemAssets(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = minRedeemAssets;
        minRedeemAssets = newMin;
        emit MinRedeemAssetsUpdated(prev, newMin);
    }

    function setNavStalenessThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = navStalenessThreshold;
        navStalenessThreshold = newThreshold;
        emit NavStalenessThresholdUpdated(prev, newThreshold);
    }

    function setMaxNavChangeBps(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMax <= MAX_BPS * 10, "unreasonably high");
        uint256 prev = maxNavChangeBps;
        maxNavChangeBps = newMax;
        emit MaxNavChangeBpsUpdated(prev, newMax);
    }

    function setTokenIdentifiers(string memory newName, string memory newSymbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(bytes(newName).length > 0, "name is empty");
        require(bytes(newSymbol).length > 0, "symbol is empty");
        _customName = newName;
        _customSymbol = newSymbol;
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
        require(account != address(0), "account is zero");
        whitelist[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setWhitelistedBatch(address[] calldata accounts, bool status) external onlyRole(OPERATOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account is zero");
            whitelist[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    // =========================================================
    // NAV Manager — price update
    // =========================================================

    /**
     * @notice Set share price. Only entry point for NAV updates.
     *
     * @dev The vault performs no yield computation. The fund admin determines NAV off-chain
     *      (whether yield came from price appreciation or additional tokens in custody) and
     *      reports it as a price per share. This follows the same pattern as OpenTrade's
     *      setExchangeRate — permissioned role, backend-mediated, no on-chain oracle needed.
     *
     *      Backend workflow:
     *        1. Read price from fund admin API / Chainlink / CoinGecko (off-chain, free)
     *        2. Call setNAV(newPricePerShare) — one tx, one storage write
     *
     *      Deviation guard: reverts if |newPrice - currentPrice| / currentPrice > maxNavChangeBps.
     *      Skipped on first call (pricePerShare == 0).
     *      For large loss events exceeding the guard: admin raises maxNavChangeBps temporarily.
     *
     * @param newPricePerShare  Price of 1 vault share in asset units (asset decimals precision).
     *                          e.g. USDC vault: 1_000_000 = 1.000000 USDC/share.
     *                          Initial call sets this from 0 — subsequent calls price from current.
     */
    function setNAV(uint256 newPricePerShare) external onlyRole(NAV_MANAGER_ROLE) {
        require(newPricePerShare > 0, "price is zero");

        if (pricePerShare > 0) {
            uint256 changeBps;
            if (newPricePerShare >= pricePerShare) {
                changeBps = (newPricePerShare - pricePerShare).mulDiv(MAX_BPS, pricePerShare, Math.Rounding.Ceil);
            } else {
                changeBps = (pricePerShare - newPricePerShare).mulDiv(MAX_BPS, pricePerShare, Math.Rounding.Ceil);
            }
            require(changeBps <= maxNavChangeBps, "nav change too large");
        }

        uint256 prev = pricePerShare;
        pricePerShare = newPricePerShare;
        priceUpdatedAt = block.timestamp;

        emit NavUpdated(prev, newPricePerShare);
    }

    // =========================================================
    // Admin — emergency sweep
    // =========================================================

    /**
     * @notice Sweep any third-party ERC-20 to custody.
     *
     * Blocked:
     *   - vault asset  — earmarked for redemption settlements
     *   - vault shares — escrowed pending redeem requests live here
     */
    function sweepTokenToCustody(address token, uint256 minAmount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0), "token is zero");
        require(token != asset(), "cannot sweep vault asset");
        require(token != address(this), "cannot sweep vault shares");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= minAmount, "below min sweep");
        IERC20(token).safeTransfer(custody, balance);
        emit TokenSweptToCustody(token, custody, balance);
    }

    // =========================================================
    // User — redeem queue
    // =========================================================

    /**
     * @notice Queue a redemption. Shares escrowed until finalized or rejected.
     *
     * @dev priceAtRequest locked at request time — used for finalization, not audit trail only.
     *      feeBpsAtRequest frozen at request — exit fee immune to future fee changes.
     *      Whitelist checked on msg.sender (the regulated party), not receiver.
     *
     * @param shares    Vault shares to redeem.
     * @param receiver  Address to receive assets on finalization.
     * @return id       Request ID (1-indexed).
     */
    function requestRedeem(uint256 shares, address receiver) external whenNotPaused nonReentrant returns (uint256 id) {
        require(shares > 0, "shares is zero");
        require(receiver != address(0), "receiver is zero");
        require(previewRedeem(shares) >= minRedeemAssets, "below min redeem");
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);

        _transfer(msg.sender, address(this), shares);

        id = ++nextRedeemRequestId;
        pendingRedeemCount += 1;
        totalRedeemRequestCount += 1;

        redeemRequests[id] = RedeemRequest({
            owner: msg.sender,
            receiver: receiver,
            shares: shares,
            priceAtRequest: pricePerShare,
            feeBpsAtRequest: feeBps,
            requestedAt: block.timestamp,
            processedAt: 0,
            status: RequestStatus.Pending
        });

        emit RedeemRequested(id, msg.sender, receiver, shares, pricePerShare, feeBps);
    }

    /**
     * @notice Finalize a pending redeem. Burns escrowed shares, sends net assets to receiver.
     *
     * @dev NOT gated by whenNotPaused — existing queue must drain during a pause.
     *
     *      Pricing: live pricePerShare at finalization time. NAV at request time is indicative only.
     *
     *      Custody must fund the vault (transfer assets to this contract) before
     *      this call, otherwise availableAssets() check reverts.
     *
     *      NAV staleness guard enforced — stale price blocks finalization to prevent
     *      settling redemptions against an outdated NAV.
     */
    function finalizeRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) nonReentrant {
        require(_isNavFresh(), "nav is stale");
        RedeemRequest storage request = redeemRequests[id];
        require(request.status == RequestStatus.Pending, "redeem not pending");

        uint256 grossAssets = request.shares.mulDiv(pricePerShare, 10 ** decimals(), Math.Rounding.Floor);
        uint256 feeAssets = _feeOnRaw(grossAssets, request.feeBpsAtRequest);
        uint256 netAssets = grossAssets - feeAssets;

        require(grossAssets > 0, "gross assets is zero");
        require(availableAssets() >= grossAssets, "insufficient liquidity");

        request.processedAt = block.timestamp;
        request.status = RequestStatus.Finalized;
        pendingRedeemCount -= 1;
        totalRedeemFinalized += 1;
        totalFeesAccrued += feeAssets;
        totalNetWithdrawnAssets += netAssets;
        totalRedeemedShares += request.shares;

        _burn(address(this), request.shares);

        IERC20(asset()).safeTransfer(request.receiver, netAssets);
        if (feeAssets > 0) IERC20(asset()).safeTransfer(feeRecipient, feeAssets);

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
        // ERC-4626 Withdraw event emits grossAssets per spec.
        emit Withdraw(msg.sender, request.receiver, request.owner, grossAssets, request.shares);
    }

    /**
     * @notice Reject a pending redeem. Returns escrowed shares to owner.
     * @dev NOT gated by whenNotPaused — queue must drain during a pause.
     */
    function rejectRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) nonReentrant {
        RedeemRequest storage request = redeemRequests[id];
        require(request.status == RequestStatus.Pending, "redeem not pending");

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

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    function name() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return bytes(_customName).length > 0 ? _customName : super.name();
    }

    function symbol() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return bytes(_customSymbol).length > 0 ? _customSymbol : super.symbol();
    }

    /**
     * @notice totalAssets = pricePerShare × totalSupply / 10^decimals.
     *         Pure read — no state written. Always reflects live NAV.
     *         Returns 0 when uninitialised (pricePerShare == 0).
     */
    function totalAssets() public view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return totalSupply().mulDiv(pricePerShare, 10 ** decimals(), Math.Rounding.Floor);
    }

    /// @notice Returns 0 (blocking deposits) when: paused, NAV stale/uninitialised, or receiver not whitelisted.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (!_isNavFresh()) return 0;
        if (whitelistEnabled && !whitelist[msg.sender]) return 0;
        if (whitelistEnabled && !whitelist[receiver]) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (!_isNavFresh()) return 0;
        if (whitelistEnabled && !whitelist[msg.sender]) return 0;
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

    /// @notice Asset balance held in this contract. Non-zero when custody has funded pending redemptions.
    function availableAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice True if NAV confirmed within navStalenessThreshold.
    function isNavFresh() external view returns (bool) {
        return _isNavFresh();
    }

    /// @notice Preview exit fee for a share count at current feeBps.
    function previewRedeemFee(uint256 shares) external view returns (uint256) {
        return _feeOnRaw(super.previewRedeem(shares), feeBps);
    }

    /// @notice Preview exit fee for an asset amount at current feeBps.
    function previewWithdrawFee(uint256 assets) external view returns (uint256) {
        return _feeOnRaw(assets, feeBps);
    }

    /// @notice Preview what a pending request would receive if finalized right now.
    function previewFinalizeRedeem(uint256 id)
        external
        view
        returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets)
    {
        RedeemRequest storage request = redeemRequests[id];
        require(request.status == RequestStatus.Pending, "redeem not pending");
        grossAssets = request.shares.mulDiv(pricePerShare, 10 ** decimals(), Math.Rounding.Floor);
        feeAssets = _feeOnRaw(grossAssets, request.feeBpsAtRequest);
        netAssets = grossAssets - feeAssets;
    }

    // =========================================================
    // ERC-4626 deposit / mint
    // =========================================================

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(assets >= minDepositAssets, "below min deposit");
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        require(assets >= minDepositAssets, "below min deposit");
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        assets = super.mint(shares, receiver);
    }

    // =========================================================
    // Internal overrides
    // =========================================================

    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert("queued withdrawals only");
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        require(_isNavFresh(), "nav is stale");
        super._deposit(caller, receiver, assets, shares);
        totalDepositedAssets += assets;
        totalMintedShares += shares;
        IERC20(asset()).safeTransfer(custody, assets);
        emit AssetsForwardedToCustody(custody, assets);
    }

    /**
     * @dev Share → asset conversion using live pricePerShare.
     *      shares × pricePerShare / 10^decimals
     *      Returns 0 when uninitialised (pricePerShare == 0).
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return shares.mulDiv(pricePerShare, 10 ** decimals(), rounding);
    }

    /**
     * @dev Asset → share conversion using live pricePerShare.
     *      assets × 10^decimals / pricePerShare
     *      Returns 0 when uninitialised (pricePerShare == 0).
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return assets.mulDiv(10 ** decimals(), pricePerShare, rounding);
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _decimalsOffsetVal;
    }

    // =========================================================
    // Internal — whitelist
    // =========================================================

    function _checkWhitelist(address account) internal view {
        if (whitelistEnabled) require(whitelist[account], "not whitelisted");
    }

    // =========================================================
    // Internal — NAV freshness
    // =========================================================

    /// @dev NAV is fresh if pricePerShare is set and updated within navStalenessThreshold.
    ///      priceUpdatedAt == 0 (uninitialised) is always stale.
    ///      navStalenessThreshold == 0 disables the check (pricePerShare > 0 sufficient).
    function _isNavFresh() internal view returns (bool) {
        if (priceUpdatedAt == 0) return false;
        if (navStalenessThreshold == 0) return true;
        return block.timestamp - priceUpdatedAt <= navStalenessThreshold;
    }

    // =========================================================
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
        require(custody_ != address(this), "custody is vault");
        require(custody_ != address(asset_), "custody is asset");
    }
}
