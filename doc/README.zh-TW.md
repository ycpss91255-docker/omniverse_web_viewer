# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

通用、與 Kit 解耦的瀏覽器 WebRTC 檢視器 sidecar，用於 Omniverse Kit 串流應用程式（Isaac Sim、USD Viewer 等）。映像檔建置於 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 之上，啟動時依 `VIEWER_UI_MODE` 選擇下列兩個靜態應用程式之一來提供服務：

- **`usd-viewer`** — NVIDIA 的 [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2，未經修改建置。提供著陸畫面、完整 USD Viewer UI 以及任意應用程式串流，全部以互動方式（點擊）進入。
- **`stream-only`** — 我們自家的全螢幕自動連線應用程式，建構於 `stream-core` 套件之上。直接進入串流、無需點擊；專為 Isaac Sim 與任何無頭串流消費端設計。

映像檔僅提供靜態頁面；瀏覽器 JS 直接連線至 Kit 應用程式的 WebRTC 信令/媒體埠。此容器不需要 GPU。

## 運作原理

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — a served static app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim stream)
```

檢視器採分層設計：`stream-core` 是唯一接觸 NVIDIA 串流函式庫的程式碼；應用程式僅負責呈現；映像檔層負責提供服務與啟動時的設定注入。`VIEWER_UI_MODE` 是 serve 層級的應用程式選擇器，它決定 entrypoint 提供哪個應用程式的 `dist`，並非渲染進 bundle 內的 in-bundle UI 模式。

## 前置需求

- 已啟用 NVCF livestream 的 Omniverse Kit 應用程式（例如 Isaac Sim `stream` 階段）
- Chrome 或 Chromium（Firefox 與 Omniverse WebRTC 不相容）
- Docker
- 支援的 image 架構：`linux/amd64`、`linux/arm64`

## 快速開始

可部署的階段是精簡的 `runtime` 映像檔（僅含已建置的 dist 與 `serve`，無工具鏈）。

```bash
# 1. Build (one-time)
just build

# 2. Run the lean runtime (default: 127.0.0.1:49100, serve on 5173)
just run -t runtime -d

# 3. Open Chrome -> http://<host-ip>:5173
#    usd-viewer (default): click the landing screen to choose a view
#    stream-only: auto-connects into the full-screen stream, no click
```

若要覆寫預設的主機 IP 或連接埠，請編輯 `config/docker/setup.conf`：

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
VIEWER_UI_MODE = usd-viewer
```

然後執行 `./script/setup.sh apply` 以重新產生 `compose.yaml`。

## 環境變數

| 變數 | 預設值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主機 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令埠（必須與 Kit 應用程式的 `--/app/livestream/port` 一致） |
| `MEDIA_PORT` | null（協商） | WebRTC 媒體埠 — 未設定則透過 SDP 協商，設定則固定（D1，僅 `stream-only` 應用程式適用） |
| `SERVE_PORT` | `5173` | 靜態檔案伺服器監聽的連接埠 |
| `VIEWER_UI_MODE` | `usd-viewer` | 應用程式選擇器：`usd-viewer`（上游 sample，互動式）或 `stream-only`（我們自家的全螢幕自動連線應用程式，給 Isaac Sim / 無頭消費端） |

`VIEWER_UI_MODE` 選擇 entrypoint 提供哪個應用程式，它不會被注入到資源中。`SIGNALING_SERVER`、`SIGNALING_PORT` 與 `MEDIA_PORT` 是被注入的 sentinel：建置會將每個帶有 sentinel 的 chunk 保存為 `*.js.tmpl`，entrypoint 在每次啟動時重新渲染 `*.js.tmpl -> *.js`（具冪等性 — 重啟或數值變更會在下次啟動被採用）。驗證即是逸出處理：無效值（含非法字元的 `SIGNALING_SERVER`、非數字的埠）會讓容器失敗（`exit 1`），而非烤進壞掉的 JS。媒體 sentinel 僅存在於 `stream-only` bundle（其 `streamTarget.json`）；`usd-viewer` 僅帶 server + port，並透過 SDP 協商媒體。

連接埠（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）透過 `.env` 機制（`[environment]` 表 / `setup.conf`）遞送，而非 `host.yaml`，也非硬編的 `-e`。`config/host.yaml` 僅承載 `public_ip`（並可選擇性帶 `viewer.ui_mode`）。優先序：`public_ip` / `ui_mode` -> `host.yaml` > env > 預設；連接埠 -> `.env`。見 `config/host.yaml.example`。

## 多實例

檢視器是 sidecar：可獨立嵌入的單元，每個實例一個客戶端。若要在同一頁顯示多個串流，請將檢視器嵌入 N 次 — 每個實例執行自己的檢視器、連線至自己的 Kit 實例，並透過 `.env` 取得自己的連接埠。例如一個消費端儀表板就是 N 個 `<iframe>`，各自指向不同實例、各自一條連線。它不會將多個客戶端多工到同一個 Kit 實例上，也不會將單一串流拆成多個視角（後者由 Kit 端產生）。

每實例的連接埠遞送也走 `.env` 機制：每個實例的 `SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT` 來自該實例的 `.env` 檔（例如 `config/instances/<name>.env`），讓每個檢視器確定性地對準自己的連接埠。

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

## 範例

- 可嵌入的串流 demo 站台 — [`examples/embedded-site-demo/`](../examples/embedded-site-demo/README.md)

## 疑難排解

- **畫面空白、無錯誤訊息** — 通常是 UI 模式與 Kit 應用程式不匹配。`usd-viewer` 模式僅適用於 kit-app-template 的 USD Viewer；對 Isaac Sim 或其他 Kit 應用程式而言，就緒輪詢永遠不會完成，畫面不會渲染任何內容，也不會顯示錯誤。請切換為 `stream-only`（`VIEWER_UI_MODE=stream-only`，或 `host.yaml` 中的 `viewer.ui_mode`）。
- **連線被拒 / 串流始終未出現** — 檢查 `SIGNALING_SERVER` / `SIGNALING_PORT` 是否指向正在執行的 Kit 應用程式，且該 Kit 應用程式已啟用 NVCF livestream。若是遠端瀏覽器，請在 `host.yaml` 中設定 `network.public_ip`。
- **串流中途畫面凍結，並顯示 `stream stopped -- reconnecting...` 或 `stream ended -- the source is gone`**（僅 `stream-only`） — 串流開始後 Kit 生產端消失了。前者表示檢視器仍在重試；後者表示已放棄重連，待 Kit 應用程式恢復後請重新整理頁面。請檢查串流主機上的 Kit 程序。
- **容器啟動後立即結束** — entrypoint 在渲染前會驗證設定；無效值（非數字的 `SIGNALING_PORT` / `MEDIA_PORT`、未知的 `VIEWER_UI_MODE`、或含非法字元的 `SIGNALING_SERVER`，包含 `host.yaml` 值尾端誤帶的行內 `#` 註解）會被拒絕並印出錯誤訊息，而非啟動一個壞掉的檢視器。請依錯誤訊息修正對應的環境變數 / `host.yaml` 值。
- **開啟瀏覽器主控台**（F12） — WebRTC 連線錯誤會記錄在那裡。

## 冒煙測試

詳見 [TEST.md](test/TEST.md)。

## 授權條款

[Apache-2.0](../LICENSE)
