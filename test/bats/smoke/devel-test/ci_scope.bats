#!/usr/bin/env bats
#
# CI 依變更範圍執行（#106，對齊 isaac#434）的兩支判斷腳本：
#   - script/ci/changed_scope.py：這次要不要 build 和跑 Tier B
#   - script/ci/gate_result.py：`gate` 這個總結狀態要不要通過
#
# changed_scope 的 PR 案例用真的暫存 git repo 產生 diff，而不是把「變更了
# 哪些檔案」直接餵給腳本：腳本實際做的是 `git diff base...head`，測試要
# 測的就是那一步，不是測試自己寫好的答案。
#
# 兩支腳本都由 devel-test stage 複製到 /ci/。

SCOPE="/ci/changed_scope.py"
GATE="/ci/gate_result.py"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  REPO="$(mktemp -d)"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email bats@example.invalid
  git -C "${REPO}" config user.name bats
  mkdir -p "${REPO}/doc" "${REPO}/apps/stream-only/src"
  printf 'x\n' >"${REPO}/README.md"
  printf 'x\n' >"${REPO}/apps/stream-only/src/main.ts"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m base
  BASE="$(git -C "${REPO}" rev-parse HEAD)"
}

teardown() {
  rm -rf "${REPO}"
}

# _pr_with FILE... -- commit a change to each FILE on top of BASE; prints the
# new head sha.
_pr_with() {
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "${REPO}/${f}")"
    printf 'changed %s\n' "${f}" >>"${REPO}/${f}"
  done
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m change
  git -C "${REPO}" rev-parse HEAD
}

_scope() {
  (cd "${REPO}" && env -u BASE_SHA -u HEAD_SHA -u EVENT_NAME "$@" python3 "${SCOPE}")
}

# ---------------------------------------------------------------- changed_scope

# why: push 到 main、tag、手動 dispatch 一律全跑，不看改了什麼
@test "scope: a push or a dispatch always selects the viewer" {
  run _scope EVENT_NAME=push
  assert_success
  assert_output "viewer=true"
  run _scope EVENT_NAME=workflow_dispatch
  assert_success
  assert_output "viewer=true"
}

# why: 只改文件的 PR 不 build、不佔 GPU -- 文件的三種形式都要認得
@test "scope: a PR touching only docs selects nothing" {
  head="$(_pr_with README.md doc/test/TEST.md LICENSE)"
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${head}"
  assert_success
  assert_output "viewer=false"
}

# why: 文件和程式一起改，程式那一半就需要驗畫面
@test "scope: a PR touching code and docs selects the viewer" {
  head="$(_pr_with README.md apps/stream-only/src/main.ts)"
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${head}"
  assert_success
  assert_output "viewer=true"
}

# why: 沒有對應規則的路徑一律歸 viewer，不會變成「什麼都不跑」-- 例如
# workflow 本身、Dockerfile
@test "scope: a path no rule names selects the viewer" {
  head="$(_pr_with .github/workflows/main.yaml)"
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${head}"
  assert_success
  assert_output "viewer=true"
  head="$(_pr_with Dockerfile)"
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${head}"
  assert_output "viewer=true"
}

# why: 一個只是剛好以 .md 結尾的目錄不是文件；判斷看的是檔案路徑本身
@test "scope: a code file under a directory named like a doc is still code" {
  head="$(_pr_with notes.md/build.sh)"
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${head}"
  assert_success
  assert_output "viewer=true"
}

# why: 拿不到 base / head 時判斷不出來，寧可多跑一次 GPU
@test "scope: a PR with no base or head selects the viewer" {
  run _scope EVENT_NAME=pull_request
  assert_success
  assert_output "viewer=true"
}

# why: 沒有任何變更檔案（例如空 commit）也判斷不出來，同樣全跑
@test "scope: a PR with no changed file selects the viewer" {
  run _scope EVENT_NAME=pull_request BASE_SHA="${BASE}" HEAD_SHA="${BASE}"
  assert_success
  assert_output "viewer=true"
}

# why: git diff 本身失敗時 job 要失敗，讓 gate 失敗，而不是輸出一個猜的結果
@test "scope: a diff that git cannot compute fails the job" {
  run _scope EVENT_NAME=pull_request BASE_SHA=0000000000000000000000000000000000000000 HEAD_SHA="${BASE}"
  assert_failure
  refute_output --partial "viewer="
}

# ----------------------------------------------------------------- gate_result

_gate() {
  NEEDS_JSON="$1" python3 "${GATE}"
}

# why: 全部成功當然通過
@test "gate: every selected job succeeding passes" {
  run _gate '{"changes":{"result":"success"},"call-docker-build":{"result":"success"},"tier-b-visual-e2e":{"result":"success"}}'
  assert_success
}

# why: 依範圍被跳過的 job 不能讓 PR 卡住，skipped 算通過
@test "gate: a job skipped by scope passes" {
  run _gate '{"changes":{"result":"success"},"call-docker-build":{"result":"skipped"},"tier-b-visual-e2e":{"result":"skipped"}}'
  assert_success
}

# why: 任何一個 job 失敗或被取消，gate 都要失敗
@test "gate: a failed or cancelled job fails" {
  run _gate '{"changes":{"result":"success"},"tier-b-visual-e2e":{"result":"failure"}}'
  assert_failure
  assert_output --partial "tier-b-visual-e2e ended failure"
  run _gate '{"changes":{"result":"success"},"tier-b-visual-e2e":{"result":"cancelled"}}'
  assert_failure
}

# why: changes 沒成功時下游全部被跳過；照 skipped 算通過，gate 就會在什麼都
# 沒檢查的情況下通過
@test "gate: changes not succeeding fails even when everything else is skipped" {
  run _gate '{"changes":{"result":"failure"},"call-docker-build":{"result":"skipped"},"tier-b-visual-e2e":{"result":"skipped"}}'
  assert_failure
  assert_output --partial "changes ended failure"
  run _gate '{"changes":{"result":"skipped"},"tier-b-visual-e2e":{"result":"skipped"}}'
  assert_failure
}

# why: gate 的 needs 少了 changes，等於沒有人保證範圍判斷真的跑過
@test "gate: a needs list without changes fails" {
  run _gate '{"tier-b-visual-e2e":{"result":"success"}}'
  assert_failure
  assert_output --partial "changes ended <absent>"
}

# why: GitHub 之後新增的狀態值不能被當成通過
@test "gate: an unknown result fails" {
  run _gate '{"changes":{"result":"success"},"tier-b-visual-e2e":{"result":"neutral"}}'
  assert_failure
}

# why: 讀不到 needs 時沒有任何東西可以判斷，不能通過
@test "gate: unreadable or empty needs fail" {
  run _gate 'not json'
  assert_failure
  run _gate '{}'
  assert_failure
}
