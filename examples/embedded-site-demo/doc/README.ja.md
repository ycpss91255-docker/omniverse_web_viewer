# embedded-site-demo

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

ライブの Isaac Sim / Kit ストリームを「実際のウェブサイト」ページに直接埋め込む、自己完結型のサンプルサイトです。これは **ショーケース**（ヘッダー + レイアウトとライブストリームパネル）であると同時に、**開発者向けリファレンス**（クリーンでコピー&ペーストできる統合コード）でもあります。

メインビューアとは異なり、このサンプルは純粋な **vanilla TypeScript + Vite** であり、**ランタイム依存は 1 つだけ**です -- `@nvidia/omniverse-webrtc-streaming-library`。React も bootstrap も選択画面もありません。ストリーム専用の直接接続を行います。

## レイアウト

| ファイル | 役割 |
|------|------|
| `index.html` | サイトの外枠（ヘッダー / ナビ / ヒーロー）+ ストリームパネル（`<video id="remote-video">`）。 |
| `src/main.ts` | DOM + ライブラリの接着部: ターゲットの解決、接続、ステータスの表示。 |
| `src/buildStreamConfig.js` | DIRECT ストリーム設定を生成する、純粋で DOM 非依存のファクトリ。検証済みかつユニットテスト済み。 |
| `src/buildStreamConfig.test.js` | ファクトリ向けの `node --test` ユニットテスト。 |
| `src/streamTarget.json` | ビルド時の `__OWV_SERVER__` / `__OWV_PORT__` プレースホルダー。 |

## 実行する（コンテナ）

このサンプルは、ビルド済みのサイトを `EXAMPLE_PORT`（8080）上で配信する Docker の `example` ステージです。メインビューア（5173）とは別であり -- 両方を同時に実行できます。**ページ** は `http://<host>:8080` で開きます。`SIGNALING_SERVER` / `SIGNALING_PORT`（デフォルト `49100`）は、ページを Kit/Isaac の **ストリーム** のシグナリングへ向けるためのものです -- これはページが接続する先であって、開く URL ではありません。

イメージをビルドし、動作中のストリームを指定して host ネットワークで実行します（`SIGNALING_SERVER` は Kit/Isaac ストリームを実行しているホストです）:

```bash
make build -- -t example
docker run --rm -d --network=host \
  -e SIGNALING_SERVER=<host-ip> -e SIGNALING_PORT=49100 -e EXAMPLE_PORT=8080 \
  local/omniverse_web_viewer:example
# then open http://<host-ip>:8080
```

エントリポイントは起動のたびに、`SIGNALING_SERVER` / `SIGNALING_PORT`（env）または `/etc/host.yaml`（`network.public_ip`）から `__OWV_SERVER__` / `__OWV_PORT__` を、ビルド済みバンドルへ差し込みます。

> 注意: `make run -- -t example -d` はまだ使用できません -- `example`（および `serve`）compose サービスは `devel` から `/dev:/dev` のデバイスマウントを継承しており、起動時に `/dev/pts` エラーで失敗します（#26 で追跡中）。修正されるまでは上記の `docker run` の形式を使用してください。（また `make run` はデタッチモードで `-e` の env 変数を転送しません。）

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
import { AppStreamer, StreamType } from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';

const streamConfig = buildStreamConfig('127.0.0.1', 49100); // validates + returns a DIRECT config
AppStreamer.connect({ streamConfig, streamSource: StreamType.DIRECT });
// needs <video id="remote-video"> + <audio id="remote-audio"> in the DOM
```

### iframe による代替手段

ストリーミングライブラリを自分のアプリにバンドルしたくない場合は、代わりにメインビューアを `<iframe>` に埋め込みます。自動起動（#14）を使えば、選択画面なしで直接ストリームへ起動します:

```html
<iframe src="http://<viewer-host>:5173/" allow="autoplay" style="width:100%;height:60vh;border:0"></iframe>
```

このサンプルの直接接続のアプローチは、レイアウトとライフサイクルを完全に制御できます。iframe はコード不要の選択肢です。

## テスト / lint

```bash
npm test           # node --test (buildStreamConfig unit tests)
npm run lint       # eslint
npm run build      # vite build -> dist/
```
