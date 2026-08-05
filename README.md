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

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SIGNALING_SERVER` | `127.0.0.1` | Host IP for WebRTC signaling |
| `SIGNALING_PORT` | `49100` | WebRTC signaling port (must match Kit app's `--/app/livestream/port`) |
| `MEDIA_PORT` | null (negotiate) | WebRTC media port — unset negotiates via SDP, set pins it (D1, `stream-only` app only) |
| `SERVE_PORT` | `5173` | Port the static file server listens on |
| `VIEWER_UI_MODE` | `usd-viewer` | App selector: `usd-viewer` (upstream sample, interactive) or `stream-only` (our full-screen auto-connect app, for Isaac Sim / headless consumers) |

`VIEWER_UI_MODE` selects which app the entrypoint serves; it is not asset-injected. `SIGNALING_SERVER`, `SIGNALING_PORT`, and `MEDIA_PORT` are the injected sentinels: the build preserves each sentinel-bearing chunk as a `*.js.tmpl`, and the entrypoint re-renders `*.js.tmpl -> *.js` on every boot (idempotent — a restart or changed value is picked up next start). Validation is the escaping: an invalid value (illegal-character `SIGNALING_SERVER`, non-numeric port) fails the container (`exit 1`) rather than baking malformed JS. The media sentinel exists ONLY in the `stream-only` bundle (its `streamTarget.json`); `usd-viewer` carries server + port only and negotiates media via SDP.

Ports (`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`) are delivered via the `.env` mechanism (the `[environment]` table / `setup.conf`), not via `host.yaml` and not via hardcoded `-e`. `config/host.yaml` carries `public_ip` (and optionally `viewer.ui_mode`) only. Precedence: `public_ip` / `ui_mode` -> `host.yaml` > env > default; ports -> `.env`. See `config/host.yaml.example`.

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
- **Connection refused / stream never appears** — check `SIGNALING_SERVER` / `SIGNALING_PORT` point at the running Kit app, and that the Kit app has NVCF livestream enabled. For remote browsers set `network.public_ip` in `host.yaml`.
- **Picture freezes mid-session, with `stream stopped -- waiting for frames to resume...` or `stream ended -- the source is gone`** (`stream-only` only) — the Kit producer went away after the stream had started. The first message means the viewer is waiting to see whether the picture comes back; nothing is reconnecting on your behalf, so if no frame renders within about 15 seconds it escalates to the second, terminal message and you must reload the page once the Kit app is back. Check the Kit process on the streaming host.
- **Container exits immediately at startup** — the entrypoint validates config before rendering; an invalid value (non-numeric `SIGNALING_PORT` / `MEDIA_PORT`, unknown `VIEWER_UI_MODE`, or a `SIGNALING_SERVER` with illegal characters, including a stray inline `#` comment on a `host.yaml` value) is rejected with an error message instead of booting a broken viewer. Fix the reported env / `host.yaml` value.
- **Open the browser console** (F12) — WebRTC connection errors are logged there.

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.

## License

[Apache-2.0](LICENSE)
