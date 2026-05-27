# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

基於瀏覽器的 WebRTC 檢視器 sidecar，用於 Omniverse Kit 串流應用程式（Isaac Sim、USD Viewer 等）。將 NVIDIA 的 [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 封裝為基於 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 建置的 Docker 映像檔。

## 運作原理

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (此容器 — 靜態 React 應用程式)
  -> ws://<host-ip>:<SIGNALING_PORT>     (瀏覽器 JS -> Isaac Sim WebRTC 信令)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC 媒體串流)
  -> Omniverse Kit streaming app         (例如 Isaac Sim headless-stream)
```

檢視器是由 `serve` 提供的靜態 React 應用程式。瀏覽器 JS 直接連線至 Kit 應用程式的 WebRTC 信令/媒體埠。此容器不需要 GPU。

## 前置需求

- 已啟用 NVCF livestream 的 Omniverse Kit 應用程式（例如 Isaac Sim `headless-stream` 階段）
- Chrome 或 Chromium（Firefox 與 Omniverse WebRTC 不相容）
- Docker

## 快速開始

```bash
# 1. 建置（僅需一次）
make build

# 2. 執行（預設：127.0.0.1:49100，serve 監聽 5173）
make run -- -d

# 3. 開啟 Chrome -> http://<host-ip>:5173
#    選擇 "UI for any streaming app" -> Next
```

若要覆寫預設的主機 IP 或連接埠，請編輯 `config/docker/setup.conf`：

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
```

然後執行 `./script/setup.sh apply` 以重新產生 `compose.yaml`。

## 環境變數

| 變數 | 預設值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主機 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令埠（必須與 Kit 應用程式的 `--/app/livestream/port` 一致） |
| `SERVE_PORT` | `5173` | 靜態檔案伺服器監聽的連接埠 |

三個變數皆在容器啟動時透過 entrypoint 注入，變更數值時無需重新建置。

## 多實例部署

一次建置，以不同連接埠啟動多個容器：

```bash
make build  # 僅需一次

# 實例 A
docker run --rm -d --name owv-a --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49100 \
  -e SERVE_PORT=5173 \
  omniverse_web_viewer:devel

# 實例 B
docker run --rm -d --name owv-b --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49200 \
  -e SERVE_PORT=5174 \
  omniverse_web_viewer:devel
```

## 相容性

| Kit 應用程式 | 版本 | 是否支援？ |
|-------------|------|-----------|
| Isaac Sim | 5.1.0+ | 是 |
| USD Composer | Kit 107.3.1+ | 是 |
| USD Viewer (kit-app-template) | Kit 107.3.1+ | 是（原始設計對象） |
| 任何啟用 NVCF livestream 的自訂 Kit 應用程式 | Kit 107.3.1+ | 是 |

## 已知限制（Isaac Sim 5.1.0）

- 每個 Kit 實例僅支援一個互動式客戶端（第二個連線會被拒絕）
- Firefox 不相容，必須使用 Chrome/Chromium

## 冒煙測試

詳見 [TEST.md](test/TEST.md)。

## 授權條款

[Apache-2.0](../LICENSE)
