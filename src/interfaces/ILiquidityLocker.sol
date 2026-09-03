// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidityLocker {
    /// @notice Create the Uniswap v4 pool for `token`/`quote`, seed it with full-range liquidity and
    ///         lock the position forever. Token and quote must already be held by the locker
    ///         (native quote is sent as msg.value).
    function lock(
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        address creator,
        uint16 creatorTaxBps
    ) external payable;
}
