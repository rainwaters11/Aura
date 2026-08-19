# Aura Baseline

## Imported source

- Repository: `rainwaters11/Argos_LTS`
- Commit: `4603269e8af7dbbff6e337546fd9d7be27deb34c`
- Aura repository: `rainwaters11/Aura`
- Import status: Aura `main` points to the approved baseline commit
- Target: Unichain Sepolia, chain ID 1301
- Compiler baseline: Solidity 0.8.30, Cancun EVM
- MVP intake window: `MAX_BATCH_WINDOW = 20` Unichain blocks, measured from the first order's `openedAtBlock`; permissionless window closure begins when `block.number > openedAtBlock + 20`
- MVP finality and settlement bound: record `closedAtTimestamp` for a two-sided closure; `MAX_FINALITY_LAG_SECONDS = 12 hours` covers the documented OP Stack finalized-head lag and `SETTLEMENT_GRACE_SECONDS = 5 minutes` reserves the subsequent inbox/callback window. Basis: [OP Stack transaction finality](https://docs.optimism.io/op-stack/transactions/transaction-finality) and its documented adverse-condition lag. A closed batch becomes refundable only when `block.timestamp > closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`.
- MVP callback retry: `CALLBACK_RETRY_DELAY_SECONDS = 60 seconds`, `MAX_CALLBACK_ATTEMPTS = 3`, and `MAX_PENDING_RETRY_BATCHES = 8`. Only the identical canonical solution may retry before its Unix deadline and the refund boundary. The dispatcher uses an eight-slot retry ring plus a persistent round-robin cursor; each authenticated cron tick scans at most eight slots, selects at most one eligible pending batch, and advances the cursor. A full ring suppresses a new initial dispatch rather than creating unbounded work; the destination batch remains safely refundable.
- Deadline clock: order and solution `deadline` fields are Unix timestamps; equality remains valid and expiry begins only when `block.timestamp > deadline`. Intake windows remain block-number based. `MIN_ORDER_LIFETIME_SECONDS = 13 hours`; admission requires `deadline >= block.timestamp + MIN_ORDER_LIFETIME_SECONDS`, and closure requires every frozen order deadline to cover `closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`.
- MVP directional-capacity rule: while a batch is one-sided, its final slot is reserved for the missing direction. A same-direction order is rejected when `orderCount == MAX_BATCH_ORDERS - 1`; a timed-out one-sided batch becomes refundable.
- MVP canonical-price rule: derive the target from the exact rational midpoint of the frozen orders' feasible interval, never from a close-time pool spot value. Admission rejects any prospective two-sided batch whose greatest lower bound exceeds its least upper bound. Before any `BatchClosed`, the interval is rechecked, every frozen deadline must cover the finality-plus-grace boundary, and every canonical individual payout must fit both the `uint128[]` schema and `type(int128).max`; an at-cap failure reverts the incoming order and a timeout-close failure becomes directly refundable without `BatchClosed`; owners may cancel that failed-preflight batch immediately after the timeout-close transition, while only successfully closed batches wait through finality plus grace.

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
