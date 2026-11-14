#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-fix-test.sh で実行する。
# squad-review-next decide の判定のうち、修正の依頼・使用率の待ち・24 時間を超えた待ちの人間の呼びを確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 修正の依頼。
fix_body() { # 役 回数 指摘
	printf '%s PR の ❌ の指摘を直してください。\n前の回: round-1\n修正の依頼: %s 回目\n振り分け: Claude で足りる。工程: fix\n直す指摘: %s（結果は、この回の返事のコメントと PR のコメントにある）\n対象の PR: %s' "$(mention "$1")" "$2" "$3" "$pr_url"
}
reset
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ❌ "$sha" なし
run round-1
expect_posted 修正 "$(fix_body claude-fixer 1 'code-reviewer、qa')"
expect_calls pick-calls 'pick test-issue fix --round round-1'
expect_no_calls watch-calls
# 修正の依頼の回数は、修正の依頼: の行の数から数える。3 回目まで書ける。
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n前の回: older-1'
add fix-2 orchestrator $'修正の依頼: 2 回目\n前の回: older-2'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_posted 修正 "$(fix_body claude-fixer 3 code-reviewer)"
# 4 回目は書かずリーダーに任せる。
reset
base_round
for i in 1 2 3; do add "fix-$i" orchestrator "修正の依頼: $i 回目"$'\n'"前の回: older-$i"; done
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '修正の依頼が 3 回に達している'
expect_no_calls pick-calls
# 設計の変更が実装を始めたあとで、印も 重要の印: もないなら、リーダーに任せる。
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '設計の変更が実装を始めたあと'
expect_no_calls pick-calls
# 重要の印: の行があれば修正に進む。
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n重要の印: 付けない（テスト）'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "重要の印: があるのに修正でない: $(<"$test_dir/out")"
# 印があり、最上位の役の結果がタスクにないなら、リーダーに任せる。
reset
set_issue_labels label-imp
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '最上位の役の結果がタスクにない'
expect_no_calls pick-calls
# 印があっても、見直しの種類の回に最上位の役の結果があれば、修正に進む。
reset
set_issue_labels label-imp
add design-r orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$old"$'\n返事を待つ役: '"$(mentions claude-principal)"
result design-r claude-principal ✅ "$old" なし
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "最上位の役の結果があるのに修正でない: $(<"$test_dir/out")"
echo 'PASS review-next-decide: ❌ があれば、回数と印の条件を確認して、修正の依頼を書く'

# 使用率の待ち（pick の終了コード 3）。待ちのコメントだけを書き、状態も CI の待ちも変えない。
reset
set_metadata ci_wait_head "$sha"
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
printf '使用率の待ち: fix を 5 時間待つ。\n' >"$test_dir/pick-out"
echo 3 >"$test_dir/pick-status"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 使用率の待ち\n依頼: posted-comment' ]] || fail "待ちの出力が違う: $(<"$test_dir/out")"
[[ $(posted_body) == $'使用率の待ち: fix を 5 時間待つ。\n前の回: round-1' ]] || fail "待ちのコメントが違う: $(posted_body)"
expect_call_lacks pr-watch-calls ci-wait-clear
expect_no_calls status-calls
expect_no_calls watch-calls
# pick が想定外の終了コードなら、書かずに失敗する。
reset
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
echo 1 >"$test_dir/pick-status"
run round-1
expect_failure '役を選べない'
echo 'PASS review-next-decide: 役を選べないとき、使用率の待ちは待ちのコメントだけを書き、想定外は書かずに失敗する'

# 24 時間を超えた待ち（pick の終了コード 4）は、人間を呼んでタスクを in_review にする。
human_setup() {
	reset
	add pr-made orchestrator "PR を作りました ${pr_url}"$'\n'"紐付けの失敗: PR をタスクに紐付けられませんでした。"$'\n'"GitHub 連携が見つかりません。" ""
	review_round round-1 "$sha" code-reviewer qa
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	printf '使用率の待ち: fix を通算 24 時間待った。\n' >"$test_dir/pick-out"
	echo 4 >"$test_dir/pick-status"
}
human_setup
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 人間の確認\n依頼: posted-comment' ]] || fail "人間の呼びの出力が違う: $(<"$test_dir/out")"
expect_calls status-calls 'issue status test-issue in_review'
body=$(posted_body)
[[ $body == '[@Owner](mention://member/human-1) 使用率の待ちが通算 24 時間を超えました。待つか、別の進め方にするかを決めてください。'$'\n前の回: round-1\n使用率の待ち: fix を通算 24 時間待った。\n'* ]] || fail "人間の呼びの先頭が違う: $body"
[[ $body == *$'\n紐付けの失敗: PR をタスクに紐付けられませんでした。\nGitHub 連携が見つかりません。\n'* ]] || fail "紐付けの失敗の段落がない: $body"
[[ $body == *'ワークスペースの設定のコードの画面で、作業先のリポジトリが GitHub 連携につながっていることを確認してください。'* ]] || fail "連携の案内がない: $body"
[[ $body != *'PR がタスクに紐付いていません'* ]] || fail "紐付いているのに、紐付いていない案内がある: $body"
expect_no_calls watch-calls
# 紐付いていないときは、紐付ける PR の案内を足す。
human_setup
printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"
run round-1
expect_status 0
body=$(posted_body)
[[ $body == *$'\nPR がタスクに紐付いていません。タスクの画面の PR の欄で `'"$pr_url"$'` を紐付けてください。\n'* ]] || fail "紐付けの案内がない: $body"
# 紐付けの失敗の段落がなければ、段落も連携の案内も付けない。
human_setup
add pr-made2 orchestrator "PR の確認 ${pr_url}" ""
jq 'map(if .id == "pr-made" then .content = "PR を作りました https://github.com/demo/project/pull/7" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
run round-1
expect_status 0
body=$(posted_body)
[[ $body != *'紐付けの失敗:'* && $body != *'GitHub 連携'* ]] || fail "段落がないのに案内がある: $body"
# 連携に触れない段落だけなら、段落だけを付ける。
human_setup
jq 'map(if .id == "pr-made" then .content = "PR を作りました https://github.com/demo/project/pull/7\n紐付けの失敗: タイムアウトでした。\n再実行してください。" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
run round-1
body=$(posted_body)
[[ $body == *$'\n紐付けの失敗: タイムアウトでした。\n再実行してください。' && $body != *'ワークスペースの設定'* ]] || fail "連携に触れない段落の扱いが違う: $body"
# CI の待ちの規則があれば、人間を呼ぶ前に消す。消せなければ書かない。
human_setup
set_metadata ci_wait_head "$sha"
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci-wait-clear test-issue'
human_setup
set_metadata ci_wait_head "$sha"
echo 1 >"$test_dir/clear-status"
run round-1
expect_failure 'CI の待ちの規則を消せない'
expect_no_calls status-calls
# 呼ぶ人間を決められなければ書かない。
human_setup
cp "$test_dir/squads.json" "$test_dir/squads.orig"
jq 'map(.creator_id = "nobody")' "$test_dir/squads.orig" >"$test_dir/squads.json"
run round-1
expect_failure '呼ぶ人間の名前を読めない'
mv "$test_dir/squads.orig" "$test_dir/squads.json"
# コメントを書けなかったら、状態は変えない。
human_setup
touch "$test_dir/post-fail"
run round-1
expect_failure 'コメントの投稿に失敗した'
expect_no_calls status-calls
echo 'PASS review-next-decide: 24 時間を超えた待ちは、人間を呼ぶコメントを書いてから in_review にする'
