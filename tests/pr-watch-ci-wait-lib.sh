#!/usr/bin/env bash
# squad-pr-watch ci-wait のテストの共通の準備。source して使う。単独では実行しない。
# 使う側は、先に root を決め、cd "$root" してから source する。
source "$root/tests/pr-watch-test-lib.sh"
head=abcdef0123456789abcdef0123456789abcdef0123
cat >"$test_dir/bin/date" <<'EOF'
#!/bin/bash
[[ "$*" == +%s ]] || exit 1
cat "$PR_WATCH_TEST_DIR/now"
EOF
chmod +x "$test_dir/bin/date"

wait_fixture() {
	reset_fixture
	echo 10000 >"$test_dir/now"
	touch "$test_dir/persist-created-rule"
	printf 'trigger-comment' >"$test_dir/allowed-parent"
	jq --arg head "$head" '.headRefOid=$head | .statusCheckRollup=[.statusCheckRollup[2]]' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
}
old_wait() {
	local age=${1:-0}
	jq --arg head "$head" --argjson since "$((10000-age))" '.metadata += {ci_wait_head:$head,ci_wait_since:$since,ci_wait_rule:"old-wait"}' "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
	fixture issue-wakeups | jq '[. + {id:"old-wait",mode:"once",condition:{type:"pull_request",event:"checks_finished"},instruction:"CI の待ちの規則で起きました。"},
		. + {id:"monitor-rule",mode:"continuous",condition:{type:"pull_request",event:"checks_finished"}},
		. + {id:"conflicts-rule",mode:"once",condition:{type:"pull_request",event:"conflicts"}}]' >"$test_dir/rules.json"
}
status_pr() {
	local status=$1
	jq --arg status "$status" --slurpfile base "$test_dir/check-prototype.json" '
		.statusCheckRollup = (if $status=="none" then []
		elif $status=="external" then [{__typename:"StatusContext",state:"PENDING",context:"external"}]
		elif $status=="FAILURE" then [$base[0] + {status:"COMPLETED",conclusion:$status,workflowName:"CI",name:"test"},
			$base[0] + {status:"IN_PROGRESS",conclusion:null}]
		else [$base[0] + {status:"COMPLETED",conclusion:$status}] end)' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
}
wait_output() { check_output "$1" ci-wait test-issue orchestrator trigger-comment "${@:2}"; }
assert_cleared() {
	assert_jq '.metadata | has("ci_wait_head") or has("ci_wait_since") or has("ci_wait_rule") | not' "$test_dir/task.json"
	assert_jq '[.[] | select(.instruction | startswith("CI の待ちの規則で起きました。"))] | length==0' "$test_dir/rules.json"
	assert_jq '.metadata.ci_watch_thread=="ci-thread"' "$test_dir/task.json"
}
requested() {
	local author=$1 value=$2
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg author "$author" --arg value "$value" -n \
		'[$base[0] + {author_type:"agent",author_id:$author,content:$value}]' >"$test_dir/comments.json"
}

# 回 final-1 はリーダーが書いた最終レビューの回で、最上位の役 principal を待つ。決める記録 decide-1 は principal が書く。
# 3 つ目のコメント merge-1 が調べる候補。本文は JSON の文字列で渡す（NUL や単独の CR を含められる）。
requested_chain_json() { # 作者 種類 時刻 本文の JSON 文字列
	local author=$1 type=$2 at=$3 json=$4
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg author "$author" --arg type "$type" --arg at "$at" --argjson text "$json" -n '
		def c($id; $who; $kind; $time; $body): $base[0] + {id: $id, author_id: $who, author_type: $kind, created_at: $time, content: $body};
		[c("final-1"; "orchestrator"; "agent"; "2026-01-01T00:00:00Z";
			"見直しの種類: 最終レビュー\n確認するコミット: abcdef0\n返事を待つ役: [@p](mention://agent/principal)"),
		c("decide-1"; "principal"; "agent"; "2026-01-01T00:01:00Z"; "/note\n返事の待ち: 次の依頼を決めます"),
		c("merge-1"; $author; $type; $at; $text)]' >"$test_dir/comments.json"
}
requested_chain() { # 作者 種類 時刻 本文
	requested_chain_json "$1" "$2" "$3" "$(jq -nc --arg text "$4" '$text')"
}

# `マージの依頼: <head>` を含む読めない候補があれば、依頼済みと読まず、規則と待ちの記録を残して終了 1 になる。コメントは書かない。
wait_blocked() { # 標準エラーに含まれる理由
	local out code=0
	out=$(cd "$test_dir" && bash "$script" ci-wait test-issue orchestrator trigger-comment 2>"$test_dir/wait-err") || code=$?
	[[ $code == 1 ]] || { printf '終了コード 1 を期待したが %s（出力: %s）\n' "$code" "$out" >&2; exit 1; }
	[[ $out != *'マージを依頼済み'* ]] || { printf '依頼済みと読んではいけない: %s\n' "$out" >&2; exit 1; }
	[[ $(<"$test_dir/wait-err") == *"$1"* ]] || { printf '標準エラーに「%s」がない: %s\n' "$1" "$(<"$test_dir/wait-err")" >&2; exit 1; }
	[[ ! -s $test_dir/posted.jsonl ]] || { printf 'コメントを書いてはいけない: %s\n' "$(<"$test_dir/posted.jsonl")" >&2; exit 1; }
	assert_jq '.metadata.ci_wait_head == "'"$head"'" and (.metadata | has("ci_wait_since") and has("ci_wait_rule"))' "$test_dir/task.json"
	assert_jq '[.[] | select(.id == "old-wait")] | length == 1' "$test_dir/rules.json"
}
