# crossr contracts

Launch a token once and trade it on every chain. Each chain runs its own Pons-style bonding curve in its own coin
(ETH on Robinhood Chain, BNB or a BEP-20 on BNB Chain, ...), the token has the same address everywhere and bridges
between chains, and every curve graduates into a permanently locked Uniswap v4 pool.

```
src/Launchpad.sol          per-chain curve legs, fees, graduation
src/LaunchToken.sol        ERC20 + Permit, mint/burn gated to launchpad and bridge
src/Create3Factory.sol     same token address on every chain (CREATE3 keyed by manifest hash)
src/LiquidityLocker.sol    owns graduated v4 positions forever, collects fees only
src/LaunchHook.sol         v4 hook: gated pool init, afterSwap fee + creator tax
src/FeeEscrow.sol          claim-based fee accounting
src/bridge/TokenBridge.sol LayerZero V2 OApp: burn on source, mint on destination
src/bridge/LaunchRelay.sol LayerZero V2 OApp: replicate a launch to peer chains
script/                    Deploy, DeployLocal, Wire, SetQuote, Simulate, Chains registry
test/                      unit / fuzz / cross-chain tests against a real v4 PoolManager
```

## Documentation

- [docs/architecture.md](docs/architecture.md) — contract map, manifest, launch / trade / bridge flows, fees, trust model
- [docs/testing.md](docs/testing.md) — test layout, the two cross-chain suites, conventions
- [docs/local-development.md](docs/local-development.md) — anvil stack, `Simulate.s.sol`, common problems
- [docs/glossary.md](docs/glossary.md) — curve and LayerZero terms
- [CONTRIBUTING.md](CONTRIBUTING.md) — workflow, commit style, PR checklist, security disclosure

## How it works

**Manifest.** A launch is a `Manifest` — creator, nonce, name, symbol, metadata URI, creator tax, snipe-exempt
wallets and a list of *legs* `{chainId, quote, allocationBps}` (allocations sum to 100%). `keccak256(abi.encode(manifest))`
is the launch id and the CREATE3 salt, so the token gets the same address on every chain and every chain can verify it
is creating the same launch.

**Curve (per leg) — Pons V2 parity.** Constant product with a phantom quote reserve: `k = phantom × legSupply`.
Defaults for ETH legs: phantom 1.68 ETH, graduation 4.2 ETH ⇒ 5/7 of the leg supply is sold on the curve, 2/7 stays
reserved. Fees: 1% of the quote side both ways (30% protocol / 70% creator) plus an optional 0–10% creator tax (100% to
creator). Snipe tax on buys in the first seconds (99% → 0 with 14 halvings over 3 s; creator + listed wallets exempt).
Buys that cross the threshold are partially filled and refunded. Config per quote asset is scaled by the leg allocation
so every leg opens at the same token price.

**Graduation.** Triggered on the token side (sellable supply exhausted), inside the crossing buy with `try/catch`; anyone
can call `graduate()` afterwards. All raised quote + `quote × reserved / (phantom + raised)` tokens (10/49 of supply for
the default ratio) go into a full-range Uniswap v4 pool at the curve's terminal price; the rest of the reserve is burned.
The position is owned by `LiquidityLocker`, which can only collect fees. The pool key uses `LaunchHook`:
`beforeInitialize` is gated to the locker (no pool squatting) and `afterSwap` takes a 1% fee (+ creator tax) on the
unspecified currency into `FeeEscrow`.

**Cross-chain.** `createLaunch` on the home chain creates the local leg and, for each `RelaySpec`, sends the manifest
through `LaunchRelay` (LayerZero V2 OApp) to the peer chain, whose `Launchpad.createLegFromRelay` deploys the token at
the same address and opens that leg. Legs can also be created directly on a chain by the creator with the same manifest.
`TokenBridge` (one shared OApp per chain) burns on the source and mints on the destination; messages carry the launch
id. Bridged tokens can be sold into the destination curve only up to what that curve has sold, so no curve can be drained
below its own deposits; arbitrage keeps legs priced together.

**Fees.** Everything is claim-based from `FeeEscrow` (launch fees, curve fees, creator tax, hook fees, LP fees if a pool
fee is configured).

## Develop

```sh
git submodule update --init
bun install
forge test          # 55 unit / fuzz / cross-chain tests against a real v4 PoolManager
#   CrossChain.t.sol   — two chains through a minimal mock endpoint (fast, business logic)
#   CrossChainLz.t.sol — same flows through LayerZero's TestHelperOz5 (real EndpointV2 + ULN302 + DVN + executor)

# local stack
anvil &
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # writes deployments/31337.json
DEPLOYER_PRIVATE_KEY=0xac09…ff80 GRADUATE=true forge script script/Simulate.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Foundry note: via-IR rematerializes `block.timestamp` across `vm.warp`, so tests use literal timestamps.

## Deploy

`script/Chains.sol` carries the Uniswap v4 PoolManager, LayerZero endpoint/EID and default curve parameters for
Robinhood Chain (4663), BNB (56), Base, Arbitrum, Ethereum, Optimism, Polygon, Avalanche, Unichain and their testnets.
Copy `.env.example` to `.env` and fill in keys and RPC URLs.

```sh
set -a && source .env && set +a
# 1. deploy on every chain (same DEPLOYER key + CREATE3_SALT on all chains ⇒ same Create3Factory address)
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api
forge script script/Deploy.s.sol --rpc-url bsc --broadcast --verify --etherscan-api-key $BSCSCAN_KEY
# 2. wire LayerZero peers + enforced options + remote quote allow-lists (run on every chain)
PEER_CHAIN_IDS=56      forge script script/Wire.s.sol --rpc-url robinhood --broadcast
PEER_CHAIN_IDS=4663    forge script script/Wire.s.sol --rpc-url bsc --broadcast
# 3. optional: enable an ERC20 quote (e.g. CAKE on BNB; PHANTOM/TARGET in raw token units)
QUOTE=0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82 PHANTOM=4000000000000000000000 TARGET=10000000000000000000000 \
  forge script script/SetQuote.s.sol --rpc-url bsc --broadcast
# also allow it as a remote quote from the home chain: PEER_QUOTES_56=0x0E09… in step 2
```

If `OWNER` differs from the deployer, the scripts call `transferOwnership`; the owner must `acceptOwnership()` on every
contract (Ownable2Step).

## Mainnet checklist

- [ ] Independent audit of `src` (curve accounting, hook delta handling, bridge mint authority).
- [ ] `OWNER` = multisig behind a timelock on every chain; accept ownership on all contracts.
- [ ] LayerZero: after `Wire.s.sol`, set explicit DVN configs (2-of-2, e.g. LayerZero Labs + Nethermind) with
      `endpoint.setConfig` for both `TokenBridge` and `LaunchRelay`; the default config is a single DVN.
- [ ] Verify sources on Blockscout / BscScan; publish the hook address (its low 14 bits encode its permissions).
- [ ] Set per-chain quote configs so every leg opens at roughly the same USD price (BNB defaults in `Chains.sol` assume
      ~$600/BNB vs ~$2.5k/ETH — adjust to market before launch).
- [ ] Decide ERC20 quotes (e.g. CAKE on BNB) and enable them with `SetQuote.s.sol` + `PEER_QUOTES_<id>`.
