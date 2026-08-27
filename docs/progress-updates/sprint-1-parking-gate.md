# Sprint 1 parking and custody gate

Report updated: 2026-08-27 UTC  
Verification run: 2026-08-25 UTC  
Scope: authenticated exact-input parking, bounded batch admission, ERC-6909 custody, curve neutrality, and timeout refunds.

## Architecture and working demonstration

`AuraRouter` is the sole user entrypoint and derives the owner from `msg.sender`; users may select only the direction, exact input, minimum output, recipient, and Unix deadline. It submits the immutable Aura `PoolKey`. `AuraHook` accepts exact-input parking only when the v4 sender is that router, validates the versioned order and pool, then delegates custody to OpenZeppelin `BaseAsyncSwap`. The hook records the domain-separated order ID only after the base path mints the input ERC-6909 claim.

The local Foundry demonstration covers both input currencies. For each parked order, PoolManager ERC-20 custody and the hook's currency-scoped ERC-6909 balance increase by exactly the input while pool square-root price, tick, and active liquidity remain unchanged. One-sided timeout cancellation burns the same claim and returns the exact input once.

## Acceptance evidence

- Router attribution: `AuraSecurityTest.test_routerAlwaysAttributesOrderToCaller` verifies that choosing another recipient cannot change the caller-derived owner.
- Authentication failure neutrality: `test_unauthenticatedParkingCannotMoveFundsOrCreateClaims` verifies a forged sender creates neither an order nor ERC-20/ERC-6909 movement.
- Exact custody and curve neutrality: `AuraParkingTest.test_parksCurrency{0,1}WithExactBackingAndNoCurveMovement` covers both directions; `AuraParkingInvariant` repeats the currency-scoped backing and unchanged-pool properties under invariant runs.
- Bounds: the parking and security suites cover the four-order cap, reserved final directional slot, signed individual limit, signed per-direction aggregate limit, malformed data, nonce replay, invalid deadlines/minimums, incompatible price bounds, and rollover into a fresh batch.
- Refund: the parking suite covers strict timeout boundaries, caller ownership, replay rejection, claim burning, exact input return, and the closed-batch finality/grace boundary.

These tests cover the Issue #7 evidence requirements for caller attribution, unauthorized-call custody neutrality, currency-scoped ERC-6909 backing, unchanged AMM curve state, signed limits, bounded rollover, and one-time refunds.

## Authoritative verification

Repository-root Foundry CI, pinned to Foundry 1.7.1 with Solidity 0.8.30/Cancun, is the authoritative compilation and test gate. Remix IDE is optional supplementary visual evidence only; it is not a source-authoring, compilation, or merge dependency.

Evidence identities:

- PR source head tested by GitHub Actions: `331682613a532af21a06fc6d06efad47002ac9ac`.
- GitHub-generated merge commit checked out by CI: `a507834fff64cdfc35bf98e02c2fc50b67271887`, merging that PR head into base `e23b7173819a87d8a08edc039e85dd90b914b5d5`.
- Authoritative CI: [run #54](https://github.com/rainwaters11/Aura/actions/runs/32804954648), job `Forge Build & Test`, completed successfully.

Commands executed from the repository root:

```text
forge fmt --check
forge build --sizes
forge test --match-path "test/AuraParking.t.sol" -vv
forge test --match-path "test/AuraSecurity.t.sol" -vv
forge test -vv
git diff --check
slither . --filter-paths "lib|test|script|src/Argos|src/Counter|src/Reactive|src/libraries|src/mocks"
```

Exact observed results:

| Command | Result |
| --- | --- |
| `forge fmt --check` | PASS; GitHub Actions step completed successfully with no formatting diff. |
| `forge build --sizes` | PASS; 142 files compiled with Solc 0.8.30. `AuraHook` runtime size was 24,181 bytes, leaving 395 bytes below the EIP-170 limit. |
| Focused `AuraParking.t.sol` run | PASS; 20 passed, 0 failed. |
| Focused `AuraSecurity.t.sol` run | PASS; 4 passed, 0 failed. |
| Full Forge suite | PASS; 14 suites, 98 passed, 0 failed, 8 skipped, 106 total. GitHub Actions reproduced this result with `forge test -vvv`. |
| `git diff --check` | PASS; no whitespace errors. |
| Scoped Slither 0.11.6 | COMPLETED; no high-severity finding was reported. Findings are dispositioned below. |

The focused-test, diff-check, and Slither results were captured by the PR task run; GitHub Actions run #54 independently reproduces the authoritative formatting, build-size, compiler, and complete-test results.

## Static-analysis dispositions

| Finding | Disposition | Rationale |
| --- | --- | --- |
| Divide-before-multiply in `_frozenBounds` | False positive | Comparisons use the unreduced exact ratios; subsequent divisions are only by computed GCDs and are exact normalization. |
| Router reentrancy / write-after-write | Accepted design | The external call is only to the immutable PoolManager. `_unlocking` is set before it and is deliberately retained through the authenticated callback; nested user entry is rejected. |
| Hook refund reentrancy / event-after-call / ignored unlock return | Accepted design | The immutable PoolManager is the only callback caller, the order is cancelled before unlock, the callback is bound to `_refundOrderId`, and return data is not part of the refund protocol. A revert rolls back all state. |
| Uninitialized rational-bound locals | False positive | Solidity zero initialization is intentional: zero denominators encode a bound that has not yet been observed and are checked before use. |
| Timestamp comparisons | Accepted design | Unix timestamps and strict equality/expiry boundaries are normative protocol requirements, not randomness or price inputs. |
| Router cyclomatic complexity | Accepted, bounded | The function is a single bounded validation/encoding entrypoint with no loops; splitting it would not reduce the trust boundary. |

No high-severity finding was reported. These dispositions do not replace independent review.

## Security impact, risks, and rollback

Security impact is test-only and documentation-only: the change adds regression evidence without modifying deployed contract behavior. The remaining implementation risk is the narrow 395-byte runtime-size margin; later settlement work must re-run `forge build --sizes`. Slither's accepted trusted-PoolManager callback findings must be reconsidered if the immutable call graph changes.

Rollback is a normal revert of the Sprint 1 gate commits. That removes only `test/AuraSecurity.t.sol` and this progress record; the existing parking implementation remains unchanged.

## Next sprint

Sprint 2 may build clearing and settlement only after review accepts this gate. It must add canonical clearing math, typed solution validation, settlement/claim accounting, authenticated Reactive callbacks, and settlement invariants. No deployment or public-network transaction was performed for this gate.
