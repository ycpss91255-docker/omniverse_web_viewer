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

このサンプルは、メインビューア（5173）とは別の `EXAMPLE_PORT`（8080）上で、プロファイルで制御される Docker ステージとして提供されます -- 両方を同時に実行できます。

```bash
make run -- -t example -d
# open http://<host>:8080
```

メインビューアと同じ方法で、動作中のストリームを指定します: エントリポイントが起動のたびに `SIGNALING_SERVER` / `SIGNALING_PORT`（env）または `/etc/host.yaml`（`network.public_ip`）から `__OWV_SERVER__` / `__OWV_PORT__` を差し込みます。

```bash
make run -- -t example -d -e SIGNALING_SERVER=10.2.23.83 -e SIGNALING_PORT=49100
```

## 実行する（開発）

```bash
npm install
npm run dev        # http://localhost:8080
```

開発モードにはエントリポイントがないため、プレースホルダーは差し込まれません -- ターゲットはクエリ文字列で渡してください:

```
http://localhost:8080/?server=10.2.23.83&port=49100
```

## 自分のページへの統合

統合全体は 3 ステップです（`src/main.ts` を参照）:

```ts
import { AppStreamer, StreamType } from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';

const streamConfig = buildStreamConfig('10.2.23.83', 49100); // validates + returns a DIRECT config
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
