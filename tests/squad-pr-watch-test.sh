#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

script="$root/common/monitor/squad-pr-watch"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-watch-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export PR_WATCH_TEST_DIR="$test_dir"
mkdir -p "$test_dir/bin"
export PATH="$test_dir/bin:$PATH"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
if [[ -f $dir/fail && "$1 $2 $3" == "$(<"$dir/fail")" ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
case "$1 $2 $3" in
'issue get test-issue') cat "$dir/task.json" ;;
'agent list --output') cat "$dir/agents.json" ;;
"agent get $3") jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" ;;
'issue runs test-issue') cat "$dir/runs.json" ;;
'issue wakeup list') cat "$dir/rules.json" ;;
'issue wakeup delete') echo '{}' ;;
'issue wakeup create')
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--instruction-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args:$args, body:.}' <"$file" >>"$dir/wakeups.jsonl"
	echo '{}'
	;;
'issue comment list')
	thread=''
	compact=false
	while (($#)); do
		if [[ $1 == --thread ]]; then thread=$2; fi
		if [[ $1 == --compact ]]; then compact=true; fi
		shift
	done
	jq --arg thread "$thread" --argjson compact "$compact" '[.[]
		| select($thread == "" or (.test_thread // "ci-thread") == $thread)
		| if $compact then del(.source_task_id) else . end]' "$dir/comments.json"
	;;
'issue comment add')
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	parent=$(jq -r 'index("--parent") as $i | if $i == null then "" else .[$i+1] end' <<<"$args")
	if [[ $parent != "$(<"$dir/allowed-parent")" ]]; then
		echo "mock reply-scope rejection: parent=$parent" >&2
		exit 1
	fi
	while (($#)); do
		if [[ $1 == --content-file ]]; then
			jq -Rs --argjson args "$args" '{args: $args, body: .}' <"$2" >>"$dir/posted.jsonl"
			jq --rawfile body "$2" --arg parent "$parent" '. + [{author_type: "agent", content: $body, test_thread: $parent}]' "$dir/comments.json" >"$dir/updated.json"
			mv "$dir/updated.json" "$dir/comments.json"
			echo '{}'
			exit 0
		fi
		shift
	done
	exit 1
	;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'pr view test-pr' ]] || exit 1
cat "$PR_WATCH_TEST_DIR/pr.json"
EOF
chmod +x "$test_dir/bin/multica" "$test_dir/bin/gh"

cat >"$test_dir/agents.json" <<'EOF'
[
  {"id": "orchestrator", "name": "demo-orchestrator-test"},
  {"id": "monitor", "name": "demo-ci-monitor-test"},
  {"id": "fixer", "name": "demo-codex-fixer-test"},
  {"id": "implementer", "name": "demo-codex-implementer-test"}
]
EOF

reset_fixture() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/wakeups.jsonl"
	printf '[]' >"$test_dir/rules.json"
	printf '[]' >"$test_dir/comments.json"
	printf '[]' >"$test_dir/runs.json"
	printf 'ci-thread' >"$test_dir/allowed-parent"
	printf '%s\n' '{"status_category":"in_progress","assignee_type":"squad","assignee_id":"test-squad","metadata":{"pr_url":"test-pr","ci_watch_thread":"ci-thread"}}' >"$test_dir/task.json"
	cat >"$test_dir/pr.json" <<'EOF'
{
  "state": "OPEN", "headRefOid": "abcdef0123456789",
  "statusCheckRollup": [
    {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE", "workflowName": "CI", "name": "test"},
    {"__typename": "StatusContext", "state": "ERROR", "context": "external"},
    {"__typename": "CheckRun", "status": "IN_PROGRESS", "name": "lint"},
    {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED", "name": "cancelled"}
  ]
}
EOF
}

check_output() {
	local expected=$1 output
	shift
	output=$(cd "$test_dir" && bash "$script" "$@")
	[[ $output == "$expected" ]] || {
		printf '期待した出力:\n%s\n実際の出力:\n%s\n' "$expected" "$output" >&2
		exit 1
	}
}

assert_jq() { jq -e "$@" >/dev/null; }
check_ci() {
	printf 'ci-thread' >"$test_dir/allowed-parent"
	check_output "$1" ci-check test-issue orchestrator monitor
}
check_held() {
	printf '%s' "${2:-handoff-comment}" >"$test_dir/allowed-parent"
	check_output "$1" ci-held test-issue "${2:-handoff-comment}"
}
hold_fixture() {
	jq -n --arg content $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）\n' \
		'[{author_type: "agent", content: $content}]' >"$test_dir/comments.json"
}

# 終わっていない実行は、実行中以外の状態でも保留する。
for status in running queued dispatched waiting_local_directory; do
	reset_fixture
	jq -n --arg status "$status" '[{agent_id: "fixer", status: $status}]' >"$test_dir/runs.json"
	check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-check: ほかの役の終わっていない実行は、メンションせず保留を出す'

reset_fixture
printf '%s\n' '[{"agent_id":"implementer","status":"running"},{"agent_id":"fixer","status":"queued"},{"agent_id":"fixer","status":"running"}]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test、demo-codex-implementer-test の作業中なので保留）'
echo 'PASS ci-check: 複数の役の名前を ID から引き、同じ役は重複しない'

# orchestrator と見張り役自身、および終了した役は通知を妨げない。
for status in none completed failed cancelled; do
	reset_fixture
	jq -n --arg status "$status" '[{agent_id: "orchestrator", status: "running"}, {agent_id: "monitor", status: "running"}]
		+ if $status == "none" then [] else [{agent_id: "fixer", status: $status}] end' >"$test_dir/runs.json"
	check_ci $'/note\nCI abcdef0: 失敗を進行役に知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\nCI の失敗を検出しました。\n"))
		and (.[0].body | contains("[@demo-orchestrator-test](mention://agent/orchestrator)"))
		and (.[0].body | contains("- CI / test\n- external\n"))
		and (.[0].body | contains("cancelled") | not)
		and (.[0].args | index("--parent") as $i | .[$i+1] == "ci-thread")' "$test_dir/posted.jsonl"
	check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
	check_held ''
	assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
done
echo 'PASS ci-check: ほかの役の実行がなければ一度だけ知らせ、知らせ済みなら ci-held も出さない'

reset_fixture
hold_fixture
check_held $'CI / test\nexternal'
check_held '' next-handoff
check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
assert_jq -s 'length == 1 and .[0].body == "/note\nCI abcdef0: 保留した失敗を進行役が引き継ぎで受けた\n"
	and (.[0].args | index("--parent") as $i | .[$i+1] == "handoff-comment")' "$test_dir/posted.jsonl"
echo 'PASS ci-held: 許可された起点へ無通知で記録し、別スレッドの次の取得と見張りでも重複しない'

# 保留の判定後、最終投稿前に引き継ぎが届く順序を再現する。
# 引き継いだ役の run がまだ running でも、保留記録なしで失敗を拾う。
reset_fixture
printf '%s\n' '[{"agent_id":"fixer","status":"running"}]' >"$test_dir/runs.json"
late_hold=$(cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor)
[[ $late_hold == $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）' ]]
check_held $'CI / test\nexternal'
jq --arg body "$late_hold" '. + [{author_type: "agent", content: $body, test_thread: "ci-thread"}]' \
	"$test_dir/comments.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/comments.json"
check_held '' next-handoff
printf '[]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
assert_jq -s 'length == 1 and (.[0].body | startswith("/note\n"))' "$test_dir/posted.jsonl"
echo 'PASS 投稿順序: 保留の最終投稿より先に取得しても失敗を拾い、遅れた保留で再通知しない'

# 引き継ぎ時はまだ CI が実行中で、その直後に失敗が確定する順序。
# run の終了前でも、起点の run と対応する引き継ぎがあれば通常の通知に進む。
for handoff in mention squad-mention review-report; do
	reset_fixture
	printf '%s\n' '[{"id":"fixer-run","agent_id":"fixer","status":"running"}]' >"$test_dir/runs.json"
	printf '%s\n' '[{"author_type":"agent","author_id":"fixer","source_task_id":"fixer-run","content":"[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます","test_thread":"handoff-thread"}]' >"$test_dir/comments.json"
	if [[ $handoff == review-report ]]; then
		jq '.[0].content = "/note\n確かめたコミット: abcdef0123456789\nレビュー結果"' \
			"$test_dir/comments.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/comments.json"
	elif [[ $handoff == squad-mention ]]; then
		jq '.[0].content = "[@Demo](mention://squad/test-squad) 引き継ぎます"' \
			"$test_dir/comments.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/comments.json"
	fi
	cp "$test_dir/pr.json" "$test_dir/failed-pr.json"
	jq '.statusCheckRollup = [{"__typename":"CheckRun","status":"IN_PROGRESS","name":"test"}]' \
		"$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	check_held ''
	mv "$test_dir/failed-pr.json" "$test_dir/pr.json"
	check_ci $'/note\nCI abcdef0: 失敗を進行役に知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\n"))' "$test_dir/posted.jsonl"
	check_held ''
done
echo 'PASS 引き継ぎ後の失敗: 取得時に未確定でも、引き継ぎ（スクワッドかエージェントのメンション）・レビュー報告後の run の終了前に通常の通知で拾う'

for fixture in old-run other-author no-mention new-run other-squad; do
	reset_fixture
	printf '%s\n' '[{"id":"fixer-run","agent_id":"fixer","status":"running"}]' >"$test_dir/runs.json"
	jq -n --arg fixture "$fixture" '[{author_type: "agent", author_id: "fixer",
		source_task_id: "fixer-run", content: "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます"}]
		| if $fixture == "old-run" then .[0].source_task_id = "old-fixer-run"
		  elif $fixture == "other-author" then .[0].author_id = "implementer"
		  elif $fixture == "no-mention" then .[0].content = "/note\n途中の記録"
		  elif $fixture == "other-squad" then .[0].content = "[@Demo](mention://squad/other-squad) 引き継ぎます" else . end' >"$test_dir/comments.json"
	if [[ $fixture == new-run ]]; then
		jq '. + [{id: "new-fixer-run", agent_id: "fixer", status: "running"}]' \
			"$test_dir/runs.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/runs.json"
	fi
	check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS 引き継ぎの対応: 別の run・別の作者・別のスクワッド・途中の記録では作業中の保留を解除しない'

# 古い head の取得記録では、今の head の失敗を抑止しない。
reset_fixture
hold_fixture
check_held $'CI / test\nexternal'
jq '.headRefOid = "123456789abcdef0"' "$test_dir/pr.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/pr.json"
check_held $'CI / test\nexternal' next-handoff
check_held '' third-handoff
assert_jq -s 'length == 2 and (.[1].body | contains("CI 1234567:"))' "$test_dir/posted.jsonl"
echo 'PASS ci-held: 古い head の取得記録があっても今の head の失敗は取得する'

for fixture in notified success pending cancelled no-checks merged closed done no-thread; do
	reset_fixture
	hold_fixture
	case $fixture in
	notified) jq '. + [{author_type: "agent", content: "head: abcdef0\nCI の失敗を検出しました。\n"}]' "$test_dir/comments.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/comments.json" ;;
	success | pending | cancelled | no-checks)
		case $fixture in
		success) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
		pending) checks='[{"__typename":"StatusContext","state":"PENDING","context":"external"}]' ;;
		cancelled) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]' ;;
		no-checks) checks='[]' ;;
		esac
		jq --argjson checks "$checks" '.statusCheckRollup = $checks' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json"
		;;
	merged | closed) jq --arg state "$(printf '%s' "$fixture" | tr '[:lower:]' '[:upper:]')" '.state = $state' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	done) jq '.status_category = "done"' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	no-thread) jq 'del(.metadata.ci_watch_thread)' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	esac
	check_held ''
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-held: 知らせ済み・失敗なし・終了済みでは何も出さない'

# CLI の失敗で通知したり、引き継ぎを受けたと答えたりしない。
for operation in runs held; do
	reset_fixture
	if [[ $operation == runs ]]; then
		printf 'issue runs test-issue' >"$test_dir/fail"
		args=(ci-check test-issue orchestrator monitor)
	else
		hold_fixture
		printf 'issue comment add' >"$test_dir/fail"
		printf 'handoff-comment' >"$test_dir/allowed-parent"
		args=(ci-held test-issue handoff-comment)
	fi
	if (cd "$test_dir" && bash "$script" "${args[@]}") >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ $(<"$test_dir/error") == 'CLI mock failure' && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl ]]
	rm "$test_dir/fail"
	if [[ $operation == held ]]; then check_held $'CI / test\nexternal'; fi
done
echo 'PASS CLI 失敗: エラーを返し、受けた記録を書けなかった保留は再取得できる'

# 名前の置換で役を推測せず、引数の ID を規則にそのまま渡す。
reset_fixture
(cd "$test_dir" && bash "$script" ci test-issue monitor trigger-comment) >"$test_dir/output"
assert_jq -s 'length == 1 and (.[0].args | index("--agent-id") as $i | .[$i+1] == "monitor")
	and (.[0].body | contains("squad-pr-watch ci-check"))' "$test_dir/wakeups.jsonl"
assert_jq -s 'all(.[]; .[0:2] != ["agent", "list"])' "$test_dir/calls.jsonl"
reset_fixture
(cd "$test_dir" && bash "$script" conflicts test-issue) >"$test_dir/output"
assert_jq -s 'length == 1 and (.[0].body | contains("進行役の「実装・修正の振り分け」に従い、有効な修正の役を選んでください"))
	and (.[0].body | contains("squad-dispatch-pick") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS 登録: 見張り役 ID を渡し、コンフリクト通知は進行役の振り分けを参照する'

# 通知の参照先を実際に展開した進行役からたどり、残る系統の修正役だけへ進める。
source "$root/lib/render.sh"
section=$(jq -sr '.[0].body | capture("進行役の「(?<section>[^」]+)」").section' "$test_dir/wakeups.jsonl")
for family in claude codex; do
	enabled="orchestrator $family-implementer $family-fixer"
	template_filter "$enabled" "$root/common/agents/orchestrator.md" >"$test_dir/orchestrator-filtered"
	jq -n --arg family "$family" '{project_key:"demo", member_key:"member-a", project_name:"Demo",
		project_id:"project-a", repository:"example/project", repositories:"`example/project`、`example/client`", squad_id:"squad-a",
		squad_mention:"[@Squad](mention://squad/squad-a)", owner_mention:"[@Owner](mention://member/member-a)"}
		+ (reduce ["orchestrator", ($family+"-implementer"), ($family+"-fixer")][] as $role ({};
			. + {("agent."+$role+".id"): ("agent-"+$role),
				("agent."+$role+".name"): ("demo-"+$role+"-member-a"),
				("agent."+$role+".mention"): ("[@Role](mention://agent/agent-"+$role+")")}))' >"$test_dir/template-values.json"
	template_apply "$test_dir/template-values.json" "$test_dir/orchestrator-filtered" >"$test_dir/orchestrator"
	awk -v heading="## $section" '$0==heading {inside=1; next} inside && /^## / {exit} inside {print}' \
		"$test_dir/orchestrator" >"$test_dir/dispatch-instructions"
	grep -qF 'squad-usage-read' "$test_dir/dispatch-instructions"
	grep -qF '80%' "$test_dir/dispatch-instructions"
	grep -qF 'それ以外はこの系統の対応する実装・修正の役へ回す' "$test_dir/dispatch-instructions"
	grep -qF '読めなければこの系統に固定して選んだことと理由を書く' "$test_dir/dispatch-instructions"
	# 両系統用の選択コマンドも、外した系統の役も残らない。
	if grep -qF 'squad-dispatch-pick' "$test_dir/dispatch-instructions"; then exit 1; fi
	fixers=$(awk '/^- `[^`]+-fixer`:/ {print}' "$test_dir/dispatch-instructions")
	[[ $fixers == "- \`$family-fixer\`: [@Role](mention://agent/agent-$family-fixer)" ]]
	other=codex
	[[ $family != codex ]] || other=claude
	if grep -qF "$other-fixer" "$test_dir/orchestrator"; then exit 1; fi
	echo "PASS conflicts: $family のみでは通知から単一系統の使用率判定と有効な修正役へたどれる"
done
