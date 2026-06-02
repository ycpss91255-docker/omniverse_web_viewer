# omniverse_web_viewer

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

Browser-based WebRTC viewer sidecar for Omniverse Kit streaming applications (Isaac Sim, USD Viewer, etc.). Wraps NVIDIA's [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 into a Docker image built on [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base).

## How it works

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — static React app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim stream)
```

The viewer is a static React app served by `serve`. Browser JS connects directly to the Kit app's WebRTC signaling/media ports. No GPU needed in this container.

## Prerequisites

- An Omniverse Kit application running with NVCF livestream enabled (e.g. Isaac Sim `stream` stage)
- Chrome or Chromium (Firefox incompatible with Omniverse WebRTC)
- Docker
- Supported image architectures: `linux/amd64`, `linux/arm64`

## Quick Start

```bash
# 1. Build (one-time)
make build

# 2. Run (default: 127.0.0.1:49100, serve on 5173)
make run -- -d

# 3. Open Chrome -> http://<host-ip>:5173
#    Select "UI for any streaming app" -> Next
```

To override the default host IP or ports, edit `config/docker/setup.conf`:

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
```

Then run `./script/setup.sh apply` to regenerate `compose.yaml`.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SIGNALING_SERVER` | `127.0.0.1` | Host IP for WebRTC signaling |
| `SIGNALING_PORT` | `49100` | WebRTC signaling port (must match Kit app's `--/app/livestream/port`) |
| `SERVE_PORT` | `5173` | Port the static file server listens on |
| `VIEWER_UI_MODE` | `usd-viewer` | `usd-viewer` (full USD Viewer UI) or `stream-only` (pure video, for Isaac Sim / non-USD-Viewer Kit apps) |
| `VIEWER_AUTO_LAUNCH` | `false` | `true` skips the "UI Option" selection screen and boots straight into `VIEWER_UI_MODE` |

`SIGNALING_SERVER` / `SIGNALING_PORT` / `VIEWER_UI_MODE` / `VIEWER_AUTO_LAUNCH` are substituted into the built JS at container startup (no rebuild needed when changing values). `SERVE_PORT` is not asset-injected — it only sets the static server's listen port via the container `CMD`. `VIEWER_*` and `SIGNALING_SERVER` can also be set via `config/host.yaml` (`viewer:` / `network:`, mounted at `/etc/host.yaml`), which takes precedence; see `config/host.yaml.example`.

## Multi-instance

One build, multiple containers with different ports:

```bash
make build  # one-time

# Instance A
docker run --rm -d --name owv-a --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49100 \
  -e SERVE_PORT=5173 \
  omniverse_web_viewer:devel

# Instance B
docker run --rm -d --name owv-b --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49200 \
  -e SERVE_PORT=5174 \
  omniverse_web_viewer:devel
```

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

## Troubleshooting

- **Blank screen, no error** — usually a UI-mode / Kit-app mismatch. `usd-viewer` mode only works with the kit-app-template USD Viewer; against Isaac Sim or another Kit app the readiness poll never completes and nothing renders, with no error shown. Switch to `stream-only` (`VIEWER_UI_MODE=stream-only`, or `viewer.ui_mode` in `host.yaml`).
- **Connection refused / stream never appears** — check `SIGNALING_SERVER` / `SIGNALING_PORT` point at the running Kit app, and that the Kit app has NVCF livestream enabled. For remote browsers set `network.public_ip` in `host.yaml`.
- **Container exits immediately at startup** — the entrypoint validates config before rendering; an invalid value (non-numeric `SIGNALING_PORT`, unknown `VIEWER_UI_MODE` / `VIEWER_AUTO_LAUNCH`, or a `SIGNALING_SERVER` with illegal characters, including a stray inline `#` comment on a `host.yaml` value) is rejected with an error message instead of booting a broken viewer. Fix the reported env / `host.yaml` value.
- **Open the browser console** (F12) — WebRTC connection errors are logged there.

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.

## License

[Apache-2.0](LICENSE)
