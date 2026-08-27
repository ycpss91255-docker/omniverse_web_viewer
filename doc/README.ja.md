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

## 公開イメージ

git tag を打つたびに、同じ commit から同じ CI run のなかで GitHub Release **と**対応するコンテナイメージの両方が公開されます。したがって両者は常に対で存在します — イメージからその元になった release をたどれますし、release からそのイメージも分かります：

```
ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

イメージの tag は release のバージョンから先頭の `v` を除いたものです。この値は CI が git tag から導出するもので、人が入力することはありません。だからこそ release とイメージがずれることがありません：

| Git tag | イメージ |
|---------|----------|
| `v0.3.0` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0` |
| `v0.3.0-rc1` | `ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0-rc1` |

リリース候補も公開されます。正式な tag を切る前に実際に検証されるのは rc だからです。

公開は **tag のときだけ**行われます（ほかに、メンテナが手動で再公開するための経路があります）。pull request や `main` への push では何も公開されません。`:latest` は意図的に用意していません。バージョンを固定してください。そうすれば、後続の release や rc が動作中のものを黙って置き換えることはありません。

公開されるのは軽量な `runtime` stage で、アーキテクチャは `linux/amd64`（CI がビルドして検証している唯一のプラットフォーム）です。ほかのアーキテクチャは `just build` でローカルにビルドしてください。

```bash
docker run --rm -d --name owv \
  -e SIGNALING_SERVER=<host-ip> \
  -e SIGNALING_PORT=49100 \
  -e VIEWER_UI_MODE=stream-only \
  -p 5173:5173 \
  ghcr.io/ycpss91255-docker/omniverse_web_viewer:<version>
```

そのうえで Chrome から `http://<host-ip>:5173` を開きます。設定できる項目は下記の環境変数の表のとおりです。

## 環境変数

| 変数 | デフォルト値 | 用途 |
|------|-------------|------|
| `SIGNALING_SERVER` | `127.0.0.1` | WebRTC シグナリング用ホスト IP |
| `SIGNALING_PORT` | `49100` | WebRTC シグナリングポート（Kit アプリの `--/app/livestream/port` と一致させる必要があります） |
| `MEDIA_PORT` | null（ネゴシエーション） | WebRTC メディアポート — 未設定なら SDP でネゴシエーション、設定すると固定（D1、`stream-only` アプリのみ） |
| `SERVE_PORT` | `5173` | 静的ファイルサーバーがリッスンするポート |
| `VIEWER_UI_MODE` | `usd-viewer` | アプリセレクタ：`usd-viewer`（上流 sample、インタラクティブ）または `stream-only`（自前のフルスクリーン自動接続アプリ。Isaac Sim / ヘッドレス利用者向け） |

`VIEWER_UI_MODE` は entrypoint がどのアプリを配信するかを選択するもので、アセットには注入されません。`SIGNALING_SERVER`、`SIGNALING_PORT`、`MEDIA_PORT` は注入されるセンチネルです: ビルドはセンチネルを含む各チャンクを `*.js.tmpl` として保存し、entrypoint は起動のたびに `*.js.tmpl -> *.js` を再レンダリングします（冪等 — 再起動や値の変更は次回起動時に反映）。バリデーションがエスケープそのものです: 無効な値はコンテナを失敗させ（`exit 1`）、壊れた JS を焼き込みません。拒否されるのは: `A-Za-z0-9.-` 以外の文字を含む `SIGNALING_SERVER`、および `SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT` のいずれかが「先頭ゼロなしの 1..65535 の整数」でない場合です — したがって `80x`、`0`、`99999`、`049100` はすべて失敗します。先頭ゼロの規則は些末ではありません: ポートのセンチネルは引用符なしで置換されるため、`049100` は裸の `049100` トークンとしてレンダリングされ、strict mode では `SyntaxError` となり、コンテナは正常に起動したのにビューアは真っ黒になります。`SERVE_PORT` は設定されている場合のみ検査されます（`example` ステージは `EXAMPLE_PORT` で配信します）。また、素のポート番号でも `serve -l` のエンドポイントでも構いません — `SERVE_PORT=tcp://127.0.0.1:5173` はループバックのみにバインドし、これがビューアを全インターフェースで待ち受けさせない唯一の方法です。対応する形式はちょうど 2 つ、`<port>` と `tcp://<host>:<port>` です。`serve -l` はさらに 2 形式を挙げていますが、どちらもうっかりではなく明示的に拒否します: UNIX ドメインソケット（`unix:/path/to/socket.sock`）はこのコンテナの利用者から到達できず（ブラウザは URL を叩き、イメージ自身の serve スモークも 2 つの e2e ランナーも `http://127.0.0.1:<port>` を curl します）、Windows の名前付きパイプ（`pipe:\\.\pipe\Name`）は公開される linux/amd64 イメージには存在し得ないためです。メディアセンチネルは `stream-only` バンドル（その `streamTarget.json`）にのみ存在し、`usd-viewer` は server + port のみを持ち、メディアは SDP でネゴシエーションします。配信されるバンドルはそのレンダリング結果のみをターゲットとします: `?server=`/`?port=`/`?media=` のクエリ文字列は `npm run dev` 用の利便機能であり、ビルドされたバンドルでは無視されるため、リンク 1 本で稼働中のビューアを別のホストへ向け直すことはできません。

ポート（`SIGNALING_PORT` / `MEDIA_PORT` / `SERVE_PORT`）は `.env` メカニズム（`[environment]` テーブル / `setup.conf`）で配送され、`host.yaml` でもハードコードの `-e` でもありません。`config/host.yaml` は `public_ip`（および任意で `viewer.ui_mode`）のみを保持します。優先順位: `public_ip` / `ui_mode` -> `host.yaml` > env > デフォルト、ポート -> `.env`。`config/host.yaml.example` を参照。どちらのキーも「自分のセクション」からのみ読まれます（`network.public_ip`、`viewer.ui_mode`）。このファイルは設計上ホスト上の他のコンテナと共有されるため、他人のセクションにあるキーには手を出しません。列 0（どのセクションにも属さない位置）に書かれたキーも読まれません — そしてここで 2 つのキーの扱いが分かれます。列 0 の `public_ip:` は entrypoint が**起動を拒否**し、そのキーが属すべきセクション名を示します: `network:` セクションが無いこと自体が異常であり（そのセクションこそこのファイルを読む理由です）、無視すれば env / デフォルトのまま誰も選んでいないアドレスへ接続しにいくことになるからです。列 0 の `ui_mode:` は**標準エラー出力に報告したうえで無視**します: `viewer:` セクションが無いのは通常の状態であり（モードは通常 `VIEWER_UI_MODE` から与えられます）、ここで拒否すれば、他のコンテナが所有するキーのせいで正しく構成されたビューアが起動できなくなります — しかも「本来こちら宛てで書き方を誤った」のか「他人のキー」なのかを、ファイルの内容から区別する手がかりはありません。この 1 行は、無視されたキー、実際に有効なモード、そしてその出どころを示します。

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
- **接続拒否 / ストリームが表示されない** — `SIGNALING_SERVER` / `SIGNALING_PORT` が動作中の Kit アプリを指していること、およびその Kit アプリで NVCF ライブストリームが有効になっていることを確認してください。リモートブラウザの場合は `host.yaml` で `network.public_ip` を設定してください。`stream-only` では、接続を試みている間は `connecting to <server>:<port>...` と表示されます — 最初のフレームが描画されるまで判断材料がないため、ストリームが成立したとは決して主張しません。約 20 秒経っても映像が届かない場合は `no video from the source -- it never started. Check that it is running, then reload.` に変わります。プロデューサが後から起動した場合、実際のフレームが届いた時点でこのメッセージは自動的に消えます。ビューアはバックグラウンドでセッション開始のリトライを続けており、描画されたフレームはビューア自身が先に下した判断より優先されるためで、このケースで再読み込みは不要です。
- **セッション中に映像が固まり、`stream stopped -- waiting for frames to resume...` または `stream ended -- the source is gone` と表示される**（`stream-only` のみ） — ストリーム開始後に Kit のプロデューサが消えました。ビューアはストリーミングライブラリからの通知で気づきますが、ライブラリが何も知らせない場合は映像そのものから判断します（約 5 秒間、新しいフレームが来なければ十分です）。前者は映像が戻るかどうかをビューアが待っている状態です。自動で再接続は行われないため、約 15 秒以内に新しいフレームが描画されなければ後者の終了メッセージに切り替わります。Kit アプリの復旧後にページを再読み込みするのが新しいストリームを得る通常の方法ですが、フレームが実際に再び届き始めた場合は、正常に再生されている映像の上に残り続けることなく、このメッセージも自動的に消えます。ストリーミングホスト上の Kit プロセスを確認してください。
- **コンテナが起動直後に終了する** — エントリポイントはレンダリング前に設定を検証し、無効な値はエラーメッセージとともに拒否され、壊れたビューアは起動しません。拒否されるのは: `SIGNALING_PORT` / `MEDIA_PORT` が「先頭ゼロなしの 1..65535 の整数」でない場合 — `80x`、`0`、`99999`、`049100` はすべて失敗します。`SERVE_PORT` はその整数か、ポート部分が同じ規則を満たす `tcp://<host>:<port>` エンドポイントのどちらかでなければ拒否されます（`serve -l` の残り 2 形式 `unix:` / `pipe:` は理由付きで明示的に拒否します）。ほかに、不明な `VIEWER_UI_MODE`、または不正な文字を含む `SIGNALING_SERVER`（`host.yaml` の値末尾に紛れ込んだインライン `#` コメントを含む）、存在するが読み取れない `host.yaml`、あるいは `public_ip` を読み取り対象のセクション（`network:`）の外に書いた `host.yaml`。最後のケースは黙って無視せず拒否します — 無視すれば env / デフォルトのまま起動し、誰も選んでいないアドレスへ接続することになるからです。位置を誤った `ui_mode:` はコンテナを終了させ**ません**: 標準エラー出力に報告され、ビューアは実際に有効なモードで起動します。表示された環境変数 / `host.yaml` の値を修正してください。
- **ブラウザコンソールを開く**（F12） — WebRTC の接続エラーはそこに記録されます。

## スモークテスト

詳細は [TEST.md](test/TEST.md) を参照してください。

PR ごとのゲートに加えて、セルフホストの GPU ランナー上で毎晩実行される `tier-b-visual-e2e` ジョブがあります。実際の Kit ストリームソースを起動し、ヘッドレスブラウザで `stream-only` ビューアに本当に映像が出ていること — `RTCPeerConnection` が connected になり、リモートトラックを受信し、`videoWidth > 0` で、サンプリングしたフレームが真っ黒でないこと — を検証します。つまり「映像が出ている」ことを人がページを見て確かめるのではなく、CI が証明します。

このジョブはリリースゲートでもあります: リリース対象のコミットでこれが通らない限り、いかなるバージョンも公開されません。override も `continue-on-error` もないため、GPU ランナーが利用できなければリリースはブロックされます。この配線自体もテスト対象です — `release_gate_workflow.bats` は `.github/workflows/main.yaml` を読み、ゲートの `if:` / `needs:` 構造が取り除かれると失敗します。さらに、その性質だけを削除したワークフローのコピーに対してチェッカーを再実行し、各アサーションが実際に失敗しうることを証明します。 このチェックは job レベル、step レベル（gate job の作業 step がスキップされても job は `success` を返し、`needs:` から見えるのはそれだけです）、およびファイルから導出した「公開しうる job」の集合を対象とします — 名前のリストではありません。しかもワークフローをテキストとしてパターンマッチするのではなく、YAML として解析します: `script/ci/check_release_gates.py` が本物のパーサで `.github/workflows/main.yaml` を読みます — テキスト比較だった以前の 2 版がレビューで素通りされたためです。これは意図的に狭いゲートであり、何が見えないかの正式な一覧は `script/ci/check_release_gates.py` のヘッダにあります。ここでは繰り返さず、その 1 か所に置いています。README に残す価値のある限界は 1 つだけで、それはチェッカーの話ではありません: branch protection と required status checks は repo の設定であり、このリポジトリのどこでもチェックしていません。

同じジョブは**タグを push するたびにも実行され**、GitHub Release と GHCR image の両方がこのジョブをゲートとしています。そのコミットで映像が検証されていない限り、いかなるバージョンも公開されません。強制的に通すためのスイッチは意図的に用意していません — GPU ランナーが使えない場合、リリースは未検証のまま公開されるのではなく、ブロックされます。

GPU を備えたホストであれば、同じ受け入れテストをローカルでも実行できます:

```bash
just build -t e2e-test               # ビューアとブラウザを 1 つの image に
bash script/ci/tier_b_visual_e2e.sh  # ソースを起動し、ブラウザを駆動する
```

インスタンス単位のコンテナ名を使い、ポートは空いていることを確認してから使用するため、同じホストで動作中の開発用・デモ用スタックを妨げません。

## ライセンス

[Apache-2.0](../LICENSE)
