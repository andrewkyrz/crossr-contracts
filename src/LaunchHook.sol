// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {IFeeEscrow} from "./interfaces/IFeeEscrow.sol";

/// @title LaunchHook
/// @notice Uniswap v4 hook for graduation pools (Pons V2 "MemeHook" equivalent).
///         - beforeInitialize: only the LiquidityLocker may create pools keyed with this hook, so a
///           graduation pool can never be squatted at a manipulated price.
///         - afterSwap: takes `hookFeeBps` (+ the launch's creator tax) of the unspecified currency
///           and credits it to the fee escrow, split between protocol treasury and creator.
/// @dev Deployed at an address whose low 14 bits equal
///      BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA (mined with HookMiner).
contract LaunchHook is BaseHook, ILaunchHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeTransferLib for address;

    error OnlyLocker();
    error InvalidBps();

    event PoolRegistered(PoolId indexed poolId, address indexed token, address indexed creator, uint16 creatorTaxBps);
    event HookFee(PoolId indexed poolId, address indexed currency, uint256 baseFee, uint256 creatorTax);
    event FeeConfigUpdated(uint16 hookFeeBps, uint16 protocolShareBps, address treasury);

    struct PoolInfo {
        address token;
        address creator;
        uint16 creatorTaxBps;
        bool registered;
    }

    address public immutable locker;
    IFeeEscrow public immutable escrow;
    address public treasury;
    uint16 public hookFeeBps = 100; // 1%
    uint16 public protocolShareBps = 3_000; // 30% of the base fee, 70% to the creator

    mapping(PoolId => PoolInfo) public pools;

    constructor(IPoolManager manager, address locker_, IFeeEscrow escrow_, address owner_, address treasury_)
        BaseHook(manager)
        Ownable(owner_)
    {
        locker = locker_;
        escrow = escrow_;
        treasury = treasury_;
    }

    function setFeeConfig(uint16 hookFeeBps_, uint16 protocolShareBps_, address treasury_) external onlyOwner {
        if (hookFeeBps_ > 1_000 || protocolShareBps_ > 5_000) revert InvalidBps();
        hookFeeBps = hookFeeBps_;
        protocolShareBps = protocolShareBps_;
        treasury = treasury_;
        emit FeeConfigUpdated(hookFeeBps_, protocolShareBps_, treasury_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc ILaunchHook
    function registerPool(PoolId poolId, address token, address creator, uint16 creatorTaxBps) external {
        if (msg.sender != locker) revert OnlyLocker();
        pools[poolId] = PoolInfo({token: token, creator: creator, creatorTaxBps: creatorTaxBps, registered: true});
        emit PoolRegistered(poolId, token, creator, creatorTaxBps);
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != locker) revert OnlyLocker();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolInfo memory info = pools[id];
        uint256 totalBps = uint256(hookFeeBps) + (info.registered ? info.creatorTaxBps : 0);
        if (totalBps == 0) return (BaseHook.afterSwap.selector, 0);

        // fee is charged on the unspecified currency
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 amt) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (amt < 0) amt = -amt;
        uint256 unspecified = uint256(uint128(amt));

        uint256 baseFee = (unspecified * hookFeeBps) / 10_000;
        uint256 creatorTax = info.registered ? (unspecified * info.creatorTaxBps) / 10_000 : 0;
        uint256 total = baseFee + creatorTax;
        if (total == 0) return (BaseHook.afterSwap.selector, 0);

        poolManager.take(feeCurrency, address(this), total);
        _distribute(Currency.unwrap(feeCurrency), info, baseFee, creatorTax);
        emit HookFee(id, Currency.unwrap(feeCurrency), baseFee, creatorTax);
        return (BaseHook.afterSwap.selector, total.toInt128());
    }

    function _distribute(address asset, PoolInfo memory info, uint256 baseFee, uint256 creatorTax) internal {
        uint256 toProtocol = info.registered ? (baseFee * protocolShareBps) / 10_000 : baseFee;
        uint256 toCreator = baseFee - toProtocol + creatorTax;
        if (asset == address(0)) {
            if (toProtocol > 0) escrow.creditNative{value: toProtocol}(treasury);
            if (toCreator > 0) escrow.creditNative{value: toCreator}(info.creator);
        } else {
            asset.safeTransfer(address(escrow), toProtocol + toCreator);
            if (toProtocol > 0) escrow.creditToken(treasury, asset, toProtocol);
            if (toCreator > 0) escrow.creditToken(info.creator, asset, toCreator);
        }
    }

    receive() external payable {}
}
