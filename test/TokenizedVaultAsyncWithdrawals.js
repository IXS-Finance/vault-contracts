import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const ONE_USDC = 1_000_000n;
const ONE_SHARE = 10n ** 18n;
const MAX_BPS = 10_000n;

describe("TokenizedVaultAsyncWithdrawals", function () {
  async function deployFixture() {
    const [admin, user, custody, feeRecipient, outsider] = await ethers.getSigners();

    const usdc = await ethers.deployContract("MockUSDC", [0n], admin);
    const vault = await ethers.deployContract(
      "TokenizedVaultAsyncWithdrawals",
      [await usdc.getAddress(), "Requestable NAV Vault Share", "RNVS", admin.address, custody.address],
      admin,
    );

    await usdc.connect(admin).mint(user.address, 1_000_000n * ONE_USDC);

    return { admin, user, custody, feeRecipient, outsider, usdc, vault };
  }

  async function depositForUser(vault, usdc, user, assets) {
    await usdc.connect(user).approve(await vault.getAddress(), assets);
    await vault.connect(user).deposit(assets, user.address);
    return vault.balanceOf(user.address);
  }

  function feeOnTotalCeil(assets, feeBps) {
    const numerator = assets * feeBps;
    const denominator = MAX_BPS + feeBps;
    return (numerator + denominator - 1n) / denominator;
  }

  it("disables synchronous withdraw/redeem surface", async function () {
    const { admin, user, custody, usdc, vault } = await deployFixture();
    const shares = await depositForUser(vault, usdc, user, 100n * ONE_USDC);
    const grossAssets = await vault.convertToAssets(shares);

    await usdc.connect(custody).transfer(await vault.getAddress(), grossAssets);

    expect(await vault.maxWithdraw(user.address)).to.equal(0n);
    expect(await vault.maxRedeem(user.address)).to.equal(0n);
    await expect(vault.connect(user).withdraw(1n, user.address, user.address)).to.be.rejected;
    await expect(vault.connect(user).redeem(1n, user.address, user.address)).to.be.rejected;
    expect(await vault.balanceOf(user.address)).to.equal(shares);
    expect(await vault.totalSupply()).to.equal(100n * ONE_SHARE);
    expect(await vault.totalAssets()).to.equal(100n * ONE_USDC);
    expect(await usdc.balanceOf(await vault.getAddress())).to.equal(grossAssets);
    expect(await usdc.balanceOf(custody.address)).to.equal(0n);
    expect(await usdc.balanceOf(user.address)).to.equal(1_000_000n * ONE_USDC - 100n * ONE_USDC);
    expect(await vault.pendingRedeemCount()).to.equal(0n);
  });

  it("requestRedeem snapshots feeBps and finalize uses snapshot", async function () {
    const { admin, user, custody, feeRecipient, usdc, vault } = await deployFixture();
    const shares = await depositForUser(vault, usdc, user, 200n * ONE_USDC);

    await vault.connect(admin).setFeeRecipient(feeRecipient.address);
    await vault.connect(admin).setFeeBps(100n); // 1%

    await vault.connect(user).requestRedeem(shares, user.address);
    const id = await vault.nextRedeemRequestId();
    const request = await vault.redeemRequests(id);
    expect(request.feeBpsAtRequest).to.equal(100n);

    await vault.connect(admin).setFeeBps(900n); // 9%, should not affect this request

    const grossAssets = await vault.convertToAssets(shares);
    const expectedFeeAssets = feeOnTotalCeil(grossAssets, 100n);
    const expectedNetAssets = grossAssets - expectedFeeAssets;

    await usdc.connect(custody).transfer(await vault.getAddress(), grossAssets);

    const userBalanceBefore = await usdc.balanceOf(user.address);
    const feeBalanceBefore = await usdc.balanceOf(feeRecipient.address);

    await vault.connect(admin).finalizeRedeem(id);

    expect(await usdc.balanceOf(user.address) - userBalanceBefore).to.equal(expectedNetAssets);
    expect(await usdc.balanceOf(feeRecipient.address) - feeBalanceBefore).to.equal(expectedFeeAssets);
    expect(await vault.totalFeesAccrued()).to.equal(expectedFeeAssets);
    expect(await vault.pendingRedeemCount()).to.equal(0n);
    expect(await vault.totalRedeemFinalized()).to.equal(1n);
    expect((await vault.redeemRequests(id)).status).to.equal(2n);
  });

  it("rejectRedeem returns escrowed shares without charging fee", async function () {
    const { admin, user, usdc, vault } = await deployFixture();
    const shares = await depositForUser(vault, usdc, user, 50n * ONE_USDC);

    await vault.connect(admin).setFeeBps(250n);
    await vault.connect(user).requestRedeem(shares, user.address);
    const id = await vault.nextRedeemRequestId();

    expect(await vault.balanceOf(user.address)).to.equal(0n);
    expect(await vault.balanceOf(await vault.getAddress())).to.equal(shares);

    await vault.connect(admin).rejectRedeem(id);

    expect(await vault.balanceOf(user.address)).to.equal(shares);
    expect(await vault.balanceOf(await vault.getAddress())).to.equal(0n);
    expect(await vault.totalFeesAccrued()).to.equal(0n);
    expect(await vault.pendingRedeemCount()).to.equal(0n);
    expect(await vault.totalRedeemRejected()).to.equal(1n);
    expect((await vault.redeemRequests(id)).status).to.equal(3n);
  });

  it("generic sweep can move both asset and share token balances", async function () {
    const { admin, user, custody, usdc, vault } = await deployFixture();
    const shares = await depositForUser(vault, usdc, user, 10n * ONE_USDC);

    await vault.connect(user).requestRedeem(shares, user.address);
    expect(await vault.balanceOf(await vault.getAddress())).to.equal(shares);

    await vault.connect(admin).sweepTokenToCustody(await vault.getAddress());
    expect(await vault.balanceOf(await vault.getAddress())).to.equal(0n);
    expect(await vault.balanceOf(custody.address)).to.equal(shares);

    const directAssets = 7n * ONE_USDC;
    await usdc.connect(admin).mint(await vault.getAddress(), directAssets);
    await vault.connect(admin).sweepTokenToCustody(await usdc.getAddress());
    expect(await usdc.balanceOf(await vault.getAddress())).to.equal(0n);
    expect(await usdc.balanceOf(custody.address)).to.equal(10n * ONE_USDC + directAssets);
  });
});
