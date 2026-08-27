# omniverse_web_viewer

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

A generic, Kit-agnostic browser-based WebRTC viewer sidecar for Omniverse Kit streaming applications (Isaac Sim, USD Viewer, etc.). Built on [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base), the image serves one of two static apps selected at boot by `VIEWER_UI_MODE`:

- **`usd-viewer`** — NVIDIA's [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2, built UNMODIFIED. Provides the landing screen, the full USD Viewer UI, and any-app streaming — all reached interactively (click).
- **`stream-only`** — our own full-screen, auto-connect app built over the `stream-core` package. Boots straight into the stream with no click; intended for Isaac Sim and any headless stream consumer.

The image only ships static pages; browser JS connects directly to the Kit app's WebRTC signaling/media ports. No GPU is needed in this container.

## How it works

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — a served static app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim stream)
```

The viewer is layered: `stream-core` is the only code that touches the NVIDIA streaming library; the apps own presentation only; the image layer owns serving plus boot-time config injection. `VIEWER_UI_MODE` is a serve-level app selector — it picks which app's `dist` the entrypoint serves, it is not an in-bundle UI mode rendered into a bundle.

## Prerequisites

- An Omniverse Kit application running with NVCF livestream enabled (e.g. Isaac Sim `stream` stage)
- Chrome or Chromium (Firefox incompatible with Omniverse WebRTC)
- Docker
- Supported image architectures: `linux/amd64`, `linux/arm64`

## Quick Start

The deployable stage is the lean `runtime` image (built dists + `serve` only, no toolchain).

```bash
# 1. Build (one-time)
just build

# 2. Run the lean runtime (default: 127.0.0.1:49100, serve on 5173)
just run -t runtime -d

# 3. Open Chrome -> http://<host-ip>:5173
#    usd-viewer (default): click the landing screen to choose a view
#    stream-only: auto-connects into the full-screen stream, no click
```

To override the default host IP or ports, edit `config/docker/setup.conf`:

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
VIEWER_UI_MODE = usd-viewer
```

Then run `./script/setup.sh apply` to regenerate `compose.yaml`.

## Released image

Every git tag publishes a GitHub Release **and** a matching container image, from the same commit in the same CI run, so the two always exist as a pair — given an image you can find its source release, and given a release you can find its image:

```
ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

The image tag is the release version with the leading `v` removed. CI derives it from the git tag; nobody types it in, which is what keeps a release and its image from drifting apart:

| Git tag | Image |
|---------|-------|
| `v0.3.0` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0` |
| `v0.3.0-rc1` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0-rc1` |

Release candidates are published as well, since the rc is what gets verified before the final tag is cut.

Publishing happens **on a tag only** (plus a maintainer-only manual dispatch for a republish). A pull request or a `main` push publishes nothing. There is deliberately no `:latest`: pin a version, so a later release — or an rc — can never silently replace what you are running.

The published image is the lean `runtime` stage, built for `linux/amd64` (the one platform CI builds and gates). For other architectures, build locally with `just build`.

```bash
docker run --rm -d --name owv \
  -e SIGNALING_SERVER=<host-ip> \
  -e SIGNALING_PORT=49100 \
  -e VIEWER_UI_MODE=stream-only \
  -p 5173:5173 \
  ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

Then open Chrome at `http://<host-ip>:5173`. The knobs are the environment variables documented below.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SIGNALING_SERVER` | `127.0.0.1` | Host IP for WebRTC signaling |
| `SIGNALING_PORT` | `49100` | WebRTC signaling port (must match Kit app's `--/app/livestream/port`) |
| `MEDIA_PORT` | null (negotiate) | WebRTC media port — unset negotiates via SDP, set pins it (D1, `stream-only` app only) |
| `SERVE_PORT` | `5173` | Port the static file server listens on |
| `VIEWER_UI_MODE` | `usd-viewer` | App selector: `usd-viewer` (upstream sample, interactive) or `stream-only` (our full-screen auto-connect app, for Isaac Sim / headless consumers) |

`VIEWER_UI_MODE` selects which app the entrypoint serves; it is not asset-injected. `SIGNALING_SERVER`, `SIGNALING_PORT`, and `MEDIA_PORT` are the injected sentinels: the build preserves each sentinel-bearing chunk as a `*.js.tmpl`, and the entrypoint re-renders `*.js.tmpl -> *.js` on every boot (idempotent — a restart or changed value is picked up next start). Validation is the escaping: an invalid value fails the container (`exit 1`) rather than baking malformed JS. Rejected: a `SIGNALING_SERVER` carrying anything outside `A-Za-z0-9.-`; and any of `SIGNALING_PORT`, `MEDIA_PORT` or `SERVE_PORT` that is not an integer 1..65535 written WITHOUT a leading zero — so `80x`, `0`, `99999` and `049100` all fail. The leading-zero rule is not pedantry: the port sentinel is substituted unquoted, so `049100` would render a bare `049100` token, which is a strict-mode `SyntaxError` that black-pages the viewer from a container that started fine. `SERVE_PORT` is checked only when set (the `example` stage serves on `EXAMPLE_PORT`) and may be either a bare port or a `serve -l` endpoint — `SERVE_PORT=tcp://127.0.0.1:5173` binds loopback only, which is the only way to stop the viewer listening on every interface. Exactly two forms are supported: `<port>` and `tcp://<host>:<port>`. `serve -l` documents two more, and both are refused by name rather than by accident: a UNIX socket (`unix:/path/to/socket.sock`) cannot be addressed by anything that consumes this container — the browser dials a URL, and the image's own serve smoke and both e2e runners curl `http://127.0.0.1:<port>` — and a Windows named pipe (`pipe:\\.\pipe\Name`) cannot exist in the linux/amd64 image that is published. The media sentinel exists ONLY in the `stream-only` bundle (its `streamTarget.json`); `usd-viewer` carries server + port only and negotiates media via SDP. The served bundle takes its target from that render ALONE: a `?server=`/`?port=`/`?media=` query string is a `npm run dev` convenience and is ignored by built bundles, so a link cannot repoint a running viewer at another host.

Ports (`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`) are delivered via the `.env` mechanism (the `[environment]` table / `setup.conf`), not via `host.yaml` and not via hardcoded `-e`. `config/host.yaml` carries `public_ip` (and optionally `viewer.ui_mode`) only. Precedence: `public_ip` / `ui_mode` -> `host.yaml` > env > default; ports -> `.env`. See `config/host.yaml.example`. Both keys are read from THEIR OWN SECTION only (`network.public_ip`, `viewer.ui_mode`), because that file is by design shared with the other containers on the host — a key in someone else's section is left alone. A key written at column 0, outside any section, is not read either — and the two keys part company there. A column-0 `public_ip:` makes the entrypoint REFUSE to start, naming the section the key belongs in: a missing `network:` section is anomalous, because that section is the reason the file is read at all, and ignoring the key would mean booting on env/defaults against an address nobody chose. A column-0 `ui_mode:` is REPORTED on stderr and ignored: a missing `viewer:` section is the normal state (the mode usually arrives via `VIEWER_UI_MODE`), so refusing there would stop a properly configured viewer from booting over a key another container owns — and nothing in the file distinguishes "meant for us, mis-shaped" from "someone else's key". That line names the ignored key, the mode actually in effect, and where it came from.

## Multi-instance

The viewer is a sidecar: an independently-embeddable unit with one client per instance. To show many streams on one page, embed the viewer N times — each instance runs its own viewer, connects to its own Kit instance, and gets its own ports delivered via `.env`. A consumer dashboard, for example, is N `<iframe>`s, each pointed at a different instance with one connection each. It does not multiplex multiple clients onto one Kit instance, and it does not split a single stream into multiple viewpoints (that is produced on the Kit side).

Per-instance port delivery rides the `.env` mechanism: each instance's `SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT` come from that instance's `.env` file (e.g. `config/instances/<name>.env`), so each viewer targets its own ports deterministically.

## Compatibility

| Kit application | Version | Works? |
|-----------------|---------|--------|
| Isaac Sim | 5.1.0+ | Yes |
| USD Composer | Kit 107.3.1+ | Yes |
| USD Viewer (kit-app-template) | Kit 107.3.1+ | Yes (originally designed for this) |
| Any custom Kit app with NVCF livestream | Kit 107.3.1+ | Yes |

## Known limitations (Isaac Sim 5.1.0)

- One interactive client per Kit instance (second connection rejected)
- Firefox incompatible — must use Chrome/Chromium

## Examples

- Embeddable stream demo site -- [`examples/embedded-site-demo/`](examples/embedded-site-demo/README.md)

## Troubleshooting

- **Blank screen, no error** — usually a UI-mode / Kit-app mismatch. `usd-viewer` mode only works with the kit-app-template USD Viewer; against Isaac Sim or another Kit app the readiness poll never completes and nothing renders, with no error shown. Switch to `stream-only` (`VIEWER_UI_MODE=stream-only`, or `viewer.ui_mode` in `host.yaml`).
- **Connection refused / stream never appears** — check `SIGNALING_SERVER` / `SIGNALING_PORT` point at the running Kit app, and that the Kit app has NVCF livestream enabled. For remote browsers set `network.public_ip` in `host.yaml`. In `stream-only` the readout reads `connecting to <server>:<port>...` while the viewer is trying — it never claims a working stream, because until a frame renders there is nothing to claim — and if no picture has arrived after about 20 seconds it becomes `no video from the source -- it never started. Check that it is running, then reload.` If the producer comes up later, that message clears itself the moment real frames arrive: the viewer keeps retrying session start in the background, and a rendered frame outranks the viewer's own earlier verdict — so for that case no reload is needed.
- **Picture freezes mid-session, with `stream stopped -- waiting for frames to resume...` or `stream ended -- the source is gone`** (`stream-only` only) — the Kit producer went away after the stream had started. The viewer notices either from the streaming library or, if the library stays silent, from the picture itself: about 5 seconds with no new frame is enough. The first message means the viewer is waiting to see whether the picture comes back; nothing is reconnecting on your behalf, so if no frame renders within about 15 seconds it escalates to the second, terminal message. Reloading once the Kit app is back is normally what gets you a new stream; but if frames do start arriving again by any route, that message clears itself rather than sitting on top of a working picture. Check the Kit process on the streaming host.
- **Container exits immediately at startup** — the entrypoint validates config before rendering and rejects an invalid value with an error message instead of booting a broken viewer. Rejected: a `SIGNALING_PORT` or `MEDIA_PORT` that is not an integer 1..65535 written without a leading zero — `80x`, `0`, `99999` and `049100` all fail; a `SERVE_PORT` that is neither such an integer nor a `tcp://<host>:<port>` endpoint whose port half passes the same rule (the two other `serve -l` forms, `unix:` and `pipe:`, are refused by name); an unknown `VIEWER_UI_MODE`, or a `SIGNALING_SERVER` with illegal characters (including a stray inline `#` comment on a `host.yaml` value), a `host.yaml` that exists but cannot be read, or a `host.yaml` that puts `public_ip` outside the `network:` section it is read from — that last one is refused rather than ignored, because ignoring it means booting on env/defaults and dialling an address nobody chose. A misplaced `ui_mode:` does NOT exit: it is reported on stderr and the viewer boots on the mode that is actually in effect. Fix the reported env / `host.yaml` value.
- **Open the browser console** (F12) — WebRTC connection errors are logged there.

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.

On top of the per-PR gates, a nightly `tier-b-visual-e2e` job on a self-hosted GPU runner boots a real Kit producer and asserts in a headless browser that the `stream-only` viewer really renders a picture — a connected `RTCPeerConnection`, a remote track, `videoWidth > 0` and a sampled frame that is not black — so "there is a picture" is proven by CI instead of by someone looking at the page.

That job is also the release gate: no version publishes without it passing on the commit being released, with no override and no `continue-on-error`, so an unavailable GPU runner blocks the release. That wiring is itself under test — `release_gate_workflow.bats` reads `.github/workflows/main.yaml` and fails when any of the gate's `if:` / `needs:` structure is removed, and it proves each assertion can fail by re-running the checker against a workflow copy with that one property deleted. That check reads job level, step level and a set of publishing jobs derived from the file rather than a list of names; for the two jobs whose work IS one named driver (`tier-b-visual-e2e`, `verify-tag-shape`) it asserts that exact command runs, unconditionally, with nothing else in the job invoking the same script in another spelling — because a gate job that runs but does nothing still reports `success`, and that is all a `needs:` can see. It reads the workflow as YAML rather than pattern-matching its text (`script/ci/check_release_gates.py` parses `.github/workflows/main.yaml` with a real parser, after a reviewer walked two earlier text-matching versions past their own assertions), and it compares expressions case-INSENSITIVELY, after `if: ALWAYS()` walked a case-sensitive version past the entire invariant. It is deliberately a narrow gate; the canonical list of what it cannot see is the header of `script/ci/check_release_gates.py`, kept there in one place instead of restated here. The one limit worth repeating in a README is not about the checker at all: branch protection and required status checks are repo settings, and nothing in this repo checks them.

The same job also runs on **every tag push**, and both the GitHub Release and the GHCR image are gated on it: no version is published unless the picture was verified for that exact commit. There is deliberately no override — if the GPU runner is unavailable, the release is blocked rather than published unverified.

On a GPU host you can run the same acceptance locally:

```bash
just build -t e2e-test               # viewer + browser in one image
bash script/ci/tier_b_visual_e2e.sh  # boots the producer, drives the browser
```

It uses instance-scoped container names and probed-free ports, so it will not disturb a dev or demo stack running on the same host.

## License

[Apache-2.0](LICENSE)
