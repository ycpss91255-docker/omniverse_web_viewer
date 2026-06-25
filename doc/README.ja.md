# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

Omniverse Kit ストリーミングアプリケーション（Isaac Sim、USD Viewer など）向けの、汎用かつ Kit 非依存のブラウザベース WebRTC ビューアサイドカー。イメージは [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築され、起動時に `VIEWER_UI_MODE` で次の 2 つの静的アプリのいずれかを選択して配信します:

- **`usd-viewer`** — NVIDIA の [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 を未改変でビルド。ランディング画面、フル USD Viewer UI、任意アプリのストリーミングを提供し、すべてインタラクティブに（クリックで）到達します。
- **`stream-only`** — `stream-core` パッケージ上に構築した自前のフルスクリーン自動接続アプリ。クリック不要でストリームへ直行します。Isaac Sim および任意のヘッドレスストリーム利用者向け。

イメージは静的ページを配信するだけで、ブラウザの JS が Kit アプリの WebRTC シグナリング/メディアポートに直接接続します。このコンテナに GPU は不要です。

## 仕組み

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (this container — a served static app)
  -> ws://<host-ip>:<SIGNALING_PORT>     (browser JS -> Isaac Sim WebRTC signaling)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC media stream)
  -> Omniverse Kit streaming app         (e.g. Isaac Sim stream)
```

ビューアは階層化されています: `stream-core` は NVIDIA ストリーミングライブラリに触れる唯一のコードであり、アプリはプレゼンテーションのみを担い、イメージ層は配信と起動時の設定注入を担います。`VIEWER_UI_MODE` は serve レベルのアプリセレクタであり、entrypoint がどのアプリの `dist` を配信するかを選びます。バンドルにレンダリングされる in-bundle の UI モードではありません。

## 前提条件

- NVCF ライブストリームが有効な状態で動作している Omniverse Kit アプリケーション（例: Isaac Sim `stream` ステージ）
- Chrome または Chromium（Firefox は Omniverse WebRTC と互換性がありません）
- Docker
- 対応イメージアーキテクチャ：`linux/amd64`、`linux/arm64`

## クイックスタート

デプロイ対象のステージは軽量な `runtime` イメージです（ビルド済み dist と `serve` のみ、ツールチェーンなし）。

```bash
# 1. Build (one-time)
just build

# 2. Run the lean runtime (default: 127.0.0.1:49100, serve on 5173)
just run -t runtime -d

# 3. Open Chrome -> http://<host-ip>:5173
#    usd-viewer (default): click the landing screen to choose a view
#    stream-only: auto-connects into the full-screen stream, no click
```

デフォルトのホスト IP やポートを変更するには、`config/docker/setup.conf` を編集してください:

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
VIEWER_UI_MODE = usd-viewer
```

その後 `./script/setup.sh apply` を実行して `compose.yaml` を再生成します。

## 環境変数

| 変数 | デフォルト値 | 用途 |
|------|-------------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC シグナリング用ホスト IP |
| `SIGNALING_PORT` | `49100` | WebRTC シグナリングポート（Kit アプリの `--/app/livestream/port` と一致させる必要があります） |
| `MEDIA_PORT` | null（ネゴシエーション） | WebRTC メディアポート — 未設定なら SDP でネゴシエーション、設定すると固定（D1、`stream-only` アプリのみ） |
| `SERVE_PORT` | `5173` | 静的ファイルサーバーがリッスンするポート |
| `VIEWER_UI_MODE` | `usd-viewer` | アプリセレクタ：`usd-viewer`（上流 sample、インタラクティブ）または `stream-only`（自前のフルスクリーン自動接続アプリ。Isaac Sim / ヘッドレス利用者向け） |

`VIEWER_UI_MODE` は entrypoint がどのアプリを配信するかを選択するもので、アセットには注入されません。`SIGNALING_SERVER`、`SIGNALING_PORT`、`MEDIA_PORT` は注入されるセンチネルです: ビルドはセンチネルを含む各チャンクを `*.js.tmpl` として保存し、entrypoint は起動のたびに `*.js.tmpl -> *.js` を再レンダリングします（冪等 — 再起動や値の変更は次回起動時に反映）。バリデーションがエスケープそのものです: 無効な値（不正文字を含む `SIGNALING_SERVER`、数値でないポート）はコンテナを失敗させ（`exit 1`）、壊れた JS を焼き込みません。メディアセンチネルは `stream-only` バンドル（その `streamTarget.json`）にのみ存在し、`usd-viewer` は server + port のみを持ち、メディアは SDP でネゴシエーションします。

ポート（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）は `.env` メカニズム（`[environment]` テーブル / `setup.conf`）で配送され、`host.yaml` でもハードコードの `-e` でもありません。`config/host.yaml` は `public_ip`（および任意で `viewer.ui_mode`）のみを保持します。優先順位: `public_ip` / `ui_mode` -> `host.yaml` > env > デフォルト、ポート -> `.env`。`config/host.yaml.example` を参照。

## マルチインスタンス

ビューアはサイドカーです: 独立して埋め込み可能な単位で、インスタンスごとに 1 クライアントです。1 つのページに多数のストリームを表示するには、ビューアを N 回埋め込みます — 各インスタンスは自身のビューアを実行し、自身の Kit インスタンスに接続し、自身のポートを `.env` 経由で受け取ります。例えば利用者のダッシュボードは N 個の `<iframe>` であり、それぞれが異なるインスタンスを指し、それぞれ 1 接続です。複数のクライアントを 1 つの Kit インスタンスに多重化することはなく、単一のストリームを複数の視点に分割することもありません（後者は Kit 側で生成されます）。

インスタンスごとのポート配送も `.env` メカニズムに乗ります: 各インスタンスの `SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT` はそのインスタンスの `.env` ファイル（例: `config/instances/<name>.env`）から来るため、各ビューアは確定的に自身のポートを狙います。

## 互換性

| Kit アプリケーション | バージョン | 動作 |
|---------------------|-----------|------|
| Isaac Sim | 5.1.0+ | 対応 |
| USD Composer | Kit 107.3.1+ | 対応 |
| USD Viewer (kit-app-template) | Kit 107.3.1+ | 対応（元々このアプリ向けに設計） |
| NVCF ライブストリーム対応のカスタム Kit アプリ | Kit 107.3.1+ | 対応 |

## 既知の制限事項（Isaac Sim 5.1.0）

- Kit インスタンスあたりインタラクティブクライアントは 1 つのみ（2 番目の接続は拒否されます）
- Firefox は非対応 — Chrome/Chromium を使用してください

## サンプル

- 埋め込み可能なストリーム demo サイト — [`examples/embedded-site-demo/`](../examples/embedded-site-demo/README.md)

## トラブルシューティング

- **画面が真っ白でエラーも出ない** — 通常は UI モードと Kit アプリの不一致です。`usd-viewer` モードは kit-app-template の USD Viewer でのみ動作します。Isaac Sim や他の Kit アプリに対しては準備完了ポーリングが完了せず、何も描画されず、エラーも表示されません。`stream-only` に切り替えてください（`VIEWER_UI_MODE=stream-only`、または `host.yaml` の `viewer.ui_mode`）。
- **接続拒否 / ストリームが表示されない** — `SIGNALING_SERVER` / `SIGNALING_PORT` が動作中の Kit アプリを指していること、およびその Kit アプリで NVCF ライブストリームが有効になっていることを確認してください。リモートブラウザの場合は `host.yaml` で `network.public_ip` を設定してください。
- **コンテナが起動直後に終了する** — エントリポイントはレンダリング前に設定を検証します。無効な値（数値でない `SIGNALING_PORT` / `MEDIA_PORT`、不明な `VIEWER_UI_MODE`、または不正な文字を含む `SIGNALING_SERVER`、`host.yaml` の値末尾に紛れ込んだインライン `#` コメントを含む）はエラーメッセージとともに拒否され、壊れたビューアを起動しません。表示された環境変数 / `host.yaml` の値を修正してください。
- **ブラウザコンソールを開く**（F12） — WebRTC の接続エラーはそこに記録されます。

## スモークテスト

詳細は [TEST.md](test/TEST.md) を参照してください。

## ライセンス

[Apache-2.0](../LICENSE)
