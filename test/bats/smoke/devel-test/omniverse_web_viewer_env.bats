#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the `devel` image built
# from this repo's Dockerfile, via the `devel-test` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, ...) to keep assertions terse.
#
# Config-pipeline model (S5): VIEWER_UI_MODE is an APP SELECTOR (D7). The
# entrypoint serves /app/${VIEWER_UI_MODE}/dist and renders ONLY that dir's
# *.js.tmpl on every boot, after validating every operator value. Each app's
# build preserves its sentinel-bearing chunks as pristine *.js.tmpl:
#   - usd-viewer    carries __OWV_SERVER__ + "__OWV_PORT__"        (server/port)
#   - stream-only   carries those PLUS "__OWV_MEDIA_PORT__"        (+media, D1)
# The render path is proven with DISTINCTIVE server IPs / ports that cannot
# appear except via sentinel substitution. The render is idempotent: it always
# re-renders from the pristine *.js.tmpl, never from a previously-rendered *.js.
#
# devel-test is FROM devel, so BOTH /app/usd-viewer/dist and
# /app/stream-only/dist exist here for the bats to exercise.

USD_ASSETS="/app/usd-viewer/dist/assets"
STREAM_ASSETS="/app/stream-only/dist/assets"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

teardown() {
  # Several tests mount config via /etc/host.yaml; always clear it so a
  # later test sees a clean (env/default-only) state regardless of order.
  sudo rm -f /etc/host.yaml 2>/dev/null || true
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}

@test "SIGNALING_SERVER env defaults to 127.0.0.1" {
  assert [ "${SIGNALING_SERVER}" = "127.0.0.1" ]
}

@test "SIGNALING_PORT env defaults to 49100" {
  assert [ "${SIGNALING_PORT}" = "49100" ]
}

@test "SERVE_PORT env defaults to 5173" {
  assert [ "${SERVE_PORT}" = "5173" ]
}

@test "VIEWER_UI_MODE env defaults to usd-viewer" {
  assert [ "${VIEWER_UI_MODE}" = "usd-viewer" ]
}

@test "both app dist dirs exist (devel has both modes)" {
  assert_dir_exists "${USD_ASSETS}"
  assert_dir_exists "${STREAM_ASSETS}"
}

@test "usd-viewer build preserves server/port templates, no media sentinel" {
  run grep -rF "__OWV_SERVER__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_PORT__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_success
  # usd-viewer keeps upstream native SDP media negotiation -- no media sentinel.
  run grep -rF "__OWV_MEDIA_PORT__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_failure
}

@test "stream-only build preserves all three sentinels in templates" {
  run grep -rF "__OWV_SERVER__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_PORT__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_MEDIA_PORT__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
}

@test "default mode (usd-viewer) renders defaults + clears sentinels" {
  run /entrypoint.sh true
  assert_success
  # Sentinels gone from rendered *.js (the *.js.tmpl keep them).
  run grep -rF "__OWV_SERVER__" "${USD_ASSETS}/" --include="*.js"
  assert_failure
  run grep -rF "__OWV_PORT__" "${USD_ASSETS}/" --include="*.js"
  assert_failure
  # Defaults applied: server 127.0.0.1, port 49100.
  run grep -rF "127.0.0.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "49100" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

@test "default mode renders ONLY the usd-viewer dir, not stream-only" {
  # Distinctive server that must only appear in the active (usd-viewer) dir.
  SIGNALING_SERVER="10.1.1.1" run /entrypoint.sh true
  assert_success
  run grep -rF "10.1.1.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.1.1.1" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
}

@test "usd-viewer applies SIGNALING_SERVER env override" {
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.11.12.13" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

# The server override above had a port-shaped sibling missing: every render
# assertion in this file, and the tier-1 e2e, used 49100 -- which is the baked
# default (Dockerfile ENV, entrypoint fallback, overlay/stream.config.json), so
# none of them could tell a rendered port from a fallback. 49277 can only get
# into the bundle through the sed.
@test "usd-viewer applies SIGNALING_PORT env override" {
  SIGNALING_PORT="49277" run /entrypoint.sh true
  assert_success
  run grep -rF "49277" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

@test "VIEWER_UI_MODE=stream-only renders the stream-only dir" {
  VIEWER_UI_MODE="stream-only" SIGNALING_SERVER="10.2.2.2" run /entrypoint.sh true
  assert_success
  run grep -rF "10.2.2.2" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
  # The active dir's sentinels are cleared.
  run grep -rF "__OWV_SERVER__" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
}

@test "stream-only unset MEDIA_PORT renders literal null (negotiate, D1)" {
  VIEWER_UI_MODE="stream-only" run /entrypoint.sh true
  assert_success
  # Sentinel is gone; the omitted media port becomes the literal null.
  run grep -rF "__OWV_MEDIA_PORT__" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
  # The rendered mediaPort value is the literal null (JSON value, not sentinel).
  run bash -c "grep -rhoE 'mediaPort\"?: *null' ${STREAM_ASSETS}/*.js"
  assert_success
}

@test "stream-only MEDIA_PORT=47998 pins the media port" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="47998" run /entrypoint.sh true
  assert_success
  run grep -rF "47998" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
}

@test "re-render is idempotent with changed values (de-one-shot, #17)" {
  # First render with one server, then a different one. The second value
  # must win AND the first must be gone -- proves it re-renders from the
  # pristine template, not the previously-rendered *.js.
  SIGNALING_SERVER="10.20.20.20" run /entrypoint.sh true
  assert_success
  run grep -rF "10.20.20.20" "${USD_ASSETS}/" --include="*.js"
  assert_success
  SIGNALING_SERVER="10.30.30.30" run /entrypoint.sh true
  assert_success
  run grep -rF "10.30.30.30" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.20.20.20" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml public_ip takes precedence over env" {
  printf 'network:\n  public_ip: "10.99.99.99"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.99.99.99" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.11.12.13" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml inline comment is stripped from the value" {
  printf 'network:\n  public_ip: "10.88.88.88"  # LEAKCOMMENT\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_success
  run grep -rF "10.88.88.88" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "LEAKCOMMENT" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml viewer.ui_mode selects the served app" {
  printf 'viewer:\n  ui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.3.3.3" run /entrypoint.sh true
  assert_success
  run grep -rF "10.3.3.3" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.3.3.3" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

# /etc/host.yaml is SHARED with other containers on the host by design (the
# entrypoint's own comment cites isaac#65, and the live isaac host.yaml already
# carries a second top-level `livestream:` block). The lookup used to match
# `^[[:space:]]*<key>:` -- any indentation, any section, first hit wins -- so a
# foreign section's key steered this viewer. The public_ip case is the bad one:
# it does not fail the container, it silently dials the wrong host with exit 0
# and HTTP 200.
@test "host.yaml public_ip in a FOREIGN section does not win" {
  printf 'livestream:\n  public_ip: "10.77.77.77"\nnetwork:\n  public_ip: "10.66.66.66"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_success
  run grep -rF "10.66.66.66" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.77.77.77" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml ui_mode in a FOREIGN section is ignored, not enum-checked" {
  # Unscoped, this failed the usd-viewer|stream-only enum and the container
  # refused to boot on a key that was never addressed to it.
  printf 'livestream:\n  ui_mode: "bogus"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.55.55.55" run /entrypoint.sh true
  assert_success
  run grep -rF "10.55.55.55" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

# Scoping the lookup to `network:` / `viewer:` also stopped matching column 0,
# which the old `^[[:space:]]*<key>:` did match -- so a FLAT host.yaml went from
# working to being silently ignored: exit 0, HTTP 200, dialling whatever the env
# default is instead of the address in the file the operator just wrote. That is
# the same silent-wrong-address failure the unreadable-file case refuses, so a
# misplaced key is refused too, not guessed at and not ignored.
@test "a FLAT host.yaml key is refused, not silently ignored" {
  printf 'public_ip: "10.9.9.9"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_failure
  assert_output --partial "top-level 'public_ip:'"
  # And it must not have quietly dialled the default instead.
  run grep -rF "10.9.9.9" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

# The refusal must not fire on a file that configures the viewer properly: a
# top-level key someone else's container reads is exactly what /etc/host.yaml
# being SHARED means, and our own section is the answer to it.
@test "a top-level key does not refuse when the section supplies the value" {
  printf 'network:\n  public_ip: "10.22.22.22"\npublic_ip: "10.9.9.9"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_success
  run grep -rF "10.22.22.22" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.9.9.9" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

# The ui_mode half of the case above, which nothing covered -- and that gap is
# exactly why the refusal shipped over-firing. For public_ip the refusal
# precondition ("our own section supplied nothing") is anomalous; for ui_mode a
# missing `viewer:` section is the NORMAL documented state, because the mode is
# routinely supplied by env. So the refusal fired on ordinary correct files and
# the container would not boot -- a narrower restatement of the foreign-key bug
# two cases up. This is the reviewer's exact reproduction.
@test "a top-level ui_mode does not block a viewer the env configures" {
  printf 'network:\n  public_ip: "10.50.50.1"\nui_mode: "stream-only"\nlivestream:\n  enabled: true\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="stream-only" run /entrypoint.sh true
  assert_success
  # Not silent either: the key is named, with the mode actually in effect.
  assert_output --partial "top-level 'ui_mode:'"
  assert_output --partial "In effect: 'stream-only'"
  assert_output --partial "the VIEWER_UI_MODE env"
  # This file has no `viewer:` at all, so the absent-section clause and the
  # add-the-section remedy are the pair that belongs here.
  assert_output --partial "there is no 'viewer:' section in it"
  assert_output --partial "add a 'viewer:' section"
  # And the env-chosen app is the one that got rendered.
  run grep -rF "10.50.50.1" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
}

# The other half of the same decision: when NOTHING else supplies a mode, the
# operator who wrote `ui_mode:` at column 0 meaning it for us is the likeliest
# reader of this line, so it still gets said -- but it is said, not enforced.
# The built-in default is itself a supported configuration (the entrypoint's
# own back-compat note), so refusing here would block a valid boot too.
@test "a top-level ui_mode is named when nothing else supplies a mode" {
  printf 'network:\n  public_ip: "10.51.51.1"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  assert_output --partial "nothing else supplied one"
  # The misplaced key did NOT select the app: the built-in default is served.
  run grep -rF "10.51.51.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.51.51.1" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
}

# And when our own section DOES supply the value there is nothing to report:
# the note must not become background noise on a correctly written file.
@test "a top-level ui_mode is not reported when the viewer section supplies it" {
  printf 'viewer:\n  ui_mode: "stream-only"\nui_mode: "usd-viewer"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.52.52.1" run /entrypoint.sh true
  assert_success
  refute_output --partial "top-level 'ui_mode:'"
  run grep -rF "10.52.52.1" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
}

# Both flat-key messages used to say "but no '<section>:' section supplying
# it", which is only one of the two cases the scoped lookup can come back
# empty for -- and it is FALSE in the other. An operator reading "no 'viewer:'
# section" against a file whose second line is `viewer:` learns the message is
# guesswork, and discounts the next true thing it says. The two cases also
# want different fixes: add the section, or add the key to the one already
# there.
@test "a present-but-incomplete section is described as present, not missing" {
  printf 'viewer:\n  theme: "dark"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "there IS a 'viewer:' section in it"
  assert_output --partial "does not supply 'ui_mode'"
  refute_output --partial "no 'viewer:' section"
  # The remedy for THIS state is the indent one, and it must stay attached to
  # this state alone -- the four states below each want a different fix, so a
  # single blanket sentence would be wrong in three of them.
  assert_output --partial "indent it under 'viewer:'"
}

# refuse_flat_key shares the phrasing and predates the warning, so it is fixed
# in the same change rather than left as the odd one out.
@test "the refusal describes a present-but-incomplete section correctly" {
  printf 'network:\n  gateway: "10.0.0.1"\npublic_ip: "10.9.9.9"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_failure
  assert_output --partial "there IS a 'network:' section in it"
  assert_output --partial "does not supply 'public_ip'"
  refute_output --partial "no 'network:' section"
  assert_output --partial "indent it under 'network:'"
}

# ... and the genuinely-absent case still says so, so the fix above did not
# just swap one wrong sentence for another.
@test "a genuinely absent section is still described as absent" {
  printf 'public_ip: "10.9.9.9"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_failure
  assert_output --partial "there is no 'network:' section in it"
  # Nothing to indent under yet, so the remedy for this state is the section
  # itself -- not the indent sentence the present-but-incomplete state gets.
  assert_output --partial "add a 'network:' section"
  refute_output --partial "indent it under 'network:'"
}

# The reason clause had exactly two branches -- section present, section absent
# -- and the file has more states than that. A section that DOES carry our key
# with an empty value hits the flat-key path (the scoped lookup returns
# nothing), and was then told that the section "does not supply 'ui_mode'"
# about a `ui_mode:` sitting plainly inside it, and told to indent a key that
# is already indented. Both halves of that are false, and a diagnostic that is
# provably false about the file in front of the operator is not worth the line
# it costs.
@test "an empty key inside the section is not reported as a missing key" {
  printf 'network:\n  public_ip: "10.53.53.1"\nviewer:\n  ui_mode:\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  assert_output --partial "it does carry a 'ui_mode:', but that key has no value"
  refute_output --partial "does not supply 'ui_mode'"
  refute_output --partial "no 'viewer:' section"
  # The fix is to fill that key in, NOT to indent something already indented.
  refute_output --partial "indent it under 'viewer:'"
  assert_output --partial "give the empty 'ui_mode:' already inside 'viewer:' a value"
}

# The same shape on the public_ip side reaches the REFUSAL, so the container
# does not boot and the stated reason is the only thing the operator has. It
# must stay a refusal -- an empty `public_ip:` plus a column-0 one is still a
# file that would otherwise dial an address nobody chose -- but the reason it
# gives has to be the true one.
@test "the refusal names an empty key rather than a missing one" {
  printf 'network:\n  public_ip:\npublic_ip: "10.9.9.9"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_failure
  assert_output --partial "it does carry a 'public_ip:', but that key has no value"
  refute_output --partial "does not supply 'public_ip'"
  refute_output --partial "no 'network:' section"
  refute_output --partial "indent it under 'network:'"
  assert_output --partial "give the empty 'public_ip:' already inside 'network:' a value"
  # And it must not have quietly dialled anything from the column-0 key.
  run grep -rF "10.9.9.9" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

# `viewer: "not-a-section"` is a top-level SCALAR, but the presence probe only
# matches `^viewer:` and so reported it as a section that exists -- and the
# remedy that follows from that ("indent it under 'viewer:'") produces invalid
# YAML, a mapping key indented under a scalar value. An operator who does what
# the message says ends up with a file that is worse than the one they had.
@test "a section key that is really a scalar is not called a section" {
  printf 'network:\n  public_ip: "10.54.54.1"\nviewer: "not-a-section"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  assert_output --partial "'viewer:' is set to a value rather than opening a section"
  refute_output --partial "there IS a 'viewer:' section in it"
  refute_output --partial "indent it under 'viewer:'"
  assert_output --partial "make 'viewer:' open a section rather than carry a value"
  # The scalar did not select an app either: the env-chosen mode is served.
  run grep -rF "10.54.54.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

# THREE VALID FILES THE SCALAR PROBE ABOVE USED TO CALL SCALARS. Deciding
# "scalar" from "there is text after the colon on the header line" is wrong
# for a one-line FLOW MAPPING (which is a real mapping) and for a YAML node
# PROPERTY -- an anchor or a tag -- which is not the value at all. In each of
# the three the operator was told to fix something already correct, which is
# the exact class of provably-false diagnostic this group of helpers exists
# to end: a message caught being wrong about the file on the screen gets the
# next true thing it says discounted too.
@test "a flow mapping is not called a scalar" {
  printf 'network:\n  public_ip: "10.54.54.1"\nviewer: {ui_mode: "stream-only"}\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  refute_output --partial "is set to a value rather than opening a section"
  assert_output --partial "'viewer:' is written as a one-line flow collection"
  assert_output --partial "rewrite 'viewer:' as an indented block mapping"
}

@test "an anchored section header is not called a scalar" {
  printf 'network:\n  public_ip: "10.54.54.1"\nviewer: &v\n  something_else: "x"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  refute_output --partial "is set to a value rather than opening a section"
  refute_output --partial "flow collection"
  assert_output --partial "there IS a 'viewer:' section in it"
}

@test "a tagged section header is not called a scalar" {
  printf 'network:\n  public_ip: "10.54.54.1"\nviewer: !!map\n  something_else: "x"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  refute_output --partial "is set to a value rather than opening a section"
  refute_output --partial "flow collection"
  assert_output --partial "there IS a 'viewer:' section in it"
}

# THE ANCHOR'S DIRECT COMPANION, which the round that added anchor handling
# did not cover. `viewer: *v` is an ALIAS: a reference to a node defined
# somewhere else in the same document, which PyYAML (and every other parser)
# resolves to that node -- so the file is VALID and `viewer:` really does
# supply a mapping. Calling it "set to a value rather than opening a section"
# is provably false about the file on the screen, and the remedy that follows
# ("make it open a section") describes work already done. What is TRUE is
# that this line-based reader does not follow the reference: the keys are not
# below the header, they are wherever the anchor is.
@test "an aliased section header is not called a scalar" {
  printf 'defaults: &v\n  ui_mode: "stream-only"\nnetwork:\n  public_ip: "10.54.54.1"\nviewer: *v\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  VIEWER_UI_MODE="usd-viewer" run /entrypoint.sh true
  assert_success
  assert_output --partial "top-level 'ui_mode:'"
  refute_output --partial "is set to a value rather than opening a section"
  refute_output --partial "make 'viewer:' open a section rather than carry a value"
  refute_output --partial "flow collection"
  assert_output --partial "'viewer:' is an alias"
  assert_output --partial "replace the alias"
}

# The supplier variable was never initialised, and it is read in a script that
# is the container ENTRYPOINT -- so its environment is operator- and
# compose-controlled, and an unset shell variable read out of the environment
# is an operator-supplied value. With no /etc/host.yaml mounted AT ALL, the
# deferred warning fired anyway and the boot log described a key in a file
# that does not exist, with the operator's own text spliced in as the source.
# Behaviour was unaffected -- so not a bypass, but a log saying something that
# is not true, which is the class every other fix in this file is about.
@test "a flat_ui_mode_supplier in the environment invents no host.yaml note" {
  run test -f /etc/host.yaml
  assert_failure
  flat_ui_mode_supplier="ghost-supplier-text" run /entrypoint.sh true
  assert_success
  refute_output --partial "top-level 'ui_mode:'"
  refute_output --partial "ghost-supplier-text"
}

# Initialising the variable stopped the fabricated note, but under the OBVIOUS
# name, and the commit that did it claimed "nothing behaves differently". That
# is untrue for the process this script execs. The assignment does not create a
# fresh shell-local: an inherited variable keeps its export attribute, so
# `docker run -e flat_ui_mode_supplier=x` handed the CMD an EMPTIED variable it
# had set itself. The entrypoint is the last thing between compose and the
# workload; quietly rewriting part of the environment it passes on is the one
# thing it must not do. The name it works with is internal now, so neither read
# nor write touches the operator's.
@test "an inherited flat_ui_mode_supplier reaches the exec'd command intact" {
  run test -f /etc/host.yaml
  assert_failure
  flat_ui_mode_supplier="operator-owned-value" \
    run /entrypoint.sh sh -c 'printf "%s" "${flat_ui_mode_supplier-UNSET}"'
  assert_success
  assert [ "${output}" = "operator-owned-value" ]
}

# ... including on the path that actually uses the supplier, which is where an
# assignment to the obvious name would definitely have fired: the warning is
# still emitted, from the internal name, and the operator's variable passes
# through untouched.
@test "the flat-ui_mode warning does not rewrite the operator's variable" {
  printf 'network:\n  public_ip: "10.57.57.1"\nui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  flat_ui_mode_supplier="operator-owned-value" VIEWER_UI_MODE="stream-only" \
    run /entrypoint.sh sh -c 'printf "%s" "${flat_ui_mode_supplier-UNSET}"'
  assert_success
  # The warning still fires, and still names the real supplier.
  assert_output --partial "top-level 'ui_mode:'"
  assert_output --partial "the VIEWER_UI_MODE env"
  # And the exec'd command still sees what the operator set.
  assert_output --partial "operator-owned-value"
}

# An unreadable host.yaml is an operator mistake, not an absent file. awk's
# failure was swallowed, so the container booted on env/defaults and dialled
# whatever address the operator had just moved OUT of the env and INTO that
# file -- exit 0, HTTP 200, nothing said. This stage runs as the non-root image
# USER, which is what makes mode 000 mean anything here.
@test "an unreadable host.yaml fails the container, not falls back" {
  printf 'network:\n  public_ip: "10.44.44.44"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  sudo chmod 000 /etc/host.yaml
  run /entrypoint.sh true
  assert_failure
  assert_output --partial 'not readable'
}

@test "entrypoint exports the resolved VIEWER_UI_MODE for the CMD" {
  # The CMD reads ${VIEWER_UI_MODE}; the entrypoint must export the
  # host.yaml/env-resolved value before exec, so a child sees it.
  printf 'viewer:\n  ui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh sh -c 'printf "%s" "${VIEWER_UI_MODE}"'
  assert_success
  assert [ "${output}" = "stream-only" ]
}

@test "non-numeric SIGNALING_PORT is rejected" {
  SIGNALING_PORT="80x" run /entrypoint.sh true
  assert_failure
}

# The port sed replaces the QUOTED sentinel, so the value reaches the bundle as
# a bare numeric token: `049100` renders `signalingPort:049100`, which is a
# SyntaxError in an ES module (strict mode). The chunk then fails to parse and
# the viewer is a black page -- from a container that started successfully and
# answers HTTP 200, which is all the runtime smoke ever asked.
@test "SIGNALING_PORT with a leading zero is rejected" {
  SIGNALING_PORT="049100" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range SIGNALING_PORT is rejected" {
  SIGNALING_PORT="99999" run /entrypoint.sh true
  assert_failure
}

@test "MEDIA_PORT with a leading zero is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="047998" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range SERVE_PORT is rejected" {
  SERVE_PORT="0" run /entrypoint.sh true
  assert_failure
}

# `serve -l` takes an ENDPOINT, not only a port, and that is the only way to
# scope the listen ADDRESS. Requiring a bare integer removed the ability to
# bind loopback only, leaving the published image able to listen on every
# interface and nothing else.
@test "SERVE_PORT accepts a tcp:// listen endpoint" {
  SERVE_PORT="tcp://127.0.0.1:5173" run /entrypoint.sh true
  assert_success
}

@test "a malformed tcp:// serve endpoint is rejected" {
  # Host but no port.
  SERVE_PORT="tcp://127.0.0.1" run /entrypoint.sh true
  assert_failure
  # Port present but not a port.
  SERVE_PORT="tcp://127.0.0.1:0" run /entrypoint.sh true
  assert_failure
}

# `serve --help` documents four endpoint forms. Only the two NETWORK ones are
# supported, and the refusal of the other two is a decision, not an oversight:
# a UNIX socket is unreachable by the browser and by every HTTP gate in this
# repo (and would widen a charset the CMD's `sh -c` expands), and a Windows
# named pipe cannot exist in the linux/amd64 image that gets published. The
# message must say so rather than report a bad integer.
@test "a unix:/pipe: serve endpoint is refused by name" {
  SERVE_PORT="unix:/tmp/owv.sock" run /entrypoint.sh true
  assert_failure
  assert_output --partial "unsupported serve endpoint"
  assert_output --partial "tcp://<host>:<port>"
  SERVE_PORT='pipe:\\.\pipe\owv' run /entrypoint.sh true
  assert_failure
  assert_output --partial "unsupported serve endpoint"
}

@test "invalid VIEWER_UI_MODE is rejected" {
  VIEWER_UI_MODE="bogus" run /entrypoint.sh true
  assert_failure
}

@test "non-numeric MEDIA_PORT is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="80x" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range MEDIA_PORT is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="70000" run /entrypoint.sh true
  assert_failure
}

@test "SIGNALING_SERVER with shell/sed metacharacters is rejected" {
  SIGNALING_SERVER="a;rm -rf /|b" run /entrypoint.sh true
  assert_failure
}

# SIGTERM REACHES `serve`, OR STOPPING THE VIEWER TAKES TEN SECONDS.
#
# MEASURED on the published ghcr.io/.../omniverse_web_viewer:0.3.0 image
# before this case existed: `docker top` showed `sh -c serve ...` as PID 1
# with `node /usr/bin/serve` as its child; `docker kill -s TERM` left the
# container running; `docker stop` took 10.2 s -- the whole default grace
# period, ending in SIGKILL. `sh` does not forward signals to a child it
# forked. The same image with `exec` in front of `serve` stops in 0.24 s with
# exit code 0. Every `just stop`, every `docker stop` and isaac's teardown
# paid the ten seconds, and serve was killed uncleanly each time.
#
# This asserts the MECHANISM, in the Dockerfile that /lint already carries for
# hadolint, because the behaviour itself needs a container lifecycle and
# nothing in this repo runs one: bats runs INSIDE an image, and `runtime-test`
# smoke-tests with `RUN`, which is build time. The trade is stated rather than
# skipped -- a spec that starts and stops a real container belongs with the
# host-side runners (script/ci/), and there is no home for it there today.
@test "env: every CMD that serves the bundle execs it (PID 1 gets SIGTERM)" {
  run grep -cE '^CMD \["sh", "-c", "exec serve ' /lint/Dockerfile
  assert_success
  assert_output "3"

  # ...and none of them forgot it. Counting both ways is what makes a fourth
  # CMD added without `exec` a red test rather than a silent pass.
  run grep -E '^CMD \["sh", "-c", "serve ' /lint/Dockerfile
  assert_failure
}
