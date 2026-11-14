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
(cd "$test_dir" && bash "$script" watch test-issue trigger-comment --agent-id leader-id "$a" "$b") >"$test_dir/output"
jq -s '.' "$test_dir/calls.jsonl" >"$test_dir/watch-calls.json"
assert_jq '
	def value($flag): . as $args | index($flag) as $i | if $i == null then null else $args[$i+1] end;
	[.[] | select(.[0:3] == ["issue", "wakeup", "create"])] as $creates
	| ($creates | length) == 3 and all($creates[]; value("--agent-id") == "leader-id" and value("--parent") == "trigger-comment")
' "$test_dir/watch-calls.json"
echo 'PASS watch: --agent-id を、役ごとの規則と上限の規則のすべてに渡す'

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
	$comment[0] + {id: "added-1", author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"}
]' "$test_dir/comments.json" >"$test_dir/partial.json"
cp "$test_dir/partial.json" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回から 61 分たっても返っていない役がいます\n- demo-qa-test: running'
echo 'PASS status: 返した役の失敗を除き、未返答の役だけを記録'

jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg b "$b" --arg time "$after" '. + [
	$comment[0] + {id: "added-2", author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"},
	$comment[0] + {id: "added-3", author_type: "agent", author_id: $b, created_at: $time, content: "/note\nqa result"}
]' "$test_dir/comments.json" >"$test_dir/returned.json"
cp "$test_dir/returned.json" "$test_dir/comments.json"
check_status $'返事の待ち: 返事がそろっていて、まだ次へ回していない'
check_status $'返事の待ち: 返事がそろっていて、まだ次へ回していない' --timeout
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg time "$after" '. + [$comment[0] + {id: "added-4", author_type: "agent", author_id: "orchestrator", created_at: $time, content: "返事がそろいました。"}]' \
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
 $comment[0] + {id: "added-5", author_type:"agent", author_id:$a, created_at:$time, content:"result"},
 $comment[0] + {id: "added-6", author_type:"agent", author_id:$b, created_at:$time, content:"result"},
 $comment[0] + {id: "added-7", author_type:"agent", author_id:"orchestrator", created_at:$time, content:"返事がそろいました。"}]' \
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

# 決める記録のある回の判定。回は 2 役とも返し済み。記録は回の 90 秒後で、今の 30 秒前。
round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
both='result:a:r1:5 result:b:r2:6'
printf '[]' >"$test_dir/runs.json"
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: スクリプトが次の依頼を決めている'
REVIEW_WAIT_TEST_NOW=$((now + 869)) check_status $'/note\n返事の待ち: スクリプトが次の依頼を決めている'
REVIEW_WAIT_TEST_NOW=$((now + 870)) check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
REVIEW_WAIT_DECIDE_MINUTES=1 REVIEW_WAIT_TEST_NOW=$((now + 29)) check_status $'/note\n返事の待ち: スクリプトが次の依頼を決めている'
REVIEW_WAIT_DECIDE_MINUTES=1 REVIEW_WAIT_TEST_NOW=$((now + 30)) check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
[[ ! -s $test_dir/posted.jsonl && $(list_count) == 5 ]]
echo 'PASS status: 決める記録から 15 分たつまでは待ち、15 分で拾い直しに回す（分は REVIEW_WAIT_DECIDE_MINUTES）'

# 決める記録が複数あっても、いちばん新しい記録でなく、いちばん早い記録の時刻で測る。
reset_calls
build_comments $both decide:b:d2:100 decide:a:d1:60 >"$test_dir/comments.json"
REVIEW_WAIT_TEST_NOW=$((now + 839)) check_status $'/note\n返事の待ち: スクリプトが次の依頼を決めている'
REVIEW_WAIT_TEST_NOW=$((now + 840)) check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
echo 'PASS status: 決める記録が複数あれば、いちばん早い記録の時刻で測る'

# 決める記録がなければ、そろっていてもこれまでどおり拾い直しに回す。
reset_calls
build_comments $both >"$test_dir/comments.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
echo 'PASS status: 決める記録がなければ、そろった回は拾い直しに回す'

# `前の回:` で回を指すコメント（次の依頼）か次へ回す記録があれば、決める記録の経過によらず次へ回し済み。
for later in next:orch:n1:95 claim:orch:c1:95; do
	reset_calls
	build_comments $both decide:a:d1:90 "$later" >"$test_dir/comments.json"
	check_status $'/note\n返事の待ち: 次へ回し済みなので何もしない'
	REVIEW_WAIT_TEST_NOW=$((now + 870)) check_status $'/note\n返事の待ち: 次へ回し済みなので何もしない'
done
reset_calls
build_comments $both next:orch:n1:95 >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 次へ回し済みなので何もしない'
echo 'PASS status: 前の回で回を指すコメントがあれば、次へ回し済み'

# 別の回を指す `前の回:` は、この回の次へ回し済みにしない。
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.json"
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg time "$(jq -nr --argjson ts "$((round_ts + 95))" '$ts | todateiso8601')" \
	'. + [$comment[0] + {id: "n9", author_type: "agent", author_id: "orchestrator", created_at: $time, content: "次の依頼です。\n前の回: other-round"}]' \
	"$test_dir/comments.json" >"$test_dir/comments.tmp"
mv "$test_dir/comments.tmp" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: スクリプトが次の依頼を決めている'
echo 'PASS status: 別の回を指す前の回では、この回を次へ回し済みにしない'

# 返っていない役がいるときは、決める記録があっても待ちの判定は変えない（実行の状態で決める）。
reset_calls
build_comments result:a:r1:5 decide:a:d1:90 >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 返っていない役がいれば、決める記録があっても実行の状態で判定する'

# 制御記録でない `前の回:` は、次へ回し済みにしない。引用、役の結果、人間のコメント、種類の行のないコメントは、
# 決める記録から 15 分たったあとも拾い直しに回す。
noise=(
	"nq orchestrator agent 95 $(printf '> 修正の依頼: 直してください\n> 前の回: round')"
	"nr $a agent 95 $(printf '/note\n返事の回: round\n修正の依頼: 直してください\n前の回: round')"
	"nh human-1 member 95 $(printf '修正の依頼: 直してください\n前の回: round')"
	"nb orchestrator agent 95 $(printf '次の依頼です\n前の回: round')"
	"nf orchestrator agent 95 $(printf '```\n修正の依頼: 直してください\n前の回: round\n```')"
	"nf4 orchestrator agent 95 $(printf '````\n```\n修正の依頼: 直してください\n前の回: round\n```\n````')"
	"nc4 orchestrator agent 95 $(printf '````\n```\n返事の待ち: この回を次へ回します\n```\n````')"
	"ni4 orchestrator agent 95 $(printf '```\n    ```\n修正の依頼: 直してください\n前の回: round\n```')"
	"nd4 orchestrator agent 95 $(printf '````\n    ````\n返事の待ち: この回を次へ回します\n````')"
)
for spec in "${noise[@]}"; do
	read -r id who type sec content <<<"${spec%%$'\n'*}"
	body=${spec#"$id $who $type $sec "}
	reset_calls
	build_comments $both decide:a:d1:90 | with_raw "$id" "$who" "$type" "$sec" "$body" >"$test_dir/comments.json"
	REVIEW_WAIT_TEST_NOW=$((now + 870)) check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
done
echo 'PASS status: 引用・結果・人間・種類のない前の回: だけでは、次へ回し済みにしない'

# 返事を待つ役の行を引用したコメントや、作者がリーダーでも決める実行の役でもない回の形のコメントは、最新の回にしない。
reset_calls
build_comments $both decide:a:d1:90 \
	| with_raw q1 orchestrator agent 100 "$(printf '> 返事を待つ役: [@review](mention://agent/%s)' "$a")" \
	| with_raw q2 "$a" agent 101 "$(printf '返事を待つ役: [@review](mention://agent/%s)\n観点: qa（テスト）' "$a")" \
	| with_raw q3 human-1 member 102 "$(printf '返事を待つ役: [@review](mention://agent/%s)' "$a")" >"$test_dir/comments.json"
REVIEW_WAIT_TEST_NOW=$((now + 870)) check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
echo 'PASS status: 引用や作者の違う回の形のコメントを、最新の回として読まない'

# 返事を待つ役でない役の決める記録は、15 分の判定に使わない。記録がないのと同じに、すぐ拾い直しに回す。
reset_calls
build_comments $both decide:orch:d1:100 >"$test_dir/comments.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
echo 'PASS status: 返事を待つ役でない役の決める記録を、15 分の判定に使わない'
