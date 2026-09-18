// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";
import {LaunchTypes, ILaunchpad} from "../src/interfaces/ILaunchpad.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/// @dev Simulates two chains (Robinhood 4663 = A, BNB 56 = B) in one VM with a synchronous mock endpoint.
contract CrossChainTest is LaunchpadTestBase {
    using OptionsBuilder for bytes;

    uint64 constant CHAIN_A = 4663;
    uint64 constant CHAIN_B = 56;
    uint32 constant EID_A = 30416;
    uint32 constant EID_B = 30102;

    Stack a;
    Stack b;
    MockLzEndpoint lz;
    TokenBridge bridgeA;
    TokenBridge bridgeB;
    LaunchRelay relayA;
    LaunchRelay relayB;

    function setUp() public {
        vm.warp(1_800_000_000);
        lz = new MockLzEndpoint();

        vm.chainId(CHAIN_A);
        a = deployStack();
        vm.chainId(CHAIN_B);
        b = deployStack();

        bridgeA = new TokenBridge(address(lz), owner, ILaunchpad(address(a.pad)));
        bridgeB = new TokenBridge(address(lz), owner, ILaunchpad(address(b.pad)));
        relayA = new LaunchRelay(address(lz), owner);
        relayB = new LaunchRelay(address(lz), owner);
        lz.setEid(address(bridgeA), EID_A);
        lz.setEid(address(bridgeB), EID_B);
        lz.setEid(address(relayA), EID_A);
        lz.setEid(address(relayB), EID_B);

        bridgeA.setPeer(EID_B, _b32(address(bridgeB)));
        bridgeB.setPeer(EID_A, _b32(address(bridgeA)));
        relayA.setPeer(EID_B, _b32(address(relayB)));
        relayB.setPeer(EID_A, _b32(address(relayA)));
        relayA.setLaunchpad(ILaunchpad(address(a.pad)));
        relayB.setLaunchpad(ILaunchpad(address(b.pad)));
        relayA.mapChain(CHAIN_B, EID_B);
        relayB.mapChain(CHAIN_A, EID_A);

        a.pad.setModules(address(bridgeA), address(relayA), address(a.locker), address(a.escrow), treasury);
        b.pad.setModules(address(bridgeB), address(relayB), address(b.locker), address(b.escrow), treasury);
        a.pad.setRemoteQuote(CHAIN_B, address(0), true);
        b.pad.setRemoteQuote(CHAIN_A, address(0), true);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(creator, 10 ether);
    }

    function _b32(address x) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(x)));
    }

    function _relayed(uint8 idx) internal pure returns (Launchpad.RelaySpec[] memory r) {
        r = new Launchpad.RelaySpec[](1);
        r[0] = Launchpad.RelaySpec({
            legIndex: idx, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
    }

    /// Launch on A with a single tx; the relay creates the B leg.
    function _launchBoth(uint16 bpsA) internal returns (LaunchTypes.Manifest memory m, address token) {
        m = twoLegManifest(creator, CHAIN_A, CHAIN_B, bpsA);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        uint256 relayFee = relayA.quoteLeg(m, 1, _relayed(1)[0].options);
        assertEq(relayFee, lz.FEE());
        Launchpad.RelaySpec[] memory relays = _relayed(1);
        vm.prank(creator);
        token = a.pad.createLaunch{value: fee * 2 + relayFee}(m, 0, relays, 0, 0);
        assertEq(lz.pending(), 1);

        vm.chainId(CHAIN_B);
        lz.deliverNext();
        assertEq(lz.pending(), 0);
    }

    function test_relay_createsRemoteLeg() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(6_000);
        bytes32 id = a.pad.manifestHash(m);
        address tokenB = b.pad.tokenOf(id);
        assertTrue(tokenB != address(0), "leg B created");
        assertEq(LaunchToken(tokenA).launchId(), id);
        assertEq(LaunchToken(tokenB).launchId(), id);
        assertEq(LaunchToken(tokenA).totalSupply(), (SUPPLY * 6) / 10);
        assertEq(LaunchToken(tokenB).totalSupply(), (SUPPLY * 4) / 10);
        assertEq(LaunchToken(tokenB).name(), m.name);
        // both launch fees landed in A's treasury balance
        assertEq(a.escrow.balanceOf(treasury, address(0)), a.pad.creationFee() * 2);
        assertEq(b.escrow.balanceOf(treasury, address(0)), 0);
        // both legs open at the same price
        assertEq(a.pad.spotPrice(tokenA), b.pad.spotPrice(tokenB));
    }

    function test_relay_revertsIfRemoteQuoteNotAllowed() public {
        a.pad.setRemoteQuote(CHAIN_B, address(0), false);
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        Launchpad.RelaySpec[] memory relays = _relayed(1);
        vm.prank(creator);
        vm.expectRevert(Launchpad.RemoteQuoteNotAllowed.selector);
        a.pad.createLaunch{value: 1 ether}(m, 0, relays, 0, 0);
    }

    function test_relay_revertsIfChainUnsupported() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, 8453, 5_000);
        a.pad.setRemoteQuote(8453, address(0), true);
        vm.chainId(CHAIN_A);
        Launchpad.RelaySpec[] memory relays = _relayed(1);
        vm.prank(creator);
        vm.expectRevert(Launchpad.RemoteChainUnsupported.selector);
        a.pad.createLaunch{value: 1 ether}(m, 0, relays, 0, 0);
    }

    function test_relay_onlyLaunchpadCanSend() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.expectRevert(LaunchRelay.NotLaunchpad.selector);
        relayA.sendLeg{value: 0.001 ether}(m, 1, _relayed(1)[0].options, creator);
    }

    function test_directLeg_creatorCanCreateRemoteLegThemselves() public {
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        uint256 fee = a.pad.creationFee();
        Launchpad.RelaySpec[] memory none = noRelays();
        vm.prank(creator);
        address tokenA = a.pad.createLaunch{value: fee}(m, 0, none, 0, 0);
        vm.chainId(CHAIN_B);
        vm.prank(creator);
        address tokenB = b.pad.createLaunch{value: fee}(m, 1, none, 0, 0);
        assertEq(LaunchToken(tokenA).launchId(), LaunchToken(tokenB).launchId());
        // a relayed duplicate is rejected
        vm.chainId(CHAIN_A);
        vm.prank(creator);
        vm.expectRevert(Launchpad.LegExists.selector);
        a.pad.createLaunch{value: fee}(m, 0, none, 0, 0);
    }

    function test_bridge_burnsAndMints() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));

        vm.chainId(CHAIN_A);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 bought = a.pad.buy{value: 1 ether}(tokenA, 1 ether, 0, alice, block.timestamp);
        uint256 half = bridgeA.removeDust(bought / 2); // bridged amounts are multiples of 1e9 wei

        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        MessagingFee memory fee = bridgeA.quoteSend(EID_B, tokenA, _b32(bob), bought / 2, opts);
        uint256 supplyA = LaunchToken(tokenA).totalSupply();
        vm.prank(alice);
        bridgeA.send{value: fee.nativeFee}(EID_B, tokenA, _b32(bob), bought / 2, opts);
        assertEq(LaunchToken(tokenA).balanceOf(alice), bought - half);
        assertEq(LaunchToken(tokenA).totalSupply(), supplyA - half, "burned on A");

        vm.chainId(CHAIN_B);
        uint256 supplyB = LaunchToken(tokenB).totalSupply();
        lz.deliverNext();
        assertEq(LaunchToken(tokenB).balanceOf(bob), half, "minted on B");
        assertEq(LaunchToken(tokenB).totalSupply(), supplyB + half);
        // global supply conserved
        assertEq(LaunchToken(tokenA).totalSupply() + LaunchToken(tokenB).totalSupply(), SUPPLY);

        // bridged tokens can be sold into B's curve only up to what B has sold: nothing yet
        vm.startPrank(bob);
        LaunchToken(tokenB).approve(address(b.pad), half);
        vm.expectRevert(Launchpad.InsufficientSold.selector);
        b.pad.sell(tokenB, half, 0, bob, block.timestamp);
        vm.stopPrank();

        // after someone buys on B, arbitrage sells are possible
        vm.prank(alice);
        uint256 boughtB = b.pad.buy{value: 1 ether}(tokenB, 1 ether, 0, alice, block.timestamp + 100);
        uint256 sellAmt = boughtB < half ? boughtB : half;
        vm.prank(bob);
        uint256 got = b.pad.sell(tokenB, sellAmt, 0, bob, block.timestamp + 100);
        assertGt(got, 0);
    }

    function test_bridge_rejectsForeignToken() public {
        vm.chainId(CHAIN_A);
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        vm.prank(alice);
        vm.expectRevert(TokenBridge.NotLaunchToken.selector);
        bridgeA.send{value: 0.001 ether}(EID_B, address(0xBEEF), _b32(bob), 1, opts);
    }

    function test_bridge_receiveRevertsUntilLegExists() public {
        // create only the A leg, bridge to B before B's leg exists: message must fail (stays retryable)
        LaunchTypes.Manifest memory m = twoLegManifest(creator, CHAIN_A, CHAIN_B, 5_000);
        vm.chainId(CHAIN_A);
        Launchpad.RelaySpec[] memory none = noRelays();
        uint256 fee = a.pad.creationFee();
        vm.prank(creator);
        address tokenA = a.pad.createLaunch{value: fee}(m, 0, none, 0, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 bought = a.pad.buy{value: 1 ether}(tokenA, 1 ether, 0, alice, block.timestamp);
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        vm.prank(alice);
        bridgeA.send{value: 0.001 ether}(EID_B, tokenA, _b32(bob), bought, opts);

        vm.chainId(CHAIN_B);
        vm.expectRevert(TokenBridge.NotLaunchToken.selector);
        lz.deliverNext();
    }

    function test_bridge_pausable() public {
        (, address tokenA) = _launchBoth(5_000);
        vm.chainId(CHAIN_A);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 bought = a.pad.buy{value: 1 ether}(tokenA, 1 ether, 0, alice, block.timestamp);
        bridgeA.pause();
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        vm.prank(alice);
        vm.expectRevert();
        bridgeA.send{value: 0.001 ether}(EID_B, tokenA, _b32(bob), bought, opts);
    }

    function test_token_onlyBridgeCanMint() public {
        (, address tokenA) = _launchBoth(5_000);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.NotBridge.selector);
        LaunchToken(tokenA).bridgeMint(alice, 1);
        vm.prank(owner);
        vm.expectRevert(LaunchToken.NotBridge.selector);
        LaunchToken(tokenA).bridgeMint(alice, 1);
        vm.expectRevert(LaunchToken.NotLaunchpad.selector);
        LaunchToken(tokenA).burnFromLaunchpad(1);
    }

    function test_bothLegsGraduateIndependently() public {
        (LaunchTypes.Manifest memory m, address tokenA) = _launchBoth(5_000);
        address tokenB = b.pad.tokenOf(a.pad.manifestHash(m));
        vm.warp(block.timestamp + 10);

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        a.pad.buy{value: 10 ether}(tokenA, 10 ether, 0, alice, block.timestamp);
        assertEq(uint8(a.pad.getCurve(tokenA).status), uint8(LaunchTypes.Status.Graduated));
        assertEq(uint8(b.pad.getCurve(tokenB).status), uint8(LaunchTypes.Status.Active));
        assertApproxEqRel(address(a.poolManager).balance, TARGET / 2, 1e9);

        vm.chainId(CHAIN_B);
        vm.prank(bob);
        b.pad.buy{value: 10 ether}(tokenB, 10 ether, 0, bob, block.timestamp);
        assertEq(uint8(b.pad.getCurve(tokenB).status), uint8(LaunchTypes.Status.Graduated));
        assertApproxEqRel(address(b.poolManager).balance, TARGET / 2, 1e9);
    }
}
