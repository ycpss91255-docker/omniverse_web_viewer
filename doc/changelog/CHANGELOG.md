# Changelog

## [Unreleased]

### Added
- `SIGNALING_PORT` build arg (default `49100`) — baked into `stream.config.json` at build time. Allows per-instance web-viewer to connect to different Isaac Sim signaling ports.
- `SERVE_PORT` build arg (default `5173`) — controls `serve` listen port. Allows multiple web-viewer instances on different ports.
- Initial release

### Changed
- `setup.conf`: `gpu_mode=off`, `privileged=false`, no device mounts. Web-viewer is a static file server with no GPU requirement.
