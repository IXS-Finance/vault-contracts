// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AsyncNavVault} from "../contracts/AsyncNavVault.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";
import {TokenizedVaultAsyncWithdrawals} from "../contracts/TokenizedVaultAsyncWithdrawals.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
}

contract AsyncNavVaultFuzzTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ONE_USDC = 1e6;
    uint256 private constant MAX_ASSET_AMOUNT = 1_000_000_000_000_000; // 1e15 base units = 1e9 USDC
    uint256 private constant MAX_NAV = 1_000_000_000_000; // positive and large enough to vary meaningfully
    uint256 private constant INITIAL_MINT = 1_000_000_000_000_000_000_000_000;

    address private constant ADMIN = address(0xA11CE);
    address private constant USER = address(0xB0B);
    address private constant SECOND_USER = address(0xB0B1);
    address private constant CUSTODY = address(0xC0FFEE);

    MockUSDC private usdc;
    AsyncNavVault private vault;

    function setUp() public {
        vm.startPrank(ADMIN);
        usdc = new MockUSDC(0);
        vault = new AsyncNavVault("Async NAV Vault Share", "ANVS", address(usdc), CUSTODY, ADMIN);
        usdc.mint(USER, INITIAL_MINT);
        usdc.mint(SECOND_USER, INITIAL_MINT);
        vm.stopPrank();
    }

    function testFuzz_FinalizeDepositUsesNavSnapshot(
        uint256 rawAssetAmount,
        uint256 rawNavBefore,
        uint256 rawNavAfter
    ) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 navBefore = _boundNav(rawNavBefore);
        uint256 navAfter = _boundNav(rawNavAfter);

        vm.prank(ADMIN);
        vault.setNav(navBefore);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount);
        vm.stopPrank();

        uint256 requestId = vault.nextDepositRequestId();
        uint256 expectedShares = vault.previewSharesFromNav(assetAmount, navBefore);

        vm.prank(ADMIN);
        vault.setNav(navAfter);

        vm.prank(ADMIN);
        vault.finalizeDeposit(requestId);

        (
            address owner,
            uint256 storedAssetAmount,
            uint256 navAtRequest,
            ,
            uint256 finalizedAt,
            uint256 rejectedAt,
            AsyncNavVault.RequestStatus status
        ) = vault.depositRequests(requestId);

        require(owner == USER, "deposit owner mismatch");
        require(storedAssetAmount == assetAmount, "deposit amount mismatch");
        require(navAtRequest == navBefore, "nav snapshot mismatch");
        require(finalizedAt > 0, "deposit not finalized");
        require(rejectedAt == 0, "deposit rejected");
        require(status == AsyncNavVault.RequestStatus.Finalized, "deposit status not finalized");
        require(vault.balanceOf(USER) == expectedShares, "unexpected share mint");
    }

    function testFuzz_RejectDepositReturnsAssets(
        uint256 rawAssetAmount,
        uint256 rawNav
    ) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 navValue = _boundNav(rawNav);

        vm.prank(ADMIN);
        vault.setNav(navValue);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount);
        vm.stopPrank();

        uint256 requestId = vault.nextDepositRequestId();
        uint256 userBalanceBefore = usdc.balanceOf(USER);

        vm.prank(CUSTODY);
        usdc.transfer(address(vault), assetAmount);

        vm.prank(ADMIN);
        vault.rejectDeposit(requestId);

        (
            ,
            ,
            ,
            ,
            uint256 finalizedAt,
            uint256 rejectedAt,
            AsyncNavVault.RequestStatus status
        ) = vault.depositRequests(requestId);

        require(finalizedAt == 0, "deposit finalized unexpectedly");
        require(rejectedAt > 0, "deposit not rejected");
        require(status == AsyncNavVault.RequestStatus.Rejected, "deposit status not rejected");
        require(usdc.balanceOf(USER) == userBalanceBefore + assetAmount, "refund mismatch");
        require(usdc.balanceOf(CUSTODY) == 0, "custody should not retain rejected deposit assets");
    }

    function testFuzz_RejectRedeemRestoresEscrowedShares(uint256 rawAssetAmount) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 navBefore = ONE_USDC;

        vm.prank(ADMIN);
        vault.setNav(navBefore);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount);
        vm.stopPrank();

        uint256 depositId = vault.nextDepositRequestId();
        vm.prank(ADMIN);
        vault.finalizeDeposit(depositId);

        uint256 shares = vault.balanceOf(USER);
        vm.startPrank(USER);
        vault.requestRedeem(shares);
        vm.stopPrank();

        uint256 redeemId = vault.nextRedeemRequestId();

        vm.prank(ADMIN);
        vault.rejectRedeem(redeemId);

        (
            address owner,
            uint256 storedShares,
            uint256 navAtRequest,
            ,
            uint256 finalizedAt,
            uint256 rejectedAt,
            AsyncNavVault.RequestStatus status
        ) = vault.redeemRequests(redeemId);

        require(owner == USER, "redeem owner mismatch");
        require(storedShares == shares, "redeem share amount mismatch");
        require(navAtRequest == navBefore, "redeem nav snapshot mismatch");
        require(finalizedAt == 0, "redeem finalized unexpectedly");
        require(rejectedAt > 0, "redeem not rejected");
        require(status == AsyncNavVault.RequestStatus.Rejected, "redeem status not rejected");
        require(vault.balanceOf(USER) == shares, "escrowed shares not restored");
        require(vault.balanceOf(address(vault)) == 0, "vault still holds shares");
    }

    function testFuzz_MultipleDepositRequestsFinalizeAndRejectOutOfOrder(
        uint256 rawFirstAmount,
        uint256 rawSecondAmount,
        bool finalizeSecondFirst
    ) public {
        uint256 firstAmount = _boundAssetAmount(rawFirstAmount);
        uint256 secondAmount = _boundAssetAmount(rawSecondAmount);

        vm.prank(ADMIN);
        vault.setNav(ONE_USDC);

        uint256 userBalanceBefore = usdc.balanceOf(USER);
        uint256 secondUserBalanceBefore = usdc.balanceOf(SECOND_USER);

        vm.startPrank(USER);
        usdc.approve(address(vault), firstAmount);
        vault.requestDeposit(firstAmount);
        vm.stopPrank();
        uint256 firstDepositId = vault.nextDepositRequestId();

        vm.startPrank(SECOND_USER);
        usdc.approve(address(vault), secondAmount);
        vault.requestDeposit(secondAmount);
        vm.stopPrank();
        uint256 secondDepositId = vault.nextDepositRequestId();

        require(vault.pendingDepositCount() == 2, "pending deposit count mismatch");
        require(vault.totalDepositRequested() == 2, "deposit request count mismatch");
        require(vault.nextDepositRequestId() == 2, "deposit id mismatch");

        if (finalizeSecondFirst) {
            vm.prank(ADMIN);
            vault.finalizeDeposit(secondDepositId);

            vm.prank(CUSTODY);
            usdc.transfer(address(vault), firstAmount);

            vm.prank(ADMIN);
            vault.rejectDeposit(firstDepositId);

            _assertDepositState(firstDepositId, USER, firstAmount, false, firstAmount, true);
            _assertDepositState(secondDepositId, SECOND_USER, secondAmount, true, secondAmount, false);

            require(usdc.balanceOf(USER) == userBalanceBefore, "rejected deposit should refund user");
            require(
                usdc.balanceOf(SECOND_USER) == secondUserBalanceBefore - secondAmount,
                "finalized deposit should leave assets forwarded"
            );
            require(vault.balanceOf(SECOND_USER) == vault.previewSharesFromNav(secondAmount, ONE_USDC), "finalized share mismatch");
            require(vault.balanceOf(USER) == 0, "rejected user should not receive shares");
        } else {
            vm.prank(ADMIN);
            vault.finalizeDeposit(firstDepositId);

            vm.prank(CUSTODY);
            usdc.transfer(address(vault), secondAmount);

            vm.prank(ADMIN);
            vault.rejectDeposit(secondDepositId);

            _assertDepositState(firstDepositId, USER, firstAmount, true, firstAmount, false);
            _assertDepositState(secondDepositId, SECOND_USER, secondAmount, false, secondAmount, true);

            require(
                usdc.balanceOf(USER) == userBalanceBefore - firstAmount,
                "finalized deposit should leave user funds forwarded"
            );
            require(usdc.balanceOf(SECOND_USER) == secondUserBalanceBefore, "rejected deposit should refund user");
            require(vault.balanceOf(USER) == vault.previewSharesFromNav(firstAmount, ONE_USDC), "finalized share mismatch");
            require(vault.balanceOf(SECOND_USER) == 0, "rejected user should not receive shares");
        }

        require(vault.totalDepositFinalized() == 1, "finalized deposit count mismatch");
        require(vault.totalDepositRejected() == 1, "rejected deposit count mismatch");
        require(vault.pendingDepositCount() == 0, "pending deposits not cleared");
    }

    function testFuzz_MultipleRedeemRequestsFinalizeAndRejectOutOfOrder(
        uint256 rawFirstAmount,
        uint256 rawSecondAmount,
        bool finalizeSecondFirst
    ) public {
        uint256 firstAmount = _boundAssetAmount(rawFirstAmount);
        uint256 secondAmount = _boundAssetAmount(rawSecondAmount);

        vm.prank(ADMIN);
        vault.setNav(ONE_USDC);

        (uint256 firstDepositId, uint256 firstShares) = _depositAndFinalize(USER, firstAmount);
        (uint256 secondDepositId, uint256 secondShares) = _depositAndFinalize(SECOND_USER, secondAmount);

        uint256 userBalanceBefore = usdc.balanceOf(USER);
        uint256 secondUserBalanceBefore = usdc.balanceOf(SECOND_USER);

        vm.startPrank(USER);
        vault.requestRedeem(firstShares);
        vm.stopPrank();
        uint256 firstRedeemId = vault.nextRedeemRequestId();

        vm.startPrank(SECOND_USER);
        vault.requestRedeem(secondShares);
        vm.stopPrank();
        uint256 secondRedeemId = vault.nextRedeemRequestId();

        require(vault.pendingRedeemCount() == 2, "pending redeem count mismatch");
        require(vault.totalRedeemRequested() == 2, "redeem request count mismatch");
        require(vault.nextRedeemRequestId() == 2, "redeem id mismatch");

        if (finalizeSecondFirst) {
            vm.prank(CUSTODY);
            usdc.transfer(address(vault), secondAmount);

            vm.prank(ADMIN);
            vault.finalizeRedeem(secondRedeemId);

            vm.prank(ADMIN);
            vault.rejectRedeem(firstRedeemId);

            _assertRedeemState(firstRedeemId, USER, firstShares, true, false);
            _assertRedeemState(secondRedeemId, SECOND_USER, secondShares, true, true);

            require(usdc.balanceOf(USER) == userBalanceBefore, "rejected redeem should leave user balance unchanged");
            require(
                usdc.balanceOf(SECOND_USER) == secondUserBalanceBefore + secondAmount,
                "finalized redeem should return original balance"
            );
            require(vault.balanceOf(USER) == firstShares, "rejected redeem should restore shares");
            require(vault.balanceOf(SECOND_USER) == 0, "finalized redeem should burn escrowed shares");
        } else {
            vm.prank(CUSTODY);
            usdc.transfer(address(vault), firstAmount);

            vm.prank(ADMIN);
            vault.finalizeRedeem(firstRedeemId);

            vm.prank(ADMIN);
            vault.rejectRedeem(secondRedeemId);

            _assertRedeemState(firstRedeemId, USER, firstShares, true, true);
            _assertRedeemState(secondRedeemId, SECOND_USER, secondShares, true, false);

            require(usdc.balanceOf(USER) == userBalanceBefore + firstAmount, "finalized redeem should return original balance");
            require(
                usdc.balanceOf(SECOND_USER) == secondUserBalanceBefore,
                "rejected redeem should leave user balance unchanged"
            );
            require(vault.balanceOf(USER) == 0, "finalized redeem should burn escrowed shares");
            require(vault.balanceOf(SECOND_USER) == secondShares, "rejected redeem should restore shares");
        }

        require(firstDepositId == 1, "first deposit id mismatch");
        require(secondDepositId == 2, "second deposit id mismatch");
        require(vault.totalRedeemFinalized() == 1, "finalized redeem count mismatch");
        require(vault.totalRedeemRejected() == 1, "rejected redeem count mismatch");
        require(vault.pendingRedeemCount() == 0, "pending redeems not cleared");
    }

    function testFuzz_RequestDepositHonorsMinBoundary(uint256 rawMinDeposit) public {
        // Ensure minDeposit > ONE_USDC so belowMin is a meaningful below-min value, not zero.
        uint256 minDeposit = _boundAssetAmount(rawMinDeposit) + ONE_USDC;
        uint256 belowMinDeposit = minDeposit - ONE_USDC;

        vm.prank(ADMIN);
        vault.setNav(ONE_USDC);

        vm.prank(ADMIN);
        vault.setMinDepositAssetAmount(minDeposit);

        vm.startPrank(USER);
        usdc.approve(address(vault), minDeposit);

        vm.expectRevert(bytes("below min deposit"));
        vault.requestDeposit(belowMinDeposit);

        vault.requestDeposit(minDeposit);
        vm.stopPrank();

        uint256 requestId = vault.nextDepositRequestId();

        vm.prank(ADMIN);
        vault.finalizeDeposit(requestId);

        require(vault.balanceOf(USER) == vault.previewSharesFromNav(minDeposit, ONE_USDC), "min deposit share mismatch");
        require(vault.pendingDepositCount() == 0, "pending deposit count mismatch");
    }

    function testFuzz_RequestRedeemHonorsMinBoundary(uint256 rawMinRedeem) public {
        // Ensure minRedeem > ONE_USDC so belowMin is a meaningful below-min value, not zero.
        uint256 minRedeem = _boundAssetAmount(rawMinRedeem) + ONE_USDC;
        uint256 belowMinRedeem = minRedeem - ONE_USDC;

        vm.prank(ADMIN);
        vault.setNav(ONE_USDC);

        vm.prank(ADMIN);
        vault.setMinRedeemAssetAmount(minRedeem);

        vm.startPrank(USER);
        usdc.approve(address(vault), minRedeem);
        vault.requestDeposit(minRedeem);
        vm.stopPrank();

        uint256 depositId = vault.nextDepositRequestId();
        vm.prank(ADMIN);
        vault.finalizeDeposit(depositId);

        uint256 shares = vault.balanceOf(USER);
        uint256 belowMinShares = vault.previewSharesFromNav(belowMinRedeem, ONE_USDC);

        vm.startPrank(USER);
        vm.expectRevert(bytes("below min redeem"));
        vault.requestRedeem(belowMinShares);

        vault.requestRedeem(shares);
        vm.stopPrank();

        uint256 redeemId = vault.nextRedeemRequestId();

        vm.prank(ADMIN);
        vault.rejectRedeem(redeemId);

        require(vault.balanceOf(USER) == shares, "min redeem share mismatch");
        require(vault.pendingRedeemCount() == 0, "pending redeem count mismatch");
    }

    function testFuzz_PauseBlocksAndUnpauseRestoresFlows(uint256 rawAssetAmount) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);

        vm.prank(ADMIN);
        vault.setNav(ONE_USDC);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount);
        vm.stopPrank();

        uint256 depositId = vault.nextDepositRequestId();

        vm.prank(ADMIN);
        vault.pause();

        vm.prank(USER);
        usdc.approve(address(vault), assetAmount);

        bytes memory enforcedPause = abi.encodeWithSignature("EnforcedPause()");

        vm.expectRevert(enforcedPause);
        vm.prank(USER);
        vault.requestDeposit(assetAmount);

        vm.expectRevert(enforcedPause);
        vm.prank(ADMIN);
        vault.finalizeDeposit(depositId);

        vm.expectRevert(enforcedPause);
        vm.prank(ADMIN);
        vault.rejectDeposit(depositId);

        vm.prank(ADMIN);
        vault.unpause();

        vm.prank(ADMIN);
        vault.finalizeDeposit(depositId);

        uint256 shares = vault.balanceOf(USER);

        vm.prank(ADMIN);
        vault.pause();

        vm.expectRevert(enforcedPause);
        vm.prank(USER);
        vault.requestRedeem(shares);

        vm.prank(ADMIN);
        vault.unpause();

        vm.prank(USER);
        vault.requestRedeem(shares);
        uint256 redeemId = vault.nextRedeemRequestId();

        vm.prank(ADMIN);
        vault.pause();

        vm.expectRevert(enforcedPause);
        vm.prank(ADMIN);
        vault.finalizeRedeem(redeemId);

        vm.expectRevert(enforcedPause);
        vm.prank(ADMIN);
        vault.rejectRedeem(redeemId);

        vm.prank(ADMIN);
        vault.unpause();

        vm.prank(CUSTODY);
        usdc.transfer(address(vault), assetAmount);

        vm.prank(ADMIN);
        vault.finalizeRedeem(redeemId);

        require(vault.pendingDepositCount() == 0, "pending deposit count mismatch");
        require(vault.pendingRedeemCount() == 0, "pending redeem count mismatch");
        require(vault.balanceOf(USER) == 0, "user shares not cleared");
        require(usdc.balanceOf(USER) == INITIAL_MINT, "final user balance mismatch");
    }

    function _depositAndFinalize(
        address user,
        uint256 assetAmount
    ) internal returns (uint256 requestId, uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount);
        vm.stopPrank();

        requestId = vault.nextDepositRequestId();

        vm.prank(ADMIN);
        vault.finalizeDeposit(requestId);

        shares = vault.balanceOf(user);
    }

    function _assertDepositState(
        uint256 requestId,
        address owner,
        uint256 assetAmount,
        bool finalized,
        uint256 expectedAssets,
        bool rejected
    ) internal view {
        (
            address storedOwner,
            uint256 storedAssetAmount,
            ,
            ,
            uint256 finalizedAt,
            uint256 rejectedAt,
            AsyncNavVault.RequestStatus status
        ) = vault.depositRequests(requestId);

        require(storedOwner == owner, "deposit owner mismatch");
        require(storedAssetAmount == assetAmount, "deposit asset amount mismatch");
        require(vault.balanceOf(owner) == (finalized ? vault.previewSharesFromNav(expectedAssets, ONE_USDC) : 0), "deposit share mismatch");
        require((finalizedAt > 0) == finalized, "deposit finalized flag mismatch");
        require((rejectedAt > 0) == rejected, "deposit rejected flag mismatch");
        require(
            status == (finalized
                ? AsyncNavVault.RequestStatus.Finalized
                : AsyncNavVault.RequestStatus.Rejected),
            "deposit status mismatch"
        );
    }

    function _assertRedeemState(
        uint256 requestId,
        address owner,
        uint256 shareAmount,
        bool processed,
        bool finalized
    ) internal view {
        (
            address storedOwner,
            uint256 storedShareAmount,
            ,
            ,
            uint256 finalizedAt,
            uint256 rejectedAt,
            AsyncNavVault.RequestStatus status
        ) = vault.redeemRequests(requestId);

        require(storedOwner == owner, "redeem owner mismatch");
        require(storedShareAmount == shareAmount, "redeem share amount mismatch");
        require((finalizedAt > 0) == (processed && finalized), "redeem finalized flag mismatch");
        require((rejectedAt > 0) == (processed && !finalized), "redeem rejected flag mismatch");
        require(
            status == (finalized
                ? AsyncNavVault.RequestStatus.Finalized
                : AsyncNavVault.RequestStatus.Rejected),
            "redeem status mismatch"
        );
    }

    function _boundAssetAmount(uint256 raw) internal pure returns (uint256) {
        return (raw % MAX_ASSET_AMOUNT) + ONE_USDC;
    }

    function _boundNav(uint256 raw) internal pure returns (uint256) {
        return (raw % MAX_NAV) + 1;
    }
}

contract TokenizedVaultAsyncWithdrawalsFuzzTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ONE_USDC = 1e6;
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant MAX_ASSET_AMOUNT = 1_000_000_000_000_000; // 1e15 base units = 1e9 USDC

    address private constant ADMIN = address(0xA11CE);
    address private constant USER = address(0xB0B);
    address private constant CUSTODY = address(0xC0FFEE);
    address private constant FEE_RECIPIENT = address(0xFEE);

    MockUSDC private usdc;
    TokenizedVaultAsyncWithdrawals private vault;

    function setUp() public {
        vm.startPrank(ADMIN);
        usdc = new MockUSDC(0);
        vault = new TokenizedVaultAsyncWithdrawals(
            usdc,
            "Requestable NAV Vault Share",
            "RNVS",
            ADMIN,
            CUSTODY,
            false
        );
        usdc.mint(USER, 1_000_000_000_000_000_000_000_000);
        vault.setFeeRecipient(FEE_RECIPIENT);
        // Prime NAV so _isNavFresh() passes and deposits are accepted.
        vault.reportManagedAssets(0, 0);
        vm.stopPrank();
    }

    function testFuzz_FinalizeRedeemUsesFeeSnapshot(
        uint256 rawAssetAmount,
        uint256 rawInitialFeeBps,
        uint256 rawLaterFeeBps
    ) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 initialFeeBps = _boundBps(rawInitialFeeBps);
        uint256 laterFeeBps = _boundBps(rawLaterFeeBps);

        vm.prank(ADMIN);
        vault.setFeeBps(initialFeeBps);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        uint256 shares = vault.previewDeposit(assetAmount);
        vault.deposit(assetAmount, USER);
        vault.requestRedeem(shares, USER);
        vm.stopPrank();

        uint256 redeemId = vault.nextRedeemRequestId();
        uint256 expectedNetAssets = vault.previewRedeem(shares);
        uint256 expectedFeeAssets = vault.previewRedeemFee(shares);
        uint256 grossAssets = expectedNetAssets + expectedFeeAssets;
        uint256 userBalanceBefore = usdc.balanceOf(USER);
        uint256 feeBalanceBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.prank(ADMIN);
        vault.setFeeBps(laterFeeBps);

        vm.prank(CUSTODY);
        usdc.transfer(address(vault), grossAssets);

        vm.prank(ADMIN);
        vault.finalizeRedeem(redeemId);

        (
            address owner,
            address receiver,
            uint256 storedShares,
            ,
            uint256 feeBpsAtRequest,
            ,
            uint256 processedAt,
            TokenizedVaultAsyncWithdrawals.RequestStatus status
        ) = vault.redeemRequests(redeemId);

        require(owner == USER, "redeem owner mismatch");
        require(receiver == USER, "redeem receiver mismatch");
        require(storedShares == shares, "redeem share amount mismatch");
        require(feeBpsAtRequest == initialFeeBps, "fee snapshot mismatch");
        require(processedAt > 0, "redeem not processed");
        require(
            status == TokenizedVaultAsyncWithdrawals.RequestStatus.Finalized,
            "redeem status not finalized"
        );
        require(usdc.balanceOf(USER) == userBalanceBefore + expectedNetAssets, "net asset mismatch");
        require(
            usdc.balanceOf(FEE_RECIPIENT) == feeBalanceBefore + expectedFeeAssets,
            "fee asset mismatch"
        );
        require(vault.totalFeesAccrued() == expectedFeeAssets, "fee accounting mismatch");
        require(vault.pendingRedeemCount() == 0, "pending redeem count mismatch");
        require(vault.balanceOf(address(vault)) == 0, "vault still holds shares");
        require(vault.balanceOf(USER) == 0, "user still holds shares");
    }

    function testFuzz_FinalizeRedeemUsesFeeBoundary(
        uint256 rawAssetAmount,
        bool useMaxFee
    ) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 feeBps = useMaxFee ? MAX_BPS : 0;

        vm.prank(ADMIN);
        vault.setFeeBps(feeBps);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        uint256 shares = vault.previewDeposit(assetAmount);
        vault.deposit(assetAmount, USER);
        vault.requestRedeem(shares, USER);
        vm.stopPrank();

        uint256 redeemId = vault.nextRedeemRequestId();
        uint256 expectedNetAssets = vault.previewRedeem(shares);
        uint256 expectedFeeAssets = vault.previewRedeemFee(shares);
        uint256 grossAssets = expectedNetAssets + expectedFeeAssets;
        uint256 userBalanceBefore = usdc.balanceOf(USER);
        uint256 feeBalanceBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.prank(CUSTODY);
        usdc.transfer(address(vault), grossAssets);

        vm.prank(ADMIN);
        vault.finalizeRedeem(redeemId);

        require(usdc.balanceOf(USER) == userBalanceBefore + expectedNetAssets, "boundary net asset mismatch");
        require(
            usdc.balanceOf(FEE_RECIPIENT) == feeBalanceBefore + expectedFeeAssets,
            "boundary fee asset mismatch"
        );
        require(vault.totalFeesAccrued() == expectedFeeAssets, "boundary fee accounting mismatch");
        require(vault.pendingRedeemCount() == 0, "boundary pending redeem count mismatch");
    }

    function testFuzz_RejectRedeemRestoresEscrowedShares(
        uint256 rawAssetAmount,
        uint256 rawFeeBps
    ) public {
        uint256 assetAmount = _boundAssetAmount(rawAssetAmount);
        uint256 feeBps = _boundBps(rawFeeBps);

        vm.prank(ADMIN);
        vault.setFeeBps(feeBps);

        vm.startPrank(USER);
        usdc.approve(address(vault), assetAmount);
        uint256 shares = vault.previewDeposit(assetAmount);
        vault.deposit(assetAmount, USER);
        vault.requestRedeem(shares, USER);
        vm.stopPrank();

        uint256 redeemId = vault.nextRedeemRequestId();
        require(vault.balanceOf(USER) == 0, "shares not escrowed");
        require(vault.balanceOf(address(vault)) == shares, "vault escrow mismatch");

        vm.prank(ADMIN);
        vault.rejectRedeem(redeemId);

        (
            address owner,
            address receiver,
            uint256 storedShares,
            ,
            uint256 feeBpsAtRequest,
            ,
            uint256 processedAt,
            TokenizedVaultAsyncWithdrawals.RequestStatus status
        ) = vault.redeemRequests(redeemId);

        require(owner == USER, "redeem owner mismatch");
        require(receiver == USER, "redeem receiver mismatch");
        require(storedShares == shares, "redeem share amount mismatch");
        require(feeBpsAtRequest == feeBps, "fee snapshot mismatch");
        require(processedAt > 0, "redeem not processed");
        require(
            status == TokenizedVaultAsyncWithdrawals.RequestStatus.Rejected,
            "redeem status not rejected"
        );
        require(vault.balanceOf(USER) == shares, "shares not restored");
        require(vault.balanceOf(address(vault)) == 0, "vault still holds shares");
        require(vault.totalFeesAccrued() == 0, "fees accrued on rejection");
        require(vault.pendingRedeemCount() == 0, "pending redeem count mismatch");
    }

    function _boundAssetAmount(uint256 raw) internal pure returns (uint256) {
        return (raw % MAX_ASSET_AMOUNT) + ONE_USDC;
    }

    function _boundBps(uint256 raw) internal pure returns (uint256) {
        return raw % (MAX_BPS + 1);
    }
}
