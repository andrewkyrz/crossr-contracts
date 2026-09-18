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
///         Peers may be EVM bridges or the Solana `crossr_bridge` OApp: recipients are `bytes32` (EVM addresses
///         left-padded, Solana public keys as-is) and amounts travel in shared 9-decimal units (Solana mints have
///         9 decimals, EVM tokens 18), so a send burns `amount` rounded down to a multiple of 1e9 wei.
/// @dev Security: only tokens created by the local Launchpad can be burned/minted, peers are set by
///      the owner (use a multisig + timelock in production) and the bridge is pausable.
contract TokenBridge is OApp, OAppOptionsType3, Ownable2Step, Pausable {
    error NotLaunchToken();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidMessage();

    event BridgeSent(
        bytes32 indexed guid, address indexed token, address indexed from, uint32 dstEid, bytes32 to, uint256 amount
    );
    event BridgeReceived(bytes32 indexed guid, address indexed token, address indexed to, uint32 srcEid, uint256 amount);

    uint16 public constant MSG_TYPE = 1;
    /// @notice Decimals of amounts inside bridge messages (the Solana mint's decimals).
    uint8 public constant SHARED_DECIMALS = 9;
    /// @notice 18 local decimals → 9 shared decimals.
    uint256 public constant DECIMAL_CONVERSION_RATE = 1e9;
    uint256 internal constant MESSAGE_LENGTH = 96; // abi.encode(bytes32, bytes32, uint256)

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

    /// @notice Local amount that a send of `amount` actually bridges (rounded down to the shared precision).
    function removeDust(uint256 amount) public pure returns (uint256) {
        return (amount / DECIMAL_CONVERSION_RATE) * DECIMAL_CONVERSION_RATE;
    }

    function quoteSend(uint32 dstEid, address token, bytes32 to, uint256 amount, bytes calldata extraOptions)
        external
        view
        returns (MessagingFee memory)
    {
        bytes32 launchId = ILaunchToken(token).launchId();
        return _quote(
            dstEid,
            _encode(launchId, to, amount / DECIMAL_CONVERSION_RATE),
            combineOptions(dstEid, MSG_TYPE, extraOptions),
            false
        );
    }

    /// @notice Burn `amount` of `token` (rounded down to 1e9 wei) from the caller and mint it to `to` on `dstEid`.
    /// @param to Recipient on the destination: `bytes32(uint256(uint160(addr)))` for EVM, the public key for Solana.
    function send(uint32 dstEid, address token, bytes32 to, uint256 amount, bytes calldata extraOptions)
        external
        payable
        whenNotPaused
        returns (MessagingReceipt memory receipt)
    {
        if (!launchpad.isLaunchToken(token)) revert NotLaunchToken();
        uint256 amountSD = amount / DECIMAL_CONVERSION_RATE;
        if (amountSD == 0) revert ZeroAmount();
        if (to == bytes32(0)) revert ZeroAddress();
        uint256 amountLD = amountSD * DECIMAL_CONVERSION_RATE;

        bytes32 launchId = ILaunchToken(token).launchId();
        ILaunchToken(token).bridgeBurn(msg.sender, amountLD);
        receipt = _lzSend(
            dstEid,
            _encode(launchId, to, amountSD),
            combineOptions(dstEid, MSG_TYPE, extraOptions),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
        emit BridgeSent(receipt.guid, token, msg.sender, dstEid, to, amountLD);
    }

    function _lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        internal
        override
        whenNotPaused
    {
        if (message.length != MESSAGE_LENGTH) revert InvalidMessage();
        (bytes32 launchId, bytes32 to, uint256 amountSD) = abi.decode(message, (bytes32, bytes32, uint256));
        if (uint256(to) >> 160 != 0) revert InvalidMessage(); // not an EVM address
        if (amountSD == 0 || amountSD > type(uint64).max) revert InvalidMessage();
        // The leg must already exist locally; otherwise the message stays retryable on the endpoint.
        address token = launchpad.tokenOf(launchId);
        if (token == address(0)) revert NotLaunchToken();
        address recipient = address(uint160(uint256(to)));
        uint256 amountLD = amountSD * DECIMAL_CONVERSION_RATE;
        ILaunchToken(token).bridgeMint(recipient, amountLD);
        emit BridgeReceived(guid, token, recipient, origin.srcEid, amountLD);
    }

    /// @dev Same bytes as the Solana program's `msg::encode`: 32-byte launch id, 32-byte recipient, uint256 amount.
    function _encode(bytes32 launchId, bytes32 to, uint256 amountSD) internal pure returns (bytes memory) {
        return abi.encode(launchId, to, amountSD);
    }

    /// @dev Resolve the Ownable diamond (OAppCore inherits Ownable, we add Ownable2Step).
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}
