// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice LayerZero V2 message libraries and DVN workers per chain, from the LayerZero metadata API
///         (https://metadata.layerzero-api.com/v1/metadata, fetched 2026-09-18). Used by SetDvn.s.sol to pin an
///         explicit 2-of-2 security stack (LayerZero Labs + Nethermind) instead of the single-DVN default.
///         Env vars SEND_LIB / RECEIVE_LIB / DVNS override these at run time.
library LzConfig {
    struct Libs {
        address sendUln302;
        address receiveUln302;
        address dvnLayerZeroLabs;
        address dvnNethermind;
    }

    function get(uint256 chainId) internal pure returns (Libs memory) {
        // ── mainnets ──
        if (chainId == 4663) {
            // Robinhood Chain (eid 30416)
            return Libs(
                0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7,
                0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043,
                0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12,
                0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8
            );
        }
        if (chainId == 8453) {
            // Base (eid 30184)
            return Libs(
                0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2,
                0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf,
                0x9e059a54699a285714207b43B055483E78FAac25,
                0xcd37CA043f8479064e10635020c65FfC005d36f6
            );
        }
        if (chainId == 42161) {
            // Arbitrum One (eid 30110)
            return Libs(
                0x975bcD720be66659e3EB3C0e4F1866a3020E493A,
                0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6,
                0x2f55C492897526677C5B68fb199ea31E2c126416,
                0xa7b5189bcA84Cd304D8553977c7C614329750d99
            );
        }
        if (chainId == 10) {
            // Optimism (eid 30111)
            return Libs(
                0x1322871e4ab09Bc7f5717189434f97bBD9546e95,
                0x3c4962Ff6258dcfCafD23a814237B7d6Eb712063,
                0x6A02D83e8d433304bba74EF1c427913958187142,
                0xa7b5189bcA84Cd304D8553977c7C614329750d99
            );
        }
        if (chainId == 56) {
            // BNB Chain (eid 30102)
            return Libs(
                0x9F8C645f2D0b2159767Bd6E0839DE4BE49e823DE,
                0xB217266c3A98C8B2709Ee26836C98cf12f6cCEC1,
                0xfD6865c841c2d64565562fCc7e05e619A30615f0,
                0x31F748a368a893Bdb5aBB67ec95F232507601A73
            );
        }
        if (chainId == 1) {
            // Ethereum (eid 30101)
            return Libs(
                0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1,
                0xc02Ab410f0734EFa3F14628780e6e695156024C2,
                0x589dEDbD617e0CBcB916A9223F4d1300c294236b,
                0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5
            );
        }
        // ── testnets (rehearse the mainnet procedure here first) ──
        if (chainId == 46630) {
            // Robinhood Chain testnet (eid 40451)
            return Libs(
                0x45841dd1ca50265Da7614fC43A361e526c0e6160,
                0xd682ECF100f6F4284138AA925348633B0611Ae21,
                0xa78A78a13074eD93aD447a26Ec57121f29E8feC2,
                0xcDE82F74624525e24853B1f59c8B20A162A3d297
            );
        }
        if (chainId == 84532) {
            // Base Sepolia (eid 40245)
            return Libs(
                0xC1868e054425D378095A003EcbA3823a5D0135C9,
                0x12523de19dc41c91F7d2093E0CFbB76b17012C8d,
                0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6,
                0xd9222CC3Ccd1DF7c070d700EA377D4aDA2B86Eb5
            );
        }
        if (chainId == 421614) {
            // Arbitrum Sepolia (eid 40231)
            return Libs(
                0x4f7cd4DA19ABB31b0eC98b9066B9e857B1bf9C0E,
                0x75Db67CDab2824970131D5aa9CECfC9F69c69636,
                0x53f488E93b4f1b60E8E83aa374dBe1780A1EE8a8,
                0x3a74F7174709842d3b8a14ce60B4AA2499F2A2F2
            );
        }
        if (chainId == 11155420) {
            // OP Sepolia (eid 40232)
            return Libs(
                0xB31D2cb502E25B30C651842C7C3293c51Fe6d16f,
                0x9284fd59B95b9143AF0b9795CAC16eb3C723C9Ca,
                0xd680ec569f269aa7015F7979b4f1239b5aa4582C,
                0x2d15d4e61558480A9300632772E68d8b5e7Cc7e5
            );
        }
        if (chainId == 11155111) {
            // Sepolia (eid 40161)
            return Libs(
                0xcc1ae8Cf5D3904Cef3360A9532B477529b177cCE,
                0xdAf00F5eE2158dD58E0d3857851c432E34A3A851,
                0x8eebf8b423B73bFCa51a1Db4B7354AA0bFCA9193,
                0x68802e01D6321D5159208478f297d7007A7516Ed
            );
        }
        return Libs(address(0), address(0), address(0), address(0));
    }
}
