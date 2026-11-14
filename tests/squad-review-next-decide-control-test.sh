#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-control-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# squad-review-next decide の判定のうち、制御記録（書き済みとするか）を確認する。
# 条件は docs/review-next-step.md の「制御記録の読み方」にある。認める回と最終レビューの認め方は squad-review-next-decide-recognize-test.sh。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

written() { # 何も書かず、書き済みを出す
	expect_status 0
	[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "書き済みを出していない: $(<"$test_dir/out")"
	expect_nothing_written
}
not_written() { # 書き済みにせず、次の依頼を 1 回書く
	expect_status 0
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "書き済みにしている"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "次の依頼が 1 件でない: $(<"$test_dir/posted.jsonl")"
}

# ---- 制御記録でないものは、書き済みにしない。回を指していても、種類の行があっても、同じ。
control_case() { # 説明 作者 本文
	reset
	ok_round
	add next "$2" "$3"
	run round-1
	echo "case: $1" >"$test_dir/case"
	not_written
}
control_case '前の回: だけ（リーダー）' orchestrator $'次の依頼です\n前の回: round-1'
control_case '前の回: だけ（決める実行の役）' qa $'次の依頼です\n前の回: round-1'
control_case '種類の行だけ' orchestrator '修正の依頼: 直してください'
control_case '逆引用符の囲みの中' orchestrator $'```\n修正の依頼: 直してください\n前の回: round-1\n```'
control_case '4 個の囲みの中の 3 個の囲みの例' orchestrator $'````\n```\n修正の依頼: 直してください\n前の回: round-1\n```\n````'
control_case '4 個の囲みの中の 3 個の囲みのあとの例' qa $'````md\n```\nx\n```\n修正の依頼: 直してください\n前の回: round-1\n````'
control_case '囲みの中の字下げ 4 個の終了風の行の例（リーダー）' orchestrator $'```\n    ```\n修正の依頼: 直してください\n前の回: round-1\n```'
control_case '囲みの中の字下げ 4 個の終了風の行の例（決める実行の役）' qa $'````md\n    ````\n修正の依頼: 直してください\n前の回: round-1\n````'
control_case '役の結果の中（返事の回: あり）' qa $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n✅ demo-qa-test: 結果\n設計への指摘: なし\n修正の依頼: 直してください\n前の回: round-1'
control_case '人間のコメント' human-1 $'修正の依頼: 直してください\n前の回: round-1'
control_case '決める実行の役でもリーダーでもないエージェント' claude-fixer $'修正の依頼: 直してください\n前の回: round-1'
control_case '存在しない回を指す' orchestrator $'修正の依頼: 直してください\n前の回: round-99'
echo 'PASS review-next-decide: 前の回: だけ・囲み（字下げ 4 個の終了風の行を含む）・結果・人間・ほかの役・存在しない回を指すコメントは、書き済みにしない'

# 引用は読めない書き方で、この回を指す候補になる。書き済みにも次の依頼にもせず、何も書かずに理由つきで終了 3 になる。
for author in orchestrator qa; do
	reset
	ok_round
	add next "$author" $'> 修正の依頼: 直してください\n> 前の回: round-1'
	run round-1
	expect_leader '制御記録を読めない（next: 引用）'
done
echo 'PASS review-next-decide: 引用の中の前の回: と種類の行は、読めない候補として何も書かずに終了 3 になる'

# 回より前に書かれたコメントは、制御記録でない。
reset
base_round
add early orchestrator $'修正の依頼: 直してください\n前の回: round-1'
jq 'map(if .id == "early" then .created_at = "2026-11-10T11:00:00Z" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
all_ok round-1 "$sha" code-reviewer qa
set_principal_pick claude-principal
run round-1
not_written
echo 'PASS review-next-decide: 回より前に書かれたコメントは、書き済みにしない'

# 決める記録より前に書いた決める実行の役のコメントは、制御記録でない。決める記録のあとのものは制御記録。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
add pre qa $'修正の依頼: 直してください\n前の回: round-1'
result round-1 qa ✅ "$sha" なし
add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
set_principal_pick claude-principal
run round-1
not_written
reset
base_round
all_ok round-1 "$sha" code-reviewer qa
add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
add post qa $'修正の依頼: 直してください\n前の回: round-1'
run round-1
written
echo 'PASS review-next-decide: 決める記録より前の決める実行の役のコメントは書き済みにせず、あとのものは書き済みにする'

# 決める実行の役とリーダーが書いた各種類の記録は、書き済みにする。使用率の待ちと CI の待ちは、書き済みにしない。
for author in orchestrator qa; do
	for body in $'修正の依頼: 直してください\n前の回: round-1' $'コミットが合わず頼み直す役: qa\n前の回: round-1' \
		$'見直しの種類: 最終レビュー\n前の回: round-1' $'マージの依頼: '"$sha"$'\n前の回: round-1' \
		$'使用率の待ち: 24 時間を超えるので人間に聞く\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		written || fail "$author の記録を書き済みにしていない: $body"
	done
	for body in $'使用率の待ち: fix を待つ。\n前の回: round-1' $'マージの前の CI の待ち: 待つ。\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "$author の待ちの記録を書き済みにしている: $body"
	done
done
echo 'PASS review-next-decide: 決める実行の役とリーダーの各種類の記録は書き済み、使用率の待ちと CI の待ちは書き済みにしない'

