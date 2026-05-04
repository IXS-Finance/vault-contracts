// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity ^0.8.24;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

contract AsyncNavVault is ERC20, AccessControl, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');
  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');
  uint256 public constant MAX_BPS = 10_000;

  uint256 private constant NAV_PRECISION = 1e6;
  uint256 private constant SHARE_PRECISION = 1e18;

  enum RequestStatus {
    None,
    Requested,
    Finalized,
    Rejected
  }

  struct DepositRequest {
    address owner;
    uint256 assetAmount;
    uint256 navAtRequest;
    uint256 requestedAt;
    uint256 finalizedAt;
    uint256 rejectedAt;
    RequestStatus status;
  }

  struct RedeemRequest {
    address owner;
    uint256 shareAmount;
    uint256 navAtRequest;
    uint256 requestedAt;
    uint256 finalizedAt;
    uint256 rejectedAt;
    RequestStatus status;
  }

  IERC20 public immutable asset;
  address public custody;

  uint256 public nav;
  uint256 public minDepositAssetAmount;
  uint256 public minRedeemAssetAmount;
  uint256 public redeemFeeBps;
  address public feeRecipient;
  uint256 public totalFeesAccrued;

  uint256 public totalDepositRequested;
  uint256 public totalDepositFinalized;
  uint256 public totalDepositRejected;
  uint256 public pendingDepositCount;

  uint256 public totalRedeemRequested;
  uint256 public totalRedeemFinalized;
  uint256 public totalRedeemRejected;
  uint256 public pendingRedeemCount;

  uint256 public nextDepositRequestId;
  uint256 public nextRedeemRequestId;

  mapping(uint256 => DepositRequest) public depositRequests;
  mapping(uint256 => RedeemRequest) public redeemRequests;

  event DepositRequested(
    uint256 indexed id,
    address indexed owner,
    uint256 assetAmount,
    uint256 navAtRequest
  );

  event DepositFinalized(
    uint256 indexed id,
    address indexed owner,
    uint256 assetAmount,
    uint256 shareAmount,
    uint256 navAtRequest
  );

  event DepositRejected(
    uint256 indexed id,
    address indexed owner,
    uint256 assetAmount,
    uint256 navAtRequest
  );

  event RedeemRequested(
    uint256 indexed id,
    address indexed owner,
    uint256 shareAmount,
    uint256 navAtRequest
  );

  event RedeemFinalized(
    uint256 indexed id,
    address indexed owner,
    uint256 shareAmount,
    uint256 grossAssetAmount,
    uint256 feeAssetAmount,
    uint256 netAssetAmount,
    uint256 navAtRequest,
    uint256 feeBps
  );

  event RedeemRejected(
    uint256 indexed id,
    address indexed owner,
    uint256 shareAmount,
    uint256 navAtRequest
  );

  event NavUpdated(uint256 nav);
  event MinDepositAssetAmountUpdated(
    uint256 previousMinDepositAssetAmount,
    uint256 newMinDepositAssetAmount
  );
  event MinRedeemAssetAmountUpdated(
    uint256 previousMinRedeemAssetAmount,
    uint256 newMinRedeemAssetAmount
  );
  event RedeemFeeBpsUpdated(uint256 previousRedeemFeeBps, uint256 newRedeemFeeBps);
  event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);

  event CustodyUpdated(address indexed previousCustody, address indexed newCustody);
  event TokenSweptToCustody(address indexed token, address indexed custody, uint256 amount);

  constructor(
    string memory name_,
    string memory symbol_,
    address asset_,
    address custody_,
    address admin_
  ) ERC20(name_, symbol_) {
    require(bytes(name_).length > 0, 'name is empty');
    require(bytes(symbol_).length > 0, 'symbol is empty');
    require(asset_ != address(0), 'asset is zero');
    require(custody_ != address(0), 'custody is zero');
    require(custody_ != asset_, 'custody is asset');
    require(custody_ != address(this), 'custody is vault');
    require(admin_ != address(0), 'admin is zero');
    require(IERC20Metadata(asset_).decimals() == 6, 'asset decimals must be 6');

    asset = IERC20(asset_);
    custody = custody_;

    nav = NAV_PRECISION;
    minDepositAssetAmount = NAV_PRECISION;
    minRedeemAssetAmount = NAV_PRECISION;
    redeemFeeBps = 0;
    feeRecipient = custody_;

    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    _grantRole(OPERATOR_ROLE, admin_);
    _grantRole(PAUSER_ROLE, admin_);
  }

  function requestDeposit(uint256 assetAmount) external whenNotPaused nonReentrant returns (uint256 id) {
    require(assetAmount > 0, 'assetAmount is zero');
    require(assetAmount >= minDepositAssetAmount, 'below min deposit');
    require(nav > 0, 'nav is zero');

    asset.safeTransferFrom(msg.sender, address(this), assetAmount);
    asset.safeTransfer(custody, assetAmount);

    id = ++nextDepositRequestId;
    totalDepositRequested += 1;
    pendingDepositCount += 1;
    depositRequests[id] = DepositRequest({
      owner: msg.sender,
      assetAmount: assetAmount,
      navAtRequest: nav,
      requestedAt: block.timestamp,
      finalizedAt: 0,
      rejectedAt: 0,
      status: RequestStatus.Requested
    });

    emit DepositRequested(id, msg.sender, assetAmount, nav);
  }

  function finalizeDeposit(
    uint256 id
  ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (uint256 shareAmount) {
    DepositRequest storage request = depositRequests[id];
    require(request.status == RequestStatus.Requested, 'deposit not requested');

    shareAmount = _assetAmountToShareAmount(request.assetAmount, request.navAtRequest);
    request.finalizedAt = block.timestamp;
    request.status = RequestStatus.Finalized;
    totalDepositFinalized += 1;
    pendingDepositCount -= 1;

    _mint(request.owner, shareAmount);

    emit DepositFinalized(
      id,
      request.owner,
      request.assetAmount,
      shareAmount,
      request.navAtRequest
    );
  }

  function rejectDeposit(uint256 id) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
    DepositRequest storage request = depositRequests[id];
    require(request.status == RequestStatus.Requested, 'deposit not requested');
    require(asset.balanceOf(address(this)) >= request.assetAmount, 'insufficient asset liquidity');

    request.rejectedAt = block.timestamp;
    request.status = RequestStatus.Rejected;
    totalDepositRejected += 1;
    pendingDepositCount -= 1;
    asset.safeTransfer(request.owner, request.assetAmount);

    emit DepositRejected(id, request.owner, request.assetAmount, request.navAtRequest);
  }

  function requestRedeem(uint256 shareAmount) external whenNotPaused nonReentrant returns (uint256 id) {
    require(shareAmount > 0, 'shareAmount is zero');
    require(nav > 0, 'nav is zero');
    require(_shareAmountToAssetAmount(shareAmount, nav) >= minRedeemAssetAmount, 'below min redeem');

    _transfer(msg.sender, address(this), shareAmount);

    id = ++nextRedeemRequestId;
    totalRedeemRequested += 1;
    pendingRedeemCount += 1;
    redeemRequests[id] = RedeemRequest({
      owner: msg.sender,
      shareAmount: shareAmount,
      navAtRequest: nav,
      requestedAt: block.timestamp,
      finalizedAt: 0,
      rejectedAt: 0,
      status: RequestStatus.Requested
    });

    emit RedeemRequested(id, msg.sender, shareAmount, nav);
  }

  function finalizeRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
    RedeemRequest storage request = redeemRequests[id];
    require(request.status == RequestStatus.Requested, 'redeem not requested');

    uint256 grossAssetAmount = _shareAmountToAssetAmount(request.shareAmount, request.navAtRequest);
    uint256 feeAssetAmount = (grossAssetAmount * redeemFeeBps) / MAX_BPS;
    uint256 netAssetAmount = grossAssetAmount - feeAssetAmount;
    require(asset.balanceOf(address(this)) >= grossAssetAmount, 'insufficient asset liquidity');

    request.finalizedAt = block.timestamp;
    request.status = RequestStatus.Finalized;
    totalRedeemFinalized += 1;
    pendingRedeemCount -= 1;
    totalFeesAccrued += feeAssetAmount;

    _burn(address(this), request.shareAmount);
    asset.safeTransfer(request.owner, netAssetAmount);
    if (feeAssetAmount > 0) {
      asset.safeTransfer(feeRecipient, feeAssetAmount);
    }

    emit RedeemFinalized(
      id,
      request.owner,
      request.shareAmount,
      grossAssetAmount,
      feeAssetAmount,
      netAssetAmount,
      request.navAtRequest,
      redeemFeeBps
    );
  }

  function rejectRedeem(uint256 id) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
    RedeemRequest storage request = redeemRequests[id];
    require(request.status == RequestStatus.Requested, 'redeem not requested');

    request.rejectedAt = block.timestamp;
    request.status = RequestStatus.Rejected;
    totalRedeemRejected += 1;
    pendingRedeemCount -= 1;

    _transfer(address(this), request.owner, request.shareAmount);

    emit RedeemRejected(id, request.owner, request.shareAmount, request.navAtRequest);
  }

  function setNav(uint256 newNav) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newNav > 0, 'new nav is zero');
    nav = newNav;
    emit NavUpdated(newNav);
  }

  function setMinDepositAssetAmount(
    uint256 newMinDepositAssetAmount
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 previous = minDepositAssetAmount;
    minDepositAssetAmount = newMinDepositAssetAmount;
    emit MinDepositAssetAmountUpdated(previous, newMinDepositAssetAmount);
  }

  function setMinRedeemAssetAmount(
    uint256 newMinRedeemAssetAmount
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 previous = minRedeemAssetAmount;
    minRedeemAssetAmount = newMinRedeemAssetAmount;
    emit MinRedeemAssetAmountUpdated(previous, newMinRedeemAssetAmount);
  }

  function setRedeemFeeBps(uint256 newRedeemFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newRedeemFeeBps <= MAX_BPS, 'fee bps too high');
    uint256 previous = redeemFeeBps;
    redeemFeeBps = newRedeemFeeBps;
    emit RedeemFeeBpsUpdated(previous, newRedeemFeeBps);
  }

  function setFeeRecipient(address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newFeeRecipient != address(0), 'fee recipient is zero');
    address previous = feeRecipient;
    feeRecipient = newFeeRecipient;
    emit FeeRecipientUpdated(previous, newFeeRecipient);
  }

  function setCustody(address newCustody) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newCustody != address(0), 'custody is zero');
    require(newCustody != address(asset), 'custody is asset');
    require(newCustody != address(this), 'custody is vault');

    address previous = custody;
    custody = newCustody;

    emit CustodyUpdated(previous, newCustody);
  }

  function sweepTokenToCustody(address token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    require(token != address(0), 'token is zero');
    require(token != address(this), 'token is share');

    IERC20 sweepToken = IERC20(token);
    uint256 balance = sweepToken.balanceOf(address(this));
    if (balance == 0) {
      return;
    }

    sweepToken.safeTransfer(custody, balance);
    emit TokenSweptToCustody(token, custody, balance);
  }

  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  function previewShares(uint256 assetAmount) external view returns (uint256) {
    return _assetAmountToShareAmount(assetAmount, nav);
  }

  function previewSharesFromNav(
    uint256 assetAmount,
    uint256 navValue
  ) external pure returns (uint256) {
    return _assetAmountToShareAmount(assetAmount, navValue);
  }

  function _assetAmountToShareAmount(
    uint256 assetAmount,
    uint256 navAtRequest
  ) internal pure returns (uint256) {
    require(navAtRequest > 0, 'navAtRequest is zero');

    return (assetAmount * SHARE_PRECISION) / navAtRequest;
  }

  function _shareAmountToAssetAmount(
    uint256 shareAmount,
    uint256 navAtRequest
  ) internal pure returns (uint256) {
    require(navAtRequest > 0, 'navAtRequest is zero');

    return (shareAmount * navAtRequest) / SHARE_PRECISION;
  }
}
