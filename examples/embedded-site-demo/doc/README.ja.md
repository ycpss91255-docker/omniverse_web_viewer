# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

ライブの Isaac Sim / Kit ストリームを「実際のウェブサイト」ページに直接埋め込む、自己完結型のサンプルサイトです。これは **ショーケース**（ヘッダー + レイアウトとライブストリームパネル）であると同時に、**開発者向けリファレンス**（クリーンでコピー&ペーストできる統合コード）でもあります。

メインビューアとは異なり、このサンプルは純粋な **vanilla TypeScript + Vite** であり、**ランタイム依存は 2 つ**です -- `stream-core`（共有の接続カーネル。npm workspace の sibling パッケージ）と `@nvidia/omniverse-webrtc-streaming-library`。React も bootstrap も選択画面もありません。ストリーム専用の直接接続を行います。

## レイアウト

| ファイル | 役割 |
|------|------|
| `index.html` | サイトの外枠（ヘッダー / ナビ / ヒーロー）+ ストリームパネル（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM + ライブラリの接着部: ターゲットの解決、接続、ステータスの表示。 |
| `src/resolveTarget.js` | 純粋で DOM 非依存のターゲット解決: ビルド時に差し込まれた sentinel を既定とし、`?server=&port=&media=` による上書きは呼び出し側の明示的なオプトインが必要です。`main.ts` は Vite dev server のときだけオプトインするため、ビルド済みバンドルはクエリを無視します。 |
| `test/resolveTarget.test.js` | resolver 向けの `node --test` ユニットテスト。 |
| `src/streamTarget.json` | ビルド時の `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` プレースホルダー。 |

DIRECT 設定のファクトリ自体はこのサンプルには**ありません**: `buildStreamConfig` は `stream-core` workspace パッケージにあり、メインビューアと共有されています（ローカルの複製は削除済み）。

## 実行する（コンテナ）

このサンプルは、ビルド済みのサイトを `EXAMPLE_PORT`（8080）上で配信する Docker の `example` ステージです。メインビューア（5173）とは別であり -- 両方を同時に実行できます。**ページ** は `http://<host>:8080` で開きます。`SIGNALING_SERVER` / `SIGNALING_PORT`（デフォルト `49100`）は、ページを Kit/Isaac の **ストリーム** のシグナリングへ向けるためのものです -- これはページが接続する先であって、開く URL ではありません。

イメージをビルドし、動作中のストリームを指定して host ネットワークで実行します（`SIGNALING_SERVER` は Kit/Isaac ストリームを実行しているホストです）:

```bash
just build -t example
just run -t example -d
# then open http://<host-ip>:8080
```

エントリポイントは起動のたびに、`SIGNALING_SERVER` / `SIGNALING_PORT` / `MEDIA_PORT`（env）または `/etc/host.yaml`（`network.public_ip`）から `__OWV_SERVER__` / `__OWV_PORT__` / `__OWV_MEDIA_PORT__` を、ビルド済みバンドルへ差し込みます。`just run` はこれらを生成された `.env` から読み取ります -- `setup.conf` の `[environment]` を編集し、`./script/setup.sh apply` を再実行してください。

その 2 つを変更せずに 1 回だけターゲットを指定したい場合は、コンテナを直接起動します（`just run` はデタッチモードで `-e` を転送しません）:

```bash
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
```

## 実行する（開発）

```bash
npm install
npm run dev        # http://localhost:8080
```

開発モードにはエントリポイントがないため、プレースホルダーは差し込まれません -- ターゲットはクエリ文字列で渡してください:

```
http://localhost:8080/?server=<host-ip>&port=49100
```

## 自分のページへの統合

統合全体は 3 ステップです（`src/main.ts` を参照）:

```ts
import { buildStreamConfig, connectStream } from 'stream-core';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
connectStream(streamConfig, { onStart: () => console.info('connecting...') });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe による代替手段

ストリーミングライブラリを自分のアプリにバンドルしたくない場合は、代わりにメインビューアを `<iframe>` に埋め込みます:

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

iframe が直接ストリームへ入るには、埋め込む側のビューアを **`VIEWER_UI_MODE=stream-only`**（または `host.yaml` の `viewer.ui_mode`）で実行してください。既定のモードは対話的な `usd-viewer` で、landing /「UI Option」画面を表示し、Isaac 系の Kit アプリに対しては設計上ブランクになります（#18）。本節がかつて挙げていた `VIEWER_AUTO_LAUNCH` は完全に削除されました（BREAKING、D7）。ストリームだけの画面へ直接入る動作は、現在は `VIEWER_UI_MODE=stream-only` で選択します。

このサンプルの直接接続のアプローチは、レイアウトとライフサイクルを完全に制御できます。iframe はコード不要の選択肢です。

## テスト / lint

```bash
npm test           # node --test (resolveTarget unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
