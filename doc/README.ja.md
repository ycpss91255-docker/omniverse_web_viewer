# omniverse_web_viewer

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

Omniverse Kit ストリーミングアプリケーション（Isaac Sim、USD Viewer など）向けの、ブラウザベース WebRTC ビューアサイドカー。NVIDIA の [`web-viewer-sample`](https://github.com/NVIDIA-Omniverse/web-viewer-sample) v1.5.2 を [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築した Docker イメージにラップしています。

## 仕組み

```
Browser (Chrome/Chromium)
  -> http://<host-ip>:<SERVE_PORT>       (このコンテナ — 静的 React アプリ)
  -> ws://<host-ip>:<SIGNALING_PORT>     (ブラウザ JS -> Isaac Sim WebRTC シグナリング)
  -> udp://<host-ip>:<MEDIA_PORT>        (WebRTC メディアストリーム)
  -> Omniverse Kit streaming app         (例: Isaac Sim headless-stream)
```

ビューアは `serve` で配信される静的 React アプリです。ブラウザの JS が Kit アプリの WebRTC シグナリング/メディアポートに直接接続します。このコンテナに GPU は不要です。

## 前提条件

- NVCF ライブストリームが有効な状態で動作している Omniverse Kit アプリケーション（例: Isaac Sim `headless-stream` ステージ）
- Chrome または Chromium（Firefox は Omniverse WebRTC と互換性がありません）
- Docker

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

3 つとも entrypoint 経由でコンテナ起動時に注入されます。値を変更する際にリビルドは不要です。

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

## スモークテスト

詳細は [TEST.md](test/TEST.md) を参照してください。

## ライセンス

[Apache-2.0](../LICENSE)
