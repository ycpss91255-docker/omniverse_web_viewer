#!/usr/bin/env bash
#
# Resolve the runtime stream config and render it into the served bundle.
#
# Pipeline (#17, S5): each app build injects up to three sentinels into its
# bundle (server / port / media) and preserves each sentinel-bearing chunk as
# a pristine *.js.tmpl. VIEWER_UI_MODE is an APP SELECTOR (D7): it picks which
# app's dist the entrypoint renders + serves (/app/usd-viewer/dist or
# /app/stream-only/dist), NOT a value rendered into a bundle. This entrypoint
# validates every operator-supplied value, then re-renders the ACTIVE app's
# *.js.tmpl -> *.js on EVERY boot. Re-rendering from the pristine template
# (rather than editing *.js in place) makes the substitution idempotent: a
# `docker restart` or a changed env / host.yaml is picked up on the next start
# instead of reusing the first-boot values. The per-app sentinel set differs
# (usd-viewer carries server/port only; stream-only also carries media), so a
# sed for a sentinel a given app never emitted is a harmless no-op.
#
# Strict mode is the documented contract for the logging helper, which is
# `set -u` safe, so we enable it before sourcing.
set -euo pipefail

# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by the Dockerfile's
# build/runtime/devel stages (refs base#328 + base#368).
# shellcheck source=/dev/null
. /usr/local/lib/base/logging.sh

# yaml_value <section> <key> <file>: extract the scalar value of
# `<section>:` / `  <key>: <value>`. Strips surrounding quotes, a trailing
# inline `# comment`, and surrounding whitespace. Prints nothing if absent.
#
# THE SECTION ARGUMENT IS THE POINT. This used to match `^[[:space:]]*<key>:`
# -- any indentation, any section, first hit wins -- and /etc/host.yaml is BY
# DESIGN a file shared with other containers on the host (isaac#65, cited two
# comments down); the live isaac host.yaml already carries a second top-level
# `livestream:` block, so a key colliding with one of ours is ordinary rather
# than exotic. Unscoped, a foreign `ui_mode:` failed our enum and the container
# refused to boot, and a foreign `public_ip:` in an EARLIER section won -- the
# viewer then silently dialled the wrong host, exit 0, HTTP 200, every gate
# green. Scoping the lookup to `network:` / `viewer:` means only the keys this
# file's own schema defines can steer the viewer.
#
# A top-level key (column 0) opens or closes the section; only INDENTED keys
# inside the requested section are considered. A key written AT column 0 is
# therefore not a value of ours -- see yaml_top_level_key below, which refuses
# to let that be silent.
yaml_value() {
  awk -v section="$1" -v key="$2" '
    /^[^[:space:]#]/ {
      in_section = (index($0, section ":") == 1)
      next
    }
    !in_section { next }
    $0 ~ "^[[:space:]]+" key ":" {
      v = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", v)   # drop the key
      sub(/[[:space:]]*#.*$/, "", v)                  # drop inline comment
      gsub(/"/, "", v)                                # drop quotes
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$3"
}

# yaml_top_level_key <key> <file>: true when `<key>:` appears at COLUMN 0.
#
# Scoping the lookup above to `network:` / `viewer:` closed a real hole (a
# foreign section's key steering this viewer) but opened a quieter one: before
# it, `^[[:space:]]*key:` also matched column 0, so a FLAT host.yaml --
# `public_ip: "10.9.9.9"` with no `network:` above it -- used to work. After
# it, that file resolves nothing and the container boots on env/defaults,
# dialling an address nobody chose with exit 0 and HTTP 200. That is the exact
# failure mode the unreadable-host.yaml fix declared unacceptable, so a flat
# key is REFUSED rather than accepted-as-fallback or ignored.
#
# Refused, not accepted, because the shared-file argument still applies: a key
# at column 0 in a file shared with other containers (isaac#65) is addressed to
# nobody in particular, and quietly steering the viewer from it is what the
# scoping fix exists to prevent.
#
# THE TWO KEYS ARE NOT SYMMETRIC, and treating them as one rule was a bug of
# its own. `refuse_flat_key` fires when OUR OWN SCOPED LOOKUP produced no
# value, and that precondition means opposite things for the two keys:
#
#   - public_ip: a missing `network:` section is anomalous. That section is
#     the whole reason this file is read, so a file with none of it, plus a
#     column-0 `public_ip:`, is a file someone wrote FOR us and mis-shaped.
#     Refusing is right, and the failure it prevents is the bad one -- a
#     plausible page dialling an address nobody chose, exit 0 and HTTP 200.
#
#   - ui_mode: a missing `viewer:` section is the NORMAL, DOCUMENTED state
#     ("A host.yaml with only a network section leaves the viewer value
#     untouched", below), because VIEWER_UI_MODE is routinely supplied by env
#     instead. So the precondition is met on ordinary, correct files, and
#     refusing there blocks a properly configured viewer from booting over a
#     key another container owns -- a narrower restatement of the very bug the
#     scoping fix above was written for.
#
# It cannot be made precise, either. `network:` + `public_ip:` + a column-0
# `ui_mode:` is BYTE-FOR-BYTE the file an operator writes when they meant that
# key for us and got the shape wrong, AND the file that results when another
# container simply owns a top-level `ui_mode:`. Nothing in the file separates
# them, so any refusal rule necessarily blocks the innocent one. ui_mode is
# therefore TOLD, not refused: see warn_flat_key. Not silent, and not fatal.
yaml_top_level_key() {
  awk -v key="$1" '
    $0 ~ "^" key ":" { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$2"
}

# refuse_flat_key <key> <section> <file>: exit 1 when <key> is at column 0 and
# the scoped lookup found nothing, so a misplaced key is never silently
# ignored. Called only after the scoped lookup came back empty, and only for
# network.public_ip -- see the asymmetry note above yaml_top_level_key for why
# viewer.ui_mode uses warn_flat_key instead.
refuse_flat_key() {
  local key="$1" section="$2" file="$3"
  if yaml_top_level_key "${key}" "${file}"; then
    echo "entrypoint: ${file} has a top-level '${key}:' but no '${section}:'" \
         "section supplying it; this file's keys are read from their own" \
         "section only, so that value would be silently ignored and the" \
         "viewer would boot on env/defaults. Indent it under '${section}:'" \
         "(see config/host.yaml.example). If that key belongs to another" \
         "container, give the viewer its own '${section}: ${key}: ...' and" \
         "that value wins" >&2
    exit 1
  fi
}

# warn_flat_key <key> <section> <file> <effective> <supplier>: say on STDERR
# that a column-0 <key> was not read, and name the value actually in effect
# plus where it came from. NEVER exits -- that is the whole point, and the
# reason it exists next to refuse_flat_key rather than as a flag on it. See
# the asymmetry note above yaml_top_level_key: for ui_mode the refusal
# precondition is met by ordinary correct files, so refusing blocks a properly
# configured viewer over a key another container owns. Naming the key and the
# value actually in effect is the strongest thing that is still safe: the
# operator who mis-shaped their own file reads one line and fixes it, and the
# operator whose neighbour owns that key still boots.
warn_flat_key() {
  local key="$1" section="$2" file="$3" effective="$4" supplier="$5"
  echo "entrypoint: ${file} has a top-level '${key}:' but no '${section}:'" \
       "section supplying it; this file's keys are read from their own" \
       "section only, so that value was NOT read. In effect: '${effective}'" \
       "(from ${supplier}). If that key was meant for this viewer, indent it" \
       "under '${section}:' (see config/host.yaml.example) and it wins. If it" \
       "belongs to another container sharing this file (isaac#65), nothing" \
       "needs doing -- this line is the only trace either way" >&2
}

# Per-host config (mounted by caller from config/host.yaml). When
# present, network.public_ip overrides the SIGNALING_SERVER env var --
# keeps a single source of truth for the host IP across all containers
# that read the same yaml (e.g. ycpss91255-docker/isaac#65).
# viewer.ui_mode follows the same precedence as public_ip: host.yaml
# viewer.ui_mode > VIEWER_UI_MODE env > built-in default. A host.yaml
# with only a network section leaves the viewer value untouched
# (back-compat) -- and, because that is NORMAL rather than anomalous, a
# column-0 `ui_mode:` is reported and ignored where a column-0 `public_ip:` is
# refused; see the asymmetry note above yaml_top_level_key.
# Ports (SIGNALING_PORT / MEDIA_PORT / SERVE_PORT) are
# workload runtime params delivered via env/.env (D8), NOT host.yaml.
if [ -f /etc/host.yaml ]; then
  # An UNREADABLE host.yaml is an operator mistake, not an absent file, and it
  # must not be treated as one. awk's failure used to be swallowed
  # (`2>/dev/null || true`), so a mode-000 or wrong-owner /etc/host.yaml booted
  # silently on env/defaults -- i.e. dialled whatever address the operator had
  # just moved OUT of the env into that file, with exit 0 and HTTP 200. Both
  # the suppression and the guess are gone: the file is checked here, and awk's
  # exit status now reaches `set -e` if anything else goes wrong reading it.
  if [ ! -r /etc/host.yaml ]; then
    echo "entrypoint: /etc/host.yaml exists but is not readable by" \
         "$(id -un) (uid $(id -u)); refusing to fall back to env/defaults" \
         "and dial an address nobody chose" >&2
    exit 1
  fi

  host_ip="$(yaml_value network public_ip /etc/host.yaml)"
  if [ -n "${host_ip}" ]; then
    SIGNALING_SERVER="${host_ip}"
  else
    refuse_flat_key public_ip network /etc/host.yaml
  fi

  yaml_ui_mode="$(yaml_value viewer ui_mode /etc/host.yaml)"
  if [ -n "${yaml_ui_mode}" ]; then
    VIEWER_UI_MODE="${yaml_ui_mode}"
  elif yaml_top_level_key ui_mode /etc/host.yaml; then
    # Deferred to after the default is applied below, so the warning can name
    # the mode ACTUALLY in effect without duplicating the default literal. The
    # supplier is decided here, while VIEWER_UI_MODE still holds only what the
    # environment gave us: non-empty means an operator (or the image ENV) chose
    # a mode for THIS container, empty means nothing did and the built-in
    # default is about to. That difference does not change whether we boot --
    # the built-in default is itself a supported configuration, per the
    # back-compat note above -- it changes what the operator is told, which is
    # where it is actually useful.
    if [ -n "${VIEWER_UI_MODE:-}" ]; then
      flat_ui_mode_supplier="the VIEWER_UI_MODE env"
    else
      flat_ui_mode_supplier="the built-in default; nothing else supplied one"
    fi
  fi
fi

# Resolve final values (built-in defaults). MEDIA_PORT has NO default:
# unset = the library negotiates media via SDP (D1 back-compat).
SIGNALING_SERVER="${SIGNALING_SERVER:-127.0.0.1}"
SIGNALING_PORT="${SIGNALING_PORT:-49100}"
VIEWER_UI_MODE="${VIEWER_UI_MODE:-usd-viewer}"

# The deferred half of the flat-ui_mode note above: emitted here so it can name
# the resolved mode. Fires only when /etc/host.yaml carried a column-0
# `ui_mode:` AND our own `viewer:` section supplied nothing.
if [ -n "${flat_ui_mode_supplier:-}" ]; then
  warn_flat_key ui_mode viewer /etc/host.yaml \
    "${VIEWER_UI_MODE}" "${flat_ui_mode_supplier}"
fi

# Validate before substituting. Each value lands in a browser-executed
# JS bundle via sed, so a bad value must fail the container fast rather
# than bake malformed JS or inject sed/JS metacharacters. The charset /
# enum whitelists below also guarantee no sed replacement metacharacter
# (| & \ newline) can survive -- validation IS the escaping.
if [[ ! "${SIGNALING_SERVER}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "entrypoint: invalid signaling server '${SIGNALING_SERVER}'" \
       "(allowed: hostname / IPv4 chars A-Za-z0-9.-)" >&2
  exit 1
fi
#
# reject_bad_port <name> <value>: exit 1 unless <value> is an integer 1..65535
# written WITHOUT a leading zero. Both halves of that rule earn their place:
#   - the range, because `0` and `99999` are not ports. They reach the browser
#     otherwise -- stream-only at least throws a visible readout, but usd-viewer
#     (upstream, unmodified) just never connects and says nothing;
#   - the leading zero, because the port sed below replaces the QUOTED sentinel
#     `"__OWV_PORT__"`, so the value lands in the bundle as a BARE numeric
#     token. `SIGNALING_PORT=049100` renders `signalingPort:049100`, which is
#     `SyntaxError: Decimals with leading zeros are not allowed in strict mode`
#     -- the whole ES module fails to parse and the viewer is a black page,
#     while the entrypoint exits 0, `serve` answers HTTP 200 and every gate
#     stays green. `[ x -lt y ]` parses base 10, so a range test alone does not
#     catch it.
reject_bad_port() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^(0|[1-9][0-9]*)$ ]] || \
     [ "${value}" -lt 1 ] || [ "${value}" -gt 65535 ]; then
    echo "entrypoint: invalid ${name} '${value}'" \
         "(must be an integer 1..65535, written without a leading zero)" >&2
    exit 1
  fi
}

reject_bad_port "signaling port" "${SIGNALING_PORT}"
case "${VIEWER_UI_MODE}" in
  usd-viewer | stream-only) ;;
  *)
    echo "entrypoint: invalid ui_mode '${VIEWER_UI_MODE}'" \
         "(expected usd-viewer | stream-only)" >&2
    exit 1
    ;;
esac
# MEDIA_PORT is OPTIONAL (D1): unset -> rendered as the literal `null`
# (the stream-only app omits mediaPort and the library SDP-negotiates).
# When set it must be an integer 1..65535, same rule as the signaling port --
# it is substituted for the same kind of quoted sentinel and reaches the
# bundle as the same kind of bare numeric token.
if [ -n "${MEDIA_PORT:-}" ]; then
  reject_bad_port "media port" "${MEDIA_PORT}"
  media_value="${MEDIA_PORT}"
else
  media_value="null"
fi

# SERVE_PORT is not rendered into any bundle -- the CMD passes it to `serve -l`
# -- but the same rule applies for the same reason the header states: a bad
# value must fail the container fast. `SERVE_PORT=0` otherwise starts a viewer
# nobody can reach, on a port nobody chose. Only checked when set: the `example`
# stage serves on EXAMPLE_PORT and leaves this unset.
#
# BOTH NETWORK FORMS ARE ACCEPTED, because `serve -l` takes an ENDPOINT, not
# only a port, and that endpoint is the only way to scope the listen ADDRESS:
# `SERVE_PORT=tcp://127.0.0.1:5173` binds loopback only. Validating a bare
# integer alone (as the first version of this check did) silently removed that
# -- the published image could then only listen on every interface, so a viewer
# meant for the local browser is reachable by any LAN peer, and a URL handed to
# its user is a URL handed to the viewer. The port half is validated in both
# forms, which is what the fast-fail was actually for.
#
# `serve --help` (14.2.6) documents FOUR endpoint forms; the other two are
# REFUSED here, deliberately and by name rather than by accident:
#   - `pipe:\\.\pipe\Name` is a WINDOWS named pipe. The published image is
#     linux/amd64 (the only platform CI builds and gates), so this form cannot
#     work in it at all -- accepting it would only move the failure from a
#     named entrypoint error to an obscure one from `serve` after boot.
#   - `unix:/path/to/socket.sock` is a UNIX domain socket, and NOTHING that
#     consumes this container can address one: the browser dials a URL, the
#     runtime-test smoke and both e2e runners curl `http://127.0.0.1:<port>`,
#     and compose delivers `SERVE_PORT` as a port. A socket would also widen
#     the charset this value is allowed to carry, and that charset is load
#     bearing: the CMD is `sh -c "serve -s ... -l ${SERVE_PORT}"`, so the value
#     is expanded BY A SHELL -- validation is the escaping here exactly as it
#     is for the sentinels above.
# If a socket endpoint is ever wanted, it needs its own path containment rule
# and a consumer that can reach it; it is not a one-line widening of this case.
if [ -n "${SERVE_PORT:-}" ]; then
  case "${SERVE_PORT}" in
    tcp://*)
      serve_endpoint="${SERVE_PORT#tcp://}"
      serve_host="${serve_endpoint%:*}"
      # No colon -> `%:*` returns the whole string; that is a host with no port.
      if [ "${serve_host}" = "${serve_endpoint}" ] || \
         [[ ! "${serve_host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "entrypoint: invalid serve endpoint '${SERVE_PORT}'" \
             "(expected tcp://<host>:<port>, host from A-Za-z0-9.-)" >&2
        exit 1
      fi
      reject_bad_port "serve port" "${serve_endpoint##*:}"
      ;;
    unix:* | pipe:*)
      # Refused with the reason, not with the port message: `unix:/x.sock` is a
      # real `serve -l` form, so "must be an integer 1..65535" would read as a
      # typo report rather than as the deliberate decision it is.
      echo "entrypoint: unsupported serve endpoint '${SERVE_PORT}'" \
           "(supported: <port> or tcp://<host>:<port>; a UNIX socket cannot be" \
           "reached by the browser or by any of this repo's HTTP gates, and a" \
           "Windows named pipe cannot exist in a linux/amd64 image)" >&2
      exit 1
      ;;
    *)
      reject_bad_port "serve port" "${SERVE_PORT}"
      ;;
  esac
fi

# VIEWER_UI_MODE selects which app dist to render + serve (D7); the CMD
# reads the same resolved value via ${VIEWER_UI_MODE}, so export it.
export VIEWER_UI_MODE
assets_dir="/app/${VIEWER_UI_MODE}/dist/assets"

# Render every pristine template -> served *.js for the ACTIVE app only.
# nullglob so a missing template set yields an empty array (caught below)
# instead of the literal glob pattern.
shopt -s nullglob
templates=("${assets_dir}"/*.js.tmpl)
if [ "${#templates[@]}" -eq 0 ]; then
  echo "entrypoint: no ${assets_dir}/*.js.tmpl found;" \
       "cannot render stream config for ui_mode '${VIEWER_UI_MODE}'" >&2
  exit 1
fi
for tmpl in "${templates[@]}"; do
  out="${tmpl%.tmpl}"
  # Render to a temp file then atomically swap, so a partial sed never
  # leaves a half-written bundle being served. The media sed is a no-op
  # where the sentinel is absent (e.g. usd-viewer).
  sed \
    -e "s|__OWV_SERVER__|${SIGNALING_SERVER}|g" \
    -e "s|\"__OWV_PORT__\"|${SIGNALING_PORT}|g" \
    -e "s|\"__OWV_MEDIA_PORT__\"|${media_value}|g" \
    "${tmpl}" > "${out}.rendering"
  mv -- "${out}.rendering" "${out}"
done

exec "${@}"
