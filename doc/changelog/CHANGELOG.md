# Changelog

## [Unreleased]

### Changed
- `SIGNALING_SERVER`, `SIGNALING_PORT`, `SERVE_PORT` are now runtime environment variables instead of build args. Entrypoint replaces placeholders in built JS at container startup — one image build supports multiple instances with different ports (#4).
- CI: `build-worker.yaml` pinned `v0.34.1` → `v0.38.0`, added `submodules: recursive` so `src/` submodule is initialized during checkout (fixes CI build failure since repo creation).

### Added
- Initial release
- `setup.conf`: `gpu_mode=off`, `privileged=false`, no device mounts. Web-viewer is a static file server with no GPU requirement.
