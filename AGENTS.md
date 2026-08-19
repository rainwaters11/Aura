# Aura Agent Instructions

Aura is a Uniswap v4 batch-auction hook for Unichain Sepolia. Work must be bounded, reviewable, test-backed, and consistent with the protocol specification.

## Required reading

Before editing, read:

1. `BASELINE.md`
2. `docs/design.md`
3. `docs/agent.md` when solver, Reactive Network, event, or callback behavior is in scope
4. `docs/skill.md`
5. `docs/security.md`
6. the current implementation and the relevant installed dependency source

Precedence is `docs/design.md`, `docs/agent.md`, `docs/skill.md`, then implementation comments. Stop and surface an ambiguity instead of guessing.

## Locked MVP

- One immutable PoolKey on Unichain Sepolia
- Exact-input, full-fill orders only
- One authenticated `AuraRouter`
- `AuraHook` based on OpenZeppelin `BaseAsyncSwap`
- At most 8 orders per test batch and 4 in the live demo
- One uniform rational clearing price and at most one residual pool swap
- Pool-scoped ERC-6909 custody, claims, and one-time timeout refunds
- Authenticated Reactive callback proxy and RVM identity

Circle and Arc are optional funding or frontend integrations. Chainalysis is deferred monitoring. None may become a dependency of parking, settlement, claims, or refunds.

## Change rules

- Work only on the named issue and branch.
- Do not weaken an invariant to make a test pass.
- Add or update tests for every accounting, authorization, or state-transition change.
- Keep external source use minimal, attributed, and license-compatible. Do not copy large contracts.
- Never commit private keys, RPC credentials, Circle secrets, deployer details, or funded wallet data.
- Do not deploy, merge, close issues, or mark a pull request ready without explicit approval.

## Required verification

Run the narrowest relevant checks first, then:

```bash
forge fmt --check
forge build --sizes
forge test -vv
```

Settlement changes also require invariant tests. Frontend changes require lint, type-check, and production build. Record exact commands, results, security impact, unresolved risks, and rollback notes in the pull request.

## Definition of done

A task is done only when its acceptance criteria are met, required tests pass, documentation matches behavior, no secrets are exposed, and the pull request contains verification evidence.
