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

## 發佈的映像檔

每個 git tag 都會在同一次 CI run、以同一個 commit，同時發佈 GitHub Release **與**對應的容器映像檔，兩者永遠成對存在 — 拿到映像檔可以回推它的 release，拿到 release 也找得到它的映像檔：

```
ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

映像檔的 tag 就是 release 版號去掉開頭的 `v`。這個值由 CI 從 git tag 推導而來，不是人工填寫，release 與映像檔因此不可能對不上：

| Git tag | 映像檔 |
|---------|--------|
| `v0.3.0` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0` |
| `v0.3.0-rc1` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0-rc1` |

Release candidate 同樣會發佈：正式 tag 出來之前，真正被驗證的就是 rc。

發佈**只在 tag 時發生**（外加維護者手動觸發的重新發佈管道）。Pull request 或 `main` push 都不會發佈任何東西。刻意不提供 `:latest`：請釘住版號，才不會被之後的 release 或某個 rc 悄悄換掉正在跑的東西。

發佈的是精簡的 `runtime` stage，架構為 `linux/amd64`（CI 唯一會建置並把關的平台）。其他架構請用 `just build` 在本機自行建置。

```bash
docker run --rm -d --name owv \
  -e SIGNALING_SERVER=<host-ip> \
  -e SIGNALING_PORT=49100 \
  -e VIEWER_UI_MODE=stream-only \
  -p 5173:5173 \
  ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

接著用 Chrome 開啟 `http://<host-ip>:5173`。可調參數即下方環境變數表所列。

## 環境變數

| 變數 | 預設值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主機 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令埠（必須與 Kit 應用程式的 `--/app/livestream/port` 一致） |
| `MEDIA_PORT` | null（協商） | WebRTC 媒體埠 — 未設定則透過 SDP 協商，設定則固定（D1，僅 `stream-only` 應用程式適用） |
| `SERVE_PORT` | `5173` | 靜態檔案伺服器監聽的連接埠 |
| `VIEWER_UI_MODE` | `usd-viewer` | 應用程式選擇器：`usd-viewer`（上游 sample，互動式）或 `stream-only`（我們自家的全螢幕自動連線應用程式，給 Isaac Sim / 無頭消費端） |

`VIEWER_UI_MODE` 選擇 entrypoint 提供哪個應用程式，它不會被注入到資源中。`SIGNALING_SERVER`、`SIGNALING_PORT` 與 `MEDIA_PORT` 是被注入的 sentinel：建置會將每個帶有 sentinel 的 chunk 保存為 `*.js.tmpl`，entrypoint 在每次啟動時重新渲染 `*.js.tmpl -> *.js`（具冪等性 — 重啟或數值變更會在下次啟動被採用）。驗證即是逸出處理：無效值會讓容器失敗（`exit 1`），而非烤進壞掉的 JS。會被拒絕的有：`SIGNALING_SERVER` 含 `A-Za-z0-9.-` 以外的字元；`SIGNALING_PORT`、`MEDIA_PORT`、`SERVE_PORT` 任一不是「1..65535 且不帶前導零」的整數 — 因此 `80x`、`0`、`99999`、`049100` 都會失敗。前導零這條不是龜毛：埠的 sentinel 是不帶引號代入的，`049100` 會渲染成裸的 `049100` token，在 strict mode 是 `SyntaxError`，容器啟動正常但檢視器一片黑。`SERVE_PORT` 只在有設定時檢查（`example` stage 用的是 `EXAMPLE_PORT`），且可以是單純的埠號或 `serve -l` 的 endpoint — `SERVE_PORT=tcp://127.0.0.1:5173` 只綁 loopback，這是唯一能讓檢視器不監聽所有介面的方式。支援的形式正好兩種：`<port>` 與 `tcp://<host>:<port>`。`serve -l` 另外還列了兩種，兩種都是「指名拒絕」而非漏掉：UNIX domain socket（`unix:/path/to/socket.sock`）沒有任何本容器的消費方定址得到（瀏覽器打的是 URL，映像自身的 serve 冒煙與兩個 e2e runner 都是 curl `http://127.0.0.1:<port>`），而 Windows 具名管道（`pipe:\\.\pipe\Name`）在發布的 linux/amd64 映像裡根本不可能存在。媒體 sentinel 僅存在於 `stream-only` bundle（其 `streamTarget.json`）；`usd-viewer` 僅帶 server + port，並透過 SDP 協商媒體。已提供服務的 bundle 只以該次渲染為目標來源：`?server=`/`?port=`/`?media=` query string 僅是 `npm run dev` 的便利功能，build 出來的 bundle 會忽略它，因此無法用一條連結把執行中的 viewer 指向別的主機。

連接埠（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）透過 `.env` 機制（`[environment]` 表 / `setup.conf`）遞送，而非 `host.yaml`，也非硬編的 `-e`。`config/host.yaml` 僅承載 `public_ip`（並可選擇性帶 `viewer.ui_mode`）。優先序：`public_ip` / `ui_mode` -> `host.yaml` > env > 預設；連接埠 -> `.env`。見 `config/host.yaml.example`。這兩個 key 只從「自己的 section」讀取（`network.public_ip`、`viewer.ui_mode`），因為該檔按設計就是與主機上其他容器共用的 — 別人 section 裡的同名 key 一律不碰。寫在第 0 欄（不屬於任何 section）的 key 同樣不會被讀取 — 而兩個 key 在這裡分道揚鑣。第 0 欄的 `public_ip:` 會讓 entrypoint **拒絕啟動**並指出該 key 應該放進哪個 section：少了 `network:` section 本身就是異常，因為那個 section 正是這個檔案被讀取的理由，忽略它就等於退回 env / 預設值去連一個沒人選過的位址。第 0 欄的 `ui_mode:` 則是**在 stderr 回報後忽略**：少了 `viewer:` section 是常態（模式通常由 `VIEWER_UI_MODE` 提供），在那裡拒絕啟動會讓一台設定完全正確的檢視器因為別的容器的 key 而起不來 — 而且檔案裡沒有任何線索能區分「本來就是要給我們、只是位置寫錯」與「那是別人的 key」。那行訊息會指出被忽略的 key、實際生效的模式，以及它的來源。

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
- **連線被拒 / 串流始終未出現** — 檢查 `SIGNALING_SERVER` / `SIGNALING_PORT` 是否指向正在執行的 Kit 應用程式，且該 Kit 應用程式已啟用 NVCF livestream。若是遠端瀏覽器，請在 `host.yaml` 中設定 `network.public_ip`。在 `stream-only` 模式下，檢視器嘗試連線期間顯示 `connecting to <server>:<port>...` — 它不會宣稱串流已經成功，因為在第一個影格渲染出來之前根本無從得知；若約 20 秒後仍沒有畫面，訊息會變成 `no video from the source -- it never started. Check that it is running, then reload.`。若生產端稍後才啟動，只要真正的影格開始送達，該訊息就會自行消失：檢視器在背景仍持續重試 session 啟動，而已渲染的影格優先於檢視器自己稍早下的判斷 — 這種情況不需要重新整理。
- **串流中途畫面凍結，並顯示 `stream stopped -- waiting for frames to resume...` 或 `stream ended -- the source is gone`**（僅 `stream-only`） — 串流開始後 Kit 生產端消失了。檢視器會從串流函式庫得知，若函式庫沒有任何通知，也會直接從畫面本身判斷：約 5 秒沒有新影格就足以判定。前者表示檢視器正在等待畫面是否回來；系統不會自動替你重新連線，若約 15 秒內沒有新影格，會升級為後者的終止訊息。待 Kit 應用程式恢復後重新整理頁面，通常才是取得新串流的方式；但只要影格真的重新開始送達，該訊息就會自行消失，而不會壓在正常播放的畫面上。請檢查串流主機上的 Kit 程序。
- **容器啟動後立即結束** — entrypoint 在渲染前會驗證設定，無效值會被拒絕並印出錯誤訊息，而非啟動一個壞掉的檢視器。會被拒絕的有：`SIGNALING_PORT`、`MEDIA_PORT` 不是「1..65535 且不帶前導零」的整數 — `80x`、`0`、`99999`、`049100` 都會失敗；`SERVE_PORT` 既不是這樣的整數、也不是埠部分同樣合規的 `tcp://<host>:<port>` endpoint（`serve -l` 其餘兩種形式 `unix:` / `pipe:` 會被指名拒絕）；未知的 `VIEWER_UI_MODE`；或含非法字元的 `SIGNALING_SERVER`（包含 `host.yaml` 值尾端誤帶的行內 `#` 註解）；存在但讀不到的 `host.yaml`；以及把 `public_ip` 寫在讀取範圍（`network:` section）之外的 `host.yaml` — 最後這種會被拒絕而非忽略，因為忽略就等於退回 env / 預設值啟動，去連一個沒人選過的位址。位置寫錯的 `ui_mode:` **不會**讓容器退出：它會在 stderr 被回報，檢視器則以實際生效的模式啟動。請依錯誤訊息修正對應的環境變數 / `host.yaml` 值。
- **開啟瀏覽器主控台**（F12） — WebRTC 連線錯誤會記錄在那裡。

## 冒煙測試

詳見 [TEST.md](test/TEST.md)。

除了每個 PR 都會跑的關卡之外，還有一個每晚執行的 `tier-b-visual-e2e` job，跑在自架的 GPU runner 上：它會啟動真正的 Kit 串流來源，並在無頭瀏覽器中驗證 `stream-only` 檢視器真的有畫面 — `RTCPeerConnection` 進入 connected、收到 remote track、`videoWidth > 0`，而且抽樣的畫格不是全黑 — 讓「有畫面」這件事由 CI 證明，而不是靠人盯著頁面看。

這個 job 同時也是發布關卡：任何版本都必須在該 commit 上通過它才能發布，沒有 override、沒有 `continue-on-error`，因此 GPU runner 不可用時發布會被擋下而不是放行。這套接線本身也在測試涵蓋範圍內 — `release_gate_workflow.bats` 會讀取 `.github/workflows/main.yaml`，只要關卡的 `if:` / `needs:` 結構被拿掉就會失敗；而且它會對「只刪掉該項性質」的工作流程副本再跑一次檢查器，證明每條斷言真的會紅。 這個檢查涵蓋 job 層級、step 層級（gate job 的工作 step 被跳過時，job 仍然回報 `success`，而那正是 `needs:` 唯一看得到的東西），以及從檔案本身推導出來的「會發布東西的 job」集合，而不是一份寫死的名單。而且它是把 workflow 當成 YAML 解析，不是拿文字去比對 pattern：`script/ci/check_release_gates.py` 用真正的 parser 讀 `.github/workflows/main.yaml`，因為先前兩版文字比對的實作都被 review 繞過去了。它刻意只當一道窄關卡：它看不到什麼的完整權威清單放在 `script/ci/check_release_gates.py` 的檔頭，只留那一份，不在這裡重述。唯一值得在 README 重複的界線其實不是檢查器的事：branch protection 與 required status checks 屬於 repo 設定，這個 repo 裡沒有任何地方在檢查它們。

同一個 job 現在**每次推 tag 也會跑**，而且 GitHub Release 與 GHCR image 都以它為前置關卡：沒有替該 commit 驗證過畫面，就不會發佈任何版本。這裡刻意沒有留任何強制放行的開關 — GPU runner 不可用時，release 會被擋下來，而不是在未驗證的情況下發佈。

在有 GPU 的主機上也可以在本機跑同一套驗收：

```bash
just build -t e2e-test               # 檢視器 + 瀏覽器打包在同一個 image
bash script/ci/tier_b_visual_e2e.sh  # 啟動來源端，驅動瀏覽器
```

它使用帶 instance 編號的容器名稱，並且會先探測 port 是否空閒，因此不會干擾同一台主機上正在執行的開發或展示環境。

## 授權條款

[Apache-2.0](../LICENSE)
