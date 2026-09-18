// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStockToken} from "../test/mocks/MockStockToken.sol";

/// @notice Deploys the testnet mock stock token (MockStockToken) at the same CREATE2 address on every testnet and
///         mints a faucet balance to the deployer. Idempotent: re-running only mints.
/// env: DEPLOYER_PRIVATE_KEY, MOCK_NAME (default "Mock Tesla"), MOCK_SYMBOL (default "mTSLA"),
///      MOCK_MINT (whole tokens, default 1_000_000), MOCK_SALT (default keccak("crossr.mock-quote.v1"))
contract DeployMockQuote is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        require(block.chainid != 1 && block.chainid != 4663 && block.chainid != 56 && block.chainid != 8453, "testnets only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory name = vm.envOr("MOCK_NAME", string("Mock Tesla"));
        string memory symbol = vm.envOr("MOCK_SYMBOL", string("mTSLA"));
        uint256 amount = vm.envOr("MOCK_MINT", uint256(1_000_000)) * 1e18;
        bytes32 salt = vm.envOr("MOCK_SALT", keccak256("crossr.mock-quote.v1"));

        bytes memory initCode = abi.encodePacked(type(MockStockToken).creationCode, abi.encode(name, symbol));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);

        vm.startBroadcast(pk);
        if (predicted.code.length == 0) {
            MockStockToken t = new MockStockToken{salt: salt}(name, symbol);
            require(address(t) == predicted, "create2 address mismatch");
            console2.log("deployed", symbol, predicted);
        } else {
            console2.log("already deployed", symbol, predicted);
        }
        MockStockToken(predicted).mint(deployer, amount);
        vm.stopBroadcast();
        console2.log("minted", amount / 1e18, "to", deployer);
    }
}
