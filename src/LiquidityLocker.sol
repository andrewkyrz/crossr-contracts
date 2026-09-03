// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ILiquidityLocker} from "./interfaces/ILiquidityLocker.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";

/// @title LiquidityLocker
/// @notice Owns every graduation pool position. Liquidity can never be withdrawn; LP fees are
///         collected permissionlessly and split between the token creator and the protocol treasury.
contract LiquidityLocker is ILiquidityLocker, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    error NotLaunchpad();
    error NotPoolManager();
    error HookNotSet();
    error AlreadyLocked();
    error NotLocked();
    error ZeroLiquidity();
    error InvalidBps();

    event Locked(
        address indexed token,
        address indexed quote,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 tokenUsed,
        uint256 quoteUsed
    );
    event FeesCollected(address indexed token, uint256 amount0, uint256 amount1);
    event Claimed(address indexed account, address indexed asset, uint256 amount);
    event ConfigUpdated(uint24 lpFee, int24 tickSpacing, uint16 creatorShareBps, address treasury);
    event LaunchpadSet(address launchpad);
    event HookSet(address hook);

    enum Action {
        Add,
        Collect
    }

    struct Position {
        PoolKey key;
        address creator;
        uint128 liquidity;
        bool exists;
    }

    IPoolManager public immutable poolManager;
    address public launchpad;
    IHooks public hook;
    address public treasury;
    uint24 public lpFee = 0; // pool LP fee; the hook charges the swap fee instead (Pons style)
    int24 public tickSpacing = 200;
    uint16 public creatorShareBps = 5_000; // share of LP fees to the creator, remainder to treasury

    mapping(address token => Position) internal _positions;
    mapping(address account => mapping(address asset => uint256)) public claimable;

    constructor(IPoolManager poolManager_, address owner_, address treasury_) Ownable(owner_) {
        poolManager = poolManager_;
        treasury = treasury_;
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setLaunchpad(address launchpad_) external onlyOwner {
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    function setHook(IHooks hook_) external onlyOwner {
        hook = hook_;
        emit HookSet(address(hook_));
    }

    function setConfig(uint24 lpFee_, int24 tickSpacing_, uint16 creatorShareBps_, address treasury_)
        external
        onlyOwner
    {
        if (creatorShareBps_ > 10_000) revert InvalidBps();
        lpFee = lpFee_;
        tickSpacing = tickSpacing_;
        creatorShareBps = creatorShareBps_;
        treasury = treasury_;
        emit ConfigUpdated(lpFee_, tickSpacing_, creatorShareBps_, treasury_);
    }

    // ───────────────────────────── locking ─────────────────────────────

    /// @inheritdoc ILiquidityLocker
    function lock(
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        address creator,
        uint16 creatorTaxBps
    ) external payable nonReentrant {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (address(hook) == address(0)) revert HookNotSet();
        if (_positions[token].exists) revert AlreadyLocked();

        if (tokenAmount == 0 || quoteAmount == 0) revert ZeroLiquidity();
        (Currency c0, Currency c1, uint256 a0, uint256 a1) = _sort(token, quote, tokenAmount, quoteAmount);
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: lpFee, tickSpacing: tickSpacing, hooks: hook});

        uint160 sqrtPriceX96 = _sqrtPriceX96(a0, a1);
        poolManager.initialize(key, sqrtPriceX96);
        ILaunchHook(address(hook)).registerPool(key.toId(), token, creator, creatorTaxBps);

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), a0, a1
        );
        if (liquidity == 0) revert ZeroLiquidity();

        bytes memory result =
            poolManager.unlock(abi.encode(Action.Add, key, tickLower, tickUpper, int256(uint256(liquidity))));
        (uint256 used0, uint256 used1) = abi.decode(result, (uint256, uint256));

        _positions[token] = Position({key: key, creator: creator, liquidity: liquidity, exists: true});

        // Rounding leftovers stay claimable by the treasury rather than being stuck.
        if (a0 > used0) claimable[treasury][Currency.unwrap(c0)] += a0 - used0;
        if (a1 > used1) claimable[treasury][Currency.unwrap(c1)] += a1 - used1;

        (uint256 tokenUsed, uint256 quoteUsed) = Currency.unwrap(c0) == token ? (used0, used1) : (used1, used0);
        emit Locked(token, quote, key.toId(), sqrtPriceX96, liquidity, tokenUsed, quoteUsed);
    }

    /// @notice Collects accrued LP fees for `token`'s pool and credits creator / treasury balances.
    function collect(address token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Position memory p = _positions[token];
        if (!p.exists) revert NotLocked();

        int24 tickLower = TickMath.minUsableTick(p.key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(p.key.tickSpacing);
        bytes memory result = poolManager.unlock(abi.encode(Action.Collect, p.key, tickLower, tickUpper, int256(0)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        _credit(p.creator, Currency.unwrap(p.key.currency0), amount0);
        _credit(p.creator, Currency.unwrap(p.key.currency1), amount1);
        emit FeesCollected(token, amount0, amount1);
    }

    function claim(address asset) external nonReentrant {
        uint256 amount = claimable[msg.sender][asset];
        claimable[msg.sender][asset] = 0;
        if (amount == 0) return;
        if (asset == address(0)) msg.sender.safeTransferETH(amount);
        else asset.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, asset, amount);
    }

    function position(address token) external view returns (Position memory) {
        return _positions[token];
    }

    // ───────────────────────────── pool manager callback ─────────────────────────────

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (Action, PoolKey, int24, int24, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );

        if (action == Action.Add) {
            uint256 owed0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
            uint256 owed1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
            _settle(key.currency0, owed0);
            _settle(key.currency1, owed1);
            return abi.encode(owed0, owed1);
        } else {
            uint256 got0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            uint256 got1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            if (got0 > 0) poolManager.take(key.currency0, address(this), got0);
            if (got1 > 0) poolManager.take(key.currency1, address(this), got1);
            return abi.encode(got0, got1);
        }
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            Currency.unwrap(currency).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _credit(address creator, address asset, uint256 amount) internal {
        if (amount == 0) return;
        uint256 toCreator = (amount * creatorShareBps) / 10_000;
        claimable[creator][asset] += toCreator;
        claimable[treasury][asset] += amount - toCreator;
    }

    function _sort(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        internal
        pure
        returns (Currency c0, Currency c1, uint256 a0, uint256 a1)
    {
        if (uint160(quote) < uint160(token)) {
            return (Currency.wrap(quote), Currency.wrap(token), quoteAmount, tokenAmount);
        }
        return (Currency.wrap(token), Currency.wrap(quote), tokenAmount, quoteAmount);
    }

    /// @dev sqrt(a1 / a0) * 2^96, computed with full precision where possible.
    function _sqrtPriceX96(uint256 a0, uint256 a1) internal pure returns (uint160) {
        uint256 ratioX192;
        if (a1 / a0 < (1 << 63)) {
            ratioX192 = FullMath.mulDiv(a1, 1 << 192, a0);
        } else {
            // extremely lopsided; lose some precision instead of overflowing
            ratioX192 = FullMath.mulDiv(a1, 1 << 96, a0) << 96;
        }
        uint256 sqrtPrice = FixedPointMathLib.sqrt(ratioX192);
        if (sqrtPrice <= TickMath.MIN_SQRT_PRICE) sqrtPrice = TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE) sqrtPrice = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPrice);
    }

    receive() external payable {}
}
