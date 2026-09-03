// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ILaunchpad} from "../interfaces/ILaunchpad.sol";
import {ILaunchToken} from "../interfaces/ILaunchToken.sol";

/// @title TokenBridge
/// @notice One shared LayerZero OApp per chain that bridges every launch token (burn here, mint there).
///         Messages carry the launch id; each side resolves it to its local token through the Launchpad.
/// @dev Security: only tokens created by the local Launchpad can be burned/minted, peers are set by
///      the owner (use a multisig + timelock in production) and the bridge is pausable.
contract TokenBridge is OApp, OAppOptionsType3, Ownable2Step, Pausable {
    error NotLaunchToken();
    error ZeroAmount();
    error ZeroAddress();

    event BridgeSent(
        bytes32 indexed guid, address indexed token, address indexed from, uint32 dstEid, address to, uint256 amount
    );
    event BridgeReceived(bytes32 indexed guid, address indexed token, address indexed to, uint32 srcEid, uint256 amount);

    uint16 public constant MSG_TYPE = 1;
    ILaunchpad public immutable launchpad;

    constructor(address endpoint, address owner_, ILaunchpad launchpad_)
        OApp(endpoint, owner_)
        Ownable(owner_)
    {
        launchpad = launchpad_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function quoteSend(uint32 dstEid, address token, address to, uint256 amount, bytes calldata extraOptions)
        external
        view
        returns (MessagingFee memory)
    {
        bytes32 launchId = ILaunchToken(token).launchId();
        return _quote(dstEid, abi.encode(launchId, to, amount), combineOptions(dstEid, MSG_TYPE, extraOptions), false);
    }

    /// @notice Burn `amount` of `token` from the caller and mint it to `to` on `dstEid`.
    function send(uint32 dstEid, address token, address to, uint256 amount, bytes calldata extraOptions)
        external
        payable
        whenNotPaused
        returns (MessagingReceipt memory receipt)
    {
        if (!launchpad.isLaunchToken(token)) revert NotLaunchToken();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        bytes32 launchId = ILaunchToken(token).launchId();
        ILaunchToken(token).bridgeBurn(msg.sender, amount);
        receipt = _lzSend(
            dstEid,
            abi.encode(launchId, to, amount),
            combineOptions(dstEid, MSG_TYPE, extraOptions),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
        emit BridgeSent(receipt.guid, token, msg.sender, dstEid, to, amount);
    }

    function _lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        internal
        override
        whenNotPaused
    {
        (bytes32 launchId, address to, uint256 amount) = abi.decode(message, (bytes32, address, uint256));
        // The leg must already exist locally; otherwise the message stays retryable on the endpoint.
        address token = launchpad.tokenOf(launchId);
        if (token == address(0)) revert NotLaunchToken();
        ILaunchToken(token).bridgeMint(to, amount);
        emit BridgeReceived(guid, token, to, origin.srcEid, amount);
    }

    /// @dev Resolve the Ownable diamond (OAppCore inherits Ownable, we add Ownable2Step).
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}
