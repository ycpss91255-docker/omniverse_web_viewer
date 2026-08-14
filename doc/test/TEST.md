# TEST.md

**103 tests** total: **30 bats** (repo-level smoke, `test/smoke/bats/`, run in the `devel-test` stage) + **67 node** (per-package unit, `node --test`, run in the package builds and `devel-test`) + **6 Playwright** (tier-1 browser e2e -- config dial + status states, `test/e2e/`, run in the `e2e-test` extra stage).

Layout follows base #473 (`test/<category>/<tool>/` for the multi-tool repo level; each npm package carries its own single-tool `test/`).

## test/smoke/bats/omniverse_web_viewer_env.bats (25)

Two-app config-injection model (S5): the build preserves sentinel-bearing chunks as `*.js.tmpl` per app dir (`/app/usd-viewer/dist`, `/app/stream-only/dist`); the entrypoint resolves `VIEWER_UI_MODE` (app selector), validates every value, and re-renders ONLY the active app's templates on every boot with 3 seds (`__OWV_SERVER__` / `"__OWV_PORT__"` / `"__OWV_MEDIA_PORT__"`).

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint check |
| `bash is available on PATH` | Shell availability |
| `SIGNALING_SERVER env defaults to 127.0.0.1` | Runtime env default |
| `SIGNALING_PORT env defaults to 49100` | Runtime env default |
| `SERVE_PORT env defaults to 5173` | Runtime env default |
| `VIEWER_UI_MODE env defaults to usd-viewer` | App-selector default (D7) |
| `both app dist dirs exist (devel has both modes)` | `/app/usd-viewer/dist` + `/app/stream-only/dist` both present |
| `usd-viewer build preserves server/port templates, no media sentinel` | Per-app sentinel shape: usd-viewer carries server/port ONLY |
| `stream-only build preserves all three sentinels in templates` | stream-only carries server/port/media (from `streamTarget.json`) |
| `default mode (usd-viewer) renders defaults + clears sentinels` | Render path: sentinels gone from `*.js`, kept in `*.js.tmpl` |
| `default mode renders ONLY the usd-viewer dir, not stream-only` | Mode isolation -- inactive app untouched |
| `usd-viewer applies SIGNALING_SERVER env override` | Distinctive-IP render proof |
| `VIEWER_UI_MODE=stream-only renders the stream-only dir` | App selector switches the render target |
| `stream-only unset MEDIA_PORT renders literal null (negotiate, D1)` | Media default = null = SDP negotiation |
| `stream-only MEDIA_PORT=47998 pins the media port` | Media knob pinned when set (D1) |
| `re-render is idempotent with changed values (de-one-shot, #17)` | Second render wins, first value gone |
| `host.yaml public_ip takes precedence over env` | `host.yaml` > env > default |
| `host.yaml inline comment is stripped from the value` | `yaml_value` comment handling (#104-class) |
| `host.yaml viewer.ui_mode selects the served app` | App selector via host.yaml |
| `entrypoint exports the resolved VIEWER_UI_MODE for the CMD` | Export-before-exec so the CMD serves the resolved dir |
| `non-numeric SIGNALING_PORT is rejected` | Validation (exit 1) |
| `invalid VIEWER_UI_MODE is rejected` | Enum validation (exit 1) |
| `non-numeric MEDIA_PORT is rejected` | Optional-knob validation (exit 1) |
| `out-of-range MEDIA_PORT is rejected` | 1..65535 (exit 1) |
| `SIGNALING_SERVER with shell/sed metacharacters is rejected` | Validation IS the escaping (security) |

## test/smoke/bats/example_demo.bats (5)

| Test | Description |
|------|-------------|
| `example: key files exist` | index.html / package.json / main.ts / resolveTarget.js + its test |
| `example: depends on stream-core + the streaming library only` | Exactly 2 runtime deps |
| `example: imports the factory from stream-core (local copy deleted)` | No duplicate `buildStreamConfig` (S3 dedup) |
| `example: streamTarget.json carries all three sentinels` | server/port/media sentinels present |
| `example: resolveTarget unit tests pass (node --test)` | Runs the example's own glue tests in-image |

## packages/stream-core/test/ (20, node --test)

The kernel's contract -- the ONLY package touching the NVIDIA streaming library (lazy import; tests run registry-free).

- `buildStreamConfig.test.js` (16): valid server+port config shape (DIRECT essentials incl. `remote-video`/`remote-audio` ids), string-port coercion, hostname accept; rejects empty/whitespace/sentinel/metachar server, non-numeric / non-integer / out-of-range port; media-port arg -- omitted when unset/null, pinned when valid int, string coerced, non-integer / out-of-range throw (D1).
- `connectStream.test.js` (4): `buildStreamProps` defaults all 5 lifecycle handlers to no-ops, preserves config fields, caller handler wins; `connectStream` hands the assembled cfg to an injected connector without loading `@nvidia`.

## apps/stream-only/test/ (42, node --test)

- `resolveTarget.test.js` (6): target fallback (entrypoint-substituted values), `?server=&port=` override, `?media=` override, unsubstituted media sentinel -> null, missing/empty media -> null, server sentinel passes through (rejected downstream by `buildStreamConfig`).
- `streamStatus.test.js` (36): the `#stream-status` show/hide controller (#53), the producer-loss transitions (#56), the locally derived terminal state (#58), the honest recoverable wording (#60) and the media-driven loss detection (#62). Show/hide (7): `show()` writes the readout and leaves it visible; `show(text, true)` sets the error class; the readout hides on the first video `playing` event (and on `loadeddata`); re-showing after a hide un-hides it (reconnect/error); `show`/error route to `logger.info` / `logger.error`; tolerates null status/video elements. Producer loss (8): `stopped()` re-shows a visible, non-error, waiting-for-frames readout after the first frame had cleared it; neither producer-loss state may claim a reconnect is under way (#60 regression lock -- the library has no mid-session reconnect path); `terminated()` shows a distinct terminal state with the error class; the terminal state is sticky against a later `stopped()` and against a stray video event; `stopped()` logs as info and `terminated()` as error; the #53 happy path (start -> first frame -> cleared, no error) is locked as a no-regression case; the lifecycle transitions tolerate null status/video elements. Terminal-state derivation (12, all driven by an injected fake clock -- no real waiting): `show()` alone arms nothing; `stopped()` arms exactly one escalation with the injected delay; firing it reaches the terminal state with no `onTerminate` callback; a frame after `stopped()` disarms the escalation, clears the readout (#53) and a stale timer cannot resurrect the terminal state; a stop after a recovery re-arms; repeated `stopped()` keeps a single timer; the escalated terminal state is latched against a later `stopped()` (no re-arm) and against a stray video event; `terminated()` disarms a pending escalation; the escalation logs as an error; it tolerates null status/video elements; the exported default delay is long enough not to disturb the config-dial e2e. Media-driven loss detection (9, same injected clock, plus a fake video element that reports frame progress): a video element that reports no progress never arms the watchdog (which is what leaves every spec above, and the dead-host config-dial e2e, untouched); the watchdog arms on the first rendered frame and not before; frames that keep arriving never announce a loss; frames that stop arriving announce the recoverable state with no `onStop` involved and arm the ordinary #58 escalation; resumed frames clear it and disarm the escalation (#53); an unrecovered stall escalates to the same terminal state; `onStop` stays an accelerator (a stall detected after it neither re-announces nor re-arms -- same timer id, so the terminal state still lands one window after the first signal); the terminal state latches the watchdog (nothing left armed, later frames cannot clear it); the exported stall window is long enough to ride out a hiccup and shorter than the escalation window.

## examples/embedded-site-demo/test/ (5, node --test)

`resolveTarget.test.js`: target fallback, query override, `?media=` override, unsubstituted media sentinel -> null, server sentinel pass-through. (The example's `buildStreamConfig` tests moved to `stream-core` in S1/S3.)

## test/e2e/ (6, Playwright + headless Chromium)

Two suites, two Playwright projects, one gate. Standalone and `@nvidia`-free (outside the npm workspaces). Both drive the REAL dist served by the `runtime` image: `run-in-image.sh` renders the sentinel templates via the production entrypoint with distinctive test values (`10.20.30.40:49100`, media `47998`), serves each mode, then runs Playwright against it.

### `config-dial.spec.ts` (2) -- project `chromium`

Tier-1 browser config-dial e2e (#47). The specs wrap `window.WebSocket` / `window.RTCPeerConnection` (via `addInitScript`, before app code) to record dial targets and listen for the `owv:dial` CustomEvent; the app dialing a dead host (async failure) is EXPECTED.

| Test | Mode | Description |
|------|------|-------------|
| `stream-only dials the injected target` | stream-only | Asserts the `owv:dial` event detail (server/port/media) matches the injected values (media pinned == `MEDIA_PORT`, null when unset, D1); best-effort WS-URL corroboration; `#stream-status` not in error / no `invalid` |
| `usd-viewer dials the injected target` | usd-viewer | BLACK BOX (upstream unmodified, no event): asserts the WebSocket dial URL carries `server:port`, with a served-JS string-presence fallback (injected server present, `__OWV_SERVER__` sentinel absent) + no uncaught page error |

### `status-loopback.spec.ts` (4) -- project `chromium-loopback`

Browser-level assertions on the `#stream-status` state machine (#62), driven by an in-page WebRTC loopback: a canvas `captureStream()` through a local `RTCPeerConnection` pair into the page's own `#remote-video`, which produces REAL `loadeddata` / `playing` events with real decoded frames behind them -- no GPU, no Isaac, no Kit, no extra service. Stalling the media (`sender.replaceTrack(null)`) is what reaches the loss states, which is only possible because #62 derives them from frame progress rather than from the library's `onStop`. `stream-only` only (the loopback drives OUR app; `usd-viewer` is black-box), so all four skip in the `usd-viewer` pass.

Its own project because the loopback needs two Chromium switches (`--disable-features=WebRtcHideLocalIpsWithMdns`, `--autoplay-policy=no-user-gesture-required`) that must not change how the config-dial suite launches its browser.

| Test | Description |
|------|-------------|
| `the initial readout is visible and carries the stylesheet base styling` | Real computed style before any frame: visible, `Connecting...`, `display != none`, colour `rgb(139, 148, 158)`, no `error` class |
| `real frames hide the readout through the real stylesheet (#53)` | Loopback frames arrive -> the element is genuinely hidden (`display: none`), not merely carrying a class |
| `stalled frames announce the recoverable state, resumed frames clear it (#60, #62)` | Media cut -> visible `waiting for frames` readout in the base colour, no `error` class, no reconnect claim; media restored -> hidden again |
| `an unrecovered stall escalates to a distinct, latched terminal state (#57, #58, #62)` | Stall held past the escalation window -> `source is gone` / `reload`, `error` class, colour `rgb(248, 81, 73)` and different from the recoverable colour; a fresh loopback stream afterwards does not clear it |

`run-in-image.sh` is the in-image gate runner (not a counted spec); a non-zero Playwright exit fails the `e2e-test` stage build.

Still NOT covered here: that a real Kit produces a real, non-black picture. That needs a producer and stays with Tier B (#48, isaac#223, isaac#173).

## Where they run

- bats: `devel-test` stage (`/smoke_test/`, alongside `.base/test/smoke/` shared specs).
- node: each package's build stage (`stream-only-build` runs stream-core + stream-only tests; the `example` stage runs stream-core + example tests) and locally via `npm -w <pkg> test`.
- runtime smoke: `runtime-test` stage serves BOTH app dists and curls each for 200 (not counted above; it is a stage gate, not a spec file).
- Playwright e2e: `e2e-test` extra stage (`FROM runtime`, built via the build-worker `extra_stages` input, per-PR, no GPU / Isaac / self-hosted runner). Installs Playwright + Chromium at build time and runs `run-in-image.sh` against the served dists. Both projects run in both modes; the mode each suite does not apply to is skipped.
