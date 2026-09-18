// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {
    MessagingFee,
    Origin,
    ILayerZeroEndpointV2
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {PacketV1Codec} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";

import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";
import {LaunchTypes, ILaunchpad} from "../src/interfaces/ILaunchpad.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Cross-chain suite against LayerZero's own test harness: a real EndpointV2 per chain, the
///         UltraLightNode 302 send/receive libraries, a DVN, an executor and a price feed. Unlike the
///         MockLzEndpoint suite this exercises real fee quoting (executor gas priced through the ULN),
///         type-3 option parsing and enforced-option merging, DVN verification, nonce ordering and the
///         real receive path (the executor runs `lzReceive` with exactly the gas bought in the options,
///         and a reverting receive leaves the packet verified but unexecuted, i.e. retryable).
///         The enforced options mirror script/Wire.s.sol so the gas floors chosen there are tested.
contract CrossChainLzTest is LaunchpadTestBase, TestHelperOz5 {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;

    uint64 constant CHAIN_A = 4663;
    uint64 constant CHAIN_B = 56;
    // TestHelperOz5 numbers endpoints 1..n
    uint32 constant EID_A = 1;
    uint32 constant EID_B = 2;
    // must match script/Wire.s.sol
    uint128 constant BRIDGE_RECEIVE_GAS = 150_000;
    uint128 constant RELAY_RECEIVE_GAS = 3_000_000;

    Stack a;
    Stack b;
    TokenBridge bridgeA;
    TokenBridge bridgeB;
    LaunchRelay relayA;
    LaunchRelay relayB;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        setUpEndpoints(2, LibraryType.UltraLightNode);

        vm.chainId(CHAIN_A);
        a = deployStack();
        vm.chainId(CHAIN_B);
        b = deployStack();

        bridgeA = new TokenBridge(endpoints[EID_A], owner, ILaunchpad(address(a.pad)));
        bridgeB = new TokenBridge(endpoints[EID_B], owner, ILaunchpad(address(b.pad)));
        relayA = new LaunchRelay(endpoints[EID_A], owner);
        relayB = new LaunchRelay(endpoints[EID_B], owner);

        address[] memory bridges = new address[](2);
        bridges[0] = address(bridgeA);
        bridges[1] = address(bridgeB);
        wireOApps(bridges);
        address[] memory relays = new address[](2);
        relays[0] = address(relayA);
        relays[1] = address(relayB);
        wireOApps(relays);

        relayA.setLaunchpad(ILaunchpad(address(a.pad)));
        relayB.setLaunchpad(ILaunchpad(address(b.pad)));
        relayA.mapChain(CHAIN_B, EID_B);
        relayB.mapChain(CHAIN_A, EID_A);
        _enforce(bridgeA, relayA, EID_B, BRIDGE_RECEIVE_GAS, RELAY_RECEIVE_GAS);
        _enforce(bridgeB, relayB, EID_A, BRIDGE_RECEIVE_GAS, RELAY_RECEIVE_GAS);

        a.pad.setModules(address(bridgeA), address(relayA), address(a.locker), address(a.escrow), treasury);
        b.pad.setModules(address(bridgeB), address(relayB), address(b.locker), address(b.escrow), treasury);
        a.pad.setRemoteQuote(CHAIN_B, address(0), true);
        b.pad.setRemoteQuote(CHAIN_A, address(0), true);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(creator, 10 ether);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _enforce(TokenBridge bridge, LaunchRelay relay, uint32 eid, uint128 bridgeGas, uint128 relayGas)
        internal
    {
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
        opts[0] = EnforcedOptionParam({
            eid: eid,
            msgType: bridge.MSG_TYPE(),
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(bridgeGas, 0)
        });
        bridge.setEnforcedOptions(opts);
        EnforcedOptionParam[] memory relayOpts = new EnforcedOptionParam[](1);
        relayOpts[0] = EnforcedOptionParam({
            eid: eid,
            msgType: relay.MSG_TYPE(),
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(relayGas, 0)
        });
        relay.setEnforcedOptions(relayOpts);
    }

    function _b32(address x) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(x)));
    }

    function _relayed(uint8 idx, bytes memory options)
        internal
        pure
        returns (Launchpad.RelaySpec[] memory r)
    {
        r = new Launchpad.RelaySpec[](1);
        r[0] = Launchpad.RelaySpec({legIndex: idx, options: options});
    }

    /// Launch on A (relying only on the enforced options), deliver the relay packet on B.
    function _launchBoth(uint16 bpsA) internal returns (LaunchTypes.Manifest memory m, address tokenA) {
        m = twoLegManifest(creator, CHAIN_A, CHAIN_B, bpsA);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        uint256 relayFee = relayA.quoteLeg(m, 1, "");
        Launchpad.RelaySpec[] memory relays = _relayed(1, "");
        vm.prank(creator);
        tokenA = a.pad.createLaunch{value: fee * 2 + relayFee}(m, 0, relays, 0, 0);
        assertTrue(hasPendingPackets(uint16(EID_B), _b32(address(relayB))), "relay packet in flight");

        vm.chainId(CHAIN_B);
        verifyPackets(EID_B, address(relayB));
        assertFalse(hasPendingPackets(uint16(EID_B), _b32(address(relayB))));
    }

    function _buyA(address tokenA, uint256 value) internal returns (uint256 bought) {
        vm.chainId(CHAIN_A);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        bought = _ld(a.pad.buy{value: value}(tokenA, value, 0, alice, block.timestamp));
    }

    /// Bridged amounts are rounded down to the shared 9-decimal precision.
    function _ld(uint256 x) internal pure returns (uint256) {
        return x - (x % 1e9);
    }

    /// Executes the next verified packet for `oapp` on `eid` through the real endpoint with unlimited gas
    /// and returns the gas the endpoint call consumed. Leaves the helper queue untouched, so only use it
    /// in tests that do not call verifyPackets for the same packet afterwards.
    function _measureReceive(uint32 eid, address oapp) internal returns (uint256 used) {
        bytes memory pkt = getNextInflightPacket(uint16(eid), _b32(oapp));
        require(pkt.length > 0, "no packet");
        this.validatePacket(pkt, "");
        return this.executeMeasured(pkt);
    }

    /// @dev external so PacketV1Codec can read the packet from calldata
    function executeMeasured(bytes calldata pkt) external returns (uint256 used) {
        Origin memory origin = Origin(pkt.srcEid(), pkt.sender(), pkt.nonce());
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoints[pkt.dstEid()]);
        bytes memory message = pkt.message();
        bytes32 guid = pkt.guid();
        address receiver = pkt.receiverB20();
        uint256 before = gasleft();
        ep.lzReceive(origin, receiver, guid, message, "");
        used = before - gasleft();
    }

    // ───────────────────────────── relay ─────────────────────────────

    function test_lz_relay_createsRemoteLeg() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(6_000);
        bytes32 id = a.pad.manifestHash(m);
        address tokenB = b.pad.tokenOf(id);
        assertTrue(tokenB != address(0), "leg B created");
        assertEq(LaunchToken(tokenA).launchId(), id);
        assertEq(LaunchToken(tokenB).launchId(), id);
        assertEq(LaunchToken(tokenA).totalSupply(), (SUPPLY * 6) / 10);
        assertEq(LaunchToken(tokenB).totalSupply(), (SUPPLY * 4) / 10);
        assertEq(a.pad.spotPrice(tokenA), b.pad.spotPrice(tokenB));
        // nonce advanced on the real channel
        assertEq(
            ILayerZeroEndpointV2(endpoints[EID_A])
                .outboundNonce(address(relayA), EID_B, _b32(address(relayB))),
            1
        );
        assertEq(
            ILayerZeroEndpointV2(endpoints[EID_B])
                .inboundNonce(address(relayB), EID_A, _b32(address(relayA))),
            1
        );
    }

    /// The relay fee is a real ULN quote: it prices executor gas, so buying more gas costs more, and
    /// the enforced options alone already produce a non-zero fee.
    function test_lz_relay_feeIsRealAndScalesWithGas() public view {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        uint256 base = relayA.quoteLeg(m, 1, "");
        assertGt(base, 0, "enforced options alone are priced");
        bytes memory extra = OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
        uint256 more = relayA.quoteLeg(m, 1, extra);
        assertGt(more, base, "extra gas costs more");
    }

    /// The web app passes its own lzReceive option on top of the enforced one (LaunchForm RELAY_LEG_GAS);
    /// combined type-3 options must parse in the ULN and the fee quoted must be the fee accepted.
    function test_lz_relay_userOptionsMergeWithEnforced() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        bytes memory extra = OptionsBuilder.newOptions().addExecutorLzReceiveOption(500_000, 0);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        uint256 relayFee = relayA.quoteLeg(m, 1, extra);
        Launchpad.RelaySpec[] memory relays = _relayed(1, extra);

        // overpaying by one wei is rejected: the OApp requires msg.value == quoted fee
        vm.prank(creator);
        vm.expectRevert(Launchpad.BadValue.selector);
        a.pad.createLaunch{value: fee * 2 + relayFee + 1}(m, 0, relays, 0, 0);

        vm.prank(creator);
        a.pad.createLaunch{value: fee * 2 + relayFee}(m, 0, relays, 0, 0);
        vm.chainId(CHAIN_B);
        verifyPackets(EID_B, address(relayB));
        assertTrue(b.pad.tokenOf(a.pad.manifestHash(m)) != address(0));
    }

    /// The executor gives lzReceive exactly the gas bought. With too small an enforced floor the remote
    /// leg creation runs out of gas; the packet stays verified-but-unexecuted on the endpoint.
    function test_lz_relay_enforcedGasFloorMatters() public {
        _enforce(bridgeA, relayA, EID_B, BRIDGE_RECEIVE_GAS, 200_000);
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        uint256 relayFee = relayA.quoteLeg(m, 1, "");
        vm.prank(creator);
        a.pad.createLaunch{value: fee * 2 + relayFee}(m, 0, _relayed(1, ""), 0, 0);

        vm.chainId(CHAIN_B);
        vm.expectRevert();
        this.verifyPackets(EID_B, address(relayB));
        assertEq(b.pad.tokenOf(a.pad.manifestHash(m)), address(0), "leg not created");
        assertTrue(hasPendingPackets(uint16(EID_B), _b32(address(relayB))), "packet still pending");
    }

    /// Records what the receive paths actually cost so the Wire.s.sol floors can be judged.
    function test_lz_gas_receiveBudgets() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        uint256 relayFee = relayA.quoteLeg(m, 1, "");
        vm.prank(creator);
        address tokenA = a.pad.createLaunch{value: fee * 2 + relayFee}(m, 0, _relayed(1, ""), 0, 0);

        vm.chainId(CHAIN_B);
        uint256 relayGas = _measureReceive(EID_B, address(relayB));
        emit log_named_uint("relay lzReceive gas (endpoint call)", relayGas);
        assertLt(relayGas, RELAY_RECEIVE_GAS, "relay floor too low");
        assertLt(relayGas * 3 / 2, RELAY_RECEIVE_GAS, "relay floor has < 1.5x margin");

        uint256 bought = _buyA(tokenA, 1 ether);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought, "").nativeFee;
        vm.prank(alice);
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(bob), bought, "");
        vm.chainId(CHAIN_B);
        uint256 bridgeGas = _measureReceive(EID_B, address(bridgeB));
        emit log_named_uint("bridge lzReceive gas (endpoint call)", bridgeGas);
        assertLt(bridgeGas, BRIDGE_RECEIVE_GAS, "bridge floor too low");
        assertLt(bridgeGas * 12 / 10, BRIDGE_RECEIVE_GAS, "bridge floor has < 20% margin");
    }

    // ───────────────────────────── bridge ─────────────────────────────

    function test_lz_bridge_burnsAndMints_enforcedOptionsOnly() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));
        uint256 bought = _buyA(tokenA, 1 ether);

        MessagingFee memory fee = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought / 2, "");
        assertGt(fee.nativeFee, 0);
        assertEq(fee.lzTokenFee, 0);
        uint256 supplyA = LaunchToken(tokenA).totalSupply();
        vm.prank(alice);
        bridgeA.send{value: fee.nativeFee}(EID_B, tokenA, _b32(bob), bought / 2, "");
        assertEq(LaunchToken(tokenA).totalSupply(), supplyA - bought / 2, "burned on A");

        vm.chainId(CHAIN_B);
        uint256 supplyB = LaunchToken(tokenB).totalSupply();
        verifyPackets(EID_B, address(bridgeB));
        assertEq(LaunchToken(tokenB).balanceOf(bob), bought / 2, "minted on B");
        assertEq(LaunchToken(tokenB).totalSupply(), supplyB + bought / 2);
        assertEq(LaunchToken(tokenA).totalSupply() + LaunchToken(tokenB).totalSupply(), SUPPLY);
    }

    function test_lz_bridge_roundTripAndOrdering() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));
        uint256 bought = _buyA(tokenA, 1 ether);
        uint256 aliceA = LaunchToken(tokenA).balanceOf(alice); // includes the sub-1e9 dust `bought` drops

        // two sends A→B: nonces 1 and 2, both delivered in order by one verifyPackets call
        vm.startPrank(alice);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(alice), 100e9, "").nativeFee;
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(alice), 100e9, "");
        uint256 feeA2_ = bridgeA.quoteSend(EID_B, tokenA, _b32(alice), 200e9, "").nativeFee;
        bridgeA.send{value: feeA2_}(EID_B, tokenA, _b32(alice), 200e9, "");
        vm.stopPrank();
        assertEq(
            ILayerZeroEndpointV2(endpoints[EID_A])
                .outboundNonce(address(bridgeA), EID_B, _b32(address(bridgeB))),
            2
        );
        vm.chainId(CHAIN_B);
        verifyPackets(EID_B, address(bridgeB));
        assertEq(LaunchToken(tokenB).balanceOf(alice), 300e9);
        assertEq(
            ILayerZeroEndpointV2(endpoints[EID_B])
                .inboundNonce(address(bridgeB), EID_A, _b32(address(bridgeA))),
            2
        );

        // and back B→A on the other channel
        uint256 feeB_ = bridgeB.quoteSend(EID_A, tokenB, _b32(bob), 300e9, "").nativeFee;
        vm.prank(alice);
        bridgeB.send{value: feeB_}(EID_A, tokenB, _b32(bob), 300e9, "");
        assertEq(LaunchToken(tokenB).balanceOf(alice), 0);
        vm.chainId(CHAIN_A);
        verifyPackets(EID_A, address(bridgeA));
        assertEq(LaunchToken(tokenA).balanceOf(bob), 300e9);
        assertEq(LaunchToken(tokenA).balanceOf(alice), aliceA - 300e9);
        assertEq(LaunchToken(tokenA).totalSupply() + LaunchToken(tokenB).totalSupply(), SUPPLY);
    }

    /// Bridging before the destination leg exists: the receive reverts inside the real endpoint, the
    /// packet remains retryable, and once the creator opens the leg the same packet executes.
    function test_lz_bridge_receiveFailsThenRetriesAfterLegExists() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        vm.prank(creator);
        address tokenA = a.pad.createLaunch{value: fee}(m, 0, noRelays(), 0, 0);
        uint256 bought = _buyA(tokenA, 1 ether);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought, "").nativeFee;
        vm.prank(alice);
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(bob), bought, "");

        vm.chainId(CHAIN_B);
        vm.expectRevert(TokenBridge.NotLaunchToken.selector);
        this.verifyPackets(EID_B, address(bridgeB));
        assertTrue(hasPendingPackets(uint16(EID_B), _b32(address(bridgeB))), "still pending");

        // creator opens leg B directly with the identical manifest
        vm.prank(creator);
        address tokenB = b.pad.createLaunch{value: fee}(m, 1, noRelays(), 0, 0);
        verifyPackets(EID_B, address(bridgeB));
        assertEq(LaunchToken(tokenB).balanceOf(bob), bought, "retry minted");
    }

    /// A packet from an address that is not the configured peer is refused by the endpoint at
    /// verification (allowInitializePath), never reaching the bridge.
    function test_lz_bridge_rejectsUnknownPeer() public {
        (, address tokenA) = _launchBoth(5_000);
        uint256 bought = _buyA(tokenA, 1 ether);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought, "").nativeFee;
        vm.prank(alice);
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(bob), bought, "");

        vm.chainId(CHAIN_B);
        bridgeB.setPeer(EID_A, _b32(address(0xDEAD)));
        vm.expectRevert();
        this.verifyPackets(EID_B, address(bridgeB));
    }

    function test_lz_bridge_pausedReceiveIsRetryable() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));
        uint256 bought = _buyA(tokenA, 1 ether);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought, "").nativeFee;
        vm.prank(alice);
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(bob), bought, "");

        vm.chainId(CHAIN_B);
        bridgeB.pause();
        vm.expectRevert();
        this.verifyPackets(EID_B, address(bridgeB));
        bridgeB.unpause();
        verifyPackets(EID_B, address(bridgeB));
        assertEq(LaunchToken(tokenB).balanceOf(bob), bought);
    }

    // ───────────────────────────── curves stay independent ─────────────────────────────

    function test_lz_bothLegsGraduateIndependently() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));
        vm.warp(block.timestamp + 10);

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        a.pad.buy{value: 10 ether}(tokenA, 10 ether, 0, alice, block.timestamp);
        assertEq(uint8(a.pad.getCurve(tokenA).status), uint8(LaunchTypes.Status.Graduated));
        assertEq(uint8(b.pad.getCurve(tokenB).status), uint8(LaunchTypes.Status.Active));

        vm.chainId(CHAIN_B);
        vm.prank(bob);
        b.pad.buy{value: 10 ether}(tokenB, 10 ether, 0, bob, block.timestamp);
        assertEq(uint8(b.pad.getCurve(tokenB).status), uint8(LaunchTypes.Status.Graduated));

        // bridging keeps working after graduation on both sides
        uint256 bal = _ld(LaunchToken(tokenA).balanceOf(alice));
        vm.chainId(CHAIN_A);
        uint256 feeA_ = bridgeA.quoteSend(EID_B, tokenA, _b32(alice), bal, "").nativeFee;
        vm.prank(alice);
        bridgeA.send{value: feeA_}(EID_B, tokenA, _b32(alice), bal, "");
        vm.chainId(CHAIN_B);
        verifyPackets(EID_B, address(bridgeB));
        assertEq(LaunchToken(tokenB).balanceOf(alice), bal);
    }
}
