# TEST.md

**174 tests** total: **79 bats** (repo-level smoke, `test/bats/smoke/devel-test/`, run in the `devel-test` stage) + **86 node** (per-package unit, `node --test`, run in the package builds and `devel-test`) + **9 Playwright** (browser e2e, `test/e2e/`: **8 tier-1** -- config dial + status states, run per-PR in the `e2e-test` extra stage -- plus **1 tier-B** visual acceptance against a real Kit producer, run nightly on a self-hosted GPU runner and on every release).

Layout follows base ADR-00000012, the tool-first convention as of base v0.42.0: `test/<tool>/<category>/<stage>/` at the multi-tool repo level, where the leaf names the Dockerfile stage the specs are built to run in, so the specs a stage owns are exactly the ones its `COPY` names. Each npm package still carries its own single-tool `test/`, and `test/e2e/` stays flat (one tool, one category, three suites split by Playwright project rather than by directory; its runners resolve self-relatively).

## test/bats/smoke/devel-test/omniverse_web_viewer_env.bats (41)

Two-app config-injection model (S5): the build preserves sentinel-bearing chunks as `*.js.tmpl` per app dir (`/app/usd-viewer/dist`, `/app/stream-only/dist`); the entrypoint resolves `VIEWER_UI_MODE` (app selector), validates every value, and re-renders ONLY the active app's templates on every boot with 3 seds (`__OWV_SERVER__` / `"__OWV_PORT__"` / `"__OWV_MEDIA_PORT__"`).

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint check |
| `bash is available on PATH` | Shell availability |
| `SIGNALING_SERVER env defaults to 127.0.0.1` | Runtime env default |
| `SIGNALING_PORT env defaults to 49100` | Runtime env default |
| `SERVE_PORT env defaults to 5173` | Runtime env default |
| `VIEWER_UI_MODE env defaults to usd-viewer` | App-selector default (D7) |
| `both app dist dirs exist (devel has both modes)` | `/app/usd-viewer/dist` + `/app/stream-only/dist` both present |
| `usd-viewer build preserves server/port templates, no media sentinel` | Per-app sentinel shape: usd-viewer carries server/port ONLY |
| `stream-only build preserves all three sentinels in templates` | stream-only carries server/port/media (from `streamTarget.json`) |
| `default mode (usd-viewer) renders defaults + clears sentinels` | Render path: sentinels gone from `*.js`, kept in `*.js.tmpl` |
| `default mode renders ONLY the usd-viewer dir, not stream-only` | Mode isolation -- inactive app untouched |
| `usd-viewer applies SIGNALING_SERVER env override` | Distinctive-IP render proof |
| `usd-viewer applies SIGNALING_PORT env override` | Distinctive-PORT render proof -- every other port assertion used 49100, which is the baked default |
| `VIEWER_UI_MODE=stream-only renders the stream-only dir` | App selector switches the render target |
| `stream-only unset MEDIA_PORT renders literal null (negotiate, D1)` | Media default = null = SDP negotiation |
| `stream-only MEDIA_PORT=47998 pins the media port` | Media knob pinned when set (D1) |
| `re-render is idempotent with changed values (de-one-shot, #17)` | Second render wins, first value gone |
| `host.yaml public_ip takes precedence over env` | `host.yaml` > env > default |
| `host.yaml inline comment is stripped from the value` | `yaml_value` comment handling (#104-class) |
| `host.yaml viewer.ui_mode selects the served app` | App selector via host.yaml |
| `host.yaml public_ip in a FOREIGN section does not win` | `/etc/host.yaml` is shared with other containers by design (isaac#65); an unscoped lookup let a foreign section's `public_ip` silently repoint the viewer, exit 0 and HTTP 200 |
| `host.yaml ui_mode in a FOREIGN section is ignored, not enum-checked` | The same unscoped lookup made a foreign `ui_mode` fail our enum and refuse to boot |
| `a FLAT host.yaml key is refused, not silently ignored` | Scoping the lookup to `network:` / `viewer:` stopped matching column 0, so a flat `public_ip:` went from working to being ignored -- exit 0, HTTP 200, dialling the env default instead of the address in the file. Refused with the section named, not guessed at (exit 1) |
| `a top-level key does not refuse when the section supplies the value` | The refusal must not fire on a properly configured file: `/etc/host.yaml` is SHARED (isaac#65), so a stray top-level key someone else's container reads is ordinary, and our own section still wins |
| `a top-level ui_mode does not block a viewer the env configures` | Only the `public_ip` half of the case above was covered, and the `ui_mode` half was where the refusal over-fired: a missing `viewer:` section is the NORMAL documented state (the mode usually comes from env), so the refusal precondition was met on ordinary correct files and the container would not boot over a key another container owns |
| `a top-level ui_mode is named when nothing else supplies a mode` | The genuine case -- an operator who meant that key for us -- is still TOLD, on stderr, naming the mode actually in effect; it is not enforced, because the built-in default is itself a supported configuration and refusing would block a valid boot too |
| `a top-level ui_mode is not reported when the viewer section supplies it` | The note must not become background noise on a correctly written file |
| `an unreadable host.yaml fails the container, not falls back` | awk's failure was swallowed, so a mode-000 / wrong-owner file booted silently on env/defaults and dialled an address nobody chose (exit 1) |
| `entrypoint exports the resolved VIEWER_UI_MODE for the CMD` | Export-before-exec so the CMD serves the resolved dir |
| `non-numeric SIGNALING_PORT is rejected` | Validation (exit 1) |
| `SIGNALING_PORT with a leading zero is rejected` | `049100` renders as the bare token `049100`, a strict-mode SyntaxError -> black page from a container that started fine (exit 1) |
| `out-of-range SIGNALING_PORT is rejected` | 1..65535, same rule MEDIA_PORT always had (exit 1) |
| `invalid VIEWER_UI_MODE is rejected` | Enum validation (exit 1) |
| `non-numeric MEDIA_PORT is rejected` | Optional-knob validation (exit 1) |
| `out-of-range MEDIA_PORT is rejected` | 1..65535 (exit 1) |
| `MEDIA_PORT with a leading zero is rejected` | Same bare-token substitution, same SyntaxError (exit 1) |
| `out-of-range SERVE_PORT is rejected` | `SERVE_PORT=0` would serve the viewer on a port nobody chose (exit 1) |
| `SERVE_PORT accepts a tcp:// listen endpoint` | `serve -l` takes an endpoint, and that is the only way to scope the listen ADDRESS (`tcp://127.0.0.1:5173` binds loopback only) |
| `a malformed tcp:// serve endpoint is rejected` | Host with no port, and a host with a bad port, both fail fast (exit 1) |
| `a unix:/pipe: serve endpoint is refused by name` | `serve --help` documents four endpoint forms; only the two NETWORK ones are supported. A UNIX socket is unreachable by the browser and by every HTTP gate here, a Windows named pipe cannot exist in the published linux/amd64 image, and the message says that instead of reporting a bad integer (exit 1) |
| `SIGNALING_SERVER with shell/sed metacharacters is rejected` | Validation IS the escaping (security) |

## test/bats/smoke/devel-test/example_demo.bats (5)

| Test | Description |
|------|-------------|
| `example: key files exist` | index.html / package.json / main.ts / resolveTarget.js + its test |
| `example: depends on stream-core + the streaming library only` | Exactly 2 runtime deps |
| `example: imports the factory from stream-core (local copy deleted)` | No duplicate `buildStreamConfig` (S3 dedup) |
| `example: streamTarget.json carries all three sentinels` | server/port/media sentinels present |
| `example: resolveTarget unit tests pass (node --test)` | Runs the example's own glue tests in-image |

## test/bats/smoke/devel-test/derive_image_tag.bats (15)

Guards `script/ci/derive_image_tag.sh`, which decides the GHCR image tag for the `publish-image` job (#66). The release/image pairing only holds because that tag is DERIVED from the git ref instead of typed in, so this is the table of refs a real push produces -- and the only part of the tag-triggered publish path provable without pushing a tag. The script is copied into the image at `/ci/` by the `devel-test` stage and run there.

| Test | Description |
|------|-------------|
| `script is present and executable` | The deriver is actually shipped into the image at `/ci/` |
| `a release tag drops the v (v0.3.0 -> 0.3.0)` | The primary path: git ref -> image tag |
| `an rc tag is preserved (v0.3.0-rc1 -> 0.3.0-rc1)` | Pre-releases are first-class -- the rc is what gets verified |
| `a tag without the v prefix still resolves` | `v` is stripped, not required |
| `the git ref wins over a differing dispatch input` | The escape hatch cannot override a tag -- that would BE the drift |
| `workflow_dispatch input is used off a branch` | The escape hatch works where there is no tag to derive from |
| `a v-prefixed dispatch input is tolerated` | Typing `v0.3.0` in the box still yields `0.3.0` |
| `the resolved tag is the only thing on stdout` | The workflow captures stdout verbatim; provenance stays on stderr |
| `provenance names the rule that fired` | The CI log records WHICH rule produced the tag |
| `a plain main push publishes nothing` | Nothing publishes on a `main` push |
| `a dispatch with an empty input publishes nothing` | An empty escape hatch is a no-op, not a guess |
| `a non-version tag is refused, not published` | `vlatest` can no longer reach the workflow (the push trigger matches the version SHAPE, not `v*`), but the dispatch escape hatch types a version by hand and no glob sees it |
| `a malformed pre-release suffix is refused` | The refs that DO still slip past the trigger: GitHub's tag filters have no alternation or anchored classes, so `v[0-9]+.[0-9]+.[0-9]+-*` accepts `v1.2.3-`, `v1.2.3-rc_1`, `v1.2.3-rc1+b`. The `verify-tag-shape` job stops them by running this script before anything irreversible, so this is the assertion that job rests on |
| `a truncated version tag is refused` | `v0.3` is not MAJOR.MINOR.PATCH |
| `a dispatch input that is not a version is refused` | Same validation on the escape-hatch path |

## test/bats/smoke/devel-test/tier_b_visual_e2e.bats (4)

Guards the EXIT STATUS of `script/ci/tier_b_visual_e2e.sh`, the Tier B driver. Its header says `Exit 0 = a real browser saw a real, non-black frame`, and the workflow's picture gate believes exactly that -- so exiting 0 without having asserted a picture is the one failure this script may never have. It could: `cleanup()` took `local rc=$?` and ended `exit "${rc}"` while trapped on `EXIT INT TERM`, and on a signal path `$?` is the last COMPLETED command (the boot-wait `sleep 5`, i.e. 0). No GPU, Kit or docker daemon is involved -- a stub `docker` on `PATH` answers just enough for the driver to reach its boot-wait loop and stay there, which is the state under test. The script is copied into the image at `/ci/`.

| Test | Description |
|------|-------------|
| `the producer image is pinned by digest, not by a mutable tag` | The producer runs as root with `--network=host --ipc=host --gpus all` on the persistent GPU runner, and GHCR tags are mutable; the workflow's pull step asks the driver for the reference, so this covers the pull too |
| `SIGTERM exits non-zero, so a killed run cannot claim a picture` | A GitHub step timeout / job cancellation must not be readable as a verified picture (143) |
| `SIGINT exits non-zero, so a killed run cannot claim a picture` | Same for an interrupt (130) |
| `teardown runs exactly once on a signal path` | The signal handler and the EXIT handler used to be the same function, so its own `exit` re-entered it and `producer.log` was written twice |

## test/bats/smoke/devel-test/release_gate_workflow.bats (14)

Structural lock on the RELEASE INVARIANT, read off `.github/workflows/main.yaml` itself. The rule (#70, after `v0.3.0-rc1` published with no picture ever verified for it) is absolute: no version may publish without the Tier B picture gate having passed on that commit -- no override, no `continue-on-error`, no `if: always()` escape, and an unavailable GPU runner BLOCKS the release. Until this file existed that rule was defended by prose: it lived in `if:` / `needs:` expressions and comments in one workflow and nothing read them, so `|| github.event_name == 'workflow_dispatch'` added to a gate while debugging, or `tier-b-visual-e2e` dropped from a `needs:` list, left every other gate green with the protection gone. `script/ci/check_release_gates.sh` (bash + awk, no YAML dependency -- the test image has neither `python3` nor `yq`) does the reading; the workflow is `COPY`d to `/workflows/main.yaml` and the checker to `/ci/`, the same mechanism the other specs use for their inputs. No GPU, no tag push, no GitHub, no network: it runs on every PR.

Every property is proved TWICE -- once against the shipped workflow (it must hold) and once against a copy with that one property removed (the checker must name its `[id]`). An assertion that cannot fail is the failure this repo has been bitten by three times, so `_mutate` hard-fails when its `sed` matches nothing rather than asserting against an unmodified file.

| Test | Description |
|------|-------------|
| `the checker and the workflow are both in the image` | The spec is worthless if either input is missing |
| `the shipped workflow holds the release invariant` | All nine properties hold on `main.yaml` as committed |
| `a workflow that cannot be read is an error, not a pass` | Vacuity guard: a checker that "passes" on a file it never read reports an invariant that protects nothing (exit 2, distinct from a violation's exit 1) |
| `a workflow with no jobs is an error, not a vacuous pass` | Same guard for a file whose jobs are gone (exit 2) |
| `dropping tier-b from publish-image's needs is caught` | `[publish-image-needs-tier-b]` -- an image pushed for a commit whose picture was never verified |
| `dropping publish-image's tier-b success requirement is caught` | `[publish-image-requires-tier-b-success]` -- its `!cancelled()` means a SKIPPED gate no longer skips the job, so the explicit `result == 'success'` is the only thing left blocking the push |
| `dropping tier-b from call-release's needs is caught` | `[call-release-needs-tier-b]` -- a Release cut for a commit whose picture was never verified |
| `adding a status function to call-release's if is caught` | `[call-release-carries-no-status-function]` -- the load-bearing ABSENCE: with no `always()` / `success()` / `failure()` / `cancelled()`, GitHub's default skip propagation applies, and that default is the whole mechanism by which an unavailable GPU runner blocks a release |
| `continue-on-error on a gate job is caught` | `[gate-job-has-no-continue-on-error]` -- turns a gate into a suggestion, at job or step level, on any of the five publish-path jobs |
| `making a report-only job a dependency is caught` | `[no-job-needs-a-report-only-job]` -- `release-blocked-report` / `nightly-tier-b-report` use `always()` and exist only to ADD a failure; a job that waits on one inherits that `always()` |
| `removing the tag push trigger is caught` | `[workflow-triggers-on-tag-push]` -- a tag that does not start the workflow never reaches the gate |
| `tier-b losing its bare tag-push alternative is caught` | `[tier-b-reachable-on-every-tag-push]` -- the gate must run for every tag push, not some |
| `tier-b's tag alternative becoming a top-level AND is caught` | Same id, subtler mutation: the alternative is still there but ANDed, so the condition is false for an ordinary tag push. A substring grep passes this; splitting the expression at parenthesis depth 0 does not |
| `giving verify-tag-shape a job-level if is caught` | `[verify-tag-shape-has-no-job-level-if]` -- the gate needs it, and a SKIPPED need skips its dependent, so it carries no job-level `if:` by design (the tag check is guarded per-step) |

`script/ci/check_release_gates.sh` is the checker, not a counted spec.

## packages/stream-core/test/ (20, node --test)

The kernel's contract -- the ONLY package touching the NVIDIA streaming library (lazy import; tests run registry-free).

- `buildStreamConfig.test.js` (16): valid server+port config shape (DIRECT essentials incl. `remote-video`/`remote-audio` ids), string-port coercion, hostname accept; rejects empty/whitespace/sentinel/metachar server, non-numeric / non-integer / out-of-range port; media-port arg -- omitted when unset/null, pinned when valid int, string coerced, non-integer / out-of-range throw (D1).
- `connectStream.test.js` (4): `buildStreamProps` defaults all 5 lifecycle handlers to no-ops, preserves config fields, caller handler wins; `connectStream` hands the assembled cfg to an injected connector without loading `@nvidia`.

## apps/stream-only/test/ (59, node --test)

- `resolveTarget.test.js` (8): target fallback (entrypoint-substituted values), `?server=&port=` override, `?media=` override, unsubstituted media sentinel -> null, missing/empty media -> null, server sentinel passes through (rejected downstream by `buildStreamConfig`), and the two that describe the PUBLISHED bundle: the query override is ignored when the caller does not opt in, and an explicit `false` is the same as omitting it. The override is a `npm run dev` convenience -- `main.ts` passes `import.meta.env.DEV`, which `vite build` replaces with `false` -- so a URL cannot repoint a shipped viewer (and, with `nativeTouchEvents`, take its user's input with it).
- `streamStatus.test.js` (51): the `#stream-status` show/hide controller (#53), the producer-loss transitions (#56), the locally derived terminal state (#58), the honest recoverable wording (#60), the media-driven loss detection (#62), the bounded connect attempt (#63) and the latch that outranks claims but not observation (#73). Show/hide (7): `show()` writes the readout and leaves it visible; `show(text, true)` sets the error class; the readout hides on the first video `playing` event (and on `loadeddata`); re-showing after a hide un-hides it (reconnect/error); `show`/error route to `logger.info` / `logger.error`; tolerates null status/video elements. Producer loss (8): `stopped()` re-shows a visible, non-error, waiting-for-frames readout after the first frame had cleared it; neither producer-loss state may claim a reconnect is under way (#60 regression lock -- the library has no mid-session reconnect path); `terminated()` shows a distinct terminal state with the error class; the terminal state is sticky against a later `stopped()` and against a stray video event; `stopped()` logs as info and `terminated()` as error; the #53 happy path (start -> first frame -> cleared, no error) is locked as a no-regression case; the lifecycle transitions tolerate null status/video elements. Terminal-state derivation (12, all driven by an injected fake clock -- no real waiting): `show()` alone arms nothing; `stopped()` arms exactly one escalation with the injected delay; firing it reaches the terminal state with no `onTerminate` callback; a frame after `stopped()` disarms the escalation, clears the readout (#53) and a stale timer cannot resurrect the terminal state; a stop after a recovery re-arms; repeated `stopped()` keeps a single timer; the escalated terminal state is latched against a later `stopped()` (no re-arm) and against a stray video event; `terminated()` disarms a pending escalation; the escalation logs as an error; it tolerates null status/video elements; the exported default delay is long enough not to disturb the config-dial e2e. Media-driven loss detection (9, same injected clock, plus a fake video element that reports frame progress): a video element that reports no progress never arms the watchdog (which is what leaves every spec above, and the dead-host config-dial e2e, untouched); the watchdog arms on the first rendered frame and not before; frames that keep arriving never announce a loss; frames that stop arriving announce the recoverable state with no `onStop` involved and arm the ordinary #58 escalation; resumed frames clear it and disarm the escalation (#53); an unrecovered stall escalates to the same terminal state; `onStop` stays an accelerator (a stall detected after it neither re-announces nor re-arms -- same timer id, so the terminal state still lands one window after the first signal); the terminal state turns the watchdog into a recovery watch (the poll survives the transition, a frozen picture holds the state poll after poll, and frames that advance again clear it with no video event involved -- rewritten by #73, having previously asserted the defect: that nothing stayed armed and later frames could not clear it); the exported stall window is long enough to ride out a hiccup and shorter than the escalation window. Connect attempt (10, same injected clock): `connecting()` shows a visible, non-error attempting readout and arms exactly one window with the injected `connectDelayMs`; the window elapsing with no frame ever rendered reaches an actionable terminal state (`no video` + `reload`, error class, and no claim of a stream, a wait or a reconnect); that never-started copy is distinct from the mid-session terminal one and does not say anything ended; a first frame cancels the connect window, clears the readout (#53) and a stale timer cannot then declare a live stream dead; repeated `connecting()` (the session-start retries `onStart` makes) keeps the SAME timer, so the deadline is never pushed back; `show()` cannot overwrite the terminal state (the guard `hide()` / `stopped()` always had -- its absence was defect 2); `connecting()` after the terminal state is ignored and arms nothing; a connect retry does not overwrite an announced producer loss nor re-arm its escalation; it tolerates null status/video elements; the exported default connect window is long enough not to disturb the config-dial e2e. Claims vs. observation (5, same injected clock plus the progress-reporting fake video element): frames arriving after the connect window elapsed clear the terminal state and withdraw its error styling; a session-start retry (`connecting()` / `show()`) cannot touch it even once frames have advanced, while the media path on the same controller and the same frames still can; `stopped()` cannot touch it on the same terms; a terminal state with no frames stays terminal poll after poll, including against a `playing` event with no frame progress behind it (the #63 case, which must not regress); and a recovered viewer is fully live again -- a later stall re-announces the recoverable state and re-escalates.

## examples/embedded-site-demo/test/ (7, node --test)

`resolveTarget.test.js`: target fallback, query override (opt-in), `?media=` override (opt-in), unsubstituted media sentinel -> null, server sentinel pass-through, plus the two built-bundle cases -- the query override is ignored by default and an explicit `false` is the same as omitting it. (The example's `buildStreamConfig` tests moved to `stream-core` in S1/S3.)

## test/e2e/ (9, Playwright + headless Chromium)

Three suites, three Playwright projects, two gates. Standalone and `@nvidia`-free (outside the npm workspaces). All drive the REAL dist served by the `runtime` image.

- **Tier 1 (8, per-PR, no GPU)** -- `config-dial.spec.ts` + `status-loopback.spec.ts`. `run-in-image.sh` renders the sentinel templates via the production entrypoint with distinctive test values (`10.20.30.40:49177`, media `47998`), serves each mode, then runs Playwright against it. It names its two projects explicitly, so the Tier B project can share the directory without ever being picked up by the per-PR gate — and runs them ONE PROJECT PER INVOCATION, because Playwright evaluates its "No tests found" guard over the whole selection: selecting both at once reports `1 skipped` and exit 0 for a project that matched zero spec files, so a renamed or lost spec would drop out of the gate while the runner still printed `all modes passed`.
- **Tier B (1, nightly, self-hosted GPU)** -- `tier-b-visual.spec.ts`. `run-tier-b.sh` serves `stream-only` pointed at a REAL Kit producer and asserts real frames render.

### `config-dial.spec.ts` (2) -- project `chromium`

Tier-1 browser config-dial e2e (#47). The specs wrap `window.WebSocket` / `window.RTCPeerConnection` (via `addInitScript`, before app code) to record dial targets and listen for the `owv:dial` CustomEvent; the app dialing a dead host (async failure) is EXPECTED.

| Test | Mode | Description |
|------|------|-------------|
| `stream-only dials the injected target` | stream-only | Asserts the `owv:dial` event detail (server/port/media) matches the injected values (media pinned == `MEDIA_PORT`, null when unset, D1); best-effort WS-URL corroboration; `#stream-status` not in error / no `invalid` |
| `usd-viewer dials the injected target` | usd-viewer | BLACK BOX (upstream unmodified, no event): a short WebSocket-dial window, then a served-JS string-presence fallback -- injected server AND port present, `__OWV_SERVER__` and `__OWV_PORT__` sentinels both absent -- plus no uncaught page error. The dial branch is unreachable against the current upstream build (it starts on `Forms.AppOnly` and only connects after a Next click this spec never performs), which is exactly why the FALLBACK has to be the complete assertion; the window is kept short rather than removed so a future auto-dialing upstream still takes the stronger path |

### `status-loopback.spec.ts` (6) -- project `chromium-loopback`

Browser-level assertions on the `#stream-status` state machine (#62), driven by an in-page WebRTC loopback: a canvas `captureStream()` through a local `RTCPeerConnection` pair into the page's own `#remote-video`, which produces REAL `loadeddata` / `playing` events with real decoded frames behind them -- no GPU, no Isaac, no Kit, no extra service. Stalling the media (`sender.replaceTrack(null)`) is what reaches the loss states, which is only possible because #62 derives them from frame progress rather than from the library's `onStop`. Two specs deliberately start with NO loopback: the never-connected case (#63) is the page dialing the dead test host with no media at all, and the late-producer case (#73) lets that same connect window elapse before handing the page a stream. `stream-only` only (the loopback drives OUR app; `usd-viewer` is black-box), so all six skip in the `usd-viewer` pass.

Its own project because the loopback needs two Chromium switches (`--disable-features=WebRtcHideLocalIpsWithMdns`, `--autoplay-policy=no-user-gesture-required`) that must not change how the config-dial suite launches its browser.

| Test | Description |
|------|-------------|
| `the initial readout is visible and carries the stylesheet base styling` | Real computed style before any frame: visible, text starting `connecting` (the static placeholder or the app's dial readout -- whichever has landed), never `streaming` (#63), `display != none`, colour `rgb(139, 148, 158)`, no `error` class |
| `a viewer whose producer never answers stops claiming a connection (#63)` | NO loopback: dead host, no frame ever -> `connecting to ...` and no `streaming` claim, then after the connect window `no video` / `reload` with the `error` class and colour `rgb(248, 81, 73)` |
| `real frames hide the readout through the real stylesheet (#53)` | Loopback frames arrive -> the element is genuinely hidden (`display: none`), not merely carrying a class |
| `stalled frames announce the recoverable state, resumed frames clear it (#60, #62)` | Media cut -> visible `waiting for frames` readout in the base colour, no `error` class, no reconnect claim; media restored -> hidden again |
| `an unrecovered stall escalates to a distinct terminal state, which a real stream then clears (#57, #58, #62, #73)` | Stall held past the escalation window -> `source is gone` / `reload`, `error` class, colour `rgb(248, 81, 73)` and different from the recoverable colour; the state then holds on its own while the picture stays frozen, and a fresh loopback stream clears it (the second half asserted the opposite before #73) |
| `a producer that starts after the connect window has elapsed clears the readout (#73)` | The `v0.3.0-rc2` shape: dead host -> the connect window elapses -> `no video` in the error colour -> a loopback stream starts late -> the readout is genuinely hidden (`display: none`) again, with no reload |

`run-in-image.sh` is the in-image gate runner (not a counted spec); a non-zero Playwright exit fails the `e2e-test` stage build.

### `tier-b-visual.spec.ts` (1) -- project `chromium-tier-b`

Tier B visual acceptance (#48): the gate that finally proves there is actually a picture, so a human never has to look at the browser again. The media comes from `ghcr.io/ycpss91255-docker/isaac-stream-source` pinned by DIGEST (`@sha256:af1bb815...`, the current `:0.0.1` index digest; GHCR tags are mutable and that container runs as root with `--network=host --ipc=host --gpus all` on the persistent GPU runner, so the pin lives in `script/ci/tier_b_visual_e2e.sh` and moves only by a deliberate edit) (isaac#223 / isaac PR #243) -- a pinned Kit streaming experience rendering a deterministic scene (DomeLight + DistantLight over a 12x12 procedurally built checkerboard floor, fixed camera, RTX auto-exposure disabled) chosen precisely so a connecting browser always gets a non-black frame. A black frame here is a real failure, not scene luck.

ONE test that owns ONE session, asserting five properties of it in order. It wraps `window.RTCPeerConnection` via `addInitScript` to observe the connection the streaming library owns and exposes nothing of.

| # | Assertion | Description |
|---|-----------|-------------|
| 1 | connected peer connection | Polls the recorded `connectionState` until `connected`; logs the full state sequence |
| 2 | a remote media track arrives | A `track` event fired on the library's own peer connection |
| 3 | real dimensions, decoding | `videoWidth > 0` and `getVideoPlaybackQuality().totalVideoFrames > 0` |
| 4 | **the frame is NOT BLACK** | `drawImage` the element into a canvas downscaled to 320 px wide, reduce every 7th pixel to Rec.709 luma: mean >= 8, brightest >= 32, >= 10% of samples above the black floor. Every sample is logged; the frame PNG + stats JSON are saved as evidence |
| 5 | the readout cleared (#53 end-to-end) | `#stream-status` computed `display: none` -- the #53 path closed against a real stream instead of a synthetic one |

**Why one test and not five.** It was five specs in a `describe.serial` sharing a page from `beforeAll`, which reads better but does not work: the stream froze after a single frame every time, while a standalone single-test probe against the same producer, image and flags streamed 3500 frames at 1920x1080 with a mean luma of 152 for a full minute. The page cannot hold a live WebRTC session across test boundaries, so the structure that demonstrably holds a stream is the one used.

**Session warm-up.** `beforeAll`-style warm-up inside the test reloads (each reload is a new session) until frames are *advancing*, up to 4 attempts of 30 s, logging each attempt. This works around isaac#245: the producer's FIRST session after boot never delivers video while the 2nd+ do (measured: 0 frames vs 3521 vs 3525 in 60 s on one producer). The gate requires frames to ADVANCE rather than `totalVideoFrames > 0`, because a single frozen frame satisfies the latter -- exactly the false green this tier exists to eliminate. A producer that never streams exhausts the attempts and fails the run, so the warm-up cannot mask a regression.

`stream-only` ONLY, deliberately. #48's acceptance criteria ask for both viewer modes; that is wrong against an Isaac-family producer, because #18 established that `usd-viewer` (the upstream sample, built UNMODIFIED per D2) only works with the kit-app-template USD Viewer and blanks against Isaac Sim BY DESIGN -- asserting a picture there would fail forever. `usd-viewer` keeps its existing per-PR config-dial cover.

`run-tier-b.sh` (in-container) and `script/ci/tier_b_visual_e2e.sh` (host orchestrator) are runners, not counted specs.

## Where they run

- bats: `devel-test` stage. The stage `COPY`s `test/bats/smoke/devel-test/` into `/smoke_test/`, on top of `.base/test/smoke/` (the shared specs + `test_helper.bash`); both trees flatten into that one directory, so `load "${BATS_TEST_DIRNAME}/test_helper"` resolves and `bats /smoke_test/` runs repo and base specs together. The directory name IS the stage name (base ADR-00000012): all five specs sit under `devel-test/` because that is the only stage in this repo that runs bats. `derive_image_tag.bats`, `tier_b_visual_e2e.bats`, `release_gate_workflow.bats` and `example_demo.bats` could not run anywhere else in any case (`/ci/`, `/workflows/` and `/examples/` exist only here); `omniverse_web_viewer_env.bats` asserts `/app/*/dist` + `/entrypoint.sh`, which `runtime` also has, but `runtime-test` runs `RUNTIME_SMOKE_CMD` (serve + curl) rather than bats, so a `shared/` tree would name a second consumer that does not exist -- add a runtime-test bats block first, then move that one file. That stage also ShellCheck-lints `script/ci/` (copied to `/ci/`), which nothing was linting before #66.
- node: each package's build stage (`stream-only-build` runs stream-core + stream-only tests; the `example` stage runs stream-core + example tests) and locally via `npm -w <pkg> test`.
- runtime smoke: `runtime-test` stage serves BOTH app dists and curls each for 200, then runs two POSTURE REGRESSION GUARDS against the same image (none of the three is counted above; they are stage gates, not spec files):
  - **no passwordless root.** Running as the runtime `USER`, it asserts that `sudo -n true` cannot succeed -- a `sudo` that is absent, or present and refuses, both pass. The `sys` sudoers grant was inherited into every published image for its whole life and nothing noticed, so the posture is only true while something asks the question an attacker with a foothold would ask.
  - **no toolchain in the shipped image.** It asserts that `git`, `npm`, `npx`, `corepack` and `sudo` are all absent, which is the ADR-0001 invariant ("no npm ... no dev toolchain") the built image did not hold until it was checked. `curl` is deliberately NOT in that list -- it is the HTTP client of the two `FROM runtime` test stages.
- Playwright e2e, tier 1: `e2e-test` extra stage (`FROM runtime`, built via the build-worker `extra_stages` input, per-PR, no GPU / Isaac / self-hosted runner). Installs Playwright + Chromium at build time and runs `run-in-image.sh` against the served dists. Both tier-1 projects run in both modes; the mode each suite does not apply to is skipped.
- Playwright e2e, tier B: the `tier-b-visual-e2e` job in `.github/workflows/main.yaml` -- `runs-on: [self-hosted, gpu]`, nightly `schedule`, **every tag push and every manual publish** (#70), plus a `workflow_dispatch` opt-in input; never per-PR (the producer boots Kit, which is minutes, and contends for the GPU). On the release path it is a hard `needs` of `call-release` and of `publish-image`, with no override, no `continue-on-error` and no `if: always()` escape: if it does not report `success`, the Release is not cut and the image is not pushed, and an unavailable GPU runner therefore blocks the release rather than being waved through. That wiring is no longer only asserted in prose -- `release_gate_workflow.bats` reads the workflow and fails when any of it is removed. A `concurrency` group serialises it and never cancels mid-teardown, so a tag pushed while the nightly run is in flight queues behind it. `script/ci/tier_b_visual_e2e.sh` boots the producer with `--ipc=host` (required: Kit boots fine on the default 64 MB `/dev/shm`, but the media pipeline allocates on client ATTACH, so its absence is invisible to any check that stops at "the port is up" -- adding it took time-to-first-frame from ~16 s to 1.9 s; same root cause isaac#233 records), waits for the producer's own `[PRODUCER] empty lit stage streaming` scene-ready marker (NOT `Streaming server started.`, which fires ~11 s earlier, before the scene exists -- "the port is listening" is not "streaming works", the reusable lesson of isaac#233), then runs the SAME `e2e-test` image at container runtime (it is `FROM runtime`, so one container is both the viewer and the browser) via `run-tier-b.sh`. Isolation, per #48's acceptance criterion and the isaac#237 / #239 / #240 / #241 incident class: every container is named `owv-tierb-<instance>-*` and the teardown refuses any name outside that prefix and removes only those two names (no compose project, no `down --remove-orphans`), ports are probed free with bash `/dev/tcp` starting well away from the dev/demo ranges (5173/49100, 5174/49200), and nothing touches a compose project or a shared name. The browser container runs `--rm`; the producer deliberately does not, so its log survives for diagnosis and is saved before the container is removed. Evidence (frame PNG, luma stats, browser trace, producer log) uploads on failure OR cancellation -- the acceptance step carries its own `timeout-minutes` inside the job's budget so an overrun is a step failure rather than a job cancellation, because `if: failure()` does not run in a cancelled job and the next run's pre-checkout step deletes `.tier-b-artifacts`. The producer is started with `--user 0:0` (knob `TIER_B_PRODUCER_USER`) to work around isaac#244, in which the published `:0.0.1` image cannot read its own baked driver as its non-root `USER`.
