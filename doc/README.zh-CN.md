# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

基于浏览器的 WebRTC 查看器 sidecar，用于 Omniverse Kit 串流应用程序（Isaac Sim、USD Viewer 等）。将 NVIDIA 的 [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 封装为基于 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 构建的 Docker 镜像。

## 运作原理

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (本容器 — 静态 React 应用)
  -> ws://<host-ip>:<SIGNALING_PORT>     (浏览器 JS -> Isaac Sim WebRTC 信令)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC 媒体串流)
  -> Omniverse Kit streaming app         (例如 Isaac Sim headless-stream)
```

查看器是由 `serve` 提供的静态 React 应用。浏览器 JS 直接连接到 Kit 应用的 WebRTC 信令/媒体端口。本容器不需要 GPU。

## 前置条件

- 已启用 NVCF livestream 的 Omniverse Kit 应用程序（例如 Isaac Sim `headless-stream` 阶段）
- Chrome 或 Chromium（Firefox 与 Omniverse WebRTC 不兼容）
- Docker

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

三个变量均在容器启动时通过 entrypoint 注入 — 更改值时无需重新构建。

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

## 冒烟测试

详情请参阅 [TEST.md](test/TEST.md)。

## 许可证

[Apache-2.0](../LICENSE)
