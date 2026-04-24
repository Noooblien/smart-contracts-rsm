// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  PancakeSwapV3Swapper 
  ─────────────────────────────────────────────────────────────────
  BSC Mainnet Router : 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4
  BSC Mainnet Quoter : 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997
  BSC Testnet Router : 0x1b81D678ffb9C0263b24A97847620C99d213eB14
  BSC Testnet Quoter : 0xbC203d7f83677c7ed3F7acEc959963E7F4ECC5C2
  ─────────────────────────────────────────────────────────────────
*/

// ══════════════════════════════════════════════════════════════════
//  INTERFACES
// ══════════════════════════════════════════════════════════════════

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
    function exactInput(ExactInputParams calldata p)             external payable returns (uint256);
    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256);
}

interface IPancakeV3QuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24  fee,
        uint160 sqrtPriceLimitX96
    ) external returns (
        uint256 amountOut,
        uint160 sqrtPriceX96After,
        uint32  initializedTicksCrossed,
        uint256 gasEstimate
    );
    function quoteExactInput(
        bytes   memory path,
        uint256 amountIn
    ) external returns (
        uint256 amountOut,
        uint160[] memory sqrtPriceX96AfterList,
        uint32[]  memory initializedTicksCrossedList,
        uint256   gasEstimate
    );
}

// ══════════════════════════════════════════════════════════════════
//  REENTRANCY GUARD
// ══════════════════════════════════════════════════════════════════

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "Reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ══════════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ══════════════════════════════════════════════════════════════════

contract PancakeSwapV3Swapper is ReentrancyGuard {

    // ── Constants ──────────────────────────────────────────────────
    uint256 public constant MAX_FEE_BPS         = 500;     // 5% hard ceiling on protocol fee
    uint256 public constant BPS_DENOMINATOR     = 10_000;
    uint256 public constant FEE_TIMELOCK        = 2 days;  // fee & feeRecipient change delay
    uint256 public constant MAX_DEADLINE_BUFFER = 1 hours; // [LOW-3] cap on deadline buffer
    uint256 public constant RESCUE_DELAY        = 1 days;  // [HIGH-1] rescue timelock per token

    // ── Immutables ─────────────────────────────────────────────────
    address public immutable router;
    address public immutable quoter;

    // ── Ownership (two-step) ───────────────────────────────────────
    address public owner;
    address public pendingOwner;

    // ── Fee config ─────────────────────────────────────────────────
    address public feeRecipient;
    uint256 public feeBps;

    // Pending fee change (timelock)
    uint256 public pendingFeeBps;
    uint256 public feeChangeAvailableAt;
    bool    public hasPendingFeeChange;

    // Pending feeRecipient change (timelock) [MEDIUM-2]
    address public pendingFeeRecipient;
    uint256 public feeRecipientChangeAvailableAt;
    bool    public hasPendingFeeRecipientChange;

    // ── Swap config ────────────────────────────────────────────────
    uint256 public defaultDeadlineBuffer;
    uint256 public defaultSlippageBps;

    // ── Circuit breaker ────────────────────────────────────────────
    bool public paused;

    // ── Rescue timelock state [HIGH-1] ─────────────────────────────
    // token => earliest timestamp at which rescue is executable
    mapping(address => uint256) public rescueAvailableAt;
    mapping(address => uint256) public rescueAmount;
    mapping(address => bool)    public hasPendingRescue;

    // ── Events ─────────────────────────────────────────────────────
    event Initialized(
        address indexed owner,
        address indexed feeRecipient,
        uint256 feeBps,
        uint256 defaultDeadlineBuffer,
        uint256 defaultSlippageBps
    );
    event SwapExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 grossAmountIn,   // total tokenIn pulled from caller (swap + fee)
        uint256 amountOut,
        uint256 feeCharged,
        address recipient
    );

    // Ownership
    event OwnershipTransferInitiated(address indexed current, address indexed pending);
    event OwnershipTransferCancelled(address indexed cancelledFor);  // [MEDIUM-1,3]
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // Fee
    event FeeChangeQueued(uint256 newBps, uint256 availableAt);
    event FeeChangeApplied(uint256 oldBps, uint256 newBps);
    event FeeChangeCancelled(uint256 cancelledBps);
    event FeeRecipientChangeQueued(address newAddr, uint256 availableAt);  // [MEDIUM-2]
    event FeeRecipientChangeApplied(address oldAddr, address newAddr);
    event FeeRecipientChangeCancelled(address cancelledAddr);

    // Config
    event DeadlineBufferUpdated(uint256 oldVal, uint256 newVal);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // Rescue
    event RescueQueued(address indexed token, uint256 amount, uint256 availableAt);
    event RescueExecuted(address indexed token, uint256 amount);
    event RescueCancelled(address indexed token);

    // ── Custom errors ──────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error NoPendingTransfer();       // [MEDIUM-1]
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error DeadlineExpired();
    error DeadlineBufferTooLarge();  // [LOW-3]
    error ContractPaused();
    error InvalidPath();
    error TransferFailed();
    error ShortfallTooLarge();       // fee-on-transfer shortfall exceeds tolerance
    error SlippageNotSet();
    error TimelockNotElapsed();
    error NoPendingFeeChange();
    error NoPendingFeeRecipientChange();
    error NoPendingRescue();
    error RouterAllowanceNotZero();

    // ── Modifiers ──────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    constructor(
        address _router,
        address _quoter,
        address _feeRecipient,
        uint256 _feeBps
    ) {
        if (_router       == address(0)) revert ZeroAddress();
        if (_quoter       == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS)       revert FeeTooHigh();

        router                = _router;
        quoter                = _quoter;
        feeRecipient          = _feeRecipient;
        feeBps                = _feeBps;
        owner                 = msg.sender;
        defaultDeadlineBuffer = 300;   // 5 min
        defaultSlippageBps    = 50;    // 0.5%

        // [INFO-3] emit baseline state for indexers
        emit Initialized(msg.sender, _feeRecipient, _feeBps, 300, 50);
    }

    // ══════════════════════════════════════════════════════════════
    //  SWAP 1: EXACT INPUT — SINGLE HOP  (A → B)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Sell exactly `amountIn` of tokenIn, receive as much tokenOut as possible.
     *
     * @dev IMPORTANT — fee and slippage are coupled:
     *      The protocol fee is deducted from amountIn before the swap.
     *      amountOutMinimum must be computed against (amountIn - fee), not amountIn.
     *      Use quoteSingleHop() via eth_call with the same amountIn to get the correct
     *      minOut value. Passing a minOut computed on gross amountIn will cause reverts.
     *
     * @param tokenIn          ERC-20 to sell
     * @param tokenOut         ERC-20 to receive
     * @param fee              Pool fee tier: 100 | 500 | 2500 | 10000
     * @param amountIn         Gross tokenIn amount — protocol fee is deducted from this
     * @param amountOutMinimum Minimum tokenOut — MUST be computed via quoteSingleHop() off-chain
     * @param recipient        Receives tokenOut
     * @param deadline         Unix timestamp; 0 = block.timestamp + defaultDeadlineBuffer
     */
    function swapSingleHop(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0)           revert ZeroAmount();
        if (amountOutMinimum == 0)   revert SlippageNotSet();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 dl = _resolveDeadline(deadline);

        uint256 received = _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 feeAmt   = _calcFee(received);
        uint256 netIn    = received - feeAmt;
        if (feeAmt > 0) _safeTransfer(tokenIn, feeRecipient, feeAmt);

        _approveRouter(tokenIn, netIn);

        amountOut = IPancakeV3Router(router).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         recipient,
                deadline:          dl,
                amountIn:          netIn,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );

        _resetRouterAllowance(tokenIn);

        // grossAmountIn = received (actual pulled, may differ from amountIn for FOT tokens)
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, received, amountOut, feeAmt, recipient);
    }

    // ══════════════════════════════════════════════════════════════
    //  SWAP 2: EXACT INPUT — MULTI HOP  (A → mid → ... → B)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Swap through multiple pools in sequence.
     *
     * @dev IMPORTANT — fee and slippage are coupled (same as swapSingleHop).
     *      Use quoteMultiHop() off-chain to compute amountOutMinimum.
     *
     * @param path             abi.encodePacked(tokenA, fee1, tokenMid, fee2, tokenB, ...)
     *                         Minimum 66 bytes (two hops). Each additional hop adds 23 bytes.
     * @param tokenIn          First token in path (pulled from caller)
     * @param amountIn         Gross tokenIn — fee deducted before swap
     * @param amountOutMinimum Minimum final token — MUST be computed via quoteMultiHop() off-chain
     * @param recipient        Receives the final token in path
     * @param deadline         0 = use default
     */
    function swapMultiHop(
        bytes   calldata path,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0)           revert ZeroAmount();
        if (amountOutMinimum == 0)   revert SlippageNotSet();
        if (recipient == address(0)) revert ZeroAddress();
        // [MEDIUM-4] true multi-hop minimum: addr(20)+fee(3)+addr(20)+fee(3)+addr(20) = 66
        if (path.length < 66)        revert InvalidPath();

        uint256 dl       = _resolveDeadline(deadline);
        address tokenOut = _decodeTokenOut(path); // [LOW-1] pure-Solidity decode

        uint256 received = _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 feeAmt   = _calcFee(received);
        uint256 netIn    = received - feeAmt;
        if (feeAmt > 0) _safeTransfer(tokenIn, feeRecipient, feeAmt);

        _approveRouter(tokenIn, netIn);

        amountOut = IPancakeV3Router(router).exactInput(
            IPancakeV3Router.ExactInputParams({
                path:             path,
                recipient:        recipient,
                deadline:         dl,
                amountIn:         netIn,
                amountOutMinimum: amountOutMinimum
            })
        );

        _resetRouterAllowance(tokenIn);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, received, amountOut, feeAmt, recipient);
    }

    // ══════════════════════════════════════════════════════════════
    //  SWAP 3: EXACT OUTPUT — SINGLE HOP
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Receive exactly `amountOut` of tokenOut.
     *         Spends ≤ amountInMaximum of tokenIn (net of fee); refunds the rest.
     *
     * @dev Fee model for exact-output:
     *      - The protocol fee is computed on amountInMaximum upfront.
     *      - Caller must send grossMaximum = amountInMaximum + fee (use quoteExactOutputBudget()).
     *      - Fee is taken before the router call; router only ever sees amountInMaximum.
     *      - amountInMaximum IS the slippage control — set it tightly (e.g. quote * 1.005).
     *
     * @dev [CRITICAL-1 FIX] feeOnMax is computed once and reused — no double-fee.
     *      [CRITICAL-2] amountInMaximum enforced by router as hard cap.
     *
     * @param tokenIn          Token to sell
     * @param tokenOut         Token to buy
     * @param fee              Pool fee tier
     * @param amountOut        Exact tokenOut to receive
     * @param amountInMaximum  Max tokenIn the router may spend — this is your slippage control
     * @param recipient        Receives tokenOut
     * @param deadline         0 = use default
     */
    function swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountIn) {
        if (amountOut == 0)          revert ZeroAmount();
        if (amountInMaximum == 0)    revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 dl = _resolveDeadline(deadline);

        // [CRITICAL-1 FIX] Compute fee once, reuse — no double-fee on received
        uint256 feeOnMax     = _calcFee(amountInMaximum);
        uint256 grossMaximum = amountInMaximum + feeOnMax;

        // Pull grossMaximum; verify no excess shortfall from FOT tokens
        uint256 received = _safeTransferFrom(tokenIn, msg.sender, address(this), grossMaximum);
        // received should equal grossMaximum for standard tokens.
        // For FOT tokens the shortfall reduces netMax proportionally.
        // feeAmt is recomputed from received to stay consistent.
        uint256 feeAmt = (received * feeOnMax) / grossMaximum; // proportional fee, not double-calc
        uint256 netMax = received - feeAmt;

        if (feeAmt > 0) _safeTransfer(tokenIn, feeRecipient, feeAmt);

        _approveRouter(tokenIn, netMax);

        amountIn = IPancakeV3Router(router).exactOutputSingle(
            IPancakeV3Router.ExactOutputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         recipient,
                deadline:          dl,
                amountOut:         amountOut,
                amountInMaximum:   netMax,
                sqrtPriceLimitX96: 0
            })
        );

        _resetRouterAllowance(tokenIn);

        // Refund unspent (netMax - amountIn) to caller
        uint256 unspent = netMax - amountIn;
        if (unspent > 0) _safeTransfer(tokenIn, msg.sender, unspent);

        // [CRITICAL-1 FIX] gross cost = actual router spend + fee (true user cost)
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn + feeAmt, amountOut, feeAmt, recipient);
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW: QUOTE HELPERS  (eth_call only)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Simulate a single-hop swap off-chain before submitting swapSingleHop().
     *
     * @dev This function is NOT view — QuoterV2 simulates a full swap and reverts
     *      internally to return results. Always call via eth_call, never on-chain.
     *      Fee is deducted before quoting so minOut is accurate for the net swap.
     *
     * @param slippageBps 0 = use defaultSlippageBps
     * @return expectedOut Raw pool output on netIn
     * @return minOut      Pass this as amountOutMinimum to swapSingleHop()
     * @return feeAmt      Protocol fee that will be deducted
     */
    function quoteSingleHop(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 slippageBps
    ) external returns (uint256 expectedOut, uint256 minOut, uint256 feeAmt) {
        uint256 slip = slippageBps == 0 ? defaultSlippageBps : slippageBps;
        feeAmt = _calcFee(amountIn);
        (expectedOut,,,) = IPancakeV3QuoterV2(quoter).quoteExactInputSingle(
            tokenIn, tokenOut, amountIn - feeAmt, fee, 0
        );
        minOut = _applySlippage(expectedOut, slip);
    }

    /**
     * @notice Simulate a multi-hop swap off-chain before submitting swapMultiHop().
     *
     * @dev NOT view — call via eth_call only. See quoteSingleHop() dev note.
     *
     * @param slippageBps 0 = use defaultSlippageBps
     * @return expectedOut Raw pool output
     * @return minOut      Pass this as amountOutMinimum to swapMultiHop()
     * @return feeAmt      Protocol fee that will be deducted
     */
    function quoteMultiHop(
        bytes   calldata path,
        uint256 amountIn,
        uint256 slippageBps
    ) external returns (uint256 expectedOut, uint256 minOut, uint256 feeAmt) {
        uint256 slip = slippageBps == 0 ? defaultSlippageBps : slippageBps;
        feeAmt = _calcFee(amountIn);
        (expectedOut,,,) = IPancakeV3QuoterV2(quoter).quoteExactInput(path, amountIn - feeAmt);
        minOut = _applySlippage(expectedOut, slip);
    }

    /**
     * @notice Compute total tokenIn to approve before calling swapExactOutput().
     *         [LOW-2 FIX] Consistent with swapExactOutput — fee computed once on amountInMaximum.
     *
     * @return grossMaximum Approve this amount to the Swapper contract
     * @return feeAmt       Protocol fee component
     */
    function quoteExactOutputBudget(
        uint256 amountInMaximum
    ) external view returns (uint256 grossMaximum, uint256 feeAmt) {
        feeAmt       = _calcFee(amountInMaximum);       // computed once on amountInMaximum
        grossMaximum = amountInMaximum + feeAmt;        // no double-calc
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: CIRCUIT BREAKER
    // ══════════════════════════════════════════════════════════════

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: TWO-STEP OWNERSHIP
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Step 1 — nominate a new owner.
     *         [MEDIUM-3] Emits OwnershipTransferCancelled if overwriting an existing pending.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (pendingOwner != address(0)) {
            emit OwnershipTransferCancelled(pendingOwner); // [MEDIUM-3]
        }
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    /// @notice Step 2 — pending owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /**
     * @notice Cancel a pending ownership transfer.
     *         [MEDIUM-1] Reverts if no transfer is pending; emits cancellation event.
     */
    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert NoPendingTransfer(); // [MEDIUM-1]
        emit OwnershipTransferCancelled(pendingOwner);
        pendingOwner = address(0);
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: FEE WITH TIMELOCK
    // ══════════════════════════════════════════════════════════════

    function queueFeeChange(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        pendingFeeBps        = newBps;
        feeChangeAvailableAt = block.timestamp + FEE_TIMELOCK;
        hasPendingFeeChange  = true;
        emit FeeChangeQueued(newBps, feeChangeAvailableAt);
    }

    function applyFeeChange() external onlyOwner {
        if (!hasPendingFeeChange)                        revert NoPendingFeeChange();
        if (block.timestamp < feeChangeAvailableAt)      revert TimelockNotElapsed();
        uint256 oldBps       = feeBps;
        feeBps               = pendingFeeBps;
        hasPendingFeeChange  = false;
        pendingFeeBps        = 0;
        feeChangeAvailableAt = 0;
        emit FeeChangeApplied(oldBps, feeBps);
    }

    function cancelFeeChange() external onlyOwner {
        if (!hasPendingFeeChange) revert NoPendingFeeChange();
        emit FeeChangeCancelled(pendingFeeBps);
        hasPendingFeeChange  = false;
        pendingFeeBps        = 0;
        feeChangeAvailableAt = 0;
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: FEE RECIPIENT WITH TIMELOCK  [MEDIUM-2]
    // ══════════════════════════════════════════════════════════════

    function queueFeeRecipientChange(address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        pendingFeeRecipient              = newAddr;
        feeRecipientChangeAvailableAt    = block.timestamp + FEE_TIMELOCK;
        hasPendingFeeRecipientChange     = true;
        emit FeeRecipientChangeQueued(newAddr, feeRecipientChangeAvailableAt);
    }

    function applyFeeRecipientChange() external onlyOwner {
        if (!hasPendingFeeRecipientChange)                        revert NoPendingFeeRecipientChange();
        if (block.timestamp < feeRecipientChangeAvailableAt)      revert TimelockNotElapsed();
        address oldAddr                  = feeRecipient;
        feeRecipient                     = pendingFeeRecipient;
        hasPendingFeeRecipientChange     = false;
        pendingFeeRecipient              = address(0);
        feeRecipientChangeAvailableAt    = 0;
        emit FeeRecipientChangeApplied(oldAddr, feeRecipient);
    }

    function cancelFeeRecipientChange() external onlyOwner {
        if (!hasPendingFeeRecipientChange) revert NoPendingFeeRecipientChange();
        emit FeeRecipientChangeCancelled(pendingFeeRecipient);
        hasPendingFeeRecipientChange  = false;
        pendingFeeRecipient           = address(0);
        feeRecipientChangeAvailableAt = 0;
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: SWAP CONFIG
    // ══════════════════════════════════════════════════════════════

    /// @notice [LOW-3] Deadline buffer capped at MAX_DEADLINE_BUFFER (1 hour).
    function setDeadlineBuffer(uint256 secs) external onlyOwner {
        if (secs > MAX_DEADLINE_BUFFER) revert DeadlineBufferTooLarge();
        emit DeadlineBufferUpdated(defaultDeadlineBuffer, secs);
        defaultDeadlineBuffer = secs;
    }

    /// @notice [HIGH-2] Reverts if bps == 0 — zero slippage disables sandwich protection.
    function setDefaultSlippage(uint256 bps) external onlyOwner {
        if (bps == 0) revert SlippageNotSet();
        emit SlippageUpdated(defaultSlippageBps, bps);
        defaultSlippageBps = bps;
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: TOKEN RESCUE WITH TIMELOCK  [HIGH-1]
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Step 1 — queue a rescue. Executable after RESCUE_DELAY (24h).
     * @dev Blocks if the token still has a live router allowance (swap in-flight).
     */
    function queueRescue(address token, uint256 amount) external onlyOwner {
        if (IERC20(token).allowance(address(this), router) != 0)
            revert RouterAllowanceNotZero();
        rescueAvailableAt[token] = block.timestamp + RESCUE_DELAY;
        rescueAmount[token]      = amount;
        hasPendingRescue[token]  = true;
        emit RescueQueued(token, amount, rescueAvailableAt[token]);
    }

    /**
     * @notice Step 2 — execute rescue after timelock has elapsed.
     *         [INFO-1] nonReentrant added.
     */
    function executeRescue(address token) external onlyOwner nonReentrant {
        if (!hasPendingRescue[token])                       revert NoPendingRescue();
        if (block.timestamp < rescueAvailableAt[token])     revert TimelockNotElapsed();
        if (IERC20(token).allowance(address(this), router) != 0)
            revert RouterAllowanceNotZero();
        uint256 amount           = rescueAmount[token];
        hasPendingRescue[token]  = false;
        rescueAmount[token]      = 0;
        rescueAvailableAt[token] = 0;
        _safeTransfer(token, owner, amount);
        emit RescueExecuted(token, amount);
    }

    /// @notice Cancel a queued rescue.
    function cancelRescue(address token) external onlyOwner {
        if (!hasPendingRescue[token]) revert NoPendingRescue();
        hasPendingRescue[token]  = false;
        rescueAmount[token]      = 0;
        rescueAvailableAt[token] = 0;
        emit RescueCancelled(token);
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════

    function _resolveDeadline(uint256 dl) internal view returns (uint256) {
        if (dl == 0) return block.timestamp + defaultDeadlineBuffer;
        if (dl < block.timestamp) revert DeadlineExpired();
        return dl;
    }

    function _calcFee(uint256 amount) internal view returns (uint256) {
        return (amount * feeBps) / BPS_DENOMINATOR;
    }

    function _applySlippage(uint256 amount, uint256 slipBps) internal pure returns (uint256) {
        return (amount * (BPS_DENOMINATOR - slipBps)) / BPS_DENOMINATOR;
    }

    function _approveRouter(address token, uint256 amount) internal {
        IERC20(token).approve(router, 0);
        IERC20(token).approve(router, amount);
    }

    function _resetRouterAllowance(address token) internal {
        if (IERC20(token).allowance(address(this), router) > 0) {
            IERC20(token).approve(router, 0);
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balBefore = IERC20(token).balanceOf(to);
        bool ok = IERC20(token).transferFrom(from, to, amount);
        if (!ok) revert TransferFailed();
        received = IERC20(token).balanceOf(to) - balBefore;
        if (received == 0) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    /**
     * @dev [LOW-1] Pure-Solidity tokenOut decode from packed path.
     *      Path format: addr(20) + fee(3) + [addr(20) + fee(3)]* + addr(20)
     *      Last 20 bytes = tokenOut. Uses abi.decode on a bytes slice — no assembly.
     */
    function _decodeTokenOut(bytes calldata path) internal pure returns (address tokenOut) {
        bytes memory last20 = path[path.length - 20 : path.length];
        tokenOut = abi.decode(abi.encodePacked(new bytes(12), last20), (address));
    }

    // ── Reject accidental BNB ───────────────────────────────────────
    receive()  external payable { revert("No BNB"); }
    fallback() external payable { revert("No BNB"); }
}
