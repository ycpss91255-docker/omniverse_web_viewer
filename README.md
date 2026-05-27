# omniverse_web_viewer

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

Browser-based WebRTC viewer sidecar for Omniverse Kit streaming applications (Isaac Sim, USD Viewer, etc.). Wraps NVIDIA's [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 into a Docker image built on [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base).

## How it works

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — static React app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim headless-stream)
```

The viewer is a static React app served by `serve`. Browser JS connects directly to the Kit app's WebRTC signaling/media ports. No GPU needed in this container.

## Prerequisites

- An Omniverse Kit application running with NVCF livestream enabled (e.g. Isaac Sim `headless-stream` stage)
- Chrome or Chromium (Firefox incompatible with Omniverse WebRTC)
- Docker

## Quick Start

```bash
# 1. Configure host IP + ports
./script/setup.sh set build.arg_4 "SIGNALING_SERVER=<host-ip>"
./script/setup.sh set build.arg_5 "SIGNALING_PORT=49100"
./script/setup.sh set build.arg_6 "SERVE_PORT=5173"
./script/setup.sh apply

# 2. Build + run
make build
make run -- -d

# 3. Open Chrome -> http://<host-ip>:5173
#    Select "UI for any streaming app" -> Next
```

## Build args

| Arg | Default | Purpose |
|-----|---------|---------|
| `SIGNALING_SERVER` | `127.0.0.1` | Host IP for WebRTC signaling (baked into `stream.config.json` at build time) |
| `SIGNALING_PORT` | `49100` | WebRTC signaling port (must match Kit app's `--/app/livestream/port`) |
| `SERVE_PORT` | `5173` | Port the static file server listens on |

All three are baked at build time via Vite. Changing any value requires `make build`.

## Multi-instance

For monitoring multiple Isaac Sim instances, build separate images with different ports:

```bash
# Instance A: signal=49100, viewer=5173
./script/setup.sh set build.arg_4 "SIGNALING_SERVER=10.2.23.83"
./script/setup.sh set build.arg_5 "SIGNALING_PORT=49100"
./script/setup.sh set build.arg_6 "SERVE_PORT=5173"
make build
make run -- -d

# Instance B: clone the repo or use docker build directly
docker build --build-arg SIGNALING_SERVER=10.2.23.83 \
  --build-arg SIGNALING_PORT=49200 \
  --build-arg SERVE_PORT=5174 \
  -t omniverse_web_viewer:b .
docker run --rm -d --name owv-b --network=host omniverse_web_viewer:b
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
- `stream.config.json` server IP baked at build time (not runtime configurable)

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.

## License

[Apache-2.0](LICENSE)
