# Contributing

Thanks for helping out. This repo holds the Solidity contracts for crossr: a per-chain bonding-curve launchpad
whose tokens share one address on every chain, bridge over LayerZero V2 and graduate into locked Uniswap v4 pools.
Everything here is money-handling code, so the bar for changes is: tested, reviewed, and explained.

## Setup

Requirements: [Foundry](https://book.getfoundry.sh/) (nightly is fine), [Bun](https://bun.sh/), git.

```sh
git clone https://github.com/andrewkyrz/crossr-contracts
cd crossr-contracts
git submodule update --init   # lib/forge-std
bun install                    # OpenZeppelin, Solady, Uniswap v4, LayerZero (via node_modules remappings)
forge build
forge test
```

`forge test` should pass green before you touch anything. If it does not, open an issue with your `forge --version`
and the failing output instead of working around it.

## Workflow

1. Open or pick an issue. For anything beyond a typo, describe the change first so we can agree on the approach
   before you spend time on it.
2. Branch from `main`. Use `<type>/<short-topic>`, e.g. `feat/erc20-quote-legs`, `fix/snipe-tax-rounding`,
   `docs/architecture`, `test/bridge-fuzz`.
3. Keep commits small and self-contained. Every commit should build and pass `forge test` on its own — we bisect.
4. Open a pull request against `main`. CI runs `forge build --sizes` and `forge test -vvv` with the `ci` profile
   (2000 fuzz runs). A PR with red CI will not be reviewed.
5. One approving review is required. Address review comments with new commits; we squash or rebase at merge time
   depending on how the history reads.

## Commit messages

Conventional-commit style, lowercase, imperative, no trailing period:

```
feat: add LaunchRelay for cross-chain leg creation
fix: refund excess quote on the graduating buy
test: fuzz snipe tax decay
docs: document graduation math
chore: bump v4-periphery
```

Types: `feat`, `fix`, `test`, `docs`, `chore`, `refactor`, `script` (deployment scripts). Put the *why* in the body
when it is not obvious from the diff. Reference issues as `Closes #12`.

## Code style

- `forge fmt` before every commit. Settings live in `foundry.toml` (`line_length = 110`, `tab_width = 4`,
  `bracket_spacing = false`). CI does not enforce formatting yet; reviewers will.
- `pragma solidity ^0.8.26;` and `// SPDX-License-Identifier: MIT` on every file.
- Custom errors, not revert strings. Name them for the condition (`QuoteNotEnabled`, `InsufficientSold`), declared
  at the top of the contract or in the relevant interface.
- Events for every state transition that an indexer would care about. Index the launch id.
- Named imports only: `import {Launchpad} from "../src/Launchpad.sol";`.
- No `block.timestamp` arithmetic inside via-IR-sensitive paths without a comment. See the Foundry note in the README:
  via-IR rematerializes `block.timestamp` across `vm.warp`, so tests use literal timestamps.
- Prefer `Ownable2Step` for anything with an owner. Ownership transfers must be accepted, never assumed.
- Do not add a dependency without saying why in the PR. Pinned versions live in `package.json` / `bun.lock`.

## Tests

Every behavioural change ships with tests. Layout:

| File | Scope |
| --- | --- |
| `test/Launchpad.t.sol` | Single-chain unit and fuzz tests against a real v4 `PoolManager` |
| `test/CrossChain.t.sol` | Two stacks wired through `test/mocks/MockLzEndpoint.sol` — fast, business logic |
| `test/CrossChainLz.t.sol` | Same flows through LayerZero's `TestHelperOz5` (real EndpointV2, ULN302, DVN, executor) |
| `test/utils/LaunchpadTestBase.sol` | Deploys one full stack ("one chain"); multi-chain tests deploy several |

Naming: `test_<unit>_<behaviour>` and `testFuzz_<unit>_<behaviour>`, e.g. `test_create_revertsBadAllocation`,
`test_bridge_burnsAndMints`. Revert tests assert the specific custom error with `vm.expectRevert(Selector)`.

```sh
forge test                          # everything
forge test --match-contract Launchpad
forge test --match-test test_relay -vvvv
FOUNDRY_PROFILE=ci forge test       # what CI runs (2000 fuzz runs)
forge test --gas-report             # gas_reports in foundry.toml: Launchpad, LaunchToken, TokenBridge, LiquidityLocker
```

If you change curve maths (`src/libraries/CurveMath.sol`, `Launchpad` buy/sell/graduate), add or extend a fuzz test
and state the invariant you are protecting in the test's doc comment.

## Pull request checklist

- [ ] `forge fmt` run, `forge build` warning-free, `forge test` green locally and in CI.
- [ ] New or changed behaviour is covered by tests, including the revert paths.
- [ ] Storage layout of deployed contracts unchanged, or the PR explains the migration.
- [ ] Any change to fees, curve parameters, bridge authority or ownership is called out in the PR title.
- [ ] `README.md` / `docs/` updated if the public surface (functions, events, scripts, env vars) changed.
- [ ] `.env.example` updated if a script reads a new variable.
- [ ] No secrets, RPC keys or `broadcast/` output committed. `.gitignore` covers the usual paths; check anyway.

## Deployment scripts

Scripts under `script/` are part of the reviewed surface. If you add or change one:

- keep it idempotent where possible and read configuration from env vars documented in `.env.example`;
- add any new chain to `script/Chains.sol` with its PoolManager, LayerZero endpoint/EID and default curve parameters;
- dry-run against `anvil` using `script/DeployLocal.s.sol` and describe the run in the PR.

Never commit `broadcast/` artifacts for chain id 31337 or dry runs; real-network `broadcast/` files are committed
deliberately, in their own `chore:` commit, as the deployment record.

## Reporting security issues

Do **not** open a public issue for anything that could be exploited on a live deployment (curve accounting, hook
delta handling, bridge mint authority, ownership). Contact the maintainers privately via the email on the GitHub
profile of the repository owner and give us a reasonable window to respond before disclosure. We will credit you in
the fix commit unless you ask otherwise.

## Questions

Open a discussion or an issue tagged `question`. If the README or `docs/` did not answer it, that is a docs bug —
a PR fixing the docs is very welcome.
