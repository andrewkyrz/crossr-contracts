// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchTypes} from "../src/interfaces/ILaunchpad.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Local demo traffic: launches a token, trades it, and (optionally) graduates it.
/// env: DEPLOYER_PRIVATE_KEY, GRADUATE=true|false, NAME, SYMBOL
contract Simulate is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        bool graduate = vm.envOr("GRADUATE", false);
        string memory local =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
        Launchpad pad = Launchpad(payable(local.readAddress(".launchpad")));

        LaunchTypes.Manifest memory m;
        m.creator = me;
        m.nonce = uint64(block.timestamp);
        m.creatorTaxBps = 100;
        m.name = vm.envOr("NAME", string("Robin Coin"));
        m.symbol = vm.envOr("SYMBOL", string("ROBIN"));
        m.metadataURI = vm.envOr("METADATA_URI", string(""));
        m.legs = new LaunchTypes.Leg[](1);
        m.legs[0] = LaunchTypes.Leg({chainId: uint64(block.chainid), quote: address(0), allocationBps: 10_000});
        Launchpad.RelaySpec[] memory relays = new Launchpad.RelaySpec[](0);

        vm.startBroadcast(pk);
        address token = pad.createLaunch{value: pad.creationFee() + 0.05 ether}(m, 0, relays, 0.05 ether, 0);
        console2.log("token", token);
        pad.buy{value: 0.2 ether}(token, 0.2 ether, 0, me, block.timestamp + 1 hours);
        pad.buy{value: 0.5 ether}(token, 0.5 ether, 0, me, block.timestamp + 1 hours);
        uint256 bal = LaunchToken(token).balanceOf(me);
        LaunchToken(token).approve(address(pad), bal / 4);
        pad.sell(token, bal / 4, 0, me, block.timestamp + 1 hours);
        if (graduate) {
            pad.buy{value: 6 ether}(token, 6 ether, 0, me, block.timestamp + 1 hours);
            // one post-graduation swap through the local test router so hook fees show up
            if (vm.keyExistsJson(local, ".swapRouter")) {
                PoolSwapTest router = PoolSwapTest(local.readAddress(".swapRouter"));
                LiquidityLocker locker = LiquidityLocker(payable(local.readAddress(".locker")));
                LiquidityLocker.Position memory p = locker.position(token);
                bool ethIs0 = Currency.unwrap(p.key.currency0) == address(0);
                router.swap{value: 0.1 ether}(
                    p.key,
                    SwapParams({zeroForOne: ethIs0, amountSpecified: -0.1 ether, sqrtPriceLimitX96: ethIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                );
            }
        }
        vm.stopBroadcast();
    }
}
