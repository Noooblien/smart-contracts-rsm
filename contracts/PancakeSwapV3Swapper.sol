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

    // ── Constants ────────────────────────────────────────────────────
    uint256 public constant MAX_FEE_BPS          = 500;      // 5%  — protocol fee ceiling
    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint256 public constant FEE_TIMELOCK         = 2 days;   // fee / feeRecipient change delay
    uint256 public constant RESCUE_DELAY         = 3 days;   // FEE_TIMELOCK
    uint256 public constant MAX_DEADLINE_BUFFER  = 1 hours;  // deadline buffer ceiling
    uint256 public constant MIN_SLIPPAGE_BPS     = 1;        // 0.01% floor — must be nonzero
    uint256 public constant INITIAL_DEADLINE_BUF = 300;      // 5 min — constructor default
    uint256 public constant INITIAL_SLIPPAGE_BPS = 50;       // 0.5% — constructor default

    // ── Immutables ───────────────────────────────────────────────────
    address public immutable router;
    address public immutable quoter;

    // ── Ownership (two-step) ─────────────────────────────────────────
    address public owner;
    address public pendingOwner;

    // ── Fee config ───────────────────────────────────────────────────
    address public feeRecipient;
    uint256 public feeBps;

    // Pending fee change (timelock)
    uint256 public pendingFeeBps;
    uint256 public feeChangeAvailableAt;
    bool    public hasPendingFeeChange;

    // Pending feeRecipient change (timelock)
    address public pendingFeeRecipient;
    uint256 public feeRecipientChangeAvailableAt;
    bool    public hasPendingFeeRecipientChange;

    // ── Swap config ──────────────────────────────────────────────────
    uint256 public defaultDeadlineBuffer;
    uint256 public defaultSlippageBps;

    // ── Circuit breaker ──────────────────────────────────────────────
    bool public paused;

    // ── Rescue timelock state ────────────────────────────────────────
    mapping(address => uint256) public rescueAvailableAt;
    mapping(address => uint256) public rescueAmount;
    mapping(address => bool)    public hasPendingRescue;

    // ── Events ───────────────────────────────────────────────────────

    // [INFO-1] includes router + quoter
    event Initialized(
        address indexed owner,
        address indexed router,
        address indexed quoter,
        address feeRecipient,
        uint256 feeBps,
        uint256 defaultDeadlineBuffer,
        uint256 defaultSlippageBps
    );
    event SwapExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 grossAmountIn,  // actual non-refunded tokenIn cost (swap + fee)
        uint256 amountOut,
        uint256 feeCharged,
        address recipient
    );
    // Ownership
    event OwnershipTransferInitiated(address indexed current, address indexed pending);
    event OwnershipTransferCancelled(address indexed cancelledFor);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    // Fee
    event FeeChangeQueued(uint256 newBps, uint256 availableAt);
    event FeeChangeApplied(uint256 oldBps, uint256 newBps);
    event FeeChangeCancelled(uint256 cancelledBps);
    event FeeRecipientChangeQueued(address newAddr, uint256 availableAt);
    event FeeRecipientChangeApplied(address oldAddr, address newAddr);
    event FeeRecipientChangeCancelled(address cancelledAddr);
    // Config
    event DeadlineBufferUpdated(uint256 oldVal, uint256 newVal);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    // Circuit breaker
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    // Rescue — [LOW-1] amount included in cancelled event
    event RescueQueued(address indexed token, uint256 amount, uint256 availableAt);
    event RescueExecuted(address indexed token, uint256 amount);
    event RescueCancelled(address indexed token, uint256 amount);

    // ── Custom errors ────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error NoPendingTransfer();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error DeadlineExpired();
    error DeadlineBufferTooLarge();
    error ContractPaused();
    error InvalidPath();
    error MisalignedPath();           //  hop alignment
    error TransferFailed();
    error SlippageNotSet();
    error SlippageTooLow();
    error FOTIncompatible();          //  FOT + exact-output incompatible
    error InsufficientBalance();      //  rescue balance check
    error TimelockNotElapsed();
    error NoPendingFeeChange();
    error NoPendingFeeRecipientChange();
    error NoPendingRescue();
    error RouterAllowanceNotZero();
    error ContractCallerNotAllowed(); //  quote called by contract

    // ── Modifiers ────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    /// @dev Blocks contract callers from relying on QuoterV2 inside on-chain logic.
    ///      This is not an eth_call detector: EOAs can still submit transactions.
    modifier noContractCallers() {
        if (msg.sender != tx.origin) revert ContractCallerNotAllowed();
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

        if (INITIAL_SLIPPAGE_BPS < MIN_SLIPPAGE_BPS) revert SlippageTooLow();
        if (INITIAL_DEADLINE_BUF > MAX_DEADLINE_BUFFER) revert DeadlineBufferTooLarge();

        router                = _router;
        quoter                = _quoter;
        feeRecipient          = _feeRecipient;
        feeBps                = _feeBps;
        owner                 = msg.sender;
        defaultDeadlineBuffer = INITIAL_DEADLINE_BUF;
        defaultSlippageBps    = INITIAL_SLIPPAGE_BPS;

        emit Initialized(
            msg.sender, _router, _quoter,
            _feeRecipient, _feeBps,
            INITIAL_DEADLINE_BUF, INITIAL_SLIPPAGE_BPS
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  SWAP 1: EXACT INPUT — SINGLE HOP  (A → B)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Sell exactly `amountIn` of tokenIn for as much tokenOut as possible.
     *
     * @dev Fee + slippage coupling: the protocol fee is deducted from amountIn
     *      before the swap. `amountOutMinimum` must be computed against netIn
     *      (amountIn minus fee), not gross amountIn. Use quoteSingleHop() via
     *      eth_call to get the correct value.
     *
     * @param tokenIn          ERC-20 to sell
     * @param tokenOut         ERC-20 to receive
     * @param fee              Pool tier: 100 | 500 | 2500 | 10000
     * @param amountIn         Gross amount — fee deducted internally
     * @param amountOutMinimum Slippage guard — compute via quoteSingleHop() off-chain
     * @param recipient        Receives tokenOut
     * @param deadline         Unix ts; 0 = block.timestamp + defaultDeadlineBuffer
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
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, received, amountOut, feeAmt, recipient);
    }

    // ══════════════════════════════════════════════════════════════
    //  SWAP 2: EXACT INPUT — MULTI HOP  (A → ... → B)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Swap through multiple pools in sequence.
     *
     * @dev Path encoding: abi.encodePacked(tokenA, fee1, tokenMid, fee2, tokenB)
     *      Minimum length 66 bytes (two hops: 20+3+20+3+20).
     *      Each additional hop adds 23 bytes (fee(3) + addr(20)).
     *      [MEDIUM-2] Path must satisfy: (path.length - 20) % 23 == 0
     *
     * @param path             Packed swap path — minimum 66 bytes, hop-aligned
     * @param tokenIn          First token in path
     * @param amountIn         Gross amount — fee deducted internally
     * @param amountOutMinimum Slippage guard — compute via quoteMultiHop() off-chain
     * @param recipient        Receives the last token in path
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
        // [MEDIUM-4 from v3] minimum two-hop = 66 bytes
        if (path.length < 66)        revert InvalidPath();
        // [MEDIUM-2] every hop segment is exactly 23 bytes (addr20 + fee3)
        // total path = 20 (first addr) + N*23 (each hop). So (len-20) % 23 must be 0.
        if ((path.length - 20) % 23 != 0) revert MisalignedPath();

        uint256 dl       = _resolveDeadline(deadline);
        // [CRITICAL] spec-compliant decode — no abi.decode undefined behavior
        address tokenOut = address(bytes20(path[path.length - 20 :]));

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
     * @notice Receive exactly `amountOut` of tokenOut. Refunds unspent tokenIn.
     *
     * @dev Slippage control: `amountInMaximum` is your slippage guard. Set it to
     *      (quoted amountIn) * 1.005 for 0.5% tolerance. The router enforces it
     *      as a hard cap — if the price moves beyond it, the tx reverts.
     *      This value is tokenIn-denominated, so it should be chosen from a
     *      quote plus tolerance, not compared numerically against amountOut.
     *
     * @dev FOT tokens: exact-output is incompatible with fee-on-transfer tokens
     *      because the fee reduces netMax below amountOut. Use swapSingleHop instead.
     *      [HIGH-3] This is detected and reverts FOTIncompatible().
     *
     * @dev Fee model: caller must send grossMaximum = amountInMaximum + fee.
     *      Use quoteExactOutputBudget() to get the correct grossMaximum.
     *
     * @param tokenIn          Token to sell
     * @param tokenOut         Token to buy (received exactly)
     * @param fee              Pool tier
     * @param amountOut        Exact tokenOut desired
     * @param amountInMaximum  Max tokenIn router may spend — your slippage bound
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
        if (amountOut == 0)                    revert ZeroAmount();
        if (amountInMaximum == 0)              revert ZeroAmount();
        if (amountInMaximum <= amountOut)      revert ZeroAmount();
        if (recipient == address(0))           revert ZeroAddress();

        uint256 dl = _resolveDeadline(deadline);

        // Fee computed once on amountInMaximum — no double-calc
        uint256 feeOnMax     = _calcFee(amountInMaximum);
        uint256 grossMaximum = amountInMaximum + feeOnMax;

        uint256 received = _safeTransferFrom(tokenIn, msg.sender, address(this), grossMaximum);

        // Proportional fee on received (handles FOT shortfall consistently)
        uint256 feeAmt = (received * feeOnMax) / grossMaximum;
        uint256 netMax = received - feeAmt;

        // [HIGH-3] FOT token incompatibility: if netMax < amountOut the router
        // will always revert — surface a clear error instead.
        if (netMax < amountOut) revert FOTIncompatible();

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

        // Refund unspent (netMax - amountIn) to recipient
        uint256 unspent = netMax - amountIn;
        if (unspent > 0) _safeTransfer(tokenIn, recipient, unspent);

        // grossAmountIn = actual non-refunded tokenIn cost
        uint256 grossIn = received - unspent;
        emit SwapExecuted(
            msg.sender, tokenIn, tokenOut,
            grossIn, amountOut, feeAmt, recipient
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  QUOTE HELPERS  (EOA callers only — NOT for on-chain contract logic)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Simulate single-hop swap to compute amountOutMinimum.
     *         Call via eth_call before submitting swapSingleHop().
     *
     * @dev NOT a view function — QuoterV2 simulates a full swap internally.
     *      [INFO-3] Reverts ContractCallerNotAllowed() when called by a contract.
     *
     * @param slippageBps 0 = use defaultSlippageBps
     * @return expectedOut Pool output on net amountIn (after fee)
     * @return minOut      Pass this as amountOutMinimum to swapSingleHop()
     * @return feeAmt      Protocol fee that will be deducted from amountIn
     */
    function quoteSingleHop(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 slippageBps
    ) external noContractCallers returns (uint256 expectedOut, uint256 minOut, uint256 feeAmt) {
        uint256 slip = slippageBps == 0 ? defaultSlippageBps : slippageBps;
        feeAmt = _calcFee(amountIn);
        (expectedOut,,,) = IPancakeV3QuoterV2(quoter).quoteExactInputSingle(
            tokenIn, tokenOut, amountIn - feeAmt, fee, 0
        );
        minOut = _applySlippage(expectedOut, slip);
    }

    /**
     * @notice Simulate multi-hop swap to compute amountOutMinimum.
     *         Call via eth_call before submitting swapMultiHop().
     *
     * @dev NOT a view function. [INFO-3] Reverts ContractCallerNotAllowed() from contracts.
     *
     * @param slippageBps 0 = use defaultSlippageBps
     * @return expectedOut Pool output on net amountIn (after fee)
     * @return minOut      Pass this as amountOutMinimum to swapMultiHop()
     * @return feeAmt      Protocol fee deducted
     */
    function quoteMultiHop(
        bytes   calldata path,
        uint256 amountIn,
        uint256 slippageBps
    ) external noContractCallers returns (uint256 expectedOut, uint256 minOut, uint256 feeAmt) {
        uint256 slip = slippageBps == 0 ? defaultSlippageBps : slippageBps;
        feeAmt = _calcFee(amountIn);
        (expectedOut,,,) = IPancakeV3QuoterV2(quoter).quoteExactInput(
            path, amountIn - feeAmt
        );
        minOut = _applySlippage(expectedOut, slip);
    }

    /**
     * @notice Compute grossMaximum to approve before calling swapExactOutput().
     * @return grossMaximum Approve this exact amount to the Swapper contract
     * @return feeAmt       Protocol fee component (taken upfront)
     */
    function quoteExactOutputBudget(
        uint256 amountInMaximum
    ) external view returns (uint256 grossMaximum, uint256 feeAmt) {
        feeAmt       = _calcFee(amountInMaximum);
        grossMaximum = amountInMaximum + feeAmt;
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: CIRCUIT BREAKER
    // ══════════════════════════════════════════════════════════════

    /// @notice Halt all swaps. [INFO-2] nonReentrant added.
    function pause() external onlyOwner nonReentrant {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume swaps. [INFO-2] nonReentrant added.
    function unpause() external onlyOwner nonReentrant {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: TWO-STEP OWNERSHIP
    // ══════════════════════════════════════════════════════════════

    /// @notice Step 1: nominate a new owner.
    ///         Emits OwnershipTransferCancelled if overwriting an existing pending.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (pendingOwner != address(0)) {
            emit OwnershipTransferCancelled(pendingOwner);
        }
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    /// @notice Step 2: pending owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Cancel a pending transfer. Callable by owner or nominated pending owner.
    function cancelOwnershipTransfer() external {
        if (msg.sender != owner && msg.sender != pendingOwner) revert NotOwner();
        if (pendingOwner == address(0)) revert NoPendingTransfer();
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
        if (!hasPendingFeeChange)                   revert NoPendingFeeChange();
        if (block.timestamp < feeChangeAvailableAt) revert TimelockNotElapsed();
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
    //  OWNER: FEE RECIPIENT WITH TIMELOCK
    // ══════════════════════════════════════════════════════════════

    function queueFeeRecipientChange(address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        pendingFeeRecipient           = newAddr;
        feeRecipientChangeAvailableAt = block.timestamp + FEE_TIMELOCK;
        hasPendingFeeRecipientChange  = true;
        emit FeeRecipientChangeQueued(newAddr, feeRecipientChangeAvailableAt);
    }

    function applyFeeRecipientChange() external onlyOwner {
        if (!hasPendingFeeRecipientChange)                   revert NoPendingFeeRecipientChange();
        if (block.timestamp < feeRecipientChangeAvailableAt) revert TimelockNotElapsed();
        address oldAddr               = feeRecipient;
        feeRecipient                  = pendingFeeRecipient;
        hasPendingFeeRecipientChange  = false;
        pendingFeeRecipient           = address(0);
        feeRecipientChangeAvailableAt = 0;
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

    /// @notice Set deadline buffer. Capped at MAX_DEADLINE_BUFFER (1 hour).
    function setDeadlineBuffer(uint256 secs) external onlyOwner {
        if (secs == 0) revert ZeroAmount();
        if (secs > MAX_DEADLINE_BUFFER) revert DeadlineBufferTooLarge();
        emit DeadlineBufferUpdated(defaultDeadlineBuffer, secs);
        defaultDeadlineBuffer = secs;
    }

    /// @notice Set default slippage. Cannot be zero.
    function setDefaultSlippage(uint256 bps) external onlyOwner {
        if (bps < MIN_SLIPPAGE_BPS) revert SlippageTooLow();
        emit SlippageUpdated(defaultSlippageBps, bps);
        defaultSlippageBps = bps;
    }

    // ══════════════════════════════════════════════════════════════
    //  OWNER: TOKEN RESCUE WITH TIMELOCK
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Step 1: queue a rescue. Executable after RESCUE_DELAY (3 days).
     * @dev Defense-in-depth: also blocks if router allowance is live.
     *      Primary protection is time alone — the 3-day delay is > FEE_TIMELOCK.
     */
    function queueRescue(address token, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (IERC20(token).allowance(address(this), router) != 0)
            revert RouterAllowanceNotZero();
        if (hasPendingRescue[token]) {
            emit RescueCancelled(token, rescueAmount[token]);
        }
        rescueAvailableAt[token] = block.timestamp + RESCUE_DELAY;
        rescueAmount[token]      = amount;
        hasPendingRescue[token]  = true;
        emit RescueQueued(token, amount, rescueAvailableAt[token]);
    }

    /**
     * @notice Step 2: execute rescue after timelock.
     *         [HIGH-1] Caps amount to actual balance — stale queued amounts handled.
     *         [INFO-1] nonReentrant.
     */
    function executeRescue(address token) external onlyOwner nonReentrant {
        if (!hasPendingRescue[token])                   revert NoPendingRescue();
        if (block.timestamp < rescueAvailableAt[token]) revert TimelockNotElapsed();
        if (IERC20(token).allowance(address(this), router) != 0)
            revert RouterAllowanceNotZero();

        // [HIGH-1] cap to actual balance — queued amount may be stale
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert InsufficientBalance();
        uint256 amount = rescueAmount[token] > bal ? bal : rescueAmount[token];

        hasPendingRescue[token]  = false;
        rescueAmount[token]      = 0;
        rescueAvailableAt[token] = 0;

        _safeTransfer(token, owner, amount);
        emit RescueExecuted(token, amount);
    }

    /// @notice Cancel a queued rescue. [LOW-1] emits amount in event.
    function cancelRescue(address token) external onlyOwner {
        if (!hasPendingRescue[token]) revert NoPendingRescue();
        uint256 amount           = rescueAmount[token];
        hasPendingRescue[token]  = false;
        rescueAmount[token]      = 0;
        rescueAvailableAt[token] = 0;
        emit RescueCancelled(token, amount); // [LOW-1] amount included
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
        if (IERC20(token).allowance(address(this), router) > 0) {
            _safeApprove(token, router, 0);
        }
        _safeApprove(token, router, amount);
    }

    function _resetRouterAllowance(address token) internal {
        if (IERC20(token).allowance(address(this), router) > 0) {
            _safeApprove(token, router, 0);
        }
    }

    /// @dev Returns actual received delta — handles FOT tokens correctly.
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balBefore = IERC20(token).balanceOf(to);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        received = IERC20(token).balanceOf(to) - balBefore;
        if (received == 0) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ── Reject accidental BNB ─────────────────────────────────────
    receive()  external payable { revert("No BNB"); }
    fallback() external payable { revert("No BNB"); }
}
