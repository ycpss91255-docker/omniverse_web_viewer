#!/usr/bin/env bash
#
# check_release_gates.sh [<workflow.yaml>]
#
# Front door for the release-invariant checker. The checker itself is
# check_release_gates.py next to this file; this wrapper exists so the entry
# point, the exit codes and the callers are unchanged from when the checker
# was bash + awk, and so the ONE dependency it now has is verified out loud
# rather than discovered as a stack trace.
#
# WHY THERE IS A PYTHON FILE BEHIND THIS. Two text-matching versions of this
# checker were walked past by a reviewer, 12 mutations then 21, and almost
# none of those were mistakes in an individual rule -- they were properties of
# reading YAML with line regexes: trailing comments, `"if":` / `'if':` /
# `if :` as four spellings of one key, a `(` inside a quoted string breaking
# parenthesis depth, a job header with a trailing comment not being a job. A
# real parser answers those outright. The full argument is in
# check_release_gates.py's header, along with the canonical list of what the
# checker still CANNOT see.
#
# THE DEPENDENCY IS CONFINED TO devel-test. python3 is in the image already
# (`command -v python3` answers /usr/bin/python3); PyYAML is added by the
# `devel-test` stage as `python3-yaml`. That stage is a leaf: `runtime` is
# `FROM devel-base`, `devel-test` is `FROM devel`, and nothing is `FROM
# devel-test`, so no published image gains a package from this.
#
# EXIT CODES. 0 = the invariant holds. 1 = one or more violations, each
# printed with a stable [id]. 2 = the invariant could NOT be verified --
# unreadable file, unparseable YAML, no jobs, or a missing dependency. 2 is
# never silent and never means "fine".
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${HERE}/check_release_gates.py"

if [ ! -r "${CHECKER}" ]; then
  printf 'check_release_gates: %s is missing; the release invariant was NOT verified\n' \
    "${CHECKER}" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'check_release_gates: python3 is not on PATH; the release invariant was NOT verified. It is present in the devel-test image (/usr/bin/python3), which is where this runs.\n' >&2
  exit 2
fi

# Checked HERE rather than left to an ImportError, because "ModuleNotFoundError:
# No module named yaml" on line 1 of a traceback reads like a broken script and
# invites someone to skip the step. Refusing by name says what to install.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  printf 'check_release_gates: python3 has no PyYAML, so the workflow cannot be parsed and the release invariant was NOT verified. The devel-test stage installs it (apt-get install python3-yaml); if you are running this outside that image, install PyYAML or run it there.\n' >&2
  exit 2
fi

exec python3 "${CHECKER}" "$@"
