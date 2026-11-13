#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-ci-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。ci-check と ci-held の保留・知らせ済みの記録・取得の条件を確認する。
# 保留の判定後の順序、引き継ぎ後の失敗、古い head、CLI の失敗は tests/squad-pr-watch-ci-handoff-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/pr-watch-test-lib.sh"

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

# ci-check が読む欄（status_category・state・statusCheckRollup の各欄）は、欄がある場合にその値どおり分岐することを確認する。
# 欄が読めずに null になると、どの分岐にも入らず失敗を見逃す。
set_checks() { # checks の JSON 配列。CheckRun は実物から作った見本に重ねる。
	jq --slurpfile base "$test_dir/check-prototype.json" --argjson checks "$1" \
		'.statusCheckRollup = ($checks | map(if .__typename == "CheckRun" then $base[0] + . else . end))' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
}

for category in done cancelled; do
	reset_fixture
	jq --arg c "$category" '.status_category = $c' "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
	check_ci $'/note\nCI: タスクが終わっているので見ない'
	[[ ! -s $test_dir/posted.jsonl ]]
done
for state in MERGED CLOSED; do
	reset_fixture
	jq --arg s "$state" '.state = $s' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	check_ci $'/note\nCI abcdef0: PR がマージ済みか閉じているので見ない'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-check: タスクが done・cancelled、PR が MERGED・CLOSED なら、失敗があっても見ない'

for fixture in no-checks success cancelled-only context-pending run-in-progress; do
	reset_fixture
	case $fixture in
	no-checks) set_checks '[]'; expected='チェックなし' ;;
	success) set_checks '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS","context":"external"}]'; expected='失敗なし' ;;
	cancelled-only) set_checks '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]'; expected='失敗なし' ;;
	context-pending) set_checks '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"PENDING","context":"external"}]'; expected='失敗なし（実行中のチェックあり）' ;;
	run-in-progress) set_checks '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]'; expected='失敗なし（実行中のチェックあり）' ;;
	esac
	check_ci "/note"$'\n'"CI abcdef0: $expected"
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-check: チェックなし・成功・取り消しだけ・実行中は、失敗として知らせず、実行中の有無を分ける'

# 完了した CheckRun の TIMED_OUT・STARTUP_FAILURE と StatusContext の FAILURE は失敗に数え、実行中の CheckRun は結論があっても数えない。
reset_fixture
set_checks '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT","workflowName":"CI","name":"a"},
	{"__typename":"CheckRun","status":"COMPLETED","conclusion":"STARTUP_FAILURE","workflowName":"","name":"b"},
	{"__typename":"StatusContext","state":"FAILURE","context":"ctx"},
	{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"FAILURE","workflowName":"CI","name":"running"}]'
check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
assert_jq -s 'length == 1 and (.[0].body | contains("- CI / a\n- b\n- ctx\n")) and (.[0].body | contains("running") | not)' "$test_dir/posted.jsonl"
echo 'PASS ci-check: TIMED_OUT・STARTUP_FAILURE・StatusContext の FAILURE を失敗として名前つきで知らせ、実行中は数えない'

# 記録のスレッドがなければ、何も投稿せずエラーにする。
reset_fixture
jq 'del(.metadata.ci_watch_thread)' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
if (cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor) >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && ! -s $test_dir/posted.jsonl && $(<"$test_dir/error") == *'metadata に ci_watch_thread がありません'* ]]
echo 'PASS ci-check: 記録のスレッドがなければ、投稿せずエラーにする'
