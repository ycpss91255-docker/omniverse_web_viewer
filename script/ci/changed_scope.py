#!/usr/bin/env python3
"""判斷這次 CI 要不要 build 和跑 Tier B（#106，對齊 isaac#434）。

輸出一行 `viewer=true` 或 `viewer=false`，給 `changes` job 寫進
$GITHUB_OUTPUT，其他 job 依它決定要不要跑。

規則：
  - 不是 pull_request（push 到 main、tag、手動 dispatch）-> 一律 true。
  - pull_request：只要有任何一個變更的檔案不是文件，就是 true。文件指
    `*.md`、`doc/` 底下、`LICENSE`。
  - 判斷不出來的情況一律 true：沒有任何變更檔案、拿不到 base / head。
    寧可多跑一次 GPU，也不要因為判斷失敗而什麼都不跑。

只有一種情況會讓 job 失敗：`git diff` 本身失敗。那時候 `changes` 不是
success，`gate` 會因此失敗，Tier B 則被跳過 -- 不會被誤判成「通過」。

環境變數：
  EVENT_NAME  github.event_name
  BASE_SHA    github.event.pull_request.base.sha（pull_request 才有）
  HEAD_SHA    github.event.pull_request.head.sha（pull_request 才有）
"""

import os
import subprocess
import sys

DOC_SUFFIXES = (".md",)
DOC_PREFIXES = ("doc/",)
DOC_FILES = ("LICENSE",)


def is_doc(path):
    """True when PATH is documentation only, so changing it needs no picture."""
    return (
        path.endswith(DOC_SUFFIXES)
        or path.startswith(DOC_PREFIXES)
        or path in DOC_FILES
    )


def changed_files(base, head):
    """Files changed between the PR's merge base and head."""
    out = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def viewer_selected(event, base, head):
    """Whether the build and Tier B must run for this event."""
    if event != "pull_request":
        return True
    if not base or not head:
        return True
    files = changed_files(base, head)
    if not files:
        return True
    return not all(is_doc(path) for path in files)


def main():
    event = os.environ.get("EVENT_NAME", "")
    base = os.environ.get("BASE_SHA", "")
    head = os.environ.get("HEAD_SHA", "")
    try:
        selected = viewer_selected(event, base, head)
    except subprocess.CalledProcessError as exc:
        print(f"changed_scope: git diff failed: {exc.stderr.strip()}",
              file=sys.stderr)
        return 1
    print(f"viewer={'true' if selected else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
