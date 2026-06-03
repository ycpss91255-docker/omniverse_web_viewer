# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

一个自包含的示例站点，将实时的 Isaac Sim / Kit 串流直接嵌入到一个“真实网站”页面中。它既是一个**展示范例**（带 header + 布局以及实时串流面板），也是一份**开发者参考**（干净、可直接复制粘贴的集成代码）。

与主查看器不同，本示例是纯 **vanilla TypeScript + Vite**，只有**一个运行时依赖** -- `@nvidia/omniverse-webrtc-streaming-library`。没有 React、没有 bootstrap、没有选择界面：它执行的是纯串流的直接连接。

## 布局

| File | Role |
|------|------|
| `index.html` | 站点框架（header / nav / hero）+ 串流面板（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM 与 library 的胶水代码：解析目标、连接、呈现状态。 |
| `src/buildStreamConfig.js` | 纯粹、无 DOM 依赖的 DIRECT 串流配置工厂函数。已通过校验与单元测试。 |
| `src/buildStreamConfig.test.js` | 工厂函数的 `node --test` 单元测试。 |
| `src/streamTarget.json` | 构建期的 `__OWV_SERVER__` / `__OWV_PORT__` 占位符。 |

## 运行（容器）

本示例以一个受 profile 控制的 Docker stage 形式发布，监听 `EXAMPLE_PORT`（8080），与主查看器（5173）相互独立 -- 两者可以同时运行。

```bash
make run -- -t example -d
# open http://<host>:8080
```

与主查看器一样指向一个正在运行的串流：entrypoint 会在每次启动时，从 `SIGNALING_SERVER` / `SIGNALING_PORT`（env）或 `/etc/host.yaml`（`network.public_ip`）替换 `__OWV_SERVER__` / `__OWV_PORT__`。

```bash
make run -- -t example -d -e SIGNALING_SERVER=10.2.23.83 -e SIGNALING_PORT=49100
```

## 运行（开发模式）

```bash
npm install
npm run dev        # http://localhost:8080
```

开发模式下没有 entrypoint，因此占位符不会被替换 -- 请通过 query string 传入目标：

```
http://localhost:8080/?server=10.2.23.83&port=49100
```

## 在你自己的页面中集成

整个集成只需三步（参见 `src/main.ts`）：

```ts
import { AppStreamer, StreamType } from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';

const streamConfig = buildStreamConfig('10.2.23.83', 49100); // validates + returns a DIRECT config
AppStreamer.connect({ streamConfig, streamSource: StreamType.DIRECT });
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
npm test           # node --test (buildStreamConfig unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
