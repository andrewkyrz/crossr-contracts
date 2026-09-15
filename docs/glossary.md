# Glossary

**Allocation (bps)** — Share of the total token supply assigned to one leg, in basis points. All legs in a manifest sum
to 10 000.

**Creator tax** — Optional 0–10% fee on the quote side of every curve trade and post-graduation swap, paid entirely to
the creator. Set once in the manifest.

**CREATE3** — Deployment pattern that makes the contract address depend only on the deployer and the salt, not on the
init code. `Create3Factory` uses the manifest hash as salt so `LaunchToken` lands at the same address on every chain.

**Curve fee** — Fixed 1% on the quote side of every buy and sell on a leg. Split 30% protocol / 70% creator.

**DVN** — LayerZero Decentralised Verifier Network. Verifies cross-chain messages. Production should use a 2-of-2
configuration set with `endpoint.setConfig`; the default after `Wire.s.sol` is a single DVN.

**EID** — LayerZero endpoint id. Distinct from the EVM chain id; `script/Chains.sol` maps between them.

**Graduation** — The moment a leg's sellable supply is exhausted. Raised quote and the matching share of reserved
tokens move into a full-range Uniswap v4 pool owned by `LiquidityLocker`; the remaining reserve is burned.

**Home chain** — The chain where `createLaunch` is called. Legs on other chains are opened by relay or directly by the
creator with the same manifest.

**Launch id** — `keccak256(abi.encode(manifest))`. Identifies a launch on every chain and is the CREATE3 salt.

**Leg** — One chain's bonding curve for a launch: `{chainId, quote, allocationBps}` plus the on-chain state it accrues.

**Manifest** — The immutable description of a launch: creator, nonce, name, symbol, metadata URI, creator tax,
snipe-exempt wallets and legs. See `LaunchTypes` in `src/interfaces/ILaunchpad.sol`.

**OApp** — LayerZero V2 Omnichain Application. `TokenBridge` and `LaunchRelay` are both OApps.

**Phantom reserve** — Virtual quote balance added to the curve so the first buy has a finite price:
`k = phantom × legSupply`. Default 1.68 ETH for ETH legs.

**Pons parity** — The curve constants match Pons V2: phantom 1.68, target 4.2, so 5/7 of a leg's supply sells on the
curve and 2/7 is reserved for the pool.

**Quote** — The asset a leg is priced in: native coin (ETH, BNB) or an owner-enabled ERC20 (e.g. CAKE on BNB).
Configured per chain with `SetQuote.s.sol`.

**Relay** — Sending a manifest from the home chain to a peer chain through `LaunchRelay` so the peer opens its leg.

**Reserved supply** — The part of a leg's allocation not sold on the curve (2/7 by default). Partly paired into the v4
pool at graduation, remainder burned.

**Snipe tax** — Extra buy-side tax in the first ~3 s of a leg, starting at 99% and halving 14 times to zero. Creator
and manifest-listed wallets are exempt.

**Stack** — One chain's full deployment: PoolManager, FeeEscrow, LiquidityLocker, LaunchHook, Create3Factory,
Launchpad (+ bridge and relay). `LaunchpadTestBase` deploys one stack per simulated chain.

**Target** — Quote amount at which a leg graduates. Default 4.2 ETH for ETH legs, scaled by allocation.

**Unspecified currency** — In a Uniswap v4 swap, the side the trader did not fix. `LaunchHook.afterSwap` takes its
fee from this side.
