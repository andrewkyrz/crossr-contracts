# Local development

How to run a full stack on `anvil`, simulate a launch through graduation, and iterate on scripts without touching a
real network.

## One-time setup

```sh
git submodule update --init
bun install
cp .env.example .env     # only needed for real-network scripts; local flow uses anvil's default key
forge build
```

## Deploy a local stack

Terminal 1:

```sh
anvil
```

Terminal 2 — deploys PoolManager, FeeEscrow, LiquidityLocker, LaunchHook (address mined for its permission bits),
Create3Factory, Launchpad, TokenBridge and LaunchRelay, then writes `deployments/31337.json`:

```sh
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil account 0
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

`deployments/31337.json` and `broadcast/31337` are git-ignored; delete them and redeploy whenever you restart anvil.

## Simulate a launch

```sh
forge script script/Simulate.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
GRADUATE=true forge script script/Simulate.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Without `GRADUATE` the script creates a launch and does a handful of buys and sells. With `GRADUATE=true` it buys
through the target so you can inspect the graduated v4 pool and the locker's position. Read addresses back from
`deployments/31337.json`, e.g.:

```sh
cast call $(jq -r .launchpad deployments/31337.json) "protocolFeeBps()(uint16)" --rpc-url http://127.0.0.1:8545
```

## Iterating on scripts

- Dry-run first: drop `--broadcast` to simulate against the fork without sending.
- `-vvvv` prints every call; useful when a script reverts inside a LayerZero quote.
- Scripts read configuration from env vars listed in `.env.example`; keep that file in sync when you add one.
- Multi-chain flows cannot be exercised locally with real LayerZero. Use `test/CrossChainLz.t.sol` for that, or two
  anvil instances with the mock endpoint if you need to script it.

## Common problems

**`forge build` fails on a missing remapping** — run `bun install`; every external library is resolved from
`node_modules` via the remappings in `foundry.toml`. `lib/` only holds `forge-std` as a submodule.

**Hook address mismatch** — `LaunchHook` must live at an address whose low 14 bits encode `beforeInitialize` and
`afterSwap`. `DeployLocal` mines it; if you deploy the hook by hand you must do the same.

**Tests pass locally but fail in CI** — CI uses `FOUNDRY_PROFILE=ci` (2000 fuzz runs). Run it locally before pushing.

**Snipe tax assertions off by a block** — see the via-IR / `vm.warp` note in [testing.md](testing.md).
