// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILaunchToken is IERC20 {
    function launchId() external view returns (bytes32);
    function launchpad() external view returns (address);
    function metadataURI() external view returns (string memory);
    function burnFromLaunchpad(uint256 amount) external;
    function bridgeMint(address to, uint256 amount) external;
    function bridgeBurn(address from, uint256 amount) external;
}
