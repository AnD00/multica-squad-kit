#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-body-unreadable-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# squad-review-next decide が、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の読めない行（tests/review-body-table.tsv）を、共通の部品と同じ結果で読むかを確認する。
# 入力は、回 round-1 のあとにリーダーが書いたコメント 1 件。読める制御記録なら書き済み、読めて制御記録でないなら次の依頼を 1 回書き、読めないなら何も書かずに理由つきで終了 3 になる。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$root/tests/review-body-table.sh"

check() { # 期待 説明 本文の JSON 文字列
	local expect=$1 label=$2 json=$3
	reset
	ok_round
	add_json next orchestrator "$json"
	run round-1
	case $expect in
	control)
		expect_status 0
		[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "（${label}）書き済みにしていない: $(<"$test_dir/out")"
		expect_nothing_written ;;
	notcontrol)
		expect_status 0
		[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "（${label}）書き済みにしている"
		[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "（${label}）次の依頼が 1 件でない: $(<"$test_dir/posted.jsonl")" ;;
	unreadable:*)
		expect_leader "制御記録を読めない（next: ${expect#unreadable:}）" ;;
	esac
}
body_table '修正の依頼: 1 回目' round-1 check unreadable
echo "PASS review-next-decide: 本文の読み方の表の読めない行 ${body_table_count} 行で、読める制御記録は書き済み、読めて制御記録でないものは次の依頼を 1 回書き、読めないものは何も書かず理由つきで終了 3"
