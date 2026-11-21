#!/usr/bin/env python3
"""`gate` job 的判斷：這次 CI 選到的 job 是不是都通過了（#106，對齊 isaac#434）。

依變更範圍跳過 job 之後，PR 需要一個「不會因為被跳過而卡在 pending」的
總結狀態。`gate` 以 `always()` 執行，讀 `toJSON(needs)`：

  - `changes` 必須是 success。它沒成功時，下游全部被跳過，如果照「skipped
    算通過」的規則，gate 會在沒有檢查任何東西的情況下通過。
  - 其他 job：success 或 skipped 算通過；failure 或 cancelled 算失敗。
    任何其他值（GitHub 新增的狀態）也算失敗，未知的狀態不能被當成通過。

這不是發版關卡。tag 上的 call-release / publish-image 仍然直接 needs
tier-b-visual-e2e，沒有任何東西 needs gate。

環境變數：NEEDS_JSON = toJSON(needs)
"""

import json
import os
import sys

SCOPE_JOB = "changes"
PASSING = ("success", "skipped")


def failures(needs):
    """[(job, result)] for every need that does not let the gate pass."""
    bad = []
    if SCOPE_JOB not in needs:
        bad.append((SCOPE_JOB, "<absent>"))
    for job, info in sorted(needs.items()):
        result = (info or {}).get("result", "<missing>")
        if job == SCOPE_JOB:
            if result != "success":
                bad.append((job, result))
        elif result not in PASSING:
            bad.append((job, result))
    return bad


def main():
    raw = os.environ.get("NEEDS_JSON", "")
    try:
        needs = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"gate: NEEDS_JSON is not JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(needs, dict) or not needs:
        print("gate: NEEDS_JSON names no jobs", file=sys.stderr)
        return 1
    for job, info in sorted(needs.items()):
        print(f"gate: {job}={(info or {}).get('result', '<missing>')}")
    bad = failures(needs)
    for job, result in bad:
        print(f"gate: FAIL {job} ended {result}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
