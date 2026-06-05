# embedded-site-demo

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

A self-contained example site that embeds a live Isaac Sim / Kit stream directly
into a "real website" page. It is both a **showcase** (header + layout with a
live stream panel) and a **developer reference** (clean, copy-pasteable
integration code).

Unlike the main viewer, this example is plain **vanilla TypeScript + Vite** with
**one runtime dependency** -- `@nvidia/omniverse-webrtc-streaming-library`. No
React, no bootstrap, no selection screen: it does a stream-only direct connect.

## Layout

| File | Role |
|------|------|
| `index.html` | Site chrome (header / nav / hero) + the stream panel (`<video id="remote-video">`). |
| `src/main.ts` | DOM + library glue: resolve the target, connect, surface status. |
| `src/buildStreamConfig.js` | Pure, DOM-free factory for the DIRECT stream config. Validated and unit-tested. |
| `src/buildStreamConfig.test.js` | `node --test` unit tests for the factory. |
| `src/streamTarget.json` | Build-time `__OWV_SERVER__` / `__OWV_PORT__` placeholders. |

## Run it (container)

The example is a Docker `example` stage that serves the built site on
`EXAMPLE_PORT` (8080), separate from the main viewer (5173) -- both can run at
once. You open the **page** at `http://<host>:8080`. `SIGNALING_SERVER` /
`SIGNALING_PORT` (default `49100`) point the page at the Kit/Isaac **stream's**
signaling -- that is what the page connects to, not a URL you open.

Build the image, then run it with host networking, pointing it at a running
stream (`SIGNALING_SERVER` is the host running the Kit/Isaac stream):

```bash
make build -- -t example
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
# then open http://<host-ip>:8080
```

The entrypoint substitutes `__OWV_SERVER__` / `__OWV_PORT__` from
`SIGNALING_SERVER` / `SIGNALING_PORT` (env) or `/etc/host.yaml`
(`network.public_ip`) into the built bundle on every boot.

> Note: `make run -- -t example -d` is not usable yet -- the `example` (and
> `serve`) compose service inherits a `/dev:/dev` device mount from `devel` and
> fails at start with a `/dev/pts` error (tracked in #26). Use the `docker run`
> form above until that is fixed. (`make run` also does not forward `-e` env
> vars in detached mode.)

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
import { AppStreamer, StreamType } from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
AppStreamer.connect({ streamConfig, streamSource: StreamType.DIRECT });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe alternative

If you do not want to bundle the streaming library into your own app, embed the
main viewer in an `<iframe>` instead. With auto-launch (#14) it boots straight
into the stream with no selection screen:

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

The direct-connect approach in this example gives you full control over layout
and lifecycle; the iframe is the zero-code option.

## Test / lint

```bash
npm test           # node --test (buildStreamConfig unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
