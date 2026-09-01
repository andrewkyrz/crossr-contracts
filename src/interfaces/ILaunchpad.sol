// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared launch types. A launch is described by a Manifest that is identical on every
///         chain; its hash is the launch id and the CREATE3 salt of the token.
library LaunchTypes {
    struct Leg {
        uint64 chainId; // chain where this leg's bonding curve lives
        address quote; // quote asset on that chain, address(0) = native coin
        uint16 allocationBps; // share of TOTAL_SUPPLY minted on that chain (sum over legs = 10_000)
    }

    struct Manifest {
        address creator;
        uint64 nonce; // creator-chosen, lets the same creator relaunch identical metadata
        uint16 creatorTaxBps; // 0..1000, 100% to the creator on curve trades and post-graduation swaps
        string name;
        string symbol;
        string metadataURI;
        address[] snipeExempt; // wallets exempt from the launch snipe tax (creator is always exempt)
        Leg[] legs;
    }

    enum Status {
        None,
        Active,
        PendingGraduation,
        Graduated
    }

    struct Curve {
        address quote;
        address creator;
        bytes32 launchId;
        uint8 legIndex;
        Status status;
        uint16 creatorTaxBps;
        uint16 snipeTaxStartBps;
        uint32 snipeTaxSeconds;
        uint64 createdAt;
        uint128 phantomQuote;
        uint128 realQuote; // quote held for LP (fees excluded)
        uint128 supply; // leg supply; all of it starts in the curve
        uint128 reserved; // tokens that stay in the curve at graduation
        uint128 tokensSold;
        uint128 target;
    }

    function hash(Manifest memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }
}

interface ILaunchpad {
    function bridge() external view returns (address);
    function isLaunchToken(address token) external view returns (bool);
    function tokenOf(bytes32 launchId) external view returns (address);
    function createLegFromRelay(LaunchTypes.Manifest calldata manifest, uint8 legIndex) external;
}
