#!/usr/bin/env bash
# 置き換えた語がリポジトリに戻っていないことと、その検査が語ごとに働くことを確かめる。設計は docs/terms.md の「テスト」。
# 置き換える前の語は、このファイルに含めない。仮の記号（@HAN@ など）で書き、検査の入力を作るときに文字へ直す。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/terms.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
check() { python3 "$root/tests/check-terms.py" "$@"; }

check
echo 'PASS terms: Git で管理するテキストのファイルに、置き換える前の語がない'

# 仮の記号を文字に直す。
expand() {
	python3 -c '
import sys
words = {
    "@HAN@": chr(0x7248),
    "@DAN@": chr(0x6bb5),
    "@KAI@": chr(0x968e),
    "@KA@": chr(0x8ab2),
    "@DAI@": chr(0x984c),
    "@SHIN@": chr(0x9032) + chr(0x884c),
    "@ZAN@": chr(0x6b8b) + chr(0x91cf),
    "@ISSUE@": "issue",
}
text = sys.argv[1]
for mark, word in words.items():
    text = text.replace(mark, word)
sys.stdout.write(text)
' "$1"
}
make() { printf '%b' "$(expand "$1")" >"$test_dir/input.md"; }
allow() {
	make "$1"
	check "$test_dir/input.md"
}
deny() {
	make "$1"
	if check "$test_dir/input.md" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "input.md:$2: $(expand "$3")" "$test_dir/err"
}

allow '文の区切りの段落、普段の使い方、一段下げる、深さを 1 段まで入れる。\n'
allow 'GitHub の issue と sub-issue と `issue` と https://github.com/example/example/issues/1 は残す。\n'
allow 'After PRs merge, move the issue to Done と、`multica issue get` と、multica issue get の実行。\n'
echo 'PASS terms: 残す語（文の区切り・ふだん・一つ下・入れ子の深さ・GitHub の issue・sub-issue・コード・URL・外から受け取る値）は止めない'

deny '配る@HAN@を決める。\n' 1 '「@HAN@」は「バージョン」にする'
deny '1 行目。\n@DAN@を積む。\n' 2 '「@DAN@」は、設計の単位ならフェーズ、sub-issue の順ならステージ、処理の流れの 1 つなら手順にする'
deny '設計の@DAN@@KAI@へ進む。\n' 1 '「@DAN@@KAI@」は「ステージ」か「フェーズ」にする'
deny '@KA@@DAI@を作る。\n' 1 '「@KA@@DAI@」は「タスク」にする'
deny '@SHIN@役へ頼む。\n' 1 '役の名前の進行は「リーダー」にする'
deny '@SHIN@の役へ頼む。\n' 1 '役の名前の進行は「リーダー」にする'
deny '@SHIN@の担当へ頼む。\n' 1 '役の名前の進行は「リーダー」にする'
deny 'AI の@ZAN@を見る。\n' 1 'AI の使用の上限は「使用上限」と書く'
deny '1 行目。\nこの@ISSUE@を直す。\n' 2 'Multica の `issue` は「タスク」、GitHub の `issue` は「GitHub の issue」と書く'
deny 'Fix @ISSUE@ を直す。\n' 1 'Multica の `issue` は「タスク」、GitHub の `issue` は「GitHub の issue」と書く'
echo 'PASS terms: 置き換える前の語を、場所と理由を添えて止める'

# 同じ検査を、仮の記号のない文で、設計の対応表の語に当てて確かめる。
allow '進行の記録と利用枠は残す。\n'
echo 'PASS terms: 残すと決めた語（進行の記録・利用枠）は止めない'
