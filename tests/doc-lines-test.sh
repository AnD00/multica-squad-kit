#!/usr/bin/env bash
# README.md・manual.md・CONTRIBUTING.md の段落が、1 行 1 文と末尾の半角空白 2 つの改行を守ることを確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/doc-lines.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
check() { python3 "$root/tests/check-doc-lines.py" "$@"; }

check "$root/README.md" "$root/manual.md" "$root/CONTRIBUTING.md"
echo 'PASS doc-lines: README.md・manual.md・CONTRIBUTING.md の段落は 1 行 1 文で、末尾の半角空白 2 つで改行する'

printf '1 文目。  \n2 文目（括弧の中。）と「引用。」と `code。` は 1 文。\n\n- 項目は。複数の文でよい。\n\n| 表も。 | 同じ。 |\n\n```\nコードも。数えない。\n```\n' >"$test_dir/ok.md"
check "$test_dir/ok.md"
echo 'PASS doc-lines: 括弧・引用・コードの中の「。」と、箇条書き・表・コードは数えない'

deny() {
	printf '%b' "$1" >"$test_dir/ng.md"
	if check "$test_dir/ng.md" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "ng.md:$2: $3" "$test_dir/err"
}
deny '1 文目。2 文目。\n' 1 '段落は 1 行に 1 文にする'
deny '1 文目。\n2 文目。\n' 1 '段落の途中の行は、末尾に半角空白 2 つを付ける'
deny '1 文目。   \n2 文目。\n' 1 '段落の途中の行は、末尾に半角空白 2 つを付ける'
deny '1 文目。  \n2 文目。  \n\n' 2 '段落の最後の行は、末尾に空白を付けない'
echo 'PASS doc-lines: 1 行に複数の文・途中の行の改行の空白の不足や過剰・最後の行の空白を、場所を添えて止める'
