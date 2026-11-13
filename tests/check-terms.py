#!/usr/bin/env python3
"""置き換えた語がリポジトリに戻っていないことを確認する。

引数のファイル、なければ Git で管理するテキストのファイルすべてを読み、
置き換える語があれば「ファイル:行: 理由」を標準エラー出力に出して 1 で終わる。
置き換える語は、このファイル自身に含まれないよう、コードポイントで書く。
設計は docs/terms.md の「テスト」。
"""
import re
import subprocess
import sys
from pathlib import Path


def cp(*codes):
    """コードポイントから文字列を作る。"""
    return "".join(chr(code) for code in codes)


HAN = cp(0x7248)  # 配るもののバージョン
DAN = cp(0x6BB5)  # 設計を実装に分けた単位、sub-issue の順番、処理の手順
KAI = cp(0x968E)
KA = cp(0x8AB2)
DAI = cp(0x984C)
SHINKOU = cp(0x9032, 0x884C)
YAKU = cp(0x5F79)
NO = cp(0x306E)
TANTOU = cp(0x62C5, 0x5F53)
ZANRYOU = cp(0x6B8B, 0x91CF)
TASHIKAME = cp(0x78BA, 0x304B, 0x3081)  # 確認の意味の語。「確か」の後に「め」が続かない語は止めない

# 残すもの。文の区切り、ふだん、一つ下の深さ、数字と空白の後の 1 字と「まで」（入れ子の深さ）
DAN_ALLOWED = re.compile(
    "|".join(
        [
            DAN + cp(0x843D),
            cp(0x666E) + DAN,
            cp(0x4E00) + DAN,
            "(?<=[0-9] )" + DAN + "(?=" + cp(0x307E, 0x3067) + ")",
        ]
    )
)
# 日本語の文字（ひらがな・カタカナ・漢字）
JAPANESE = "[" + cp(0x3040) + "-" + cp(0x30FF) + cp(0x3400) + "-" + cp(0x4DBF) + cp(0x4E00) + "-" + cp(0x9FFF) + "]"
JA_CHAR = re.compile(JAPANESE)
# 英語の語の検査から除くもの。外から受け取る値は、日本語の文の中でも英語のまま書く
ISSUE_EXTERNAL = ("After PRs merge, move the issue to",)
ISSUE_EXCLUDED = re.compile(
    "|".join(
        [
            r"`[^`\n]*`",
            r"https?://\S+",
            "GitHub " + NO + " issue",
            r"sub-issue",
        ]
        + [re.escape(value) for value in ISSUE_EXTERNAL]
    ),
    re.IGNORECASE,
)
ISSUE = re.compile(r"(?<![A-Za-z0-9_/.-])issue(?![A-Za-z0-9_/.-])", re.IGNORECASE)

SIMPLE = [
    (HAN, f"「{HAN}」は「バージョン」にする"),
    (DAN + KAI, f"「{DAN}{KAI}」は「ステージ」か「フェーズ」にする"),
    (KA + DAI, f"「{KA}{DAI}」は「タスク」にする"),
    (
        SHINKOU + "(?:" + YAKU + "|" + NO + YAKU + "|" + NO + TANTOU + ")",
        "役の名前の進行は「リーダー」にする",
    ),
    ("AI ?" + NO + ZANRYOU, "AI の使用の上限は「使用上限」と書く"),
    (TASHIKAME, f"「{TASHIKAME}」は確認にする（文に合わなければ検証か照合）"),
]


def tracked_files(root):
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    ).stdout
    return [root / name for name in out.decode("utf-8").split("\0") if name]


def check_text(path, text):
    errors = []
    for number, line in enumerate(text.splitlines(), 1):
        for pattern, reason in SIMPLE:
            if re.search(pattern, line):
                errors.append(f"{path}:{number}: {reason}")
        rest = DAN_ALLOWED.sub("", line)
        rest = rest.replace(DAN + KAI, "")
        if DAN in rest:
            errors.append(
                f"{path}:{number}: 「{DAN}」は、設計の単位ならフェーズ、sub-issue の順ならステージ、処理の流れの 1 つなら手順にする"
            )
        stripped = ISSUE_EXCLUDED.sub(" ", line)
        for match in ISSUE.finditer(stripped):
            before = stripped[: match.start()].rstrip(" ")[-1:]
            after = stripped[match.end() :].lstrip(" ")[:1]
            if (before and JA_CHAR.match(before)) or (after and JA_CHAR.match(after)):
                errors.append(
                    f"{path}:{number}: Multica の `issue` は「タスク」、GitHub の `issue` は「GitHub の issue」と書く"
                )
                break
    return errors


def main(argv):
    if argv:
        paths = [Path(arg) for arg in argv]
    else:
        root = Path(__file__).resolve().parent.parent
        paths = tracked_files(root)
    errors = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        errors += check_text(path, text)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
