// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeeEscrow {
    /// @notice Credit native value (msg.value) to `account`.
    function creditNative(address account) external payable;
    /// @notice Credit `amount` of `asset` to `account`; the tokens must already be held by the escrow.
    function creditToken(address account, address asset, uint256 amount) external;
}
