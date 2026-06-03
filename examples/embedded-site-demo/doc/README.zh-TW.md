# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

一個自包含的範例網站，直接將即時的 Isaac Sim / Kit 串流嵌入到「真實網站」頁面中。它同時是一個 **showcase**（含 header + layout 與即時串流面板），也是一份 **developer reference**（乾淨、可直接複製貼上的整合程式碼）。

與主檢視器不同，此範例是純 **vanilla TypeScript + Vite**，只有 **一個 runtime dependency** -- `@nvidia/omniverse-webrtc-streaming-library`。沒有 React、沒有 bootstrap、沒有選擇畫面：它採用 stream-only 的直接連線。

## 檔案結構

| 檔案 | 角色 |
|------|------|
| `index.html` | 網站外框（header / nav / hero）+ 串流面板（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM + library 接合：解析 target、連線、呈現狀態。 |
| `src/buildStreamConfig.js` | 純粹、不依賴 DOM 的 DIRECT 串流設定 factory。已驗證並有 unit test。 |
| `src/buildStreamConfig.test.js` | factory 的 `node --test` unit tests。 |
| `src/streamTarget.json` | build-time 的 `__OWV_SERVER__` / `__OWV_PORT__` placeholder。 |

## 執行（容器）

此範例以 profile-gated 的 Docker stage 形式發布，使用 `EXAMPLE_PORT`（8080），與主檢視器（5173）分開 -- 兩者可同時執行。

```bash
make run -- -t example -d
# open http://<host>:8080
```

指向執行中串流的方式與主檢視器相同：entrypoint 會在每次啟動時，從 `SIGNALING_SERVER` / `SIGNALING_PORT`（env）或 `/etc/host.yaml`（`network.public_ip`）代入 `__OWV_SERVER__` / `__OWV_PORT__`。

```bash
make run -- -t example -d -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100
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
import { AppStreamer, StreamType } from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
AppStreamer.connect({ streamConfig, streamSource: StreamType.DIRECT });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe 替代方案

如果你不想把串流 library 打包進自己的應用程式，可以改用 `<iframe>` 嵌入主檢視器。搭配 auto-launch（#14），它會直接啟動進入串流，沒有選擇畫面：

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

此範例採用的 direct-connect 方式讓你能完全掌控 layout 與生命週期；iframe 則是零程式碼的選項。

## 測試 / lint

```bash
npm test           # node --test (buildStreamConfig unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
