# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

一个自包含的示例站点，将实时的 Isaac Sim / Kit 串流直接嵌入到一个“真实网站”页面中。它既是一个**展示范例**（带 header + 布局以及实时串流面板），也是一份**开发者参考**（干净、可直接复制粘贴的集成代码）。

与主查看器不同，本示例是纯 **vanilla TypeScript + Vite**，只有**两个运行时依赖** -- `stream-core`（共用的连接内核，npm workspace 的 sibling package）与 `@nvidia/omniverse-webrtc-streaming-library`。没有 React、没有 bootstrap、没有选择界面：它执行的是纯串流的直接连接。

## 布局

| File | Role |
|------|------|
| `index.html` | 站点框架（header / nav / hero）+ 串流面板（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM 与 library 的胶水代码：解析目标、连接、呈现状态。 |
| `src/resolveTarget.js` | 纯粹、无 DOM 依赖的目标解析：以构建期代入的 sentinel 为底，可用 `?server=&port=&media=` 覆盖。 |
| `test/resolveTarget.test.js` | resolver 的 `node --test` 单元测试。 |
| `src/streamTarget.json` | 构建期的 `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` 占位符。 |

DIRECT 配置工厂本身**不在**本示例中：`buildStreamConfig` 位于 `stream-core` workspace package，与主查看器共用，本地副本已删除。

## 运行（容器）

本示例是一个 Docker `example` stage，它将构建好的站点托管在 `EXAMPLE_PORT`（8080）上，与主查看器（5173）相互独立 -- 两者可以同时运行。你在 `http://<host>:8080` 打开的是**页面**。`SIGNALING_SERVER` / `SIGNALING_PORT`（默认 `49100`）则用于把页面指向 Kit/Isaac **串流**的 signaling -- 这是页面所连接的对象，而不是你要打开的 URL。

先构建镜像，然后用 host networking 运行它，并将其指向一个正在运行的串流（`SIGNALING_SERVER` 是运行 Kit/Isaac 串流的主机）：

```bash
make build -- -t example
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
# then open http://<host-ip>:8080
```

entrypoint 会在每次启动时，从 `SIGNALING_SERVER` / `SIGNALING_PORT`（env）或 `/etc/host.yaml`（`network.public_ip`）将 `__OWV_SERVER__` / `__OWV_PORT__` 替换进构建好的 bundle 中。

> 注意：`make run -- -t example -d` 目前还无法使用 -- `example`（以及 `serve`）compose service 从 `devel` 继承了 `/dev:/dev` 设备挂载，启动时会因 `/dev/pts` 错误而失败（追踪于 #26）。在修复之前，请使用上面的 `docker run` 写法。（`make run` 在 detached 模式下也不会转发 `-e` 环境变量。）

## 运行（开发模式）

```bash
npm install
npm run dev        # http://localhost:8080
```

开发模式下没有 entrypoint，因此占位符不会被替换 -- 请通过 query string 传入目标：

```
http://localhost:8080/?server=<host-ip>&port=49100
```

## 在你自己的页面中集成

整个集成只需三步（参见 `src/main.ts`）：

```ts
import { buildStreamConfig, connectStream } from 'stream-core';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
connectStream(streamConfig, { onStart: () => console.info('connecting...') });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe 替代方案

如果你不想把串流 library 打包进自己的应用，可以改用 `<iframe>` 嵌入主查看器。启用 auto-launch（#14）后，它会直接启动进入串流，没有选择界面：

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

本示例采用的直接连接方式可让你完全掌控布局与生命周期；iframe 则是零代码的方案。

## 测试 / lint

```bash
npm test           # node --test (resolveTarget unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
