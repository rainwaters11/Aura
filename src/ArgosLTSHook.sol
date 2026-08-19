// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║              ARGOS LTS — LIQUIDITY TOXIC SHIELD  (v2)                    ║
 * ║                                                                           ║
 * ║  Uniswap V4 hook that front-runs toxic L1 arbitrage before it reaches    ║
 * ║  Unichain, protecting LPs with two complementary defence modes:          ║
 * ║                                                                           ║
 * ║  • PARK mode  — intercepts the toxic swap and mints the input amount     ║
 * ║    as an ERC-6909 claim in PoolManager. The user can redeem it later.    ║
 * ║    No hard revert. No lost gas. Better UX.                               ║
 * ║                                                                           ║
 * ║  • PENALIZE mode — lets the swap through on a dynamic-fee pool but       ║
 * ║    overrides the fee with a 10% penalty, handing the surplus to LPs.    ║
 * ║                                                                           ║
 * ║  Detection is powered by the Reactive Network: an RSC on Ethereum        ║
 * ║  mainnet watches V3 Swap events for sandwich patterns (≥2 swaps from    ║
 * ║  the same sender in the same block) and dispatches a cross-chain         ║
 * ║  callback to flagToxicAddress() here — BEFORE the arb reaches Unichain. ║
 * ║                                                                           ║
 * ║  Redemption is gated by Lit Protocol (see integrations/lit-protocol/).   ║
 * ║  LPs, users, and protocol integrators can verify redemption eligibility  ║
 * ║  through a Lit Action before the on-chain tx is submitted.               ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 *
 * PLGenesis Frontiers of Collaboration — Crypto Track
 * Sponsor Integration: Lit Protocol (redemption gate, integrations/lit-protocol/)
 */

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ToxicFlowLib} from "./libraries/ToxicFlowLib.sol";

/// @title ArgosLTSHook
/// @notice Uniswap V4 hook — Liquidity Toxic Shield v2 for PLGenesis hackathon.
/// @dev    Inherits BaseHook (OZ) and implements IUnlockCallback for the
///         internal poolManager.unlock() call within redeemParkedClaim().
contract ArgosLTSHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutable config
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trusted Reactive Network sensor that dispatches flagToxicAddress().
    ///         Set to the ReactiveArbitrageSensor address on Unichain (or the
    ///         Reactive Network callback proxy in production).
    address public immutable reactiveSensor;

    // ─────────────────────────────────────────────────────────────────────────
    // Mutable config
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Hook owner — may call setParkingMode().
    address public owner;

    // ─────────────────────────────────────────────────────────────────────────
    // Toxic flow state
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Unix timestamp after which the toxic flag for this address expires.
    ///         0 means the address is not flagged.
    mapping(address => uint256) public toxicExpiry;

    /// @notice Duration a toxic flag persists (5 minutes).
    uint256 public constant TOXIC_WINDOW = 5 minutes;

    // ─────────────────────────────────────────────────────────────────────────
    // ERC-6909 Parking
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tracks each user's parked ERC-6909 claim balance per currency.
    ///         parkedClaims[user][currencyId] = amount of input currency parked.
    ///
    ///         DESIGN NOTE: The hook (address(this)) holds the ERC-6909 claims in
    ///         PoolManager. This mapping is the hook's own ledger tracking who is
    ///         owed what. This lets one hook instance serve many pools and users.
    ///
    ///         WHY ERC-6909 OVER HARD REVERT:
    ///         A hard revert burns the user's gas and permanently destroys the tx.
    ///         Parking the input as an ERC-6909 claim means the user's tokens are
    ///         held safely in PoolManager and can be fully redeemed via
    ///         redeemParkedClaim(). Gas is still spent, but funds are never lost.
    mapping(address => mapping(uint256 => uint256)) public parkedClaims;

    // ─────────────────────────────────────────────────────────────────────────
    // Pool mode config
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Per-pool mode flag.
    ///         true  → PARK mode: toxic swaps are intercepted and parked as ERC-6909.
    ///         false → PENALIZE mode: toxic swaps execute but pay 10% fee (dynamic pools).
    mapping(PoolId => bool) public parkingEnabled;

    // ─────────────────────────────────────────────────────────────────────────
    // Fee constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Normal swap fee (0.30%) — returned for non-toxic swaps.
    uint24 public constant BASE_FEE = 3000;

    /// @notice Penalty fee override for toxic swappers in PENALIZE mode (10.00%).
    ///         Only effective on pools initialised with LPFeeLibrary.DYNAMIC_FEE_FLAG.
    uint24 public constant TOXIC_FEE = 100_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ToxicAddressFlagged(address indexed sender, uint256 expiresAt);
    event SwapParked(address indexed user, uint256 currencyId, uint256 amount);
    event ParkedClaimRedeemed(address indexed user, uint256 currencyId, uint256 amount);
    event ToxicSwapPenalized(address indexed swapper, uint24 fee);
    event ParkingModeSet(PoolId indexed poolId, bool enabled);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error Unauthorized();
    error InsufficientParked();
    error UnsupportedParkMode();
    error InvalidSwapAmount();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _reactiveSensor, address _owner) BaseHook(_poolManager) {
        require(_reactiveSensor != address(0), "ArgosLTS: zero sensor");
        require(_owner != address(0), "ArgosLTS: zero owner");
        reactiveSensor = _reactiveSensor;
        owner = _owner;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook Permissions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Declares the hook permissions required by ArgosLTS.
    ///         • beforeSwap         — to intercept toxic swaps
    ///         • beforeSwapReturnDelta — to park the input as ERC-6909 (no hard revert)
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // ← toxic address check
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // ← ERC-6909 parking (no revert)
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sets PARK (true) or PENALIZE (false) mode for a pool.
    /// @dev    Must be called by the hook owner after pool initialization.
    ///         Defaults to PENALIZE mode (false) if never set.
    function setParkingMode(PoolKey calldata key, bool enabled) external {
        if (msg.sender != owner) revert Unauthorized();
        PoolId poolId = key.toId();
        parkingEnabled[poolId] = enabled;
        emit ParkingModeSet(poolId, enabled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reactive Network Callback
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Flags `swapper` as a toxic arbitrageur for TOXIC_WINDOW seconds.
    /// @dev    ONLY callable by the trusted `reactiveSensor` address.
    ///         In production this is the Reactive Network callback proxy.
    ///         In tests this is a mock address controlled by the test contract.
    ///
    ///         TIMING ADVANTAGE:
    ///         Unichain has ~250ms block times; Ethereum L1 has ~12s.
    ///         The Reactive Network observes L1 mempool/events and delivers this
    ///         callback to Unichain BEFORE the same arb wallet can execute here.
    ///         This is the "front-running the front-runner" mechanic.
    ///
    /// @param swapper  The L1 arbitrageur address to flag on Unichain.
    function flagToxicAddress(address swapper) external {
        if (msg.sender != reactiveSensor) revert Unauthorized();
        toxicExpiry[swapper] = block.timestamp + TOXIC_WINDOW;
        emit ToxicAddressFlagged(swapper, toxicExpiry[swapper]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // beforeSwap — Core Interception Logic
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Intercepts swaps and applies toxic flow protection.
    /// @dev    Called by PoolManager for every swap on pools using this hook.
    ///
    ///         Decision tree:
    ///         ┌─ sender not flagged? → pass through normally (ZERO_DELTA, 0 fee)
    ///         └─ sender IS flagged?
    ///            ├─ parkingEnabled[pool]? → PARK: consume input, mint ERC-6909 to hook
    ///            └─ !parkingEnabled[pool]? → PENALIZE: allow swap, return TOXIC_FEE override
    ///
    /// @param sender  msg.sender of the poolManager.swap() call (typically the router).
    /// @param key     The Uniswap V4 pool key.
    /// @param params  Swap parameters (direction, amount, price limit).
    /// @return selector    Function selector (BaseHook.beforeSwap.selector).
    /// @return delta       BeforeSwapDelta (non-zero only in PARK mode to consume input).
    /// @return feeOverride Dynamic fee override (non-zero only in PENALIZE mode).
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Fast path: not flagged → let the swap proceed normally
        if (!ToxicFlowLib.isToxic(toxicExpiry, sender)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();

        if (parkingEnabled[poolId]) {
            // ── PARK MODE ──────────────────────────────────────────────────
            // Consume the entire input amount and mint it as an ERC-6909 claim.
            // The swap is fully blocked without a hard revert.
            // The user can call redeemParkedClaim() to recover their tokens.
            return _parkSwap(sender, key, params);
        } else {
            // ── PENALIZE MODE ──────────────────────────────────────────────
            // Let the swap execute but override to TOXIC_FEE.
            // NOTE: Fee override ONLY takes effect on dynamic-fee pools
            // (initialised with LPFeeLibrary.DYNAMIC_FEE_FLAG = 0x800000).
            // On static-fee pools the override is silently ignored by PoolManager.
            uint24 penaltyFee = ToxicFlowLib.computePenaltyFee(
                toxicExpiry[sender], // expiry timestamp (see ToxicFlowLib for naming rationale)
                BASE_FEE,
                TOXIC_FEE,
                TOXIC_WINDOW
            );
            emit ToxicSwapPenalized(sender, penaltyFee);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, penaltyFee);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Park Logic (internal)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Parks an exact-input swap by consuming the input and minting ERC-6909.
    ///      Only supports exact-input (amountSpecified < 0). Exact-output parking
    ///      is not supported because the input amount is unknown at this stage.
    function _parkSwap(address sender, PoolKey calldata key, SwapParams calldata params)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Revert on exact-output or zero (amountSpecified >= 0)
        if (params.amountSpecified >= 0) revert UnsupportedParkMode();

        // Guard against int256.min underflow
        if (params.amountSpecified == type(int256).min) revert InvalidSwapAmount();

        uint256 amountIn = uint256(-params.amountSpecified);

        // Ensure it fits in int128 (required by toBeforeSwapDelta)
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();

        // Determine input currency from swap direction
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 currencyId = inputCurrency.toId();

        // Mint ERC-6909 claim TO THE HOOK (hook is the custodian)
        // The hook's poolManager ERC-6909 balance for this currency increases by amountIn.
        poolManager.mint(address(this), currencyId, amountIn);

        // Record the user's entitlement in the hook's internal ledger
        parkedClaims[sender][currencyId] += amountIn;

        emit SwapParked(sender, currencyId, amountIn);

        // Return a positive BeforeSwapDelta for the specified (input) token.
        // This tells PoolManager the hook consumed the entire input, suppressing the swap.
        // The user's input is settled into PoolManager as normal; the hook holds the claim.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(amountIn)), 0), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC-6909 Redemption
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeems parked ERC-6909 claims back to the caller's wallet.
    ///
    ///         Flow:
    ///         1. Validate caller has ≥ amount parked for this currency.
    ///         2. Deduct from parkedClaims ledger (CEI pattern).
    ///         3. Call poolManager.unlock() → unlockCallback():
    ///            a. burn(address(this), currencyId, amount) — hook relinquishes claim
    ///            b. take(currency, caller, amount) — PoolManager sends tokens to caller
    ///         4. Emit ParkedClaimRedeemed.
    ///
    ///         RECOMMENDED PATH (Lit Protocol):
    ///         Use integrations/lit-protocol/redeem-with-lit.ts to verify the toxic
    ///         window has elapsed before submitting this transaction. This ensures
    ///         legitimately flagged addresses serve their penalty window.
    ///
    /// @param currency  The input currency whose claim to redeem.
    /// @param amount    Amount of tokens to recover.
    function redeemParkedClaim(Currency currency, uint256 amount) external {
        uint256 currencyId = currency.toId();
        if (parkedClaims[msg.sender][currencyId] < amount) revert InsufficientParked();

        // Checks-Effects: deduct before external call
        parkedClaims[msg.sender][currencyId] -= amount;

        // Interactions: enter PoolManager lock to burn + take
        poolManager.unlock(abi.encode(msg.sender, currency, amount, currencyId));

        emit ParkedClaimRedeemed(msg.sender, currencyId, amount);
    }

    /// @notice Handles the PoolManager unlock callback for redeemParkedClaim().
    /// @dev    Called by PoolManager.unlock(). msg.sender MUST be the poolManager.
    ///         Inside the lock:
    ///           burn — reduces hook's ERC-6909 balance, creates +delta credit for hook
    ///           take — PoolManager sends underlying token to user, consuming the credit
    ///         Net delta is zero; the lock closes cleanly.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "ArgosLTS: only poolManager");

        (address user, Currency currency, uint256 amount, uint256 currencyId) =
            abi.decode(data, (address, Currency, uint256, uint256));

        // Burn hook's ERC-6909 claim → gives hook a +delta credit for this currency
        poolManager.burn(address(this), currencyId, amount);

        // Take the underlying token from PoolManager and deliver to the user
        poolManager.take(currency, user, amount);

        return "";
    }
}
