// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet stand-in for a Robinhood stock token: a plain 18-decimal ERC20 with the ERC-8056 scaled-UI
///         `uiMultiplier()` (fixed at 1.0) and an open faucet `mint`. Deployed with CREATE2 by DeployMockQuote.s.sol so
///         it has the same address on every testnet. Never deploy on mainnet.
contract MockStockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    /// @dev ERC-8056: UI amount = raw balance × multiplier / 1e18 (corporate actions). Constant 1.0 here.
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    /// @notice Faucet: anyone can mint (testnet only).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
