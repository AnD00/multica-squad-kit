#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-status-test.sh で実行する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。watch・unwatch と status の判定を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/review-wait-test-lib.sh"

reset_calls
(cd "$test_dir" && bash "$script" watch test-issue trigger-comment "$a" "$b") >"$test_dir/output"
jq -s '.' "$test_dir/calls.jsonl" >"$test_dir/watch-calls.json"
assert_jq '[.[] | select(.[0:3] == ["issue", "wakeup", "delete"]) | .[4]] == ["old-active", "old-disabled"]' "$test_dir/watch-calls.json"
assert_jq --arg a "$a" --arg b "$b" '
	def value($flag): . as $args | index($flag) as $i | if $i == null then null else $args[$i+1] end;
	[.[] | select(.[0:3] == ["issue", "wakeup", "create"])] as $creates
	| ($creates | length) == 3
	and ([$creates[] | select(value("--event") != null) | value("--filter-agent-id")] == [$a, $b])
	and (all($creates[]; .[3] == "test-issue" and value("--parent") == "trigger-comment"
		and value("--agent-id") == null and value("--mode") == null and value("--on-timeout") == null))
	and (all($creates[] | select(value("--event") != null);
		value("--event") == "task.failed,task.cancelled" and value("--expires-in") == "60m"))
	and ([$creates[] | select(value("--kind") == "at" and value("--after") == "60m")] | length) == 1
' "$test_dir/watch-calls.json"
assert_jq -s --arg mark "$mark" 'length == 3 and all(.[];
	(.instruction | startswith($mark + "\n"))
	and (.instruction | contains("squad-review-wait status test-issue")))
	and (.[0:2] | all(.[]; .instruction | contains("--timeout") | not))
	and (.[2].instruction | contains("status test-issue --timeout"))' "$test_dir/instructions.jsonl"
# 時刻の規則に実際に渡したコマンドで、上限時の判定を検証する。
timeout_option=''
if [[ $(jq -rs '.[-1].instruction' "$test_dir/instructions.jsonl") == *'status test-issue --timeout'* ]]; then
	timeout_option=--timeout
fi
# 指示ファイルは登録中だけ存在し、終了後は残らない。
while IFS= read -r path; do [[ ! -e $path ]]; done < <(jq -r .path "$test_dir/instructions.jsonl")
echo 'PASS watch: 古い規則だけを削除、役ごとの once と上限 1 個、返信先と指示ファイルの片付け'

reset_calls
bash "$script" unwatch test-issue
assert_jq -s '[.[] | select(.[0:3] == ["issue", "wakeup", "delete"]) | .[4]] == ["old-active", "old-disabled"]' "$test_dir/calls.jsonl"
echo 'PASS unwatch: CI とコンフリクトの規則を保存'

reset_calls
for invalid_id in missing-role archived; do
	if bash "$script" watch test-issue trigger-comment "$invalid_id" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	assert_jq -s 'all(.[]; .[0:3] != ["issue", "wakeup", "delete"])' "$test_dir/calls.jsonl"
done
echo 'PASS watch: 不明な役では古い規則を削除せずエラー'

printf 'issue wakeup create' >"$test_dir/fail"
if (cd "$test_dir" && bash "$script" watch test-issue trigger-comment "$b") >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock failure' ]]
[[ -z $(find "$test_dir/tmp" -name 'review-wait-watch.*' -print) ]]
rm "$test_dir/fail"
echo 'PASS watch: CLI 失敗を返し、指示ファイルを片付ける'

printf '[]' >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回がないので何もしない'
round_comments
printf '[]' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 回なし、実行なしで上限前'

for state in failed cancelled; do
	run_fixture "$a" "$state" "$((round_ts + 1))" '利用上限' | jq -s '.' >"$test_dir/runs.json"
	check_status "返事の待ち: 人間を呼ぶ"$'\n'"- demo-code-reviewer-test: ${state}（利用上限）"$'\n- demo-qa-test: 実行なし'
done
echo 'PASS status: 失敗・取り消しを人間へ、役の名前・理由・実行なしを表示'

# 自動再試行後の最新の実行を使う。
{
	run_fixture "$a" failed "$((round_ts + 1))"
	run_fixture "$a" queued "$((round_ts + 2))"
	run_fixture "$b" running "$((round_ts + 1))"
} | jq -s 'reverse' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 自動再試行の最新の待ち・実行中では何もしない'

# 回より前と同じ秒の失敗も拾わない。時刻の表記順でなく、小数込みで判定する。
{
	run_fixture "$a" failed "$((round_ts - 60))"
	run_fixture "$b" cancelled "$round_ts" | jq '.created_at |= sub("Z$"; ".100+00:00")'
} | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 前の回の失敗と同じ秒の過去の取り消しを除外'

round_ts=$((now - 3660))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
round_comments
run_fixture "$b" running "$((round_ts + 1))" | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 回から 61 分たっても返っていない役がいます\n- demo-code-reviewer-test: 実行なし\n- demo-qa-test: running'
echo 'PASS status: 60 分の上限では /note で役と実行状態を記録'

run_fixture "$b" failed "$((round_ts + 1))" | jq -s '.' >"$test_dir/runs.json"
check_status $'返事の待ち: 人間を呼ぶ\n- demo-code-reviewer-test: 実行なし\n- demo-qa-test: failed'
echo 'PASS status: 上限を過ぎても失敗は人間へ'

after=$(jq -nr --argjson ts "$((round_ts + 2))" '$ts | todateiso8601')
{
	run_fixture "$a" failed "$((round_ts + 1))"
	run_fixture "$b" running "$((round_ts + 1))"
} | jq -s '.' >"$test_dir/runs.json"
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg time "$after" '. + [
	$comment[0] + {author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"}
]' "$test_dir/comments.json" >"$test_dir/partial.json"
cp "$test_dir/partial.json" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回から 61 分たっても返っていない役がいます\n- demo-qa-test: running'
echo 'PASS status: 返した役の失敗を除き、未返答の役だけを記録'

jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg b "$b" --arg time "$after" '. + [
	$comment[0] + {author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"},
	$comment[0] + {author_type: "agent", author_id: $b, created_at: $time, content: "/note\nqa result"}
]' "$test_dir/comments.json" >"$test_dir/returned.json"
cp "$test_dir/returned.json" "$test_dir/comments.json"
check_status $'返事の待ち: 返事がそろっていて、まだ次へ回していない'
check_status $'返事の待ち: 返事がそろっていて、まだ次へ回していない' --timeout
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg time "$after" '. + [$comment[0] + {author_type: "agent", author_id: "orchestrator", created_at: $time, content: "返事がそろいました。"}]' \
	"$test_dir/comments.json" >"$test_dir/ready.json"
cp "$test_dir/ready.json" "$test_dir/comments.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
echo 'PASS status: 全員が返して記録がなければ、知らせの有無を問わず proceed へ進む'

# CLI が秒までの時刻を返しても、当該コメントで始まった実行は拾う。
round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
round_comments
for state in failed cancelled; do
	run_fixture "$a" "$state" "$round_ts" '利用上限' | jq -s 'map(. + {trigger_comment_id: "round"})' >"$test_dir/runs.json"
	check_status "返事の待ち: 人間を呼ぶ"$'\n'"- demo-code-reviewer-test: ${state}（利用上限）"$'\n- demo-qa-test: 実行なし'
done
echo 'PASS status: 依頼と同じ秒に始まった当該実行の失敗・取り消しを検出'

# 同じ秒でも、前の回の実行は混ぜない。
run_fixture "$a" failed "$round_ts" | jq -s 'map(. + {trigger_comment_id: "previous-round"})' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 同じ秒の前の回の実行を除外'

# 実行中に依頼が届いた場合も、delivered_comment_ids で回を特定する。
run_fixture "$a" failed "$((round_ts - 1))" | jq -s 'map(. + {trigger_comment_id: "previous-round", delivered_comment_ids: ["round"]})' >"$test_dir/runs.json"
check_status $'返事の待ち: 人間を呼ぶ\n- demo-code-reviewer-test: failed\n- demo-qa-test: 実行なし'
echo 'PASS status: 実行中に届いた依頼コメントとの対応も使用'

# 登録の 10 秒後に依頼コメントを書き、登録から 60 分で 1 回だけ起きる。
round_ts=$((now - 3590))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
round_comments
run_fixture "$b" running "$((round_ts + 1))" | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
check_status $'/note\n返事の待ち: 待つ上限に達しても返っていない役がいます\n- demo-code-reviewer-test: 実行なし\n- demo-qa-test: running' ${timeout_option:+"$timeout_option"}
echo 'PASS status: 登録とコメントに 10 秒差があっても上限用の起床で役と状態を記録'

run_fixture "$b" cancelled "$((round_ts + 1))" | jq -s '.' >"$test_dir/runs.json"
check_status $'返事の待ち: 人間を呼ぶ\n- demo-code-reviewer-test: 実行なし\n- demo-qa-test: cancelled' --timeout
echo 'PASS status: 上限用の起床でも失敗・取り消しは人間へ'

jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg b "$b" --arg time "$(jq -nr --argjson ts "$((round_ts + 2))" '$ts | todateiso8601')" '. + [
 $comment[0] + {author_type:"agent", author_id:$a, created_at:$time, content:"result"},
 $comment[0] + {author_type:"agent", author_id:$b, created_at:$time, content:"result"},
 $comment[0] + {author_type:"agent", author_id:"orchestrator", created_at:$time, content:"返事がそろいました。"}]' \
	"$test_dir/comments.json" >"$test_dir/ready.json"
cp "$test_dir/ready.json" "$test_dir/comments.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない' --timeout
printf '[]' >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回がないので何もしない' --timeout
echo 'PASS status: 上限用の起床でも未処理のそろった回は進み、回なしでは何もしない'

round_comments
printf 'issue runs test-issue' >"$test_dir/fail"
if bash "$script" status test-issue >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock failure' && ! -s $test_dir/output ]]
rm "$test_dir/fail"
echo 'PASS status: CLI 失敗では誤った判定を出さずエラー'
