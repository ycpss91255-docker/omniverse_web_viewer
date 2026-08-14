# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

通用、与 Kit 解耦的浏览器 WebRTC 查看器 sidecar，用于 Omniverse Kit 串流应用程序（Isaac Sim、USD Viewer 等）。镜像构建于 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 之上，启动时依 `VIEWER_UI_MODE` 选择下列两个静态应用之一来提供服务：

- **`usd-viewer`** — NVIDIA 的 [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2，未经修改构建。提供着陆界面、完整 USD Viewer UI 以及任意应用串流，全部以交互方式（点击）进入。
- **`stream-only`** — 我们自家的全屏自动连接应用，构建于 `stream-core` 包之上。直接进入串流、无需点击；专为 Isaac Sim 与任何无头串流消费端设计。

镜像仅提供静态页面；浏览器 JS 直接连接到 Kit 应用的 WebRTC 信令/媒体端口。本容器不需要 GPU。

## 运作原理

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — a served static app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim stream)
```

查看器采用分层设计：`stream-core` 是唯一接触 NVIDIA 串流库的代码；应用仅负责呈现；镜像层负责提供服务与启动时的配置注入。`VIEWER_UI_MODE` 是 serve 层级的应用选择器，它决定 entrypoint 提供哪个应用的 `dist`，并非渲染进 bundle 内的 in-bundle UI 模式。

## 前置条件

- 已启用 NVCF livestream 的 Omniverse Kit 应用程序（例如 Isaac Sim `stream` 阶段）
- Chrome 或 Chromium（Firefox 与 Omniverse WebRTC 不兼容）
- Docker
- 支持的 image 架构：`linux/amd64`、`linux/arm64`

## 快速开始

可部署的阶段是精简的 `runtime` 镜像（仅含已构建的 dist 与 `serve`，无工具链）。

```bash
# 1. Build (one-time)
just build

# 2. Run the lean runtime (default: 127.0.0.1:49100, serve on 5173)
just run -t runtime -d

# 3. Open Chrome -> http://<host-ip>:5173
#    usd-viewer (default): click the landing screen to choose a view
#    stream-only: auto-connects into the full-screen stream, no click
```

如需覆盖默认的主机 IP 或端口，请编辑 `config/docker/setup.conf`：

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
VIEWER_UI_MODE = usd-viewer
```

然后运行 `./script/setup.sh apply` 以重新生成 `compose.yaml`。

## 环境变量

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主机 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令端口（必须与 Kit 应用的 `--/app/livestream/port` 一致） |
| `MEDIA_PORT` | null（协商） | WebRTC 媒体端口 — 未设置则通过 SDP 协商，设置则固定（D1，仅 `stream-only` 应用适用） |
| `SERVE_PORT` | `5173` | 静态文件服务器监听的端口 |
| `VIEWER_UI_MODE` | `usd-viewer` | 应用选择器：`usd-viewer`（上游 sample，交互式）或 `stream-only`（我们自家的全屏自动连接应用，用于 Isaac Sim / 无头消费端） |

`VIEWER_UI_MODE` 选择 entrypoint 提供哪个应用，它不会被注入到资源中。`SIGNALING_SERVER`、`SIGNALING_PORT` 与 `MEDIA_PORT` 是被注入的 sentinel：构建会将每个带有 sentinel 的 chunk 保存为 `*.js.tmpl`，entrypoint 在每次启动时重新渲染 `*.js.tmpl -> *.js`（具幂等性 — 重启或值变更会在下次启动被采用）。校验即是转义处理：无效值（含非法字符的 `SIGNALING_SERVER`、非数字的端口）会让容器失败（`exit 1`），而非烤进损坏的 JS。媒体 sentinel 仅存在于 `stream-only` bundle（其 `streamTarget.json`）；`usd-viewer` 仅带 server + port，并通过 SDP 协商媒体。

端口（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）通过 `.env` 机制（`[environment]` 表 / `setup.conf`）递送，而非 `host.yaml`，也非硬编的 `-e`。`config/host.yaml` 仅承载 `public_ip`（并可选择性带 `viewer.ui_mode`）。优先级：`public_ip` / `ui_mode` -> `host.yaml` > env > 默认；端口 -> `.env`。见 `config/host.yaml.example`。

## 多实例

查看器是 sidecar：可独立嵌入的单元，每个实例一个客户端。若要在同一页显示多个串流，请将查看器嵌入 N 次 — 每个实例运行自己的查看器、连接到自己的 Kit 实例，并通过 `.env` 取得自己的端口。例如一个消费端仪表盘就是 N 个 `<iframe>`，各自指向不同实例、各自一条连接。它不会将多个客户端多路复用到同一个 Kit 实例上，也不会将单一串流拆成多个视角（后者由 Kit 端产生）。

每实例的端口递送也走 `.env` 机制：每个实例的 `SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT` 来自该实例的 `.env` 文件（例如 `config/instances/<name>.env`），让每个查看器确定性地对准自己的端口。

## 兼容性

| Kit 应用程序 | 版本 | 是否支持？ |
|-------------|------|-----------|
| Isaac Sim | 5.1.0+ | 是 |
| USD Composer | Kit 107.3.1+ | 是 |
| USD Viewer (kit-app-template) | Kit 107.3.1+ | 是（原本即为此设计） |
| 任何启用 NVCF livestream 的自定义 Kit 应用 | Kit 107.3.1+ | 是 |

## 已知限制（Isaac Sim 5.1.0）

- 每个 Kit 实例仅支持一个交互式客户端（第二个连接将被拒绝）
- Firefox 不兼容 — 必须使用 Chrome/Chromium

## 示例

- 可嵌入的串流 demo 站台 — [`examples/embedded-site-demo/`](../examples/embedded-site-demo/README.md)

## 故障排查

- **画面空白，无错误** — 通常是 UI 模式与 Kit 应用不匹配。`usd-viewer` 模式仅适用于 kit-app-template 的 USD Viewer；对接 Isaac Sim 或其他 Kit 应用时，就绪轮询永远不会完成，画面无法渲染，且不显示任何错误。请切换到 `stream-only`（`VIEWER_UI_MODE=stream-only`，或 `host.yaml` 中的 `viewer.ui_mode`）。
- **连接被拒绝 / 画面串流始终不出现** — 检查 `SIGNALING_SERVER` / `SIGNALING_PORT` 是否指向正在运行的 Kit 应用，以及该 Kit 应用是否已启用 NVCF livestream。对于远端浏览器，请在 `host.yaml` 中设置 `network.public_ip`。在 `stream-only` 模式下，查看器尝试连接期间显示 `connecting to <server>:<port>...` — 它不会声称串流已经成功，因为在第一帧渲染出来之前根本无从得知；若约 20 秒后仍没有画面，消息会变成 `no video from the source -- it never started. Check that it is running, then reload.`
- **画面在会话中途冻结，并显示 `stream stopped -- waiting for frames to resume...` 或 `stream ended -- the source is gone`**（仅 `stream-only`）— 串流开始后 Kit 生产端消失了。查看器会从串流库得知，若串流库没有任何通知，也会直接从画面本身判断：约 5 秒没有新帧就足以判定。前者表示查看器正在等待画面是否恢复；系统不会自动替你重新连接，若约 15 秒内没有新帧，将升级为后者的终止消息，待 Kit 应用恢复后必须刷新页面。请检查串流主机上的 Kit 进程。
- **容器启动后立即退出** — entrypoint 在渲染前会校验配置；无效值（非数字的 `SIGNALING_PORT` / `MEDIA_PORT`、未知的 `VIEWER_UI_MODE`、或含非法字符的 `SIGNALING_SERVER`，包括 `host.yaml` 值末尾误带的行内 `#` 注释）会被拒绝并打印错误信息，而不是启动一个损坏的查看器。请根据错误信息修正对应的环境变量 / `host.yaml` 值。
- **打开浏览器控制台**（F12）— WebRTC 连接错误会记录在那里。

## 冒烟测试

详情请参阅 [TEST.md](test/TEST.md)。

## 许可证

[Apache-2.0](../LICENSE)
