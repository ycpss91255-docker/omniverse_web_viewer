# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

Omniverse Kit ストリーミングアプリケーション（Isaac Sim、USD Viewer など）向けの、ブラウザベース WebRTC ビューアサイドカー。NVIDIA の [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 を [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築した Docker イメージにラップしています。

## 仕組み

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (このコンテナ — 静的 React アプリ)
  -> ws://<host-ip>:<SIGNALING_PORT>     (ブラウザ JS -> Isaac Sim WebRTC シグナリング)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC メディアストリーム)
  -> Omniverse Kit streaming app         (例: Isaac Sim stream)
```

ビューアは `serve` で配信される静的 React アプリです。ブラウザの JS が Kit アプリの WebRTC シグナリング/メディアポートに直接接続します。このコンテナに GPU は不要です。

## 前提条件

- NVCF ライブストリームが有効な状態で動作している Omniverse Kit アプリケーション（例: Isaac Sim `stream` ステージ）
- Chrome または Chromium（Firefox は Omniverse WebRTC と互換性がありません）
- Docker
- 対応イメージアーキテクチャ：`linux/amd64`、`linux/arm64`

## クイックスタート

```bash
# 1. ビルド（初回のみ）
make build

# 2. 実行（デフォルト: 127.0.0.1:49100、serve は 5173）
make run -- -d

# 3. Chrome で http://<host-ip>:5173 を開く
#    「UI for any streaming app」を選択 -> Next
```

デフォルトのホスト IP やポートを変更するには、`config/docker/setup.conf` を編集してください:

```ini
[environment]
SIGNALING_SERVER = <host-ip>
SIGNALING_PORT = 49100
SERVE_PORT = 5173
```

その後 `./script/setup.sh apply` を実行して `compose.yaml` を再生成します。

## 環境変数

| 変数 | デフォルト値 | 用途 |
|------|-------------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC シグナリング用ホスト IP |
| `SIGNALING_PORT` | `49100` | WebRTC シグナリングポート（Kit アプリの `--/app/livestream/port` と一致させる必要があります） |
| `SERVE_PORT` | `5173` | 静的ファイルサーバーがリッスンするポート |
| `VIEWER_UI_MODE` | `usd-viewer` | `usd-viewer`（フル USD Viewer UI）または `stream-only`（純粋な映像ストリーム。Isaac Sim / USD Viewer 以外の Kit アプリ向け） |
| `VIEWER_AUTO_LAUNCH` | `false` | `true` にすると「UI Option」選択画面をスキップし、`VIEWER_UI_MODE` で直接起動する |

`SIGNALING_SERVER` / `SIGNALING_PORT` / `VIEWER_UI_MODE` / `VIEWER_AUTO_LAUNCH` は、コンテナ起動時にビルド済み JS へ差し込まれます（値を変更してもリビルドは不要です）。`SERVE_PORT` はアセットには注入されません。コンテナの `CMD` を介して静的サーバーがリッスンするポートを設定するだけです。`VIEWER_*` と `SIGNALING_SERVER` は `config/host.yaml`（`viewer:` / `network:`、`/etc/host.yaml` にマウント）でも設定でき、そちらが優先されます。`config/host.yaml.example` を参照。

## マルチインスタンス

1 回のビルドで、異なるポートを持つ複数のコンテナを起動できます:

```bash
make build  # 初回のみ

# インスタンス A
docker run --rm -d --name owv-a --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49100 \
  -e SERVE_PORT=5173 \
  omniverse_web_viewer:devel

# インスタンス B
docker run --rm -d --name owv-b --network=host \
  -e SIGNALING_SERVER=10.2.23.83 \
  -e SIGNALING_PORT=49200 \
  -e SERVE_PORT=5174 \
  omniverse_web_viewer:devel
```

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

## トラブルシューティング

- **画面が真っ白でエラーも出ない** — 通常は UI モードと Kit アプリの不一致です。`usd-viewer` モードは kit-app-template の USD Viewer でのみ動作します。Isaac Sim や他の Kit アプリに対しては準備完了ポーリングが完了せず、何も描画されず、エラーも表示されません。`stream-only` に切り替えてください（`VIEWER_UI_MODE=stream-only`、または `host.yaml` の `viewer.ui_mode`）。
- **接続拒否 / ストリームが表示されない** — `SIGNALING_SERVER` / `SIGNALING_PORT` が動作中の Kit アプリを指していること、およびその Kit アプリで NVCF ライブストリームが有効になっていることを確認してください。リモートブラウザの場合は `host.yaml` で `network.public_ip` を設定してください。
- **コンテナが起動直後に終了する** — エントリポイントはレンダリング前に設定を検証します。無効な値（数値でない `SIGNALING_PORT`、不明な `VIEWER_UI_MODE` / `VIEWER_AUTO_LAUNCH`、または不正な文字を含む `SIGNALING_SERVER`、`host.yaml` の値末尾に紛れ込んだインライン `#` コメントを含む）はエラーメッセージとともに拒否され、壊れたビューアを起動しません。表示された環境変数 / `host.yaml` の値を修正してください。
- **ブラウザコンソールを開く**（F12） — WebRTC の接続エラーはそこに記録されます。

## スモークテスト

詳細は [TEST.md](test/TEST.md) を参照してください。

## ライセンス

[Apache-2.0](../LICENSE)
