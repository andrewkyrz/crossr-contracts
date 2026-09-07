// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Create3Factory} from "../../src/Create3Factory.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {LiquidityLocker} from "../../src/LiquidityLocker.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {LaunchTypes} from "../../src/interfaces/ILaunchpad.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Deploys one full stack ("one chain"). Tests that simulate several chains deploy several stacks.
contract LaunchpadTestBase is Test {
    uint256 constant PHANTOM = 1.68 ether;
    uint256 constant TARGET = 4.2 ether;
    uint256 constant SUPPLY = 1_000_000_000e18;

    struct Stack {
        PoolManager poolManager;
        PoolSwapTest swapRouter;
        FeeEscrow escrow;
        LiquidityLocker locker;
        LaunchHook hook;
        Create3Factory factory;
        Launchpad pad;
    }

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 hookSeed;

    function deployStack() internal returns (Stack memory s) {
        s.poolManager = new PoolManager(owner);
        s.swapRouter = new PoolSwapTest(IPoolManager(address(s.poolManager)));
        s.escrow = new FeeEscrow(owner);
        s.locker = new LiquidityLocker(IPoolManager(address(s.poolManager)), owner, treasury);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address hookAddr = address(uint160((uint160(0x4444 + hookSeed++) << 144) | flags));
        deployCodeTo(
            "LaunchHook.sol:LaunchHook",
            abi.encode(IPoolManager(address(s.poolManager)), address(s.locker), s.escrow, owner, treasury),
            hookAddr
        );
        s.hook = LaunchHook(payable(hookAddr));
        s.locker.setHook(IHooks(hookAddr));

        s.factory = new Create3Factory(owner);
        s.pad = new Launchpad(s.factory, owner, treasury);
        s.factory.setDeployer(address(s.pad), true);
        s.locker.setLaunchpad(address(s.pad));
        s.escrow.setCreditor(address(s.pad), true);
        s.escrow.setCreditor(address(s.hook), true);
        s.escrow.setCreditor(address(s.locker), true);
        s.pad.setModules(address(0), address(0), address(s.locker), address(s.escrow), treasury);
        s.pad.setQuoteConfig(address(0), true, uint128(PHANTOM), uint128(TARGET));
    }

    function singleLegManifest(address creator_, uint64 chainId, address quote, uint16 taxBps)
        internal
        pure
        returns (LaunchTypes.Manifest memory m)
    {
        m.creator = creator_;
        m.nonce = 1;
        m.creatorTaxBps = taxBps;
        m.name = "Crossr Test";
        m.symbol = "PRNT";
        m.metadataURI = "ipfs://meta";
        m.legs = new LaunchTypes.Leg[](1);
        m.legs[0] = LaunchTypes.Leg({chainId: chainId, quote: quote, allocationBps: 10_000});
    }

    function twoLegManifest(address creator_, uint64 chainA, uint64 chainB, uint16 bpsA)
        internal
        pure
        returns (LaunchTypes.Manifest memory m)
    {
        m = singleLegManifest(creator_, chainA, address(0), 0);
        m.legs = new LaunchTypes.Leg[](2);
        m.legs[0] = LaunchTypes.Leg({chainId: chainA, quote: address(0), allocationBps: bpsA});
        m.legs[1] = LaunchTypes.Leg({chainId: chainB, quote: address(0), allocationBps: 10_000 - bpsA});
    }

    function noRelays() internal pure returns (Launchpad.RelaySpec[] memory r) {
        r = new Launchpad.RelaySpec[](0);
    }

    function createNative(Stack memory s, LaunchTypes.Manifest memory m, uint256 devBuy) internal returns (address) {
        uint256 fee = s.pad.creationFee();
        vm.deal(m.creator, m.creator.balance + fee + devBuy);
        Launchpad.RelaySpec[] memory relays = noRelays();
        vm.prank(m.creator);
        return s.pad.createLaunch{value: fee + devBuy}(m, 0, relays, devBuy, 0);
    }
}
