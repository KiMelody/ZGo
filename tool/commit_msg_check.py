#!/usr/bin/env python3
"""提交消息规范检查。

规则（与 .githooks/commit-msg 配合）：
- 标题 >100 字符警告，>120 字符错误。
- 标题必须是 Conventional Commit 前缀。
- 标题和正文里的调试过程、设备名、目录名、技术栈名、代码符号、数值细节、
  尾注一律拦截。
- 版本号与纯测试计数放行。

用法：python3 tool/commit_msg_check.py <commit-message-file>
退出码 0 通过，1 拒绝。
"""

import re
import sys

TITLE_WARN = 100
TITLE_ERROR = 120

TYPES = (
    "feat|fix|perf|refactor|chore|docs|ci|build|test|assets|release|style|revert"
)
PREFIX = re.compile(rf"^(?:{TYPES})(?:\([^)]+\))?!?:")

# 允许内容：先剔除，避免误报
ALLOW = re.compile(
    r"测试\s*\d+\s*→\s*\d+"
    r"|测试\s*\+\s*\d+"
    r"|全量\s*\d+\s*绿"
    r"|\d+\.\d+\.\d+\+\d+"  # 版本号 X.Y.Z+N
    r"|\b\d+\.\d+\.\d+\b"  # 桌面版本号 3.17.2
)

# 违禁内容
RULES = {
    "遗留尾注": re.compile(r"Squashed:|原提交[:：]|cherry.?picked\s+from"),
    "调试/原因": re.compile(
        r"根因|根治|定谳|定证|探针|取证|活体|真机|实测|asar|logcat|口径|"
        r"推翻|证伪|推演|复现|铁证|三证|双证|连拍|重放丢弃|覆盖缺口|核查发现|初判|定局"
    ),
    "设备名": re.compile(
        r"PMA110|pma110|xuanyuan|ColorOS|HyperOS|OplusHansManager|"
        r"BaseMode|activeMode|mState"
    ),
    "具体目录": re.compile(
        r"\.zcode|\.claude|\.opencode|\.deja|key\.properties|\.zcodeignore"
    ),
    "技术栈名": re.compile(r"Flutter|\bDart\b|\bR8\b|sqlite3|SharedPreferences|jsonEncode"),
    "代码符号": re.compile(r"_[a-z][a-zA-Z]{2,}|[a-z]{2,}[A-Z][a-zA-Z]+"),
    "数值细节": re.compile(
        r"\d+\s*MB|\d+\s*KB|\d+dp|\d+s\b|TTL|backoff|≥|≤|2/5|"
        r"no frames|no content|never ready"
    ),
    "测试用例名": re.compile(r"测试\s*\d+\s*→\s*\d+\s*（"),
}


def check(path):
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    # git 可能附带 # 注释行，先剔除
    lines = [ln for ln in raw.splitlines() if not ln.startswith("#")]
    title = lines[0].strip() if lines else ""
    for ln in lines[1:]:
        pass
    body = "\n".join(lines[1:])

    errors = []
    warnings = []

    if not title:
        errors.append("标题为空")
    else:
        n = len(title)
        if n > TITLE_ERROR:
            errors.append(f"标题 {n} 字符，超过硬上限 {TITLE_ERROR}")
        elif n > TITLE_WARN:
            warnings.append(f"标题 {n} 字符，超过建议上限 {TITLE_WARN}")

        if not PREFIX.match(title):
            errors.append(
                f"标题缺少 Conventional 前缀（feat/fix/perf/refactor/chore/...）: {title[:40]}"
            )

    clean = ALLOW.sub("", title + "\n" + body)
    for label, pattern in RULES.items():
        hits = sorted(set(pattern.findall(clean)))
        if hits:
            shown = ", ".join(hits[:6])
            more = f" 等 {len(hits)} 项" if len(hits) > 6 else ""
            errors.append(f"{label}: {shown}{more}")

    return errors, warnings


def main():
    if len(sys.argv) != 2:
        print("用法: commit_msg_check.py <commit-message-file>", file=sys.stderr)
        return 1

    errors, warnings = check(sys.argv[1])
    for w in warnings:
        print(f"[提交消息警告] {w}", file=sys.stderr)
    for e in errors:
        print(f"[提交消息错误] {e}", file=sys.stderr)
    if errors:
        print(
            "\n提交被拒绝。请按规范重写消息："
            "\n  标题 type(scope): 简短改动概括（<=100 字符，硬上限 120）"
            "\n  正文只列改动清单，不写根因/取证/设备/目录/内部符号/尾注"
            "\n如需临时绕过（仅历史重写场景）: git commit --no-verify",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
