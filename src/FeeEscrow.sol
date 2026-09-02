// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeEscrow} from "./interfaces/IFeeEscrow.sol";

/// @title FeeEscrow
/// @notice Claim-based vault for every fee the protocol produces (curve fees, creator tax, hook fees,
///         launch fees). Creditors (launchpad, hook, locker) push balances; recipients pull.
contract FeeEscrow is IFeeEscrow, Ownable2Step, ReentrancyGuard {
    using SafeTransferLib for address;

    error NotCreditor();

    event CreditorSet(address indexed creditor, bool allowed);
    event Credited(address indexed account, address indexed asset, uint256 amount, address indexed by);
    event Claimed(address indexed account, address indexed asset, uint256 amount, address to);

    mapping(address => bool) public isCreditor;
    mapping(address account => mapping(address asset => uint256)) public balanceOf;

    constructor(address owner_) Ownable(owner_) {}

    function setCreditor(address creditor, bool allowed) external onlyOwner {
        isCreditor[creditor] = allowed;
        emit CreditorSet(creditor, allowed);
    }

    function creditNative(address account) external payable {
        if (!isCreditor[msg.sender]) revert NotCreditor();
        if (msg.value == 0) return;
        balanceOf[account][address(0)] += msg.value;
        emit Credited(account, address(0), msg.value, msg.sender);
    }

    function creditToken(address account, address asset, uint256 amount) external {
        if (!isCreditor[msg.sender]) revert NotCreditor();
        if (amount == 0) return;
        balanceOf[account][asset] += amount;
        emit Credited(account, asset, amount, msg.sender);
    }

    function claim(address asset) external nonReentrant {
        _claim(asset, msg.sender, balanceOf[msg.sender][asset]);
    }

    function claim(address asset, uint256 amount, address to) external nonReentrant {
        _claim(asset, to, amount);
    }

    function _claim(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        balanceOf[msg.sender][asset] -= amount;
        if (asset == address(0)) to.safeTransferETH(amount);
        else asset.safeTransfer(to, amount);
        emit Claimed(msg.sender, asset, amount, to);
    }
}
