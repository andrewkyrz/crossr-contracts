// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface ILaunchHook {
    function registerPool(PoolId poolId, address token, address creator, uint16 creatorTaxBps) external;
}
