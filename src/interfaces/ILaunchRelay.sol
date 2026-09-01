// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchTypes} from "./ILaunchpad.sol";

interface ILaunchRelay {
    function isSupported(uint64 chainId) external view returns (bool);
    function quoteLeg(LaunchTypes.Manifest calldata manifest, uint8 legIndex, bytes calldata options)
        external
        view
        returns (uint256 nativeFee);
    function sendLeg(
        LaunchTypes.Manifest calldata manifest,
        uint8 legIndex,
        bytes calldata options,
        address refundTo
    ) external payable;
}
