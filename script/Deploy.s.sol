// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Chains} from "./Chains.sol";
import {Create3Factory} from "../src/Create3Factory.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";
import {ILaunchpad} from "../src/interfaces/ILaunchpad.sol";

/// @notice Deploys the full stack on the current chain and writes deployments/<chainId>.json.
///
/// env:
///   DEPLOYER_PRIVATE_KEY  required
///   OWNER                 optional, defaults to deployer (use a multisig on mainnet)
///   TREASURY              optional, defaults to owner
///   POOL_MANAGER          optional override of Chains.sol
///   LZ_ENDPOINT / LZ_EID  optional override of Chains.sol; endpoint 0 skips bridge + relay
///   NATIVE_PHANTOM / NATIVE_TARGET  optional override (wei) of the native quote curve config
///   CREATE3_SALT          optional, defaults to keccak("crossr.create3.v1"); keep identical on every chain
contract Deploy is Script {
    using stdJson for string;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", owner);

        Chains.Info memory info = Chains.get(block.chainid);
        address poolManager = vm.envOr("POOL_MANAGER", info.poolManager);
        address lzEndpoint = vm.envOr("LZ_ENDPOINT", info.lzEndpoint);
        uint32 lzEid = uint32(vm.envOr("LZ_EID", uint256(info.lzEid)));
        uint128 phantom = uint128(vm.envOr("NATIVE_PHANTOM", uint256(info.nativePhantom)));
        uint128 target = uint128(vm.envOr("NATIVE_TARGET", uint256(info.nativeTarget)));
        bytes32 create3Salt = vm.envOr("CREATE3_SALT", keccak256("crossr.create3.v1"));
        require(poolManager != address(0), "POOL_MANAGER required on this chain");

        console2.log("chain", block.chainid);
        console2.log("deployer", deployer);
        console2.log("owner", owner);
        console2.log("poolManager", poolManager);
        console2.log("lzEndpoint", lzEndpoint);

        vm.startBroadcast(pk);

        // 1. CREATE3 factory at a chain-independent address (CREATE2 through the canonical deployer;
        //    init code must be identical on every chain, so OWNER must match too).
        Create3Factory factory = new Create3Factory{salt: create3Salt}(deployer);

        // 2. Fee escrow + locker
        FeeEscrow escrow = new FeeEscrow(deployer);
        LiquidityLocker locker = new LiquidityLocker(IPoolManager(poolManager), deployer, treasury);

        // 3. Hook at a mined address
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookArgs = abi.encode(IPoolManager(poolManager), address(locker), escrow, deployer, treasury);
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(LaunchHook).creationCode, hookArgs);
        LaunchHook hook =
            new LaunchHook{salt: hookSalt}(IPoolManager(poolManager), address(locker), escrow, deployer, treasury);
        require(address(hook) == hookAddr, "hook address mismatch");

        // 4. Launchpad
        Launchpad pad = new Launchpad(factory, deployer, treasury);

        // 5. Cross-chain modules (optional)
        address bridge;
        address relay;
        if (lzEndpoint != address(0)) {
            bridge = address(new TokenBridge(lzEndpoint, deployer, ILaunchpad(address(pad))));
            LaunchRelay r = new LaunchRelay(lzEndpoint, deployer);
            r.setLaunchpad(ILaunchpad(address(pad)));
            relay = address(r);
        }

        // 6. Wiring
        factory.setDeployer(address(pad), true);
        locker.setHook(IHooks(hookAddr));
        locker.setLaunchpad(address(pad));
        escrow.setCreditor(address(pad), true);
        escrow.setCreditor(hookAddr, true);
        escrow.setCreditor(address(locker), true);
        pad.setModules(bridge, relay, address(locker), address(escrow), treasury);
        pad.setQuoteConfig(address(0), true, phantom, target);

        // 7. Hand over ownership (two-step: the new owner must call acceptOwnership on each contract)
        if (owner != deployer) {
            factory.transferOwnership(owner);
            escrow.transferOwnership(owner);
            locker.transferOwnership(owner);
            hook.transferOwnership(owner);
            pad.transferOwnership(owner);
            if (bridge != address(0)) TokenBridge(bridge).transferOwnership(owner);
            if (relay != address(0)) LaunchRelay(relay).transferOwnership(owner);
        }
        vm.stopBroadcast();

        _write(block.chainid, lzEid, address(factory), address(escrow), address(locker), hookAddr, address(pad), bridge, relay, poolManager, lzEndpoint);
    }

    function _write(
        uint256 chainId,
        uint32 lzEid,
        address factory,
        address escrow,
        address locker,
        address hook,
        address pad,
        address bridge,
        address relay,
        address poolManager,
        address lzEndpoint
    ) internal {
        string memory j = "deployment";
        j.serialize("chainId", chainId);
        j.serialize("lzEid", uint256(lzEid));
        j.serialize("block", _l2BlockNumber());
        j.serialize("factory", factory);
        j.serialize("escrow", escrow);
        j.serialize("locker", locker);
        j.serialize("hook", hook);
        j.serialize("launchpad", pad);
        j.serialize("bridge", bridge);
        j.serialize("relay", relay);
        j.serialize("poolManager", poolManager);
        string memory out = j.serialize("lzEndpoint", lzEndpoint);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json");
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }

    /// Arbitrum-family chains (Arbitrum, Orbit chains such as Robinhood Chain) return the parent chain's height from
    /// `block.number`; the indexer needs the chain's own height, which the ArbSys precompile reports.
    function _l2BlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x64).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && data.length == 32) return abi.decode(data, (uint256));
        return block.number;
    }
}
