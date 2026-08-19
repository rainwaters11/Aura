# Aura Baseline

## Imported source

- Repository: `rainwaters11/Argos_LTS`
- Commit: `4603269e8af7dbbff6e337546fd9d7be27deb34c`
- Aura repository: `rainwaters11/Aura`
- Import status: Aura `main` points to the approved baseline commit
- Target: Unichain Sepolia, chain ID 1301
- Compiler baseline: Solidity 0.8.30, Cancun EVM
- MVP batch window: `MAX_BATCH_WINDOW = 20` Unichain blocks, measured from the first order's `openedAtBlock`; a batch closes when `block.number > openedAtBlock + 20`

The imported commit is preserved as the audit and rollback anchor. Aura evolves through reviewable branches and pull requests. The Argos repository and its `main` branch are not modified by Aura work.

## Reuse inventory

- ERC-6909 mint, burn, take, and CEI redemption patterns from `src/ArgosLTSHook.sol`
- Pool and liquidity setup from `test/utils/BaseTest.sol`
- ERC-6909 edge-case test patterns
- CREATE2 hook-flag mining and Unichain deployment scripts
- Existing recursive OpenZeppelin Uniswap Hooks dependency graph and remappings
- Reactive Network callback patterns, subject to Aura authentication rules

## Replace or retire from active paths

- Argos toxic-flow state and Lit Protocol product behavior
- Argos-specific contracts, tests, deployment metadata, and README claims
- Legacy React/Vite frontend
- Reactive arbitrage sensor

Historical source remains available in Git history for attribution and comparison.

## Known baseline defects

- `.github/workflows/ci.yml` uses `working-directory: ./Argos_LTS` although the Foundry project is at repository root.
- `AGENTS.md` is Argos-specific and requires a missing `docs/V4_SECURITY_SKILL.md`.
- `README.md` describes Argos, its old hackathon, and historical deployments rather than Aura.
- Live Argos addresses and Lit integration are not Aura deployment evidence.

These defects are tracked in Sprint 1. They are not silently corrected in the governance-only architecture pull request.

## Dependency policy

Pin the working graph before implementation. Do not install duplicate top-level copies of v4-core, v4-periphery, or OpenZeppelin Contracts when they already resolve through `lib/uniswap-hooks` recursive submodules.
