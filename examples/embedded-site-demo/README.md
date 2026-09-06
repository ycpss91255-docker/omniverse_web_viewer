# embedded-site-demo

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

A self-contained example site that embeds a live Isaac Sim / Kit stream directly
into a "real website" page. It is both a **showcase** (header + layout with a
live stream panel) and a **developer reference** (clean, copy-pasteable
integration code).

Unlike the main viewer, this example is plain **vanilla TypeScript + Vite** with
**two runtime dependencies** -- `stream-core` (the shared connect kernel, an npm
workspace sibling) and `@nvidia/omniverse-webrtc-streaming-library`. No React, no
bootstrap, no selection screen: it does a stream-only direct connect.

## Layout

| File | Role |
|------|------|
| `index.html` | Site chrome (header / nav / hero) + the stream panel (`<video id="remote-video">`). |
| `src/main.ts` | DOM + library glue: resolve the target, connect, surface status. |
| `src/resolveTarget.js` | Pure, DOM-free target resolution: the baked sentinels, with a `?server=&port=&media=` override the caller must opt into -- `main.ts` opts in only under the Vite dev server, so built bundles ignore the query. |
| `test/resolveTarget.test.js` | `node --test` unit tests for the resolver. |
| `src/streamTarget.json` | Build-time `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` placeholders. |

The DIRECT-config factory itself is NOT in this example: `buildStreamConfig` lives
in the `stream-core` workspace package, shared with the main viewer, and the local
copy was deleted.

## Run it (container)

The example is a Docker `example` stage that serves the built site on
`EXAMPLE_PORT` (8080), separate from the main viewer (5173) -- both can run at
once. You open the **page** at `http://<host>:8080`. `SIGNALING_SERVER` /
`SIGNALING_PORT` (default `49100`) point the page at the Kit/Isaac **stream's**
signaling -- that is what the page connects to, not a URL you open.

Build the image, then run it with host networking, pointing it at a running
stream (`SIGNALING_SERVER` is the host running the Kit/Isaac stream):

```bash
just build -t example
just run -t example -d
# then open http://<host-ip>:8080
```

The entrypoint substitutes `__OWV_SERVER__` / `__OWV_PORT__` /
`__OWV_MEDIA_PORT__` from `SIGNALING_SERVER` / `SIGNALING_PORT` / `MEDIA_PORT`
(env) or `/etc/host.yaml` (`network.public_ip`) into the built bundle on every
boot. `just run` reads those from the generated `.env` -- set them in
`setup.conf` `[environment]` and re-run `./script/setup.sh apply`.

To point the container somewhere for a single run without touching either,
start it directly instead (`just run` does not forward `-e` in detached mode):

```bash
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
```

## Run it (dev)

```bash
npm install
npm run dev        # http://localhost:8080
```

There is no entrypoint in dev, so the placeholders are not substituted -- pass
the target as a query string:

```
http://localhost:8080/?server=<host-ip>&port=49100
```

## Integration in your own page

The whole integration is three steps (see `src/main.ts`):

```ts
import { buildStreamConfig, connectStream } from 'stream-core';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
connectStream(streamConfig, { onStart: () => console.info('connect attempt started') });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe alternative

If you do not want to bundle the streaming library into your own app, embed the
main viewer in an `<iframe>` instead:

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

Run that viewer with **`VIEWER_UI_MODE=stream-only`** (or `viewer.ui_mode` in
`host.yaml`) for the iframe to boot straight into the stream. The default mode is
the interactive `usd-viewer`, which shows its landing / "UI Option" screen and,
against an Isaac-family Kit app, blanks by design (#18). The `VIEWER_AUTO_LAUNCH`
knob this section used to name was removed entirely (BREAKING, D7);
`VIEWER_UI_MODE=stream-only` is how auto-entry into a bare stream is selected now.

The direct-connect approach in this example gives you full control over layout
and lifecycle; the iframe is the zero-code option.

## Test / lint

```bash
npm test           # node --test (resolveTarget unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
