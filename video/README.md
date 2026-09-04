# Aura demo video workspace

This isolated Remotion project creates Aura's programmatic demo clips without changing the production Settlement Console dependencies.

## Timeline

| Time | Segment | Default source |
| --- | --- | --- |
| 0:00–0:08 | Aura opening | Remotion fallback or Hedra |
| 0:08–0:32 | Fragmented-intent problem | Remotion fallback or Hedra |
| 0:32–1:02 | Park → Match → Residual → Claim | Remotion |
| 1:02–3:15 | Genuine console demonstration | Browser capture required |
| 3:15–3:40 | Tests, security, and size evidence | Remotion |
| 3:40–4:02 | User benefit | Remotion fallback or Hedra |
| 4:02–4:25 | Closing statement | Remotion |

Total: 4 minutes 25 seconds, safely below the five-minute judging limit.

## Requirements

- Node.js 22.22.2 or newer
- npm
- A human-recorded voiceover for the final video

## Install and inspect

```bash
cd video
npm ci
npm run check
npm run studio
```

Remotion Studio opens at the local URL printed in the terminal.

## Render clips that do not require manual recording

```bash
npm run render:clips
```

Rendered files appear in `video/out/`:

1. `01-aura-intro.mp4`
2. `02-aura-problem.mp4`
3. `03-aura-architecture.mp4`
4. `05-aura-evidence.mp4`
5. `06-aura-impact.mp4`
6. `07-aura-closing.mp4`

## Add genuine console footage

Record the actual Aura console and save it locally as:

```text
video/public/clips/console-demo.mp4
```

In Remotion Studio, select `AuraDemo` and set the input property:

```json
{
  "consoleClip": "clips/console-demo.mp4"
}
```

Optional Hedra clips can replace the programmatic opening, problem, and impact scenes:

```json
{
  "introClip": "clips/hedra-intro.mp4",
  "problemClip": "clips/hedra-problem.mp4",
  "consoleClip": "clips/console-demo.mp4",
  "impactClip": "clips/hedra-impact.mp4",
  "voiceover": "voiceover/misty-voiceover.wav"
}
```

Copy `props.example.json` to the ignored `props.local.json`, then remove any optional clip you are not using. This keeps machine-specific media paths out of Git.

## Render the complete timeline

```bash
npm run render
```

The default command produces `video/out/aura-demo.mp4`. Confirm the real console footage and human voiceover are present before treating any render as submission-ready.

## Truth and safety boundaries

- Label the console footage **Deterministic local demonstration** unless a verified testnet deployment exists.
- Never replace product behavior, CI results, contract addresses, or transaction evidence with generated footage.
- Reactive production transport remains deferred and must not be presented as implemented.
- Do not commit private keys, RPC URLs, wallet information, browser profiles, or large media files.
