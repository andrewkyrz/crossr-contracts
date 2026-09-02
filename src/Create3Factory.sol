// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {LaunchToken} from "./LaunchToken.sol";

/// @title Create3Factory
/// @notice Deploys launch tokens at addresses that depend only on (this factory, salt), so a launch
///         token lands at the same address on every chain where this factory has the same address.
/// @dev Deployment is restricted to authorized callers (the Launchpad) so nobody can squat a launch
///      address on a chain before the launch reaches it. Holding the token creation code here also
///      keeps the Launchpad under the EIP-170 size limit.
contract Create3Factory is Ownable2Step {
    error NotAuthorized();

    event DeployerSet(address indexed deployer, bool allowed);
    event Deployed(bytes32 indexed salt, address indexed addr);

    mapping(address => bool) public isDeployer;

    constructor(address owner_) Ownable(owner_) {}

    function setDeployer(address deployer, bool allowed) external onlyOwner {
        isDeployer[deployer] = allowed;
        emit DeployerSet(deployer, allowed);
    }

    function deployLaunchToken(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 initialSupply
    ) external returns (address addr) {
        if (!isDeployer[msg.sender]) revert NotAuthorized();
        bytes memory initCode = abi.encodePacked(
            type(LaunchToken).creationCode, abi.encode(name, symbol, metadataURI, salt, msg.sender, initialSupply)
        );
        addr = CREATE3.deployDeterministic(initCode, salt);
        emit Deployed(salt, addr);
    }

    function predict(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }
}
