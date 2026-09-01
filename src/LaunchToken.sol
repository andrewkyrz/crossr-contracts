// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ILaunchpad} from "./interfaces/ILaunchpad.sol";

/// @title LaunchToken
/// @notice Plain ERC20 (+permit) minted by the Launchpad on every chain of a launch. The same address
///         is used on every chain (CREATE3, salt = launch id). Global supply is fixed: each chain mints
///         only its leg allocation, and the bridge burns on the source chain before minting on the
///         destination. Nobody, including the platform, can mint outside of a bridge transfer.
contract LaunchToken is ERC20, ERC20Permit {
    error NotLaunchpad();
    error NotBridge();

    address public immutable launchpad;
    bytes32 public immutable launchId;
    string private _metadataURI;

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _;
    }

    modifier onlyBridge() {
        address b = ILaunchpad(launchpad).bridge();
        if (b == address(0) || msg.sender != b) revert NotBridge();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        bytes32 launchId_,
        address launchpad_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        launchpad = launchpad_;
        launchId = launchId_;
        _metadataURI = metadataURI_;
        _mint(launchpad_, initialSupply);
    }

    function metadataURI() external view returns (string memory) {
        return _metadataURI;
    }

    function bridge() external view returns (address) {
        return ILaunchpad(launchpad).bridge();
    }

    /// @notice Burns launchpad-held tokens (unused curve reserve at graduation).
    function burnFromLaunchpad(uint256 amount) external onlyLaunchpad {
        _burn(launchpad, amount);
    }

    function bridgeMint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    function bridgeBurn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }
}
