# PancakeSwapV3Swapper

A production-grade smart contract for swapping ERC-20 tokens directly through PancakeSwap V3 on BSC — without visiting the PancakeSwap UI. Supports quote-assisted slippage checks via QuoterV2, multi-hop routing, protocol fee collection, configurable deadlines, and an emergency pause circuit breaker.

---

## Deployments

| Network | Router | Quoter |
|---|---|---|
| BSC Mainnet | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` | `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997` |
| BSC Testnet | `0x1b81D678ffb9C0263b24A97847620C99d213eB14` | `0xbC203d7f83677c7ed3F7acEc959963E7F4ECC5C2` |

---

## Features

- **Permissionless** — any wallet can call the swap functions
- **Quote-assisted slippage** — QuoterV2 helpers return `amountOutMinimum`; callers pass that value into swaps
- **Single-hop swaps** — Token A → Token B through one direct pool
- **Multi-hop swaps** — Token A → intermediate → Token B through multiple pools
- **Exact output swaps** — receive exactly X of token B, spend ≤ max A, leftover refunded
- **Protocol fee** — taken in `tokenIn` before the swap, sent to `feeRecipient`; hard-capped at 5%
- **Configurable deadline** — per-call override with fallback to owner-set default
- **Configurable slippage** — per-call override with fallback to owner-set default
- **Emergency pause** — owner can freeze all swaps instantly
- **Reentrancy guard** — prevents callback attacks mid-swap
- **Safe ERC-20 handling** — USDT-safe double-approve pattern + fee-on-transfer token support
- **Token rescue** — owner can recover ERC-20 tokens after a 3-day timelock

---

## Compiler Settings

```json
{
  "language": "Solidity",
  "settings": {
    "optimizer": {
      "enabled": true,
      "runs": 200
    },
    "evmVersion": "paris",
    "viaIR": true
  }
}
```

> **Important:** `evmVersion` must be set to `paris` for BSC. The default `shanghai` target includes the `PUSH0` opcode which BSC does not support and will cause all calls to revert. `viaIR: true` is required to avoid stack-too-deep errors from the large function parameter sets.

---

## Deployment

### Constructor Parameters

| Parameter | Type | Description |
|---|---|---|
| `_router` | `address` | PancakeSwap V3 SwapRouter address |
| `_quoter` | `address` | PancakeSwap V3 QuoterV2 address |
| `_feeRecipient` | `address` | Wallet that receives protocol fees |
| `_feeBps` | `uint256` | Initial protocol fee in basis points (e.g. `30` = 0.3%) |

### Example (Hardhat)

```js
const Swapper = await ethers.getContractFactory("PancakeSwapV3Swapper");
const swapper = await Swapper.deploy(
  "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4", // router
  "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997", // quoter
  "0xYourFeeWallet",
  30  // 0.3% protocol fee
);
await swapper.deployed();
```

---

## Usage

### Step 1 — Approve the contract

Before swapping, the caller must approve this contract to spend their `tokenIn`:

```js
await tokenIn.approve(swapperAddress, amountIn);
```

### Step 2 — Quote first (optional but recommended)

Call `quoteSingleHop` or `quoteMultiHop` via `eth_call` to preview the swap:

```js
const [expectedOut, minOut, feeAmt] = await swapper.quoteSingleHop(
  CAKE_ADDRESS,
  USDT_ADDRESS,
  2500,               // fee tier
  ethers.parseEther("100"),
  0                   // use default slippage
);
```

### Step 3 — Swap

---

## Swap Functions

### `swapSingleHop`

Sell exact `amountIn` of `tokenIn`, receive as much `tokenOut` as possible through one pool.

```solidity
function swapSingleHop(
    address tokenIn,
    address tokenOut,
    uint24  fee,
    uint256 amountIn,
    uint256 amountOutMinimum,
    address recipient,
    uint256 deadline     // 0 = use defaultDeadlineBuffer
) external returns (uint256 amountOut)
```

**Example:**
```js
await swapper.swapSingleHop(
  CAKE,
  USDT,
  2500,                          // 0.25% fee tier
  ethers.parseEther("100"),      // sell 100 CAKE
  minOut,                        // from quoteSingleHop
  recipientAddress,
  0                              // use default deadline
);
```

---

### `swapMultiHop`

Swap through multiple pools when no direct pool exists.

```solidity
function swapMultiHop(
    bytes   calldata path,
    address tokenIn,
    uint256 amountIn,
    uint256 amountOutMinimum,
    address recipient,
    uint256 deadline
) external returns (uint256 amountOut)
```

**Encoding the path:**
```js
const path = ethers.solidityPacked(
  ["address", "uint24", "address", "uint24", "address"],
  [CAKE, 2500, WBNB, 500, USDT]
);
```

**Example:**
```js
await swapper.swapMultiHop(
  path,
  CAKE,
  ethers.parseEther("100"),
  minOut,                        // from quoteMultiHop
  recipientAddress,
  0
);
```

---

### `swapExactOutput`

Receive exactly `amountOut` of `tokenOut`. Spends at most the gross budget returned by `quoteExactOutputBudget(amountInMaximum)`, and refunds unspent `tokenIn` to `recipient`.

```solidity
function swapExactOutput(
    address tokenIn,
    address tokenOut,
    uint24  fee,
    uint256 amountOut,
    uint256 amountInMaximum,
    address recipient,
    uint256 deadline
) external returns (uint256 amountIn)
```

**Example:**
```js
await swapper.swapExactOutput(
  CAKE,
  USDT,
  2500,
  ethers.parseUnits("500", 18),   // want exactly 500 USDT
  ethers.parseEther("200"),        // willing to spend up to 200 CAKE
  recipientAddress,
  0
);
```

---

## Fee Tier Reference

| Fee | Rate | Best for |
|---|---|---|
| `100` | 0.01% | Stablecoin pairs (USDT/USDC) |
| `500` | 0.05% | Stable pairs (WBNB/BUSD) |
| `2500` | 0.25% | Standard pairs (CAKE/WBNB) |
| `10000` | 1.00% | Exotic / volatile tokens |

> Use the wrong fee tier and the router will revert — no pool exists at that tier for the pair. Check the correct tier on [pancakeswap.finance](https://pancakeswap.finance) or via the factory contract.

---

## Owner Functions

| Function | Description |
|---|---|
| `queueFeeChange(uint256 newBps)` / `applyFeeChange()` / `cancelFeeChange()` | Manage protocol fee changes behind a 2-day timelock. Max 500 bps (5%). |
| `queueFeeRecipientChange(address newAddr)` / `applyFeeRecipientChange()` / `cancelFeeRecipientChange()` | Manage fee recipient changes behind a 2-day timelock. |
| `setDeadlineBuffer(uint256 secs)` | Change default deadline window. Must be greater than zero and at most 1 hour. |
| `setDefaultSlippage(uint256 bps)` | Change default slippage tolerance. |
| `pause()` | Freeze all swaps immediately. |
| `unpause()` | Resume swaps after pause. |
| `queueRescue(address token, uint256 amount)` / `executeRescue(address token)` / `cancelRescue(address token)` | Recover ERC-20 tokens after a 3-day timelock. |
| `transferOwnership(address)` / `acceptOwnership()` / `cancelOwnershipTransfer()` | Two-step ownership transfer. Owner or pending owner may cancel. |

---

## Events

| Event | Emitted when |
|---|---|
| `SwapExecuted` | Any swap completes successfully |
| `FeeChangeQueued` / `FeeChangeApplied` / `FeeChangeCancelled` | Fee change lifecycle updates |
| `FeeRecipientChangeQueued` / `FeeRecipientChangeApplied` / `FeeRecipientChangeCancelled` | Fee recipient change lifecycle updates |
| `DeadlineBufferUpdated` | Owner changes deadline buffer |
| `SlippageUpdated` | Owner changes default slippage |
| `OwnershipTransferInitiated` / `OwnershipTransferCancelled` / `OwnershipTransferred` | Ownership transfer lifecycle updates |
| `Paused` / `Unpaused` | Circuit breaker toggled |
| `RescueQueued` / `RescueExecuted` / `RescueCancelled` | Token rescue lifecycle updates |

---

## Custom Errors

| Error | Thrown when |
|---|---|
| `NotOwner()` | Non-owner calls an admin function |
| `ZeroAddress()` | A zero address is passed |
| `ZeroAmount()` | `amountIn` or `amountOut` is 0 |
| `FeeTooHigh()` | Fee exceeds 500 bps |
| `DeadlineExpired()` | Deadline is in the past |
| `DeadlineBufferTooLarge()` | Default deadline buffer exceeds 1 hour |
| `ContractPaused()` | Swap called while paused |
| `InvalidPath()` | Multi-hop path is too short |
| `MisalignedPath()` | Multi-hop path is not 23-byte hop aligned |
| `TransferFailed()` | ERC-20 transfer fails or reports false |
| `ContractCallerNotAllowed()` | A contract calls a quote helper |

---

## Security Considerations

- **Slippage protection** — quote first and pass the returned `minOut` into exact-input swaps. The default quote slippage (50 = 0.5%) suits most pairs; volatile or low-liquidity tokens may need higher values.
- **Pool verification** — verify a V3 pool exists for your token pair and fee tier before calling. Use the PancakeSwap V3 Factory `getPool(tokenA, tokenB, fee)` — returns `address(0)` if no pool exists.
- **Fee-on-transfer tokens** — supported via balance-delta checking, but slippage values may need to be wider to account for the token's own transfer tax.
- **Ownership** — consider transferring ownership to a multisig after deployment.
- **Quote helpers** — quote functions block contract callers to discourage on-chain integration logic, but this is not an `eth_call` detector. EOAs can still submit quote transactions.

---

## License

MIT
