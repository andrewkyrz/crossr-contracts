// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Static registry of chain infrastructure used by the deploy scripts. Values come from the
///         official Uniswap v4 deployments page and the LayerZero metadata API (September 2026).
///         Environment variables POOL_MANAGER / LZ_ENDPOINT / LZ_EID override these at deploy time.
library Chains {
    struct Info {
        uint64 chainId;
        uint32 lzEid;
        address lzEndpoint;
        address poolManager;
        uint128 nativePhantom; // default curve phantom reserve for a full native-quote leg
        uint128 nativeTarget; // default graduation threshold for a full native-quote leg
    }

    function get(uint256 chainId) internal pure returns (Info memory) {
        // ── mainnets ──
        if (chainId == 4663) {
            // Robinhood Chain (gas: ETH)
            return Info(4663, 30416, 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B, 0x8366a39CC670B4001A1121B8F6A443A643e40951, 1.68 ether, 4.2 ether);
        }
        if (chainId == 56) {
            // BNB Chain (gas: BNB) — phantom/target sized to ≈ the ETH defaults in USD
            return Info(56, 30102, 0x1a44076050125825900e736c501f859c50fE728c, 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF, 6 ether, 15 ether);
        }
        if (chainId == 8453) {
            return Info(8453, 30184, 0x1a44076050125825900e736c501f859c50fE728c, 0x498581fF718922c3f8e6A244956aF099B2652b2b, 1.68 ether, 4.2 ether);
        }
        if (chainId == 42161) {
            return Info(42161, 30110, 0x1a44076050125825900e736c501f859c50fE728c, 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32, 1.68 ether, 4.2 ether);
        }
        if (chainId == 1) {
            return Info(1, 30101, 0x1a44076050125825900e736c501f859c50fE728c, 0x000000000004444c5dc75cB358380D2e3dE08A90, 1.68 ether, 4.2 ether);
        }
        if (chainId == 10) {
            return Info(10, 30111, 0x1a44076050125825900e736c501f859c50fE728c, 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3, 1.68 ether, 4.2 ether);
        }
        if (chainId == 137) {
            return Info(137, 30109, 0x1a44076050125825900e736c501f859c50fE728c, 0x67366782805870060151383F4BbFF9daB53e5cD6, 20_000 ether, 50_000 ether);
        }
        if (chainId == 43114) {
            return Info(43114, 30106, 0x1a44076050125825900e736c501f859c50fE728c, 0x06380C0e0912312B5150364B9DC4542BA0DbBc85, 200 ether, 500 ether);
        }
        if (chainId == 130) {
            return Info(130, 30320, 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B, 0x1F98400000000000000000000000000000000004, 1.68 ether, 4.2 ether);
        }
        // ── testnets ──
        if (chainId == 46630) {
            // Robinhood testnet: v4 PoolManager observed at the mainnet address
            return Info(46630, 40451, 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32, 0x8366a39CC670B4001A1121B8F6A443A643e40951, 0.0168 ether, 0.042 ether);
        }
        if (chainId == 11155111) {
            return Info(11155111, 40161, 0x6EDCE65403992e310A62460808c4b910D972f10f, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, 0.0168 ether, 0.042 ether);
        }
        if (chainId == 84532) {
            return Info(84532, 40245, 0x6EDCE65403992e310A62460808c4b910D972f10f, 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408, 0.0168 ether, 0.042 ether);
        }
        if (chainId == 421614) {
            return Info(421614, 40231, 0x6EDCE65403992e310A62460808c4b910D972f10f, 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317, 0.0168 ether, 0.042 ether);
        }
        if (chainId == 1301) {
            return Info(1301, 40333, 0xb8815f3f882614048CbE201a67eF9c6F10fe5035, 0x00B036B58a818B1BC34d502D3fE730Db729e62AC, 0.0168 ether, 0.042 ether);
        }
        if (chainId == 97) {
            // BSC testnet: LayerZero yes, no official Uniswap v4 — set POOL_MANAGER env to a self-deployed one
            return Info(97, 40102, 0x6EDCE65403992e310A62460808c4b910D972f10f, address(0), 0.06 ether, 0.15 ether);
        }
        return Info(uint64(chainId), 0, address(0), address(0), 1.68 ether, 4.2 ether);
    }
}
