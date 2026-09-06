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
env_1 = SIGNALING_SERVER=<host-ip>
env_2 = SIGNALING_PORT=49100
env_3 = SERVE_PORT=5173
env_4 = VIEWER_UI_MODE=usd-viewer
```

`env_N = KEY=VALUE` 是语法，不是排版风格：`setup.sh` 只收集以 `env_` 开头的
键，这个 section 里不是这个形状的键会被**静默丢弃，且 exit 0、没有任何警告**。
写成 `SIGNALING_SERVER = <host-ip>`（这份文档有四个版本都是这样教的）时，
`apply` 会成功、`compose.yaml` 里什么都没有，viewer 静静地连向 `127.0.0.1`、
返回 HTTP 200，而画面永远不会出现。

然后运行 `./script/setup.sh apply` 以重新生成 `compose.yaml`。

## 发布的镜像

每个 git tag 都会在同一次 CI run、以同一个 commit，同时发布 GitHub Release **和**对应的容器镜像，两者永远成对存在 — 拿到镜像可以回溯它的 release，拿到 release 也能找到它的镜像：

```
ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

镜像的 tag 就是 release 版本号去掉开头的 `v`。这个值由 CI 从 git tag 推导得出，不是人工填写，release 与镜像因此不可能对不上：

| Git tag | 镜像 |
|---------|------|
| `v0.3.0` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0` |
| `v0.3.0-rc1` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0-rc1` |

Release candidate 同样会发布：正式 tag 出来之前，真正被验证的就是 rc。

发布**只在 tag 时发生**（外加维护者手动触发的重新发布通道）。Pull request 或 `main` push 都不会发布任何东西。刻意不提供 `:latest`：请锁定版本号，才不会被之后的 release 或某个 rc 悄悄替换掉正在运行的东西。

发布的是精简的 `runtime` stage，架构为 `linux/amd64`（CI 唯一会构建并把关的平台）。其他架构请用 `just build` 在本机自行构建。

```bash
docker run --rm -d --name owv \
  -e SIGNALING_SERVER=<host-ip> \
  -e SIGNALING_PORT=49100 \
  -e VIEWER_UI_MODE=stream-only \
  -p 5173:5173 \
  ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

然后用 Chrome 打开 `http://<host-ip>:5173`。可调参数即下方环境变量表所列。

## 环境变量

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC 信令的主机 IP |
| `SIGNALING_PORT` | `49100` | WebRTC 信令端口（必须与 Kit 应用的 `--/app/livestream/port` 一致） |
| `MEDIA_PORT` | null（协商） | WebRTC 媒体端口 — 未设置则通过 SDP 协商，设置则固定（D1，仅 `stream-only` 应用适用） |
| `SERVE_PORT` | `5173` | 静态文件服务器监听的端口 |
| `VIEWER_UI_MODE` | `usd-viewer` | 应用选择器：`usd-viewer`（上游 sample，交互式）或 `stream-only`（我们自家的全屏自动连接应用，用于 Isaac Sim / 无头消费端） |

`VIEWER_UI_MODE` 选择 entrypoint 提供哪个应用，它不会被注入到资源中。`SIGNALING_SERVER`、`SIGNALING_PORT` 与 `MEDIA_PORT` 是被注入的 sentinel：构建会将每个带有 sentinel 的 chunk 保存为 `*.js.tmpl`，entrypoint 在每次启动时重新渲染 `*.js.tmpl -> *.js`（具幂等性 — 重启或值变更会在下次启动被采用）。校验即是转义处理：无效值会让容器失败（`exit 1`），而非烤进损坏的 JS。会被拒绝的有：`SIGNALING_SERVER` 含 `A-Za-z0-9.-` 以外的字符；`SIGNALING_PORT`、`MEDIA_PORT`、`SERVE_PORT` 任一不是「1..65535 且不带前导零」的整数 — 因此 `80x`、`0`、`99999`、`049100` 都会失败。前导零这一条并非吹毛求疵：端口 sentinel 是不带引号代入的，`049100` 会渲染成裸的 `049100` token，在 strict mode 是 `SyntaxError`，容器启动正常但查看器一片黑。`SERVE_PORT` 只在有设置时检查（`example` stage 用的是 `EXAMPLE_PORT`），且可以是单纯的端口号或 `serve -l` 的 endpoint — `SERVE_PORT=tcp://127.0.0.1:5173` 只绑 loopback，这是唯一能让查看器不监听所有网卡的方式。支持的形式正好两种：`<port>` 与 `tcp://<host>:<port>`。`serve -l` 另外还列了两种，两种都是「指名拒绝」而非漏掉：UNIX domain socket（`unix:/path/to/socket.sock`）没有任何本容器的消费方能寻址得到（浏览器打的是 URL，镜像自身的 serve 冒烟与两个 e2e runner 都是 curl `http://127.0.0.1:<port>`），而 Windows 具名管道（`pipe:\\.\pipe\Name`）在发布的 linux/amd64 镜像里根本不可能存在。媒体 sentinel 仅存在于 `stream-only` bundle（其 `streamTarget.json`）；`usd-viewer` 仅带 server + port，并通过 SDP 协商媒体。已提供服务的 bundle 只以该次渲染为目标来源：`?server=`/`?port=`/`?media=` query string 仅是 `npm run dev` 的便利功能，build 出来的 bundle 会忽略它，因此无法用一条链接把运行中的 viewer 指向别的主机。

端口（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）通过 `.env` 机制（`[environment]` 表 / `setup.conf`）递送，而非 `host.yaml`，也非硬编的 `-e`。`config/host.yaml` 仅承载 `public_ip`（并可选择性带 `viewer.ui_mode`）。优先级：`public_ip` / `ui_mode` -> `host.yaml` > env > 默认；端口 -> `.env`。见 `config/host.yaml.example`。这两个 key 只从「自己的 section」读取（`network.public_ip`、`viewer.ui_mode`），因为该文件按设计就是与主机上其他容器共用的 — 别人 section 里的同名 key 一律不碰。写在第 0 栏（不属于任何 section）的 key 同样不会被读取 — 而两个 key 在这里分道扬镳。第 0 栏的 `public_ip:` 会让 entrypoint **拒绝启动**并指出该 key 应该放进哪个 section：缺少 `network:` section 本身就是异常，因为那个 section 正是这个文件被读取的理由，忽略它就等于退回 env / 默认值去连一个没人选过的地址。第 0 栏的 `ui_mode:` 则是**在 stderr 报告后忽略**：缺少 `viewer:` section 是常态（模式通常由 `VIEWER_UI_MODE` 提供），在那里拒绝启动会让一台配置完全正确的查看器因为别的容器的 key 而起不来 — 而且文件里没有任何线索能区分「本来就是要给我们、只是位置写错」与「那是别人的 key」。那行消息会指出被忽略的 key、实际生效的模式，以及它的来源。

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
- **连接被拒绝 / 画面串流始终不出现** — 检查 `SIGNALING_SERVER` / `SIGNALING_PORT` 是否指向正在运行的 Kit 应用，以及该 Kit 应用是否已启用 NVCF livestream。对于远端浏览器，请在 `host.yaml` 中设置 `network.public_ip`。在 `stream-only` 模式下，查看器尝试连接期间显示 `connecting to <server>:<port>...` — 它不会声称串流已经成功，因为在第一帧渲染出来之前根本无从得知；若约 20 秒后仍没有画面，消息会变成 `no video from the source -- it never started. Check that it is running, then reload.`。若生产端稍后才启动，只要真正的帧开始送达，该消息就会自行消失：查看器在后台仍持续重试 session 启动，而已渲染的帧优先于查看器自己此前作出的判断 — 这种情况无需刷新页面。而且只要帧持续送达，这些后台重试就会保持安静：正在播放的画面优先于重试所声称的任何内容，读出区不会被重新绘制到一个正常工作的串流之上。
- **画面在会话中途冻结，并显示 `stream stopped -- waiting for frames to resume...` 或 `stream ended -- the source is gone`**（仅 `stream-only`）— 串流开始后 Kit 生产端消失了。查看器会从串流库得知，若串流库没有任何通知，也会直接从画面本身判断：约 5 秒没有新帧就足以判定。前者表示查看器正在等待画面是否恢复；系统不会自动替你重新连接，若约 15 秒内没有新帧，将升级为后者的终止消息。待 Kit 应用恢复后刷新页面，通常才是获得新串流的方式；但只要帧真的重新开始送达，该消息就会自行消失，而不会压在正常播放的画面上。请检查串流主机上的 Kit 进程。
- **容器启动后立即退出** — entrypoint 在渲染前会校验配置，无效值会被拒绝并打印错误信息，而不是启动一个损坏的查看器。会被拒绝的有：`SIGNALING_PORT`、`MEDIA_PORT` 不是「1..65535 且不带前导零」的整数 — `80x`、`0`、`99999`、`049100` 都会失败；`SERVE_PORT` 既不是这样的整数、也不是端口部分同样合规的 `tcp://<host>:<port>` endpoint（`serve -l` 其余两种形式 `unix:` / `pipe:` 会被指名拒绝）；未知的 `VIEWER_UI_MODE`；或含非法字符的 `SIGNALING_SERVER`（包括 `host.yaml` 值末尾误带的行内 `#` 注释）；存在但读不到的 `host.yaml`；以及把 `public_ip` 写在读取范围（`network:` section）之外的 `host.yaml` — 最后这种情况会被拒绝而非忽略，因为忽略就等于退回 env / 默认值启动，去连一个没人选过的地址。位置写错的 `ui_mode:` **不会**让容器退出：它会在 stderr 被报告，查看器则以实际生效的模式启动。请根据错误信息修正对应的环境变量 / `host.yaml` 值。
- **打开浏览器控制台**（F12）— WebRTC 连接错误会记录在那里。

## 冒烟测试

详情请参阅 [TEST.md](test/TEST.md)。

除了每个 PR 都会运行的关卡之外，还有一个每晚执行的 `tier-b-visual-e2e` job，运行在自建的 GPU runner 上：它会启动真正的 Kit 流媒体来源，并在无头浏览器中验证 `stream-only` 查看器确实有画面 — `RTCPeerConnection` 进入 connected、收到 remote track、`videoWidth > 0`，并且抽样的帧不是全黑 — 让「有画面」这件事由 CI 证明，而不是靠人盯着页面看。

这个 job 同时也是发布关卡：任何版本都必须在该 commit 上通过它才能发布，没有 override、没有 `continue-on-error`，因此 GPU runner 不可用时发布会被挡下而不是放行。这套接线本身也在测试覆盖范围内 — `release_gate_workflow.bats` 会读取 `.github/workflows/main.yaml`，只要关卡的 `if:` / `needs:` 结构被拿掉就会失败；而且它会对「只删掉该项性质」的工作流副本再跑一次检查器，证明每条断言真的会红。 这个检查涵盖 job 层级、step 层级，以及从文件本身推导出来的「会发布东西的 job」集合，而不是一份写死的名单；对两个「工作内容就是单一 driver」的 job（`tier-b-visual-e2e`、`verify-tag-shape`），它会断言那道命令原样、无条件执行，且该 job 内不得有第二个以其他写法调用同一支脚本的 step —— 因为 gate job 即使跑起来什么都没做，仍然回报 `success`，而那正是 `needs:` 唯一看得到的东西。这道 pin 绑的是「这道命令真的被执行」而不是「这串字出现过」：调用 driver 的 step 不得带 `shell:`、`working-directory:`、`env:`，那两个 job 与 workflow 层级也不得有 `defaults.run` —— 因为 `shell: cat {0}` 会把被 pin 的命令打印出来而不是执行它，`TIER_B_*` 变量则决定它去看哪个 image，两者都不会动到 reviewer 读的那一行。另外 `devel-test` stage 现在复制整个 `.github/workflows/` 目录而不是指名单一文件，并有一个 case 断言目录里到底有哪些文件，所以「新增第二个会发布的 workflow」是一个红掉的测试而不是一片安静；检查器本身仍然只读它被指定的那一份 workflow。而且它是把 workflow 当成 YAML 解析，不是拿文本去比对 pattern：`script/ci/check_release_gates.py` 用真正的 parser 读取 `.github/workflows/main.yaml`，因为先前两版基于文本比对的实现都被 review 绕了过去；表达式比对也改成不分大小写，因为 `if: ALWAYS()` 曾经把只比对小写的版本整个绕了过去。它刻意只做一道窄关卡：它看不到什么的完整权威清单放在 `script/ci/check_release_gates.py` 的文件头，只保留那一份，不在这里重述。唯一值得在 README 里重复的边界其实与检查器无关：branch protection 与 required status checks 属于 repo 设置，这个 repo 里没有任何地方在检查它们。

同一个 job 现在**每次推 tag 也会运行**，而且 GitHub Release 与 GHCR image 都以它作为前置关卡：没有为该 commit 验证过画面，就不会发布任何版本。这里刻意没有保留任何强制放行的开关 — GPU runner 不可用时，release 会被拦下来，而不是在未验证的情况下发布。

在具备 GPU 的主机上也可以在本地运行同一套验收：

```bash
just build -t e2e-test               # 查看器 + 浏览器打包在同一个 image
bash script/ci/tier_b_visual_e2e.sh  # 启动来源端，驱动浏览器
```

它使用带 instance 编号的容器名称，并且会先探测端口是否空闲，因此不会干扰同一台主机上正在运行的开发或演示环境。

## 许可证

[Apache-2.0](../LICENSE)
