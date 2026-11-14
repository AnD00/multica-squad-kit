#!/usr/bin/env bash
# ci-now のその場の判定、メンションなしの知らせ、記録のスレッドの作成を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"

check_now() {
	printf 'trigger-comment' >"$test_dir/allowed-parent"
	check_output "$1" ci-now test-issue orchestrator trigger-comment "${@:2}"
}
metadata_writes() { jq -s '[.[] | select(.[0:3] == ["issue","metadata","set"])] | length' "$test_dir/calls.jsonl"; }
update_task() {
	jq "$1" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
}

# 渡した見張り役とリーダーは作業中の役から除き、知らせはメンションなしで書く。
reset_fixture
jq --slurpfile base "$test_dir/run-prototype.json" -n '[$base[0] + {agent_id:"orchestrator",status:"running"},
	$base[0] + {agent_id:"monitor",status:"running"}]' >"$test_dir/runs.json"
check_now $'/note\nCI abcdef0: 失敗あり' monitor
assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\nCI の失敗を検出しました。\n"))
	and (.[0].body | contains("mention://") | not) and (.[0].body | contains("- CI / test\n- external\n"))
	and (.[0].args | index("--parent") as $i | .[$i+1] == "trigger-comment")' "$test_dir/posted.jsonl"
[[ $(metadata_writes) == 0 && ! -s $test_dir/wakeups.jsonl ]]
assert_jq -s 'all(.[]; .[0:2] != ["squad","list"])' "$test_dir/calls.jsonl"
check_now $'/note\nCI abcdef0: 失敗は知らせ済み' monitor
check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
check_held ''
assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
echo 'PASS ci-now: 失敗をメンションなしで知らせ、同じ head を ci-check・ci-held と重ねない'

reset_fixture
check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
check_now $'/note\nCI abcdef0: 失敗は知らせ済み'
assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
echo 'PASS ci-now: ci-check が先に知らせた失敗も重ねない'

# 過去の記録先があっても今回の返信先だけを許可し、既存の見張りは保つ。
for monitor in present absent; do
	reset_fixture
	fixture issue-wakeups | jq '[. + {parent_comment_id:"ci-thread"}]' >"$test_dir/rules.json"
	cp "$test_dir/rules.json" "$test_dir/rules-before.json"
	if [[ $monitor == present ]]; then
		check_now $'/note\nCI abcdef0: 失敗あり' monitor
	else
		check_now $'/note\nCI abcdef0: 失敗あり'
	fi
	assert_jq -s 'length == 1 and (.[0].args | index("--parent") as $i | .[$i+1] == "trigger-comment")
		and (.[0].body | contains("CI の失敗を検出しました。"))
		and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
	assert_jq '.metadata.ci_watch_thread == "ci-thread"' "$test_dir/task.json"
	[[ $(metadata_writes) == 0 && ! -s $test_dir/wakeups.jsonl ]]
	cmp "$test_dir/rules-before.json" "$test_dir/rules.json"
	# 別のきっかけでも、今回の通知を全スレッドから見つけて重ねない。
	printf 'another-trigger' >"$test_dir/allowed-parent"
	check_output $'/note\nCI abcdef0: 失敗は知らせ済み' ci-now test-issue orchestrator another-trigger
	check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
	check_held ''
	assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
	# 次の head の通知は、既存の見張りの返信先へ引き続き投稿できる。
	jq '.headRefOid="1234567890abcdef"' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	check_ci $'/note\nCI 1234567: 失敗をリーダーに知らせた'
	assert_jq -s 'length == 2 and (.[1].args | index("--parent") as $i | .[$i+1] == "ci-thread")' "$test_dir/posted.jsonl"
	assert_jq '.metadata.ci_watch_thread == "ci-thread"' "$test_dir/task.json"
	cmp "$test_dir/rules-before.json" "$test_dir/rules.json"
done
echo 'PASS ci-now: 見張り役あり・なしでも今回のきっかけへ通知し、既存の返信先と全スレッドの重複防止を保つ'

# スレッドの欠落・null・空文字では、きっかけを保存して同じ記録先を使い続ける。
for value in absent null empty; do
	reset_fixture
	case $value in
	absent) update_task 'del(.metadata.ci_watch_thread)' ;;
	null) update_task '.metadata.ci_watch_thread = null' ;;
	empty) update_task '.metadata.ci_watch_thread = ""' ;;
	esac
	printf 'trigger-comment' >"$test_dir/allowed-parent"
	jq --slurpfile base "$test_dir/run-prototype.json" -n '[$base[0] + {agent_id:"orchestrator",status:"running"}]' >"$test_dir/runs.json"
	check_now $'/note\nCI abcdef0: 失敗あり'
	assert_jq '.metadata.ci_watch_thread == "trigger-comment"' "$test_dir/task.json"
	assert_jq -s 'length == 1 and (.[0].args | index("--parent") as $i | .[$i+1] == "trigger-comment")
		and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
	[[ $(metadata_writes) == 1 ]]
	check_now $'/note\nCI abcdef0: 失敗は知らせ済み'
	[[ $(metadata_writes) == 1 ]]
done
echo 'PASS ci-now: 見張り役と記録のスレッドがなくても、きっかけを保存し、リーダーだけを除いて確認する'

# 見張り役を渡さなければ、その役も作業中として扱う。ほかの役の保留も共通の判定を通す。
for role in monitor fixer; do
	reset_fixture
	jq --slurpfile base "$test_dir/run-prototype.json" -n --arg role "$role" '[$base[0] + {agent_id:$role,status:"running"}]' >"$test_dir/runs.json"
	if [[ $role == monitor ]]; then name=demo-ci-monitor-test; else name=demo-codex-fixer-test; fi
	check_now "/note"$'\n'"CI abcdef0: 失敗あり（$name の作業中なので保留）"
	[[ ! -s $test_dir/posted.jsonl ]]
done
reset_fixture
fixture issue-runs direct | jq '[. + {agent_id:"fixer",status:"running"}]' >"$test_dir/runs.json"
check_now $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）' monitor
check_held $'CI / test\nexternal'
check_now $'/note\nCI abcdef0: 失敗は知らせ済み' monitor
echo 'PASS ci-now: 作業中の役は保留し、ci-held が引き継いだあとは知らせ済みとして扱う'

# 失敗のない結果と終了済みの判定は、同じ入力の ci-check と出力が一致する。
for value in done cancelled merged closed no-checks success pending cancelled-check; do
	reset_fixture
	case $value in
	done | cancelled) update_task ".status_category = \"$value\"" ;;
	merged | closed)
		jq --arg state "$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')" '.state = $state' "$test_dir/pr.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	*)
		case $value in
		no-checks) filter='.statusCheckRollup = []' ;;
		success) filter='.statusCheckRollup = [.statusCheckRollup[0] | .conclusion = "SUCCESS"]' ;;
		pending) filter='.statusCheckRollup = [.statusCheckRollup[0] | .status = "IN_PROGRESS" | .conclusion = null]' ;;
		cancelled-check) filter='.statusCheckRollup = [.statusCheckRollup[0] | .conclusion = "CANCELLED"]' ;;
		esac
		jq "$filter" "$test_dir/pr.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	esac
	expected=$(cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor)
	check_now "$expected"
	[[ ! -s $test_dir/posted.jsonl && $(metadata_writes) == 0 ]]
done
echo 'PASS ci-now: タスク終了・PR終了・チェックなし・成功・実行中・取消は ci-check と同じ行を返す'

for operation in metadata runs comment gh; do
	reset_fixture
	case $operation in
	metadata) update_task 'del(.metadata.ci_watch_thread)'; echo 'issue metadata set' >"$test_dir/fail" ;;
	runs) echo 'issue runs test-issue' >"$test_dir/fail" ;;
	comment) echo 'issue comment add' >"$test_dir/fail" ;;
	gh) touch "$test_dir/fail-gh" ;;
	esac
	status=0
	(cd "$test_dir" && bash "$script" ci-now test-issue orchestrator trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-now: CLI の失敗は非0で返し、確認できたという行や失敗の知らせに置き換えない'

args=(test-issue orchestrator trigger-comment monitor extra)
for count in 0 1 2 5; do
	status=0
	bash "$script" ci-now "${args[@]:0:$count}" >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 2 && ! -s $test_dir/output ]]
	grep -qF 'ci-now <タスク> <リーダーの ID> <きっかけのコメント> [<見張り役の ID>]' "$test_dir/error"
done
echo 'PASS ci-now: 引数の不足・過剰は、使い方と終了コード2を返す'
