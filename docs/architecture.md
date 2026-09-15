# Architecture

crossr launches one token across many chains. Each chain runs its own bonding-curve *leg* denominated in that chain's
quote asset, the token has the same address on every chain, and every leg graduates into a permanently locked
Uniswap v4 pool. This page maps the contracts and the three flows that matter: launch, trade/graduate, bridge.

## Contract map

```
                         ┌──────────────────────┐
   creator ─ createLaunch ─▶│      Launchpad       │◀── createLegFromRelay ── LaunchRelay (LZ OApp)
                         │  legs, fees, curve   │
                         └───┬──────────┬───────┘
                             │          │ graduate()
                  deploy via │          ▼
                  CREATE3    │   ┌──────────────────┐   beforeInitialize / afterSwap
                             │   │ LiquidityLocker  │◀───────────────── LaunchHook (v4 hook)
                             ▼   │  owns v4 position│                        │
                   ┌─────────────┐└──────────────────┘                        │ fees
                   │ LaunchToken │                                            ▼
                   │ ERC20+Permit│◀── mint/burn ── TokenBridge (LZ OApp)  ┌───────────┐
                   └─────────────┘                                        │ FeeEscrow │
                                                                          └───────────┘
```

| Contract | Role | Owner-gated? |
| --- | --- | --- |
| `src/Launchpad.sol` | Per-chain curve legs: create, buy, sell, graduate. Holds raised quote until graduation. | Yes (`Ownable2Step`): quote configs, relay/bridge addresses, protocol fee |
| `src/LaunchToken.sol` | ERC20 + Permit. `mint`/`burn` callable only by the launchpad and the bridge. | No |
| `src/Create3Factory.sol` | Deploys `LaunchToken` at a chain-agnostic address; salt = manifest hash. | No |
| `src/LiquidityLocker.sol` | Owns every graduated v4 position forever. Can only collect fees. | Yes: fee sweep destination |
| `src/LaunchHook.sol` | Uniswap v4 hook. `beforeInitialize` gated to the locker; `afterSwap` takes 1% + creator tax. | No |
| `src/FeeEscrow.sol` | Claim-based accounting for every fee stream (launch, curve, creator tax, hook, LP). | No |
| `src/bridge/TokenBridge.sol` | LayerZero V2 OApp. Burn on source, mint on destination. One per chain, shared by all launches. | Yes: peers, enforced options |
| `src/bridge/LaunchRelay.sol` | LayerZero V2 OApp. Sends a manifest to peer chains so they open the same launch. | Yes: peers, enforced options |
| `src/libraries/CurveMath.sol` | Pure constant-product maths with a phantom quote reserve. | — |
| `src/interfaces/*` | External interfaces and `LaunchTypes` (Manifest, Leg, RelaySpec). | — |

## The manifest

```solidity
struct Manifest {
    address creator;
    uint256 nonce;
    string  name;
    string  symbol;
    string  metadataURI;
    uint16  creatorTaxBps;      // 0–1000
    address[] snipeExempt;      // wallets exempt from the snipe tax
    Leg[]   legs;               // {chainId, quote, allocationBps}; allocations sum to 10_000
}
```

`launchId = keccak256(abi.encode(manifest))`. It is the CREATE3 salt, the key for every mapping in `Launchpad`, and
the identifier carried in every LayerZero message. Because every chain recomputes it from the same bytes, a peer chain
can verify it is opening *the same* launch and will deploy the token at *the same* address.

## Flow 1 — launch

1. Creator calls `Launchpad.createLaunch(manifest, relaySpecs)` on the home chain, paying the launch fee (and LayerZero
   messaging fees for each relay).
2. The launchpad validates the manifest (creator == sender, this chain is one of the legs, allocations sum to 100%, quote
   enabled, no duplicate legs), deploys the `LaunchToken` through `Create3Factory`, and opens the local leg with the
   quote config scaled by that leg's allocation so every leg opens at the same token price.
3. For each `RelaySpec`, `LaunchRelay` sends the manifest to the peer chain. The peer's `LaunchRelay._lzReceive` calls
   `Launchpad.createLegFromRelay`, which repeats step 2 for its own leg. The creator can alternatively call
   `createLeg` directly on the peer chain with the same manifest.

## Flow 2 — trade and graduate

Each leg is a constant-product curve with a phantom reserve: `k = phantom × legSupply`. Defaults for ETH legs are
phantom 1.68 ETH and graduation target 4.2 ETH, so 5/7 of the leg supply is sold on the curve and 2/7 is reserved.

- **Buy**: 1% fee on the quote side (30% protocol / 70% creator) plus optional creator tax, plus a snipe tax in the
  first seconds (99% decaying to 0 over 14 halvings in 3 s; creator and `snipeExempt` wallets skip it). Buys that
  cross the sellable supply are partially filled and the excess quote is refunded.
- **Sell**: same 1% fee and creator tax; tokens are burned, quote is returned from the leg's reserve.
- **Graduation**: triggers when sellable supply is exhausted, inside the crossing buy via `try/catch`; anyone can call
  `graduate()` afterwards if that failed. All raised quote plus `quote × reserved / (phantom + raised)` tokens go into
  a full-range v4 pool at the curve's terminal price. The rest of the reserve is burned. The position is minted to
  `LiquidityLocker`, and `LaunchHook.beforeInitialize` refuses any pool for that token that is not initialised by the
  locker, so nobody can front-run the pool.
- **Post-graduation**: `LaunchHook.afterSwap` takes 1% (+ creator tax) of the unspecified currency into `FeeEscrow`.

## Flow 3 — bridge

`TokenBridge.send(launchId, dstEid, to, amount)` burns on the source chain and mints on the destination through
`LaunchToken.mint`, which trusts only the launchpad and the bridge. Messages carry the launch id, so the destination
resolves the same token address from its own `Launchpad` state.

Bridged tokens can be sold into a destination curve only up to what that curve has itself sold (`InsufficientSold`).
No leg can be drained below its own deposits; cross-leg price differences are closed by arbitrage instead.

## Fees

Every fee stream is credited in `FeeEscrow` and claimed by the recipient — nothing is pushed:

| Stream | Source | Split |
| --- | --- | --- |
| Launch fee | `createLaunch` | 100% protocol |
| Curve fee | buy / sell, 1% of quote | 30% protocol / 70% creator |
| Creator tax | buy / sell, 0–10% of quote | 100% creator |
| Hook fee | v4 `afterSwap`, 1% of unspecified currency | 30% protocol / 70% creator |
| LP fee | v4 position, only if a pool fee is configured | collected by `LiquidityLocker` into escrow |

## Trust and upgradeability

Nothing is upgradeable. Owner powers (`Ownable2Step`, intended to be a multisig behind a timelock) are limited to:
enabling quote assets and their curve parameters, pointing the launchpad at the relay and bridge, setting the protocol
fee recipient, and LayerZero peer / DVN configuration. The owner cannot mint, move locked liquidity, or change a live
leg's curve.
