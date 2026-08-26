# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

一個自包含的範例網站，直接將即時的 Isaac Sim / Kit 串流嵌入到「真實網站」頁面中。它同時是一個 **showcase**（含 header + layout 與即時串流面板），也是一份 **developer reference**（乾淨、可直接複製貼上的整合程式碼）。

與主檢視器不同，此範例是純 **vanilla TypeScript + Vite**，只有 **兩個 runtime dependency** -- `stream-core`（共用的連線核心，npm workspace 的 sibling package）與 `@nvidia/omniverse-webrtc-streaming-library`。沒有 React、沒有 bootstrap、沒有選擇畫面：它採用 stream-only 的直接連線。

## 檔案結構

| 檔案 | 角色 |
|------|------|
| `index.html` | 網站外框（header / nav / hero）+ 串流面板（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM + library 接合：解析 target、連線、呈現狀態。 |
| `src/resolveTarget.js` | 純粹、不依賴 DOM 的 target 解析：以 build-time 代入的 sentinel 為底，可用 `?server=&port=&media=` 覆蓋。 |
| `test/resolveTarget.test.js` | resolver 的 `node --test` unit tests。 |
| `src/streamTarget.json` | build-time 的 `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` placeholder。 |

DIRECT config factory 本身**不在**這個範例裡：`buildStreamConfig` 住在 `stream-core` workspace package，與主檢視器共用，本地副本已刪除。

## 執行（容器）

此範例是一個 Docker `example` stage，會在 `EXAMPLE_PORT`（8080）上提供已建置好的網站，與主檢視器（5173）分開 -- 兩者可同時執行。你要開啟的**頁面**是 `http://<host>:8080`。`SIGNALING_SERVER` / `SIGNALING_PORT`（預設 `49100`）則是把頁面指向 Kit/Isaac **串流**的 signaling -- 那是頁面要連線的對象，而不是你直接開啟的 URL。

先建置 image，接著以 host networking 執行它，並指向一個執行中的串流（`SIGNALING_SERVER` 是執行 Kit/Isaac 串流的主機）：

```bash
just build -t example
just run -t example -d
# then open http://<host-ip>:8080
```

entrypoint 會在每次啟動時，從 `SIGNALING_SERVER` / `SIGNALING_PORT` / `MEDIA_PORT`（env）或 `/etc/host.yaml`（`network.public_ip`）代入 `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` 到已建置好的 bundle 中。`just run` 是從產生出來的 `.env` 讀這些值 -- 請改 `setup.conf` 的 `[environment]`，再跑一次 `./script/setup.sh apply`。

若只想針對單次執行指定目標、不動上述兩者，就直接啟動容器（`just run` 在 detached 模式下不會轉發 `-e`）：

```bash
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
```

## 執行（開發模式）

```bash
npm install
npm run dev        # http://localhost:8080
```

開發模式下沒有 entrypoint，因此 placeholder 不會被代入 -- 請以 query string 傳入 target：

```
http://localhost:8080/?server=<host-ip>&port=49100
```

## 整合到你自己的頁面

整個整合只有三個步驟（見 `src/main.ts`）：

```ts
import { buildStreamConfig, connectStream } from 'stream-core';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
connectStream(streamConfig, { onStart: () => console.info('connecting...') });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe 替代方案

如果你不想把串流 library 打包進自己的應用程式，可以改用 `<iframe>` 嵌入主檢視器：

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

被嵌入的那個 viewer 必須以 **`VIEWER_UI_MODE=stream-only`**（或 `host.yaml` 的 `viewer.ui_mode`）執行，iframe 才會直接進入串流。預設模式是互動式的 `usd-viewer`，它會顯示 landing／「UI Option」選擇畫面，而且對 Isaac 系列的 Kit app 會依設計顯示空白（#18）。本節原本提到的 `VIEWER_AUTO_LAUNCH` 已被完全移除（BREAKING，D7）；現在改以 `VIEWER_UI_MODE=stream-only` 選擇直接進入純串流。

此範例採用的 direct-connect 方式讓你能完全掌控 layout 與生命週期；iframe 則是零程式碼的選項。

## 測試 / lint

```bash
npm test           # node --test (resolveTarget unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
