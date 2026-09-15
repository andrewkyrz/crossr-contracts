# Testing

All tests run with Foundry against a real Uniswap v4 `PoolManager`; nothing about the pool or hook is mocked. The
only mocks are an ERC20 and a minimal LayerZero endpoint used for the fast cross-chain suite.

## Running

```sh
forge test                                   # full suite
forge test -vvv                              # show traces for failures
forge test --match-contract LaunchpadTest    # one contract
forge test --match-test test_graduate        # one test or prefix
forge test --match-test testFuzz -vv         # fuzz tests only
FOUNDRY_PROFILE=ci forge test                # CI settings: 2000 fuzz runs
forge test --gas-report                      # gas table for Launchpad, LaunchToken, TokenBridge, LiquidityLocker
forge snapshot                               # write .gas-snapshot; diff it in PRs that touch hot paths
```

## Layout

```
test/
├── Launchpad.t.sol           single-chain unit + fuzz: create, buy, sell, snipe tax, graduation, fees, hook
├── CrossChain.t.sol          two stacks through MockLzEndpoint: relay, direct legs, bridge, sell caps
├── CrossChainLz.t.sol        same flows through LayerZero TestHelperOz5 (EndpointV2 + ULN302 + DVN + executor)
├── mocks/
│   ├── MockERC20.sol         mintable ERC20 used as an ERC20 quote
│   └── MockLzEndpoint.sol    delivers OApp messages synchronously between two stacks
└── utils/
    └── LaunchpadTestBase.sol deploys one Stack; helpers for manifests, buys, warps
```

### `LaunchpadTestBase`

`Stack` bundles everything one chain needs: `PoolManager`, `PoolSwapTest` router, `FeeEscrow`, `LiquidityLocker`,
`LaunchHook`, `Create3Factory`, `Launchpad`. Single-chain tests use `stack`; cross-chain tests deploy two and wire the
bridge and relay between them.

Constants match the production ETH defaults: `PHANTOM = 1.68 ether`, `TARGET = 4.2 ether`,
`SUPPLY = 1_000_000_000e18`. Change them in a test only if the test is *about* different parameters.

Actors: `owner` (the test contract), `treasury`, `creator`, `alice`, `bob`, all via `makeAddr`.

## Two cross-chain suites

| | `CrossChain.t.sol` | `CrossChainLz.t.sol` |
| --- | --- | --- |
| Endpoint | `MockLzEndpoint` — synchronous, no verification | LayerZero `TestHelperOz5` — real EndpointV2, ULN302, DVN, executor |
| Speed | fast | slower (~seconds per test) |
| Use for | business logic: relay validation, sell caps, bridge accounting | wiring: peers, enforced options, `_lzReceive` decoding, gas options |

Add business-logic tests to the mock suite first. Add an Lz test only when the behaviour depends on real LayerZero
plumbing (message encoding, options, peer checks).

## Conventions

- `test_<unit>_<behaviour>` for concrete cases, `testFuzz_<unit>_<behaviour>` for fuzz. Units follow the entry point:
  `create`, `buy`, `sell`, `graduate`, `relay`, `directLeg`, `bridge`, `hook`, `escrow`.
- Revert tests use `vm.expectRevert(Contract.Error.selector)`. Never `expectRevert()` without a selector.
- Assert balances and escrow credits after every value-moving call, not just that it did not revert.
- Fuzz inputs are bounded with `bound()` to realistic ranges and the invariant is stated in a `/// @dev` comment above
  the test.
- Timestamps are literals. via-IR rematerialises `block.timestamp` across `vm.warp`, so compute expected snipe tax from
  the same literal you warp to.

## Adding a test for a bug

1. Write the failing test first, named after the behaviour, not the issue number.
2. Fix.
3. If the bug was in curve or fee maths, also extend the nearest fuzz test so the class of bug is covered, not just the
   instance.
