#!/usr/bin/env bash
# CLI と時計を差し替え、CI 待ちの規則・期限・解除・重複防止を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
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

for status in SUCCESS CANCELLED none FAILURE; do
	wait_fixture
	old_wait
	status_pr "$status"
	case $status in SUCCESS | CANCELLED) expected="CI $head: 成功" ;; none) expected="CI $head: チェックなし" ;; FAILURE) expected=$(printf 'CI %s: 失敗あり\nCI / test' "$head") ;; esac
	wait_output "$expected"
	assert_cleared
	assert_jq 'length==2 and all(.[]; .id=="monitor-rule" or .id=="conflicts-rule")' "$test_dir/rules.json"
	[[ ! -s $test_dir/wakeups.jsonl ]]
	if [[ $status == FAILURE ]]; then
		assert_jq -s 'length==1 and .[0].body=="/note\nCI abcdef0: 保留した失敗をリーダーが引き継ぎで受けた\n"' "$test_dir/posted.jsonl"
		# 同じ失敗をもう一度受けた記録にしない。
		wait_output "$expected"
		assert_jq -s 'length==1' "$test_dir/posted.jsonl"
	else [[ ! -s $test_dir/posted.jsonl ]]; fi
done
echo 'PASS ci-wait: 成功・取り消し・チェックなし・失敗を判定し、失敗を一度受け、待ちだけを解除する'

for status in running external; do
	wait_fixture
	old_wait
	[[ $status == running ]] || status_pr external
	wait_output "CI $head: 実行中" old-wait
	assert_jq -s 'length==1 and (.[0].args | index("--expires-in") as $i | .[$i+1]=="1800s")
		and (.[0].args | index("--agent-id") as $i | .[$i+1]=="orchestrator")
		and (.[0].args | index("--until-pr") as $i | .[$i+1]=="checks")
		and (.[0].args | index("--mode") as $i | .[$i+1]=="once")
		and (.[0].args | index("--on-timeout") as $i | .[$i+1]=="wake")
		and (.[0].args | index("--parent") as $i | .[$i+1]=="trigger-comment")
		and (.[0].body | contains("規則の ID"))' "$test_dir/wakeups.jsonl"
	assert_jq '.metadata.ci_wait_since==10000 and .metadata.ci_wait_head=="abcdef0123456789abcdef0123456789abcdef0123" and .metadata.ci_wait_rule!= "old-wait"' "$test_dir/task.json"
	assert_jq '[.[] | select(.id=="old-wait")] | length==0' "$test_dir/rules.json"
done
echo 'PASS ci-wait: 実行中は古い規則を消し、リーダーを最長 30 分後に 1 回起こす'

for failure in gh missing-checks no-pr; do
	wait_fixture
	old_wait
	case $failure in
	gh) touch "$test_dir/fail-gh" ;;
	missing-checks) touch "$test_dir/allow-missing-fields"; jq 'del(.statusCheckRollup)' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	no-pr) jq 'del(.metadata.pr_url)' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	esac
	wait_output "CI $head: 未確認"
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
	assert_jq '.metadata.ci_wait_since==10000' "$test_dir/task.json"
done
wait_fixture
touch "$test_dir/fail-gh"
wait_output 'CI: 未確認'
assert_jq '.metadata.ci_wait_head=="" and .metadata.ci_wait_since==10000' "$test_dir/task.json"
echo 17200 >"$test_dir/now"
wait_output 'CI: 未確認（待つ上限の 2 時間を超えた）'
assert_cleared
echo 'PASS ci-wait: PR・CI が読めなくても成功扱いにせず待ち、head 不明でも最初の時刻から数える'

wait_fixture
old_wait 6500
wait_output "CI $head: 実行中"
assert_jq -s '.[0].args | index("--expires-in") as $i | .[$i+1]=="700s"' "$test_dir/wakeups.jsonl"
for state in running unknown; do
	wait_fixture
	old_wait 7200
	if [[ $state == unknown ]]; then touch "$test_dir/fail-gh"; expected=未確認; else expected=実行中; fi
	wait_output "CI $head: ${expected}（待つ上限の 2 時間を超えた）"
	assert_cleared
	[[ ! -s $test_dir/wakeups.jsonl ]]
done
wait_fixture
old_wait 8000
jq '.headRefOid="123456789abcdef0123456789abcdef0123456789"' "$test_dir/pr.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/pr.json"
wait_output 'CI 123456789abcdef0123456789abcdef0123456789: 実行中'
assert_jq '.metadata.ci_wait_since==10000 and .metadata.ci_wait_head=="123456789abcdef0123456789abcdef0123456789"' "$test_dir/task.json"
echo 'PASS ci-wait: 残り時間で規則を短くし、同じ head は 2 時間で終え、新しい head は数え直す'

# 登録直前の完了を拾い、削除前に起動が決まった古い規則も止める。
for status in SUCCESS FAILURE none; do
	wait_fixture
	cp "$test_dir/pr.json" "$test_dir/pending.json"
	status_pr "$status"
	mv "$test_dir/pr.json" "$test_dir/pr-after-first.json"
	cp "$test_dir/pending.json" "$test_dir/pr.json"
	case $status in SUCCESS) expected="CI $head: 成功" ;; FAILURE) expected=$(printf 'CI %s: 失敗あり\nCI / test' "$head") ;; none) expected="CI $head: チェックなし" ;; esac
	wait_output "$expected"
	assert_cleared
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
done
wait_fixture
wait_output "CI $head: 実行中"
rule=$(jq -r '.metadata.ci_wait_rule' "$test_dir/task.json")
status_pr SUCCESS
wait_output "CI $head: 成功"
assert_cleared
: >"$test_dir/calls.jsonl"
wait_output 'CI 待ち: 終わった規則で起きた' "$rule"
assert_jq -s 'length==1 and .[0][0:3]==["issue","get","test-issue"]' "$test_dir/calls.jsonl"
wait_fixture
old_wait
wait_output 'CI 待ち: 終わった規則で起きた' stale-rule
assert_jq '.metadata.ci_wait_rule=="old-wait"' "$test_dir/task.json"
echo 'PASS ci-wait: 登録直後にも読み、別経路で終えた待ちや別の規則からの起動を重ねない'

for record in current old other-author partial; do
	wait_fixture
	old_wait
	case $record in
	current) requested orchestrator "マージの依頼: $head" ;;
	old) requested orchestrator 'マージの依頼: 1234567' ;;
	other-author) requested fixer "マージの依頼: $head" ;;
	partial) requested orchestrator "説明 マージの依頼: $head" ;;
	esac
	if [[ $record == current ]]; then wait_output "CI $head: マージを依頼済み"; assert_cleared
	else wait_output "CI $head: 実行中"; fi
done
wait_fixture
requested orchestrator "マージの依頼: $head"
wait_output "CI $head: マージを依頼済み"
assert_cleared
echo 'PASS ci-wait: 待ちの記録がなくても、リーダーの今の完全な head の行で依頼済みとする'

wait_fixture
old_wait
check_output '' ci-wait-clear test-issue
assert_cleared
check_output '' ci-wait-clear test-issue
assert_cleared
echo 'PASS ci-wait-clear: 待ちの規則と metadata を解除し、解除済みでも何も出さない'

for operation in 'issue get test-issue' 'issue comment list' 'issue wakeup list' 'issue wakeup delete' 'issue wakeup create' 'issue metadata set' 'issue metadata delete' 'issue comment add'; do
	wait_fixture
	old_wait
	case $operation in 'issue metadata delete') status_pr SUCCESS ;; 'issue comment add') status_pr FAILURE ;; esac
	printf '%s' "$operation" >"$test_dir/fail"
	status=0
	(cd "$test_dir" && bash "$script" ci-wait test-issue orchestrator trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/output && -s $test_dir/error ]]
done
for args in 'ci-wait' 'ci-wait test-issue orchestrator' 'ci-wait test-issue orchestrator trigger rule extra' 'ci-wait-clear' 'ci-wait-clear test-issue extra'; do
	status=0
	# 使い方の検査だけ、引数を意図的に空白で分ける。
	bash "$script" $args >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 2 && ! -s $test_dir/output && -s $test_dir/error ]]
done
echo 'PASS ci-wait: 読み取り・書き込み・削除の失敗では終了コード 1、使い方の誤りでは 2 を返す'
