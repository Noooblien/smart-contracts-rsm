import { expect } from "chai";
import { describe, it, beforeEach } from "mocha";
import { network } from "hardhat";
import { anyValue } from "@nomicfoundation/hardhat-ethers-chai-matchers/withArgs";

describe("PancakeSwapV3Swapper", function () {
  let ethers;
  let owner;
  let user;
  let recipient;
  let feeRecipient;
  let pendingOwner;
  let router;
  let quoter;
  let tokenIn;
  let tokenOut;
  let swapper;

  async function deployFixture({ feeBps = 100n } = {}) {
    ({ ethers } = await network.create());
    [owner, user, recipient, feeRecipient, pendingOwner] = await ethers.getSigners();

    router = await ethers.deployContract("MockPancakeV3Router");
    quoter = await ethers.deployContract("MockPancakeV3Quoter");
    tokenIn = await ethers.deployContract("MockERC20", ["Token In", "TIN"]);
    tokenOut = await ethers.deployContract("MockERC20", ["Token Out", "TOUT"]);
    swapper = await ethers.deployContract("PancakeSwapV3Swapper", [
      await router.getAddress(),
      await quoter.getAddress(),
      await feeRecipient.getAddress(),
      feeBps,
    ]);
  }

  beforeEach(async function () {
    await deployFixture();
  });

  async function fundAndApprove(amount, signer = user) {
    await tokenIn.mint(await signer.getAddress(), amount);
    await tokenIn.connect(signer).approve(await swapper.getAddress(), amount);
  }

  it("refunds exact-output leftovers to recipient and emits actual non-refunded gross input", async function () {
    await fundAndApprove(101n);
    await router.setExactOutputAmountIn(60n);

    await expect(
      swapper.connect(user).swapExactOutput(
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
        2500,
        10n,
        100n,
        await recipient.getAddress(),
        0,
      ),
    )
      .to.emit(swapper, "SwapExecuted")
      .withArgs(
        await user.getAddress(),
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
        61n,
        10n,
        1n,
        await recipient.getAddress(),
      );

    expect(await tokenIn.balanceOf(await router.getAddress())).to.equal(60n);
    expect(await tokenIn.balanceOf(await feeRecipient.getAddress())).to.equal(1n);
    expect(await tokenIn.balanceOf(await recipient.getAddress())).to.equal(40n);
    expect(await tokenIn.balanceOf(await user.getAddress())).to.equal(0n);
  });

  it("rejects semantically invalid exact-output maximums before calling the router", async function () {
    await fundAndApprove(100n);

    await expect(
      swapper.connect(user).swapExactOutput(
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
        2500,
        100n,
        100n,
        await recipient.getAddress(),
        0,
      ),
    ).to.be.revertedWithCustomError(swapper, "ZeroAmount");
  });

  it("supports no-return-value ERC-20 transfers", async function () {
    await fundAndApprove(101n);
    await tokenIn.setNoReturn(true);
    await router.setExactOutputAmountIn(60n);

    await expect(
      swapper.connect(user).swapExactOutput(
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
        2500,
        10n,
        100n,
        await recipient.getAddress(),
        0,
      ),
    ).to.emit(swapper, "SwapExecuted");

    expect(await tokenIn.balanceOf(await recipient.getAddress())).to.equal(40n);
  });

  it("rejects false-returning ERC-20 transfers with TransferFailed", async function () {
    await fundAndApprove(101n);
    await tokenIn.setReturnFalse(true);

    await expect(
      swapper.connect(user).swapExactOutput(
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
        2500,
        10n,
        100n,
        await recipient.getAddress(),
        0,
      ),
    ).to.be.revertedWithCustomError(swapper, "TransferFailed");
  });

  it("blocks contract callers from quote helpers with a clear error", async function () {
    const quoteCaller = await ethers.deployContract("QuoteCaller");

    await expect(
      quoteCaller.callQuote(
        await swapper.getAddress(),
        await tokenIn.getAddress(),
        await tokenOut.getAddress(),
      ),
    ).to.be.revertedWithCustomError(swapper, "ContractCallerNotAllowed");
  });

  it("allows the pending owner to cancel an unwanted ownership nomination", async function () {
    await swapper.transferOwnership(await pendingOwner.getAddress());

    await expect(swapper.connect(pendingOwner).cancelOwnershipTransfer())
      .to.emit(swapper, "OwnershipTransferCancelled")
      .withArgs(await pendingOwner.getAddress());

    expect(await swapper.pendingOwner()).to.equal(ethers.ZeroAddress);
  });

  it("rejects a zero deadline buffer", async function () {
    await expect(swapper.setDeadlineBuffer(0)).to.be.revertedWithCustomError(
      swapper,
      "ZeroAmount",
    );
  });

  it("emits cancellation details when a rescue queue is overwritten", async function () {
    await swapper.queueRescue(await tokenIn.getAddress(), 10n);

    await expect(swapper.queueRescue(await tokenIn.getAddress(), 20n))
      .to.emit(swapper, "RescueCancelled")
      .withArgs(await tokenIn.getAddress(), 10n)
      .and.to.emit(swapper, "RescueQueued")
      .withArgs(await tokenIn.getAddress(), 20n, anyValue);

    expect(await swapper.rescueAmount(await tokenIn.getAddress())).to.equal(20n);
  });
});
