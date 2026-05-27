# TEST.md

**6 tests** total.

## test/smoke/omniverse_web_viewer_env.bats (6)

| Test | Description |
|------|-------------|
| `entrypoint.sh exists and is executable` | Entrypoint check |
| `bash is available on PATH` | Shell availability |
| `SIGNALING_SERVER env defaults to 127.0.0.1` | Runtime env default |
| `SIGNALING_PORT env defaults to 49100` | Runtime env default |
| `SERVE_PORT env defaults to 5173` | Runtime env default |
| `built JS contains OWV placeholders` | Build-time placeholder verification |
