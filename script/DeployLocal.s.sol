// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Create3Factory} from "../src/Create3Factory.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";
import {ILaunchpad} from "../src/interfaces/ILaunchpad.sol";
import {MockLzEndpoint} from "../test/mocks/MockLzEndpoint.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Local anvil deployment: a fresh PoolManager, a mock LayerZero endpoint, a mock USD quote,
///         and the full stack. Writes deployments/31337.json.
contract DeployLocal is Script {
    using stdJson for string;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        PoolManager poolManager = new PoolManager(deployer);
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockLzEndpoint lz = new MockLzEndpoint();
        MockERC20 usd = new MockERC20("Mock USD", "mUSD", 6);
        usd.mint(deployer, 1_000_000e6);

        Create3Factory factory = new Create3Factory{salt: keccak256("crossr.local")}(deployer);
        FeeEscrow escrow = new FeeEscrow(deployer);
        LiquidityLocker locker = new LiquidityLocker(IPoolManager(address(poolManager)), deployer, deployer);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookArgs =
            abi.encode(IPoolManager(address(poolManager)), address(locker), escrow, deployer, deployer);
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(LaunchHook).creationCode, hookArgs);
        LaunchHook hook = new LaunchHook{salt: hookSalt}(
            IPoolManager(address(poolManager)), address(locker), escrow, deployer, deployer
        );
        require(address(hook) == hookAddr, "hook mismatch");

        Launchpad pad = new Launchpad(factory, deployer, deployer);
        TokenBridge bridge = new TokenBridge(address(lz), deployer, ILaunchpad(address(pad)));
        LaunchRelay relay = new LaunchRelay(address(lz), deployer);
        relay.setLaunchpad(ILaunchpad(address(pad)));
        lz.setEid(address(bridge), 31337);
        lz.setEid(address(relay), 31337);

        factory.setDeployer(address(pad), true);
        locker.setHook(IHooks(hookAddr));
        locker.setLaunchpad(address(pad));
        escrow.setCreditor(address(pad), true);
        escrow.setCreditor(hookAddr, true);
        escrow.setCreditor(address(locker), true);
        pad.setModules(address(bridge), address(relay), address(locker), address(escrow), deployer);
        pad.setQuoteConfig(address(0), true, 1.68 ether, 4.2 ether);
        pad.setQuoteConfig(address(usd), true, 3_236e6, 8_090e6);
        pad.setSnipeTax(9_900, 3);
        vm.stopBroadcast();

        string memory j = "d";
        j.serialize("chainId", block.chainid);
        j.serialize("lzEid", uint256(31337));
        j.serialize("block", block.number);
        j.serialize("factory", address(factory));
        j.serialize("escrow", address(escrow));
        j.serialize("locker", address(locker));
        j.serialize("hook", hookAddr);
        j.serialize("launchpad", address(pad));
        j.serialize("bridge", address(bridge));
        j.serialize("relay", address(relay));
        j.serialize("poolManager", address(poolManager));
        j.serialize("swapRouter", address(swapRouter));
        j.serialize("mockUsd", address(usd));
        string memory out = j.serialize("lzEndpoint", address(lz));
        vm.writeJson(out, string.concat(vm.projectRoot(), "/deployments/31337.json"));
        console2.log("launchpad", address(pad));
    }
}
