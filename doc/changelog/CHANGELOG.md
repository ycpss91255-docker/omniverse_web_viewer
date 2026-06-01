# Changelog

## [Unreleased]

### Added
- Configurable UI mode and auto-launch (closes #14). A `viewer` config (`ui_mode`, `auto_launch`) lets the client default into `stream-only` and skip the "UI Option" selection screen — needed for Isaac Sim / non-USD-Viewer Kit apps. Org-owned `overlay/` files (`App.tsx`, `stream.config.json`) are layered onto the upstream sample at build time (the `src` submodule is read-only); the entrypoint resolves the values into the built JS with precedence host.yaml `viewer:` > `VIEWER_*` env > built-in default. Documented in `config/host.yaml.example`. Defaults (`usd-viewer` / `false`) keep the stock selection-screen behavior.
- Entrypoint reads `/etc/host.yaml` (when mounted) for `network.public_ip` → overrides `SIGNALING_SERVER`. Single source of truth across containers reading the same yaml (closes #11, aligns with ycpss91255-docker/isaac#65). Precedence: yaml > env var > `127.0.0.1` default.
- `serve` Dockerfile stage — profile-gated extras stage for detached server use. Base template auto-emits with `tty: false` / `stdin_open: false`, avoiding the `/dev/pts` permission error that the `devel` service's `tty: true` triggers under `privileged: false`. Usage: `make run -- -t serve -d` (closes #9).

### Fixed
- `setup.conf [gui] mode = off` — disable auto GUI detection. Web-viewer is a static file server with no display needed; auto mode triggered X11 mounts + `tty: true` that caused `/dev/pts` permission errors on hosts with active X11 sessions (closes #7).

### Changed
- Docs: updated the Isaac Sim stage reference in README x4 (`headless-stream` -> `stream`), tracking the rename in `ycpss91255-docker/isaac` (ADR-0014 in `ycpss91255-research/isaac`). Example reference only; no behavior change.
- `SIGNALING_SERVER`, `SIGNALING_PORT`, `SERVE_PORT` are now runtime environment variables instead of build args. Entrypoint replaces placeholders in built JS at container startup — one image build supports multiple instances with different ports (#4).
- CI: `build-worker.yaml` pinned `v0.34.1` → `v0.38.0`, added `submodules: recursive` so `src/` submodule is initialized during checkout (fixes CI build failure since repo creation).

### Added
- Initial release
- `setup.conf`: `gpu_mode=off`, `privileged=false`, no device mounts. Web-viewer is a static file server with no GPU requirement.
