# TEST.md

**61 tests** total: **30 bats** (repo-level smoke, `test/smoke/bats/`, run in the `devel-test` stage) + **31 node** (per-package unit, `node --test`, run in the package builds and `devel-test`).

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

## apps/stream-only/test/ (6, node --test)

`resolveTarget.test.js`: target fallback (entrypoint-substituted values), `?server=&port=` override, `?media=` override, unsubstituted media sentinel -> null, missing/empty media -> null, server sentinel passes through (rejected downstream by `buildStreamConfig`).

## examples/embedded-site-demo/test/ (5, node --test)

`resolveTarget.test.js`: target fallback, query override, `?media=` override, unsubstituted media sentinel -> null, server sentinel pass-through. (The example's `buildStreamConfig` tests moved to `stream-core` in S1/S3.)

## Where they run

- bats: `devel-test` stage (`/smoke_test/`, alongside `.base/test/smoke/` shared specs).
- node: each package's build stage (`stream-only-build` runs stream-core + stream-only tests; the `example` stage runs stream-core + example tests) and locally via `npm -w <pkg> test`.
- runtime smoke: `runtime-test` stage serves BOTH app dists and curls each for 200 (not counted above; it is a stage gate, not a spec file).
