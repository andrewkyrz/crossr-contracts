// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

/// @notice Minimal synchronous-queue LayerZero endpoint for tests. One instance plays the endpoint of
///         every "chain"; OApps register their eid so outgoing messages carry the right origin.
contract MockLzEndpoint {
    struct Pending {
        uint32 srcEid;
        bytes32 sender;
        uint32 dstEid;
        address receiver;
        bytes message;
        bytes32 guid;
        uint64 nonce;
    }

    uint256 public constant FEE = 0.001 ether;
    mapping(address => uint32) public eidOf;
    mapping(address => address) public delegates;
    Pending[] public queue;
    uint64 public nonce;
    bool public failNext;

    function setEid(address oapp, uint32 eid) external {
        eidOf[oapp] = eid;
    }

    function setDelegate(address d) external {
        delegates[msg.sender] = d;
    }

    function lzToken() external pure returns (address) {
        return address(0);
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(FEE, 0);
    }

    function send(MessagingParams calldata p, address refund) external payable returns (MessagingReceipt memory r) {
        require(msg.value >= FEE, "fee");
        if (msg.value > FEE) payable(refund).transfer(msg.value - FEE);
        nonce++;
        r.guid = keccak256(abi.encode(nonce, msg.sender, p.dstEid, p.receiver));
        r.nonce = nonce;
        r.fee = MessagingFee(FEE, 0);
        queue.push(
            Pending({
                srcEid: eidOf[msg.sender],
                sender: bytes32(uint256(uint160(msg.sender))),
                dstEid: p.dstEid,
                receiver: address(uint160(uint256(p.receiver))),
                message: p.message,
                guid: r.guid,
                nonce: nonce
            })
        );
    }

    function pending() external view returns (uint256) {
        return queue.length;
    }

    /// @notice Deliver the oldest queued message.
    function deliverNext() external {
        Pending memory m = queue[0];
        for (uint256 i = 0; i + 1 < queue.length; i++) {
            queue[i] = queue[i + 1];
        }
        queue.pop();
        ILayerZeroReceiver(m.receiver).lzReceive(Origin(m.srcEid, m.sender, m.nonce), m.guid, m.message, address(this), "");
    }
}
