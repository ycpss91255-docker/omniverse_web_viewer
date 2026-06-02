# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

基于浏览器的 WebRTC 查看器 sidecar，用于 Omniverse Kit 串流应用程序（Isaac Sim、USD Viewer 等）。将 NVIDIA 的 [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 封装为基于 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 构建的 Docker 镜像。

## 运作原理

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (本容器 — 静态 React 应用)
  -> ws://<host-ip>:<SIGNALING_PORT>     (浏览器 JS -> Isaac Sim WebRTC 信令)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC 媒体串流)
  -> Omniverse Kit streaming app         (例如 Isaac Sim stream)
```

查看器是由 `serve` 提供的静态 React 应用。浏览器 JS 直接连接到 Kit 应用的 WebRTC 信令/媒体端口。本容器不需要 GPU。

## 前置条件

- 已启用 NVCF livestream 的 Omniverse Kit 应用程序（例如 Isaac Sim `stream` 阶段）
- Chrome 或 Chromium（Firefox 与 Omniverse WebRTC 不兼容）
- Docker
- 支持的 image 架构：`linux/amd64`、`linux/arm64`

## 快速开始

```bash
# 1. 构建（仅需一次）
make build

# 2. 运行（默认：127.0.0.1:49100，serve 监听 5173）
make run -- -d

# 3. 打开 Chrome -> http://<host-ip>:5173
#    选择 "UI for any streaming app" -> Next
```

如需覆盖默认的主机 IP 或端口，请编辑 `config/docker/setup.conf`：

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
```

然后运行 `./script/setup.sh apply` 以重新生成 `compose.yaml`。

## 环境变量

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主机 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令端口（必须与 Kit 应用的 `--/app/livestream/port` 一致） |
| `SERVE_PORT` | `5173` | 静态文件服务器监听的端口 |
| `VIEWER_UI_MODE` | `usd-viewer` | `usd-viewer`（完整 USD Viewer UI）或 `stream-only`（纯画面串流，用于 Isaac Sim / 非 USD-Viewer 的 Kit app） |
| `VIEWER_AUTO_LAUNCH` | `false` | `true` 会跳过 "UI Option" 选择界面，直接以 `VIEWER_UI_MODE` 启动 |

`SIGNALING_SERVER` / `SIGNALING_PORT` / `VIEWER_UI_MODE` / `VIEWER_AUTO_LAUNCH` 会在容器启动时替换进已构建的 JS（更改值时无需重新构建）。`SERVE_PORT` 不会注入到资源中 — 它仅通过容器 `CMD` 设置静态服务器的监听端口。`VIEWER_*` 与 `SIGNALING_SERVER` 也可通过 `config/host.yaml`（`viewer:` / `network:` 段，挂载到 `/etc/host.yaml`）设置，优先级更高；见 `config/host.yaml.example`。

## 多实例

一次构建，使用不同端口运行多个容器：

```bash
make build  # 仅需一次

# 实例 A
docker run --rm -d --name owv-a --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49100 \
  -e SERVE_PORT=5173 \
  omniverse_web_viewer:devel

# 实例 B
docker run --rm -d --name owv-b --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49200 \
  -e SERVE_PORT=5174 \
  omniverse_web_viewer:devel
```

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

## 故障排查

- **画面空白，无错误** — 通常是 UI 模式与 Kit 应用不匹配。`usd-viewer` 模式仅适用于 kit-app-template 的 USD Viewer；对接 Isaac Sim 或其他 Kit 应用时，就绪轮询永远不会完成，画面无法渲染，且不显示任何错误。请切换到 `stream-only`（`VIEWER_UI_MODE=stream-only`，或 `host.yaml` 中的 `viewer.ui_mode`）。
- **连接被拒绝 / 画面串流始终不出现** — 检查 `SIGNALING_SERVER` / `SIGNALING_PORT` 是否指向正在运行的 Kit 应用，以及该 Kit 应用是否已启用 NVCF livestream。对于远端浏览器，请在 `host.yaml` 中设置 `network.public_ip`。
- **打开浏览器控制台**（F12）— WebRTC 连接错误会记录在那里。

## 冒烟测试

详情请参阅 [TEST.md](test/TEST.md)。

## 许可证

[Apache-2.0](../LICENSE)
