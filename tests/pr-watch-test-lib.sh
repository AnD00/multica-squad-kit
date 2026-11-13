#!/usr/bin/env bash
# squad-pr-watch-*-test.sh が読み込む共通の準備。単独では実行しない。

script="$root/common/monitor/squad-pr-watch"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-watch-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
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
stub_args=("$@")
# 記録と見本の返却は、補助の 1 回の呼び出しで済ませる。見本を返さずに終わる呼び出しは、終了時に記録だけする。
stub() { recorded=1; python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
if [[ -f $dir/fail && "${1-} ${2-} ${3-}" == "$(<"$dir/fail")" ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
emit() { stub emit "$@"; }
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
stub="$PR_WATCH_TEST_ROOT/tests/cli-stub.py"
if [[ ${1-} == --version ]]; then
	python3 "$stub" none "$PR_WATCH_TEST_DIR" gh - record -- "$@"
	echo 'gh fixture-version'; exit 0
fi
if [[ "${1-} ${2-} ${3-}" != 'pr view test-pr' || -f $PR_WATCH_TEST_DIR/fail-gh ]]; then
	python3 "$stub" none "$PR_WATCH_TEST_DIR" gh - record -- "$@"
	[[ "${1-} ${2-} ${3-}" == 'pr view test-pr' ]] || exit 1
	echo 'gh mock failure' >&2; exit 1
fi
python3 "$stub" pr-watch "$PR_WATCH_TEST_DIR" gh - emit gh-pr-checks "$PR_WATCH_TEST_DIR/pr.json" -- "$@"
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
