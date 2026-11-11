#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

script="$root/common/monitor/squad-pr-watch"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-watch-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/tests/cli-mode-test-lib.sh"
cli_test_wrap_monitor "$script" "$test_dir"
export PR_WATCH_TEST_DIR="$test_dir"
export PR_WATCH_TEST_ROOT="$root"
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/pr-watch-fixture.py" base "$@"; }
fixture issue-comments agent >"$test_dir/comment-prototype.json"
fixture issue-runs direct >"$test_dir/run-prototype.json"
fixture gh-pr-checks | jq '.statusCheckRollup[0]' >"$test_dir/check-prototype.json"
mkdir -p "$test_dir/bin"
export PATH="$test_dir/bin:$PATH"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
python3 "$PR_WATCH_TEST_ROOT/tests/cli-test-trace.py" "$dir" multica "$@"
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
if [[ -f $dir/fail && "${1-} ${2-} ${3-}" == "$(<"$dir/fail")" ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
emit() { python3 "$PR_WATCH_TEST_ROOT/tests/pr-watch-fixture.py" emit "$@"; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'squad list --output') emit squad-list "$dir/squads.json" ;;
'issue get test-issue') emit issue-get "$dir/task.json" ;;
'agent list --output') cat "$dir/agents.json" ;;
"agent get $3")
 jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
 emit agent-get "$dir/agent-response.json" ;;
'issue runs test-issue') emit issue-runs "$dir/runs.json" ;;
'issue wakeup list') emit issue-wakeups "$dir/rules.json" ;;
'issue wakeup delete') echo '{}' ;;
'issue wakeup create')
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--instruction-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args:$args, body:.}' <"$file" >>"$dir/wakeups.jsonl"
	if [[ -f $dir/wakeup-response.json ]]; then
		emit issue-wakeup-create "$dir/wakeup-response.json"
	else
		emit issue-wakeup-create "$dir/wakeup-prototype.json"
	fi
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
		| del(.test_thread)
		| if $compact then del(.source_task_id) else . end]' "$dir/comments.json" >"$dir/comments-response.json"
	emit issue-comments "$dir/comments-response.json"
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
			jq --slurpfile base "$dir/comment-prototype.json" --rawfile body "$2" --arg parent "$parent" '. + [$base[0] + {author_type: "agent", content: $body, test_thread: $parent}]' "$dir/comments.json" >"$dir/updated.json"
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
python3 "$PR_WATCH_TEST_ROOT/tests/cli-test-trace.py" "$PR_WATCH_TEST_DIR" gh "$@"
if [[ ${1-} == --version ]]; then echo 'gh fixture-version'; exit 0; fi
[[ "${1-} ${2-} ${3-}" == 'pr view test-pr' ]] || exit 1
if [[ -f $PR_WATCH_TEST_DIR/fail-gh ]]; then echo 'gh mock failure' >&2; exit 1; fi
python3 "$PR_WATCH_TEST_ROOT/tests/pr-watch-fixture.py" emit gh-pr-checks "$PR_WATCH_TEST_DIR/pr.json"
EOF
chmod +x "$test_dir/bin/multica" "$test_dir/bin/gh"

fixture agent-get | jq '. as $base | [
 $base + {id:"orchestrator",name:"demo-orchestrator-test"},
 $base + {id:"monitor",name:"demo-ci-monitor-test"},
 $base + {id:"fixer",name:"demo-codex-fixer-test"},
 $base + {id:"implementer",name:"demo-codex-implementer-test"}
]' >"$test_dir/agents.base.json"
fixture issue-wakeup-create >"$test_dir/wakeup-prototype.json"

reset_fixture() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/wakeups.jsonl"
	printf '[]' >"$test_dir/rules.json"
	printf '[]' >"$test_dir/comments.json"
	printf '[]' >"$test_dir/runs.json"
	printf 'ci-thread' >"$test_dir/allowed-parent"
	cp "$test_dir/agents.base.json" "$test_dir/agents.json"
	rm -f "$test_dir/allow-missing-fields" "$test_dir/wakeup-response.json" "$test_dir/fail" "$test_dir/fail-gh"
	fixture squad-list | jq '[. + {id:"test-squad",name:"Demo",leader_id:"orchestrator",archived_at:null}]' >"$test_dir/squads.json"
	fixture issue-get | jq '. + {id:"test-issue",status:"in_progress",status_category:"in_progress",assignee_type:"squad",assignee_id:"test-squad",metadata:{pr_url:"test-pr",ci_watch_thread:"ci-thread"}}' >"$test_dir/task.json"
	fixture gh-pr-checks | jq '. as $pr | .statusCheckRollup[0] as $check |
		$pr + {state:"OPEN",headRefOid:"abcdef0123456789",statusCheckRollup:[
		 $check + {status:"COMPLETED",conclusion:"FAILURE",workflowName:"CI",name:"test"},
		 {__typename:"StatusContext",state:"ERROR",context:"external"},
		 $check + {status:"IN_PROGRESS",conclusion:null,name:"lint"},
		 $check + {status:"COMPLETED",conclusion:"CANCELLED",name:"cancelled"}
		]}' >"$test_dir/pr.json"
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
	jq --slurpfile base "$test_dir/comment-prototype.json" -n --arg content $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）\n' \
		'[$base[0] + {author_type: "agent", content: $content}]' >"$test_dir/comments.json"
}

# 終わっていない実行は、実行中以外の状態でも保留する。
for status in running queued dispatched waiting_local_directory; do
	reset_fixture
	jq --slurpfile base "$test_dir/run-prototype.json" -n --arg status "$status" '[$base[0] + {agent_id: "fixer", status: $status}]' >"$test_dir/runs.json"
	check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-check: ほかの役の終わっていない実行は、メンションせず保留を出す'

reset_fixture
fixture issue-runs direct | jq '. as $base | [$base + {"agent_id": "implementer", "status": "running"}, $base + {"agent_id": "fixer", "status": "queued"}, $base + {"agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test、demo-codex-implementer-test の作業中なので保留）'
echo 'PASS ci-check: 複数の役の名前を ID から引き、同じ役は重複しない'

# orchestrator と見張り役自身、および終了した役は通知を妨げない。
for status in none completed failed cancelled; do
	reset_fixture
	jq --slurpfile base "$test_dir/run-prototype.json" -n --arg status "$status" '[$base[0] + {agent_id: "orchestrator", status: "running"}, $base[0] + {agent_id: "monitor", status: "running"}]
		+ if $status == "none" then [] else [$base[0] + {agent_id: "fixer", status: $status}] end' >"$test_dir/runs.json"
	check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\nCI の失敗を検出しました。\n"))
		and (.[0].body | contains("[@Demo](mention://squad/test-squad)"))
		and (.[0].body | contains("mention://agent/") | not)
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
assert_jq -s 'length == 1 and .[0].body == "/note\nCI abcdef0: 保留した失敗をリーダーが引き継ぎで受けた\n"
	and (.[0].args | index("--parent") as $i | .[$i+1] == "handoff-comment")' "$test_dir/posted.jsonl"
echo 'PASS ci-held: 許可された起点へ無通知で記録し、別スレッドの次の取得と見張りでも重複しない'

# 更新前後の記録は、どちらも同じ SHA の失敗を取得済みとして扱う。
for wording in old new; do
	reset_fixture
	jq --slurpfile base "$test_dir/comment-prototype.json" -n --arg wording "$wording" '
		(if $wording == "old" then "\u9032\u884c\u5f79" else "リーダー" end) as $role
		| [$base[0] + {author_type: "agent", test_thread: "previous-handoff",
			content: ("/note\nCI abcdef0: 保留した失敗を" + $role + "が引き継ぎで受けた\n")}]' >"$test_dir/comments.json"
	check_held ''
	check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS 取得記録: 新旧の文が別スレッドにあっても、取得と見張りで同じ失敗を重ねて知らせない'

# 前後の文による照合でも、エージェントの /note と同じ SHA が必要。
for fixture in member other-head no-note other-prefix other-suffix; do
	reset_fixture
	jq --slurpfile base "$test_dir/comment-prototype.json" -n --arg fixture "$fixture" '
		[$base[0] + {author_type: "agent", content: "/note\nCI abcdef0: 保留した失敗をリーダーが引き継ぎで受けた\n"}]
		| if $fixture == "member" then .[0].author_type = "member"
		  elif $fixture == "other-head" then .[0].content |= sub("abcdef0"; "1234567")
		  elif $fixture == "no-note" then .[0].content |= ltrimstr("/note\n")
		  elif $fixture == "other-prefix" then .[0].content |= sub("保留した失敗を"; "失敗を")
		  else .[0].content |= sub("が引き継ぎで受けた"; "が確認する") end' >"$test_dir/comments.json"
	check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\n"))' "$test_dir/posted.jsonl"
done
echo 'PASS 取得記録の条件: 作者・SHA・印・前後の文が違えば、今の失敗を知らせる'

# 保留の判定後、最終投稿前に引き継ぎが届く順序を再現する。
# 引き継いだ役の run がまだ running でも、保留記録なしで失敗を拾う。
reset_fixture
fixture issue-runs direct | jq '. as $base | [$base + {"agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
late_hold=$(cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor)
[[ $late_hold == $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）' ]]
check_held $'CI / test\nexternal'
jq --slurpfile base "$test_dir/comment-prototype.json" --arg body "$late_hold" '. + [$base[0] + {author_type: "agent", content: $body, test_thread: "ci-thread"}]' \
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
	fixture issue-runs direct | jq '. as $base | [$base + {"id": "fixer-run", "agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
	fixture issue-comments agent | jq '. as $base | [$base + {"author_type": "agent", "author_id": "fixer", "source_task_id": "fixer-run", "content": "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます", "test_thread": "handoff-thread"}]' >"$test_dir/comments.json"
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
	jq --slurpfile base "$test_dir/check-prototype.json" '.statusCheckRollup = [$base[0] + {status:"IN_PROGRESS",conclusion:null,name:"test"}]' \
		"$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	check_held ''
	mv "$test_dir/failed-pr.json" "$test_dir/pr.json"
	check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\n"))' "$test_dir/posted.jsonl"
	check_held ''
done
echo 'PASS 引き継ぎ後の失敗: 取得時に未確定でも、引き継ぎ（スクワッドかエージェントのメンション）・レビュー報告後の run の終了前に通常の通知で拾う'

for fixture in old-run other-author no-mention new-run other-squad; do
	reset_fixture
	fixture issue-runs direct | jq '. as $base | [$base + {"id": "fixer-run", "agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
	jq --slurpfile base "$test_dir/comment-prototype.json" -n --arg fixture "$fixture" '[$base[0] + {author_type: "agent", author_id: "fixer",
		source_task_id: "fixer-run", content: "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます"}]
		| if $fixture == "old-run" then .[0].source_task_id = "old-fixer-run"
		  elif $fixture == "other-author" then .[0].author_id = "implementer"
		  elif $fixture == "no-mention" then .[0].content = "/note\n途中の記録"
		  elif $fixture == "other-squad" then .[0].content = "[@Demo](mention://squad/other-squad) 引き継ぎます" else . end' >"$test_dir/comments.json"
	if [[ $fixture == new-run ]]; then
		jq --slurpfile base "$test_dir/run-prototype.json" '. + [$base[0] + {id: "new-fixer-run", agent_id: "fixer", status: "running"}]' \
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
	notified) jq --slurpfile base "$test_dir/comment-prototype.json" '. + [$base[0] + {author_type: "agent", content: "head: abcdef0\nCI の失敗を検出しました。\n"}]' "$test_dir/comments.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/comments.json" ;;
	success | pending | cancelled | no-checks)
		case $fixture in
		success) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
		pending) checks='[{"__typename":"StatusContext","state":"PENDING","context":"external"}]' ;;
		cancelled) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]' ;;
		no-checks) checks='[]' ;;
		esac
		jq --slurpfile base "$test_dir/check-prototype.json" --argjson checks "$checks" '.statusCheckRollup = ($checks | map(if .__typename == "CheckRun" then $base[0] + . else . end))' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json"
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
assert_jq -s 'length == 1 and (.[0].body | contains("リーダーの「実装・修正の振り分け」に従い、有効な修正の役を選んでください"))
	and (.[0].body | contains("squad-dispatch-pick") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS 登録: 見張り役 ID を渡し、コンフリクト通知はリーダーの振り分けを参照する'

# 通知の参照先を実際に展開したリーダーからたどり、残る系統の修正役だけへ進める。
source "$root/lib/render.sh"
section=$(jq -sr '.[0].body | capture("リーダーの「(?<section>[^」]+)」").section' "$test_dir/wakeups.jsonl")
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

# 通知先は、担当のスクワッドではなく、渡された役をリーダーとする有効な候補で選ぶ。
reset_fixture
jq '.[0] as $base | . + [$base + {id:"archived",archived_at:"2026-01-01T00:00:00Z"},
 $base + {id:"other",leader_id:"other-leader"}]' "$test_dir/squads.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/squads.json"
jq '.assignee_type = null | .assignee_id = null' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
assert_jq -s 'length == 1 and (.[0].body | contains("[@Demo](mention://squad/test-squad)"))
 and (.[0].body | contains("mention://agent/") | not)' "$test_dir/posted.jsonl"
echo 'PASS 通知先: 有効なスクワッドをリーダーの ID で選び、担当なしでも同じ通知先にする'

for count in 0 2; do
 reset_fixture
 jq --argjson count "$count" '.[0] as $base | if $count == 0 then [] else . + [$base + {id:"second"}] end' \
  "$test_dir/squads.json" >"$test_dir/updated.json"
 mv "$test_dir/updated.json" "$test_dir/squads.json"
 check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた' 2>"$test_dir/error"
 assert_jq -s 'length == 1 and (.[0].body | contains("[@demo-orchestrator-test](mention://agent/orchestrator)"))
  and (.[0].body | contains("mention://squad/") | not)' "$test_dir/posted.jsonl"
 [[ $(<"$test_dir/error") == *"${count} 件"* ]]
done
echo 'PASS 通知先: 0 件・複数なら従来のエージェントのメンションへ戻す'

# 人の source_task_id と直接開始の trigger_comment_id は、実物どおりなくてもよい。
reset_fixture
fixture issue-comments member | jq '[del(.source_task_id)]' >"$test_dir/comments.json"
fixture issue-runs direct | jq '[del(.trigger_comment_id) + {agent_id:"fixer",status:"running"}]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
check_held $'CI / test\nexternal'
assert_jq -s 'all(.[] | select(.[0:3] == ["issue","comment","list"]);
 index("--full") != null and index("--compact") == null)' "$test_dir/calls.jsonl"
echo 'PASS 条件付き: 正常な省略を受け入れ、ci-check と ci-held は compact を使わない'

for defect in task-status task-category comment-source run-kind run-trigger wakeup-instruction wakeup-event agent-name check-name check-workflow check-conclusion context-name squad-name; do
 reset_fixture
 touch "$test_dir/allow-missing-fields"
 action=ci-check
 args=(test-issue orchestrator monitor)
 case $defect in
 task-status) source=task; reading=issue-get; field=status; filter='del(.status)' ;;
 task-category) source=task; reading=issue-get; field=status_category; filter='del(.status_category)' ;;
 comment-source)
  fixture issue-comments agent | jq '[.]' >"$test_dir/comments.json"
  source=comments; reading=issue-comments; field=source_task_id; filter='map(del(.source_task_id))' ;;
 run-kind|run-trigger)
  fixture issue-runs comment | jq '[. + {agent_id:"fixer",status:"running"}]' >"$test_dir/runs.json"
  source=runs; reading=issue-runs; field=kind
  [[ $defect != run-trigger ]] || field=trigger_comment_id
  filter="map(del(.$field))" ;;
 wakeup-instruction|wakeup-event)
  fixture issue-wakeups | jq '[. + {condition:{type:"pull_request",event:"conflicts"}}]' >"$test_dir/rules.json"
  source=rules; reading=issue-wakeups; field=instruction
  [[ $defect != wakeup-event ]] || field=condition.event
  filter="map(del(.$field))"; action=conflicts; args=(test-issue) ;;
 agent-name) source=agents; reading=agent-get; field=name; filter='map(del(.name))' ;;
 check-name|check-workflow|check-conclusion)
  source=pr; reading=gh-pr-checks; field=name
  [[ $defect != check-workflow ]] || field=workflowName
  [[ $defect != check-conclusion ]] || field=conclusion
  filter="del(.statusCheckRollup[0].$field)" ;;
 context-name) source=pr; reading=gh-pr-checks; field=context; filter='del(.statusCheckRollup[1].context)' ;;
 squad-name) source=squads; reading=squad-list; field=name; filter='map(del(.name))' ;;
 esac
 jq "$filter" "$test_dir/$source.json" >"$test_dir/updated.json"
 mv "$test_dir/updated.json" "$test_dir/$source.json"
 status=0
 (cd "$test_dir" && bash "$script" "$action" "${args[@]}") >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl && ! -s $test_dir/wakeups.jsonl ]]
 expected_field=$field
	[[ $reading != gh-pr-checks ]] || expected_field="statusCheckRollup[].$field"
	[[ $(<"$test_dir/error") == *"CLI の出力に欄がありません: $reading の $expected_field"* ]]
 [[ $(<"$test_dir/error") == *'fixture-version'* ]]
 echo "PASS contract: $reading の $field がなければ欄名で失敗し、後続の書き込みをしない"
done

# 書き込みの応答の検証で失敗しても、登録し直さない。
reset_fixture
touch "$test_dir/allow-missing-fields"
fixture issue-wakeup-create | jq 'del(.id)' >"$test_dir/wakeup-response.json"
if (cd "$test_dir" && bash "$script" conflicts test-issue) >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == *'issue-wakeup-create の id'* ]]
assert_jq -s 'length == 1' "$test_dir/wakeups.jsonl"
echo 'PASS contract: wakeup の応答に id がなければ失敗し、登録を重ねない'

for failure in squad gh; do
 reset_fixture
 if [[ $failure == squad ]]; then printf 'squad list --output' >"$test_dir/fail"; else touch "$test_dir/fail-gh"; fi
 if (cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor) >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
 [[ ! -s $test_dir/output && ! -s $test_dir/posted.jsonl ]]
 [[ $(<"$test_dir/error") == *'mock failure'* ]]
done
echo 'PASS CLI 失敗: スクワッドと GitHub の読み取り失敗で、通知先の代替や成功の応答を返さない'

reset_fixture
fixture issue-wakeups | jq '[. + {condition:{type:"pull_request",event:"conflicts",invented_field:true}}]' >"$test_dir/invented.json"
if python3 "$root/tests/pr-watch-fixture.py" emit issue-wakeups "$test_dir/invented.json" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == *'見本とケースの鍵が違います'* ]]
echo 'PASS fixture: 実物にない入れ子の欄を追加したケースを拒否する'
