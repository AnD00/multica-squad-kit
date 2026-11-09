#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-test.sh で実行する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

script="$root/common/monitor/squad-review-wait"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/review-wait-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export REVIEW_WAIT_TEST_DIR="$test_dir"
export REVIEW_WAIT_LIMIT_MINUTES=60
mkdir -p "$test_dir/bin"
export PATH="$test_dir/bin:$PATH"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_WAIT_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
if [[ -f $dir/fail && "$1 $2 $3" == "$(<"$dir/fail")" ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
case "$1 $2 $3" in
'agent list --output') cat "$dir/agents.json" ;;
"agent get $3") jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" ;;
'issue comment list')
	# 読み直しごとに別の中身を返せるよう、n 回目の呼び出しには comments.<n>.json があればそれを返す。
	n=$(($(<"$dir/list-count") + 1))
	echo "$n" >"$dir/list-count"
	if [[ -f $dir/fail-list-at && $n == "$(<"$dir/fail-list-at")" ]]; then
		echo 'CLI mock comment list failure' >&2
		exit 1
	fi
	if [[ -f $dir/comments.$n.json ]]; then cat "$dir/comments.$n.json"; else cat "$dir/comments.json"; fi
	;;
'issue comment add')
	n=$(($(jq -s length "$dir/posted.jsonl") + 1))
	if [[ -f $dir/fail-add-at && $n == "$(<"$dir/fail-add-at")" ]]; then
		echo 'CLI mock comment add failure' >&2
		exit 1
	fi
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--content-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args: $args, body: .}' <"$file" >>"$dir/posted.jsonl"
	echo "{\"id\": \"posted-$n\"}"
	;;
'issue runs test-issue') cat "$dir/runs.json" ;;
'issue wakeup list') cat "$dir/rules.json" ;;
'issue wakeup delete') echo '{}' ;;
'issue wakeup create')
	while (($#)); do
		if [[ $1 == --instruction-file ]]; then
			jq -Rs --arg path "$2" '{path: $path, instruction: .}' <"$2" >>"$dir/instructions.jsonl"
			break
		fi
		shift
	done
	echo '{}'
	;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

# report と proceed の待ちは、実際には待たずに秒数だけ記録する。
cat >"$test_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$REVIEW_WAIT_TEST_DIR/sleeps.log"
EOF
chmod +x "$test_dir/bin/sleep"
export REVIEW_WAIT_RECHECK_SECONDS=20

# status の時計を固定し、登録と依頼コメントの数秒差も再現する。
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $# == 1 && $1 == +%s ]] || exit 1
printf '%s\n' "$REVIEW_WAIT_TEST_NOW"
EOF
chmod +x "$test_dir/bin/date"
export REVIEW_WAIT_TEST_NOW=1792947600

a=agent-a
b=agent-b
mark='レビューと E2E の返事の待ちの見張りで起きました。'
jq -n --arg a "$a" --arg b "$b" '[
	{id: $a, name: "demo-code-reviewer-test", archived_at: null},
	{id: $b, name: "demo-qa-test", archived_at: null},
	{id: "archived", name: "demo-qa-test", archived_at: "2026-01-01T00:00:00Z"}
]' >"$test_dir/agents.json"
jq -n --arg mark "$mark" '[
	{id: "old-active", enabled: true, instruction: ($mark + "\nold round")},
	{id: "old-disabled", enabled: false, instruction: $mark},
	{id: "ci", instruction: "PR の CI が終わりました。"},
	{id: "conflicts", instruction: "PR のコンフリクトの見張りで起きました。"},
	{id: "other", instruction: null}
]' >"$test_dir/rules.json"

reset_calls() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/instructions.jsonl"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/sleeps.log"
	echo 0 >"$test_dir/list-count"
	rm -f "$test_dir"/comments.[0-9]*.json
	rm -f "$test_dir/fail-list-at" "$test_dir/fail-add-at"
}

assert_jq() {
	jq -e "$@" >/dev/null
}

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

now=$(date +%s)
round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601 | sub("Z$"; ".500Z")')

round_comments() {
	jq -n --arg a "$a" --arg b "$b" --arg time "$round_time" '[{
		id: "round", author_type: "agent", author_id: "orchestrator", created_at: $time,
		content: ("返事を待つ役: [@review](mention://agent/" + $a + ") [@qa](mention://agent/" + $b + ")")
	}]' >"$test_dir/comments.json"
}

run_fixture() {
	local agent=$1 state=$2 ts=$3 error=${4:-}
	jq -n --arg agent "$agent" --arg state "$state" --argjson ts "$ts" --arg error "$error" \
		'{agent_id: $agent, status: $state, created_at: ($ts | todateiso8601), error: $error}'
}

check_status() {
	local expected=$1 output
	shift
	output=$(bash "$script" status test-issue "$@")
	[[ $output == "$expected" ]] || {
		printf '期待した出力:\n%s\n実際の出力:\n%s\n' "$expected" "$output" >&2
		exit 1
	}
}

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
jq --arg a "$a" --arg time "$after" '. + [
	{author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"}
]' "$test_dir/comments.json" >"$test_dir/partial.json"
cp "$test_dir/partial.json" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回から 61 分たっても返っていない役がいます\n- demo-qa-test: running'
echo 'PASS status: 返した役の失敗を除き、未返答の役だけを記録'

jq --arg a "$a" --arg b "$b" --arg time "$after" '. + [
	{author_type: "agent", author_id: $a, created_at: $time, content: "/note\nreview result"},
	{author_type: "agent", author_id: $b, created_at: $time, content: "/note\nqa result"}
]' "$test_dir/comments.json" >"$test_dir/returned.json"
cp "$test_dir/returned.json" "$test_dir/comments.json"
check_status $'返事の待ち: 知らせのないまま返事がそろっている'
check_status $'返事の待ち: 知らせのないまま返事がそろっている' --timeout
round_comments
jq --arg time "$after" '. + [{author_type: "agent", author_id: "orchestrator", created_at: $time, content: "返事がそろいました。"}]' \
	"$test_dir/comments.json" >"$test_dir/ready.json"
cp "$test_dir/ready.json" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: 返事がそろっているので何もしない'
echo 'PASS status: 全員が返して知らせがなければ拾い直す。知らせがあれば何もしない'

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

jq --arg time "$(jq -nr --argjson ts "$((round_ts + 2))" '$ts | todateiso8601')" '. + [{author_type: "agent", author_id: "orchestrator", created_at: $time, content: "返事がそろいました。"}]' \
	"$test_dir/comments.json" >"$test_dir/ready.json"
cp "$test_dir/ready.json" "$test_dir/comments.json"
check_status $'/note\n返事の待ち: 返事がそろっているので何もしない' --timeout
printf '[]' >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 回がないので何もしない' --timeout
echo 'PASS status: 上限用の起床でもそろった回・回なしでは何もしない'

round_comments
printf 'issue runs test-issue' >"$test_dir/fail"
if bash "$script" status test-issue >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock failure' && ! -s $test_dir/output ]]
rm "$test_dir/fail"
echo 'PASS status: CLI 失敗では誤った判定を出さずエラー'

# ここから report と proceed。回は 2 役（a, b）を待つ。
round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')

# 回に、返事（result: /note 付き、plain-result: ふつう）、そろった知らせ（ready）、次へ回す記録（claim）を足したコメントの一覧を出す。
# 引数は「種類:役:ID:回からの秒」。役は a、b、orch。
build_comments() {
	local spec kind who id sec content out
	round_comments
	out=$(<"$test_dir/comments.json")
	for spec in "$@"; do
		IFS=: read -r kind who id sec <<<"$spec"
		case $who in a) who=$a ;; b) who=$b ;; orch) who=orchestrator ;; esac
		case $kind in
		result) content=$'/note\nresult' ;;
		plain-result) content='result' ;;
		ready) content='返事がそろいました。' ;;
		claim) content=$'/note\n返事の待ち: この回を次へ回します' ;;
		esac
		out=$(jq --arg who "$who" --arg id "$id" --arg content "$content" \
			--arg time "$(jq -nr --argjson ts "$((round_ts + sec))" '$ts | todateiso8601')" \
			'. + [{id: $id, author_type: "agent", author_id: $who, created_at: $time, content: $content}]' <<<"$out")
	done
	printf '%s\n' "$out"
}

posted_claim_count() {
	jq -s '[.[] | select(.body == "/note\n返事の待ち: この回を次へ回します\n")] | length' "$test_dir/posted.jsonl"
}
posted_ready_count() {
	jq -s '[.[] | select(.body | contains("返事がそろいました"))] | length' "$test_dir/posted.jsonl"
}
list_count() { cat "$test_dir/list-count"; }
slept() { paste -sd, "$test_dir/sleeps.log"; }
deleted_rules() {
	jq -s '[.[] | select(.[0:3] == ["issue", "wakeup", "delete"])] | length' "$test_dir/calls.jsonl"
}

printf '/note\nqa result\n' >"$test_dir/result.md"

# /note 付きとふつうのコメントで返した 2 役がそろい、知らせがない回を拾い直す。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.json"
printf '[]' >"$test_dir/runs.json"
check_status '返事の待ち: 知らせのないまま返事がそろっている'
[[ ! -s $test_dir/posted.jsonl ]]
echo 'PASS status: /note 付きとふつうのコメントで返した回も、知らせがなければ拾い直す'

# 同じ状態で proceed を流すと、拾い直しの知らせと次へ回す記録を 1 つずつ書いて進む。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 plain-result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue r2)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 1 && $(posted_claim_count) == 1 ]]
assert_jq -s 'length == 2 and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n"))' "$test_dir/posted.jsonl"
echo 'PASS proceed: /note 付きとふつうのコメントの回を拾い直し、知らせを 1 つ書いて次に進む'

# 同じ秒に始まる形: 2 役が回と同じ秒に始まり、返した役のほかに失敗した役がいる。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
for state in failed cancelled; do
	{
		run_fixture "$a" completed "$round_ts"
		run_fixture "$b" "$state" "$round_ts" '利用上限'
	} | jq -s 'map(. + {trigger_comment_id: "round"})' >"$test_dir/runs.json"
	check_status "返事の待ち: 人間を呼ぶ"$'\n'"- demo-qa-test: ${state}（利用上限）"
done
echo 'PASS status: 同じ秒に始まった 2 役のうち、返した役を除いて失敗・取り消しの役だけを人間へ'

# 返した役がいても、同じ秒の前の回の失敗では人間を呼ばない。
{
	run_fixture "$a" completed "$round_ts" | jq '. + {trigger_comment_id: "round"}'
	run_fixture "$b" failed "$round_ts" | jq '. + {trigger_comment_id: "previous-round"}'
} | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 同じ秒に始まった役が返し済みでも、前の回の失敗を除外'

# すぐの読み直しでそろったときは、待たずに知らせを書く。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 1 && -z $(slept) ]]
assert_jq -s 'length == 2 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
assert_jq -s '.[1].body | startswith("[@orchestrator](mention://agent/orchestrator) 返事がそろいました。\n\n")' "$test_dir/posted.jsonl"
assert_jq -s 'all(.[]; .args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
echo 'PASS report: すぐの読み直しでそろえば、待たずに知らせを書く'

# すぐの読み直しで相手が見えず、待ってからの読み直しで見えたときは、知らせが 1 つ出る。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 >"$test_dir/comments.2.json"
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 1 && $(slept) == 20 && $(list_count) == 3 ]]
echo 'PASS report: 待ってからの読み直しで相手が見えれば、知らせを 1 つ書く'

# 待っても返していない役がいれば、知らせを書かず、読み直しは 1 回だけ。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(slept) == 20 && $(list_count) == 3 ]]
echo 'PASS report: 待っても返していない役がいれば知らせを書かず、読み直しは 1 回だけ'

# 待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う。
reset_calls
REVIEW_WAIT_RECHECK_SECONDS=7 bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 7 ]]
echo 'PASS report: 待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う'

# すでに知らせがあれば、書かず、待たない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(slept) ]]
echo 'PASS report: 知らせがすでにあれば書かない'

# 回がなければ投稿せずエラー。
reset_calls
printf '[]' >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/posted.jsonl && -z $(slept) ]]
echo 'PASS report: 回がなければ投稿しない'

# 結果投稿後の失敗は、未返答とは区別して返す。結果は再投稿しない。
# 2 回目の取得は結果投稿の直後、3 回目は待ってからの読み直し。
for read_at in 2 3; do
	for failure in cli json round; do
		reset_calls
		build_comments result:a:r1:5 >"$test_dir/comments.json"
		case $failure in
		cli) echo "$read_at" >"$test_dir/fail-list-at" ;;
		json) printf 'invalid json' >"$test_dir/comments.$read_at.json" ;;
		round) jq '.[0].content = null' "$test_dir/comments.json" >"$test_dir/comments.$read_at.json" ;;
		esac
		if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
		[[ -s $test_dir/error && ! -s $test_dir/output && $(list_count) == "$read_at" ]]
		if [[ $failure == cli ]]; then [[ $(<"$test_dir/error") == 'CLI mock comment list failure' ]]; fi
		assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
		if [[ $read_at == 2 ]]; then [[ -z $(slept) ]]; else [[ $(slept) == 20 ]]; fi
		echo "PASS report: 読み直し ${read_at} 回目の ${failure} 失敗を返し、結果を再投稿しない"
	done

	reset_calls
	if [[ $read_at == 3 ]]; then
		build_comments result:a:r1:5 >"$test_dir/comments.2.json"
	fi
	build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
	echo 2 >"$test_dir/fail-add-at"
	if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(list_count) == "$read_at" ]]
	assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
	assert_jq -s '[.[] | select(.[0:3] == ["issue", "comment", "add"])] | length == 2' "$test_dir/calls.jsonl"
	if [[ $read_at == 2 ]]; then [[ -z $(slept) ]]; else [[ $(slept) == 20 ]]; fi
	echo "PASS report: 読み直し ${read_at} 回目の知らせ投稿の失敗を返し、再投稿しない"
done

# proceed: 知らせがなければ、拾い直しの知らせと記録を書き、いちばん早い記録なので進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == '返事の待ち: 次に進む' && $(slept) == 20 && $(deleted_rules) == 2 ]]
assert_jq -s 'length == 2 and all(.[]; .args | index("--parent") as $i | .[$i+1] == "watch-trigger")
	and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n\n待っていた役の結果が、すべてそろいました。\n\n返した役:\n"))
	and (.[0].body | contains("mention://") | not)
	and .[1].body == "/note\n返事の待ち: この回を次へ回します\n"' "$test_dir/posted.jsonl"
echo 'PASS proceed: 知らせがなければ拾い直しの知らせと記録を書き、見張りを消して次に進む'

# proceed: 知らせで起きた実行は、記録だけを書いて進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 0 && $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]]
echo 'PASS proceed: 知らせで起きた実行は、記録だけを書いて次に進む'

# proceed: 1 回目は次に進み、記録が残った 2 回目は書かず、待たずに回ごと済み。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が残った回では、書かずに回ごと済み'

# proceed: 2 つの実行がほぼ同時に記録を書いたら、進むのは早い記録の実行だけ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:c0:8 claim:orch:posted-1:9 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が重なったら、早い記録の実行だけが進む'

# proceed: 同じ時刻の記録は ID の順で選ぶ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:zz:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == '返事の待ち: 次に進む' ]]
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:a0:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == $'/note\n返事の待ち: 回ごと済み' ]]
echo 'PASS proceed: 同じ時刻の記録は ID の順'

# proceed: 書いた記録が読み直しで見えなければ、リーダーを再度起こす。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: リーダーを再度起こす' && $(posted_claim_count) == 1 && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が読み直しで見えなければ、リーダーを再度起こす'

# proceed: 返していない役がいる回と、回がないときは何もしない。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 返っていない役がいるので何もしない' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]]
printf '[]' >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 回がないので何もしない' && -z $(slept) ]]
echo 'PASS proceed: 返していない役がいる回と回なしでは何もしない'

# proceed: 待つ間に新しい回が書かれたら、前の回の知らせでは進まない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 | jq --arg a "$a" --arg time "$(jq -nr --argjson ts "$((round_ts + 30))" '$ts | todateiso8601')" \
	'. + [{id: "round2", author_type: "agent", author_id: "orchestrator", created_at: $time, content: ("返事を待つ役: [@review](mention://agent/" + $a + ")")}]' >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 新しい回があるので何もしない' && $(deleted_rules) == 0 && $(posted_claim_count) == 1 ]]
echo 'PASS proceed: 待つ間に新しい回が書かれたら何もしない'

# proceed: CLI の失敗では、進むと答えずにエラー。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
printf 'issue wakeup list' >"$test_dir/fail"
if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
rm "$test_dir/fail"
echo 'PASS proceed: CLI 失敗では次に進むと答えずエラー'
