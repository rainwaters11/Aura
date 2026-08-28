# Aura Settlement Console

A judge-facing React and TypeScript interface for demonstrating Aura's bounded
CoW settlement flow. The default experience is deterministic and local: it does
not connect a wallet, submit a public transaction, or imply that its trace IDs
are block-explorer transaction hashes.

## Demonstration flow

The console presents one deliberate path:

1. Park the two exact-input orders.
2. Show the deterministic 20-block intake window has passed, then close the
   batch and freeze its membership.
3. Submit the approved local settlement fixture.
4. Inspect direct-match volume, the single residual, curve movement, and zero
   unresolved deltas.
5. Pull a sovereign claim to the selected recipient.

Use the **Perfect CoW** fixture to show that a completely matched batch leaves
the pool price and tick untouched.

## Run locally

```bash
npm ci
npm run dev
```

Open `http://localhost:5173`.

## Verification

```bash
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

## Data-source boundary

`AuraDataSource` is the typed boundary between the interface and execution
evidence. `localAuraDataSource` is the required deterministic fixture.
`AnvilAuraDataSource` documents the read/write adapter seam for a future local
Anvil integration without bundling a private key or silently falling back to a
public network.

The visual states can be reviewed with the `preview` query parameter:

- `?preview=disconnected`
- `?preview=wrong-network`
- `?preview=unavailable`
- `?preview=claim-error`

The implementation intentionally excludes analytics, wallet history, solver
competition, multi-pool navigation, and automated public-network execution.
