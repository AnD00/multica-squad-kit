#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-unreadable-scenario-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# squad-review-next decide が、読めない候補をどの場面で止め、どの場面で候補にしないかを確認する。
# 場面は docs/review-next-step.md の「本文の読み方のテスト」の表 2 の decide の行。本文の読み方そのものは squad-review-next-decide-body-*-test.sh。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

final_ok() { # 最終レビューまで済んだ状態にする。回は final-1
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}
wrote_once() { # 次の依頼を 1 回だけ書いた
	expect_status 0
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "書き済みにしている"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "次の依頼が 1 件でない: $(<"$test_dir/posted.jsonl")"
}

# 表 2 の行 2: 別の回を指す読めない候補だけがある。候補にせず、次の依頼を 1 回だけ書く。
for author in orchestrator qa; do
	reset
	ok_round
	[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
	add other "$author" $'> 修正の依頼: 直してください\n> 前の回: round-99'
	run round-1
	wrote_once
done
echo 'PASS review-next-decide: 別の回を指す読めない候補は、候補にせず、次の依頼を 1 回だけ書く'

# 表 2 の行 3: メンバーのコメントか役の結果に、読めない書き方の前の回: R がある。候補にせず、次の依頼を 1 回だけ書く。
reset
ok_round
add member human-1 $'> 修正の依頼: 直してください\n> 前の回: round-1'
run round-1
wrote_once
reset
ok_round
add member human-1 $'  前の回: round-1\n<div>\n修正の依頼: 直してください'
run round-1
wrote_once
for body in $'> 前の回: round-1' $'  前の回: round-1' $'<div>\n前の回: round-1'; do
	reset
	ok_round
	add res-extra qa $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n✅ demo-qa-test: 結果\n設計への指摘: なし\n\n'"$body"
	run round-1
	wrote_once
done
echo 'PASS review-next-decide: メンバーのコメントと役の結果（返事の回: あり）の読めない書き方は、候補にせず、次の依頼を 1 回だけ書く'

# 表 2 の行 4: 前の回: でたどる途中の回のコメントが読めない。何も書かず、理由つきで終了 3。
reset
base_round
jq 'map(if .id == "round-1" then .content += "\n> 引用の行" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$sha" なし
add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
add round-2 qa "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"コミットが合わず頼み直す役: qa"$'\n'"前の回: round-1"$'\n'"対象の PR: ${pr_url}"
result round-2 qa ✅ "$sha" なし
set_principal_pick claude-principal
run round-2
expect_leader '制御記録を読めない（round-1: 引用）'
echo 'PASS review-next-decide: 前の回: でたどる途中の回のコメントが読めなければ、何も書かず理由つきで終了 3 になる'

# 表 2 の行 5: 同じコミットで見直しの種類: 最終レビューを含む読めない候補がある。最終レビューもマージも頼まず、理由つきで終了 3。
reset
ok_round
add final-quote orchestrator $'> 見直しの種類: 最終レビュー\n> 確認するコミット: '"$sha"
run round-1
expect_leader '制御記録を読めない（final-quote: 引用）'
reset
final_ok
add final-quote orchestrator $'> 見直しの種類: 最終レビュー\n> 確認するコミット: '"$sha"
run final-1
expect_leader '制御記録を読めない（final-quote: 引用）'
expect_no_calls pr-watch-calls
echo 'PASS review-next-decide: 同じコミットの最終レビューを含む読めない候補があれば、最終レビューもマージも頼まず理由つきで終了 3 になる'

# 表 2 の行 6: 写す紐付けの失敗: の段落に、字下げの行か < で始まる行がある。何も書かず、書く本文を読めない理由で終了 3。
for case_ in 'indent:行頭の空白:  字下げした行' 'html:HTML:<b>タグの行'; do
	IFS=: read -r _ reason line <<<"$case_"
	reset
	final_ok
	printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"
	jq --arg line "$line" 'map(if .id == "pr-made" then .content = "PR を作りました https://github.com/demo/project/pull/7\n\n紐付けの失敗: PR をタスクに紐付けられなかった。\n" + $line else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
	run final-1
	expect_leader "書く本文を読めない（${reason}）"
done
echo 'PASS review-next-decide: 写す紐付けの失敗: の段落の字下げの行と < の行は、何も書かず、書く本文を読めない理由で終了 3 になる'
