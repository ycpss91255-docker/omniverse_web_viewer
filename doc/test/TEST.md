# TEST.md

**18 tests** total (bats). The example also has 10 `node --test` unit
tests for `buildStreamConfig` (run in the `example` stage build and via
the `example: ... node --test` bats below).

## test/smoke/omniverse_web_viewer_env.bats (14)

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint check |
| `bash is available on PATH` | Shell availability |
| `SIGNALING_SERVER env defaults to 127.0.0.1` | Runtime env default |
| `SIGNALING_PORT env defaults to 49100` | Runtime env default |
| `SERVE_PORT env defaults to 5173` | Runtime env default |
| `build preserves sentinel-bearing JS templates` | Build keeps the four sentinels in pristine `*.js.tmpl` (the render source of truth) |
| `entrypoint renders defaults into *.js and clears sentinels` | Renders `*.js.tmpl` -> `*.js`; all four sentinels gone from `*.js`, defaults applied (server 127.0.0.1, port 49100, ui_mode usd-viewer) |
| `entrypoint applies SIGNALING_SERVER env override` | Env value reaches the rendered bundle (distinctive IP) |
| `entrypoint re-renders on every run (de-one-shot, #17)` | Second run with a different value wins and the first is gone — proves the substitution is not one-shot |
| `host.yaml public_ip takes precedence over env` | `/etc/host.yaml` `network.public_ip` overrides the `SIGNALING_SERVER` env |
| `host.yaml inline comment is stripped from the value` | A trailing `# comment` on a host.yaml value is not leaked into the bundle |
| `non-numeric SIGNALING_PORT is rejected` | Invalid port fails the container fast (exit 1) instead of baking malformed JS |
| `invalid VIEWER_UI_MODE is rejected` | ui_mode outside `{usd-viewer, stream-only}` fails fast (exit 1) |
| `SIGNALING_SERVER with shell/sed metacharacters is rejected` | Charset whitelist blocks sed/JS metacharacter injection (exit 1) |

## test/smoke/example_demo.bats (4)

Source-contract smoke for `examples/embedded-site-demo`. The full example
build (eslint / vite / serve-200 / sentinel templating) runs in the
Dockerfile `example` stage.

| Test | Description |
|------|-------------|
| `example: key files exist` | index.html / package.json / main.ts / buildStreamConfig(.js/.test.js) present |
| `example: only runtime dependency is the streaming library` | `package.json` `dependencies` is exactly `@nvidia/omniverse-webrtc-streaming-library` |
| `example: streamTarget.json carries both sentinels` | `__OWV_SERVER__` + `__OWV_PORT__` present for entrypoint substitution |
| `example: buildStreamConfig unit tests pass (node --test)` | Runs the 10 `node --test` unit cases (valid / numeric-string / hostname / empty / whitespace / sentinel / metachar server / non-numeric / non-integer / out-of-range port) |
