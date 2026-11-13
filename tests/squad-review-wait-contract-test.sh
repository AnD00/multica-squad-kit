#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-contract-test.sh で実行する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。応答の欠落・スクワッドの選択・同時の記録を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')

# 正常な省略: 人間のコメントに source_task_id、直接開始の実行に trigger_comment_id がない。
reset_calls
round_comments
fixture issue-comments member >"$test_dir/member.json"
jq --slurpfile member "$test_dir/member.json" '. + $member' "$test_dir/comments.json" >"$test_dir/mixed.json"
cp "$test_dir/mixed.json" "$test_dir/comments.json"
fixture issue-runs direct | jq --arg a "$a" --arg time "$(jq -nr --argjson ts "$((round_ts + 1))" '$ts | todateiso8601')" \
	'.agent_id = $a | .created_at = $time | .status = "failed" | .error = null | .delivered_comment_ids = []' | jq -s '.' >"$test_dir/runs.json"
check_status $'返事の待ち: 人間を呼ぶ\n- demo-code-reviewer-test: failed\n- demo-qa-test: 実行なし'
echo 'PASS contract: 人間のコメント・直接開始の実行の正常な省略と null の error を受け入れる'

cp "$test_dir/agents.json" "$test_dir/agents.base.json"
cp "$test_dir/rules.json" "$test_dir/rules.base.json"
for defect in comments-time comments-source runs-kind agent-name wakeup-instruction comment-id wakeup-id; do
	reset_calls
	round_comments
	run_fixture "$a" running "$((round_ts + 1))" | jq -s '.' >"$test_dir/runs.json"
	cp "$test_dir/agents.base.json" "$test_dir/agents.json"
	cp "$test_dir/rules.base.json" "$test_dir/rules.json"
	# 欠落時の失敗を調べるケースだけ、必須の鍵の削除を許す。
	touch "$test_dir/allow-missing-fields"
	case $defect in
	comments-time) reading=issue-comments; field=created_at; action=status; source_file=comments; filter='map(del(.created_at))' ;;
	comments-source) reading=issue-comments; field=source_task_id; action=status; source_file=comments; filter='map(del(.source_task_id))' ;;
	runs-kind) reading=issue-runs; field=kind; action=status; source_file=runs; filter='map(del(.kind))' ;;
	agent-name) reading=agent-get; field=name; action=watch; source_file=agents; filter='map(del(.name))' ;;
	wakeup-instruction) reading=issue-wakeups; field=instruction; action=unwatch; source_file=rules; filter='map(del(.instruction))' ;;
	comment-id|wakeup-id)
		field=id
		if [[ $defect == comment-id ]]; then reading=issue-comment-add; action=report; else reading=issue-wakeup-create; action=watch; fi
		fixture "$reading" | jq 'del(.id)' >"$test_dir/$reading-response.json"
		;;
	esac
	if [[ $field != id ]]; then
		jq "$filter" "$test_dir/$source_file.json" >"$test_dir/defect.json"
		cp "$test_dir/defect.json" "$test_dir/$source_file.json"
	fi
	status=0
	case $action in
	status|unwatch) bash "$script" "$action" test-issue >"$test_dir/output" 2>"$test_dir/error" || status=$? ;;
	watch) bash "$script" watch test-issue trigger-comment "$a" >"$test_dir/output" 2>"$test_dir/error" || status=$? ;;
	report) bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || status=$? ;;
	esac
	[[ $status == 1 && ! -s $test_dir/output ]]
	[[ $(<"$test_dir/error") == *"CLI の出力に欄がありません: $reading の $field"* ]]
	[[ $(<"$test_dir/error") == *'multica fixture-version'* ]]
	case $defect in
	agent-name|wakeup-instruction) [[ $(deleted_rules) == 0 ]] ;;
	comment-id) [[ $(jq -s length "$test_dir/posted.jsonl") == 1 && $(list_count) == 1 && -z $(slept) ]] ;;
	wakeup-id) assert_jq -s '[.[] | select(.[0:3] == ["issue", "wakeup", "create"])] | length == 1' "$test_dir/calls.jsonl" ;;
	esac
	echo "PASS contract: $reading の $field がなければ欄名で失敗し、後続の処理を進めない"
done
cp "$test_dir/agents.base.json" "$test_dir/agents.json"
cp "$test_dir/rules.base.json" "$test_dir/rules.json"

# 結果のあとに返した役の名前が読めなくても、ID に置き換えて知らせを投稿しない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
jq --arg a "$a" 'map(if .id == $a then del(.name) else . end)' "$test_dir/agents.json" >"$test_dir/defect.json"
cp "$test_dir/defect.json" "$test_dir/agents.json"
touch "$test_dir/allow-missing-fields"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(posted_ready_count) == 0 && $(jq -s length "$test_dir/posted.jsonl") == 1 ]]
[[ $(<"$test_dir/error") == *'agent-get の name'* ]]
echo 'PASS contract: 返した役の名前の欠落を隠さず、結果を再投稿しない'

# null だった親をオブジェクトに変えても、見本にない鍵を足せない。
jq '.[0].condition = {type:"pull_request", event:"checks_finished", invented_field:true}' \
	"$test_dir/rules.base.json" >"$test_dir/invented.json"
if python3 "$root/tests/review-wait-fixture.py" emit issue-wakeups "$test_dir/invented.json" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == *'見本とケースの鍵が違います'* ]]
echo 'PASS fixture: 入れ子に手書きの鍵を足したケースを拒否する'

# 回の役をリーダーとするスクワッドを選び、報告する役の実行の種類は問わない。
cp "$test_dir/agents.base.json" "$test_dir/agents.json"
reset_calls
jq '. + [.[0] + {id:"archived-squad",archived_at:"2026-01-01T00:00:00Z"}, .[0] + {id:"other-squad",leader_id:"other-leader"}]' \
	"$test_dir/squads.base.json" >"$test_dir/squads.json"
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
MULTICA_AGENT_ID="$a" MULTICA_TASK_ID=member-run bash "$script" report test-issue trigger "$test_dir/result.md"
assert_jq -s 'length == 2 and (.[1].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n"))
 and (.[1].body | contains("mention://agent/") | not)' "$test_dir/posted.jsonl"
echo 'PASS report: 回を書いたリーダーの有効なスクワッドだけをメンションし、エージェントのメンションを含まない'

# スクワッドを決められなければ、結果を /note で投稿する前に止める。
for selection in none archived other-leader duplicate missing-name cli; do
	reset_calls
	build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
	case $selection in
	none) printf '[]' >"$test_dir/squads.json" ;;
	archived) jq 'map(.archived_at = "2026-01-01T00:00:00Z")' "$test_dir/squads.base.json" >"$test_dir/squads.json" ;;
	other-leader) jq 'map(.leader_id = "other-leader")' "$test_dir/squads.base.json" >"$test_dir/squads.json" ;;
	duplicate) jq '. + [.[0] + {id:"second-squad"}]' "$test_dir/squads.base.json" >"$test_dir/squads.json" ;;
	missing-name)
		touch "$test_dir/allow-missing-fields"
		jq 'map(del(.name))' "$test_dir/squads.base.json" >"$test_dir/squads.json" ;;
	cli) printf 'squad list --output' >"$test_dir/fail" ;;
	esac
	if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output && ! -s $test_dir/posted.jsonl && -z $(slept) ]]
	case $selection in
	none|archived|other-leader) [[ $(<"$test_dir/error") == *'0 件'* && $(<"$test_dir/error") == *'orchestrator'* ]] ;;
	duplicate) [[ $(<"$test_dir/error") == *'2 件'* && $(<"$test_dir/error") == *'orchestrator'* ]] ;;
	missing-name) [[ $(<"$test_dir/error") == *'squad-list の name'* ]] ;;
	cli) [[ $(<"$test_dir/error") == 'CLI mock failure' ]] ;;
	esac
	rm -f "$test_dir/fail"
	echo "PASS report: スクワッドの $selection では結果を投稿せずに失敗する"
done

# 記録があれば、返事の有無にかかわらず status は次へ回し済みを返す。
reset_calls
build_comments claim:orch:claimed:10 >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 次へ回し済みなので何もしない'
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:claimed:10 >"$test_dir/comments.json"
check_status $'/note\n返事の待ち: 次へ回し済みなので何もしない' --timeout
echo 'PASS status: 記録がある回は、返事・知らせ・上限の有無を問わず次へ回し済み'

# 同じタスクに別の実行として 2 回呼ぶ。最初の記録の実行だけが進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
first_output=$(MULTICA_TASK_ID=first-run bash "$script" proceed test-issue k1)
second_output=$(MULTICA_TASK_ID=second-run bash "$script" proceed test-issue k1)
[[ $first_output == '返事の待ち: 次に進む' && $second_output == $'/note\n返事の待ち: 回ごと済み' ]]
[[ $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]]
echo 'PASS proceed: 異なる実行で 2 回呼んでも、進むのは最初の記録の実行だけ'

# 自分の記録が初回に見えなければ、他の記録が見えてももう 1 回待つ。
for winner in own other; do
	reset_calls
	build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
	if [[ $winner == own ]]; then
		build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:later:9 >"$test_dir/comments.2.json"
		build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:later:9 >"$test_dir/comments.json"
		expected='返事の待ち: 次に進む'; deletes=2
	else
		build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:earlier:8 >"$test_dir/comments.2.json"
		build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:earlier:8 claim:orch:posted-1:9 >"$test_dir/comments.json"
		expected=$'/note\n返事の待ち: 回ごと済み'; deletes=0
	fi
	[[ $(bash "$script" proceed test-issue k1) == "$expected" ]]
	[[ $(posted_claim_count) == 1 && $(slept) == '20,20' && $(list_count) == 3 && $(deleted_rules) == "$deletes" ]]
	echo "PASS proceed: 自分の記録を 2 回目で読めたら、最も早い $winner の記録だけが進む"
done

# 2 回目の読み直しでも、新しい回の確認と取得失敗の伝播を行う。
for change in round cli; do
	reset_calls
	build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
	build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.2.json"
	build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.base.json"
	if [[ $change == round ]]; then
		jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg time "$(jq -nr --argjson ts "$((round_ts + 30))" '$ts | todateiso8601')" \
			'. + [$comment[0] + {id:"round2", author_type:"agent", author_id:"orchestrator", created_at:$time, content:("返事を待つ役: [@review](mention://agent/" + $a + ")")}]' \
			"$test_dir/comments.base.json" >"$test_dir/comments.json"
		[[ $(bash "$script" proceed test-issue k1) == $'/note\n返事の待ち: 新しい回があるので何もしない' ]]
	else
		cp "$test_dir/comments.base.json" "$test_dir/comments.json"
		echo 3 >"$test_dir/fail-list-at"
		if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
		[[ ! -s $test_dir/output && $(<"$test_dir/error") == 'CLI mock comment list failure' ]]
	fi
	[[ $(posted_claim_count) == 1 && $(slept) == '20,20' && $(deleted_rules) == 0 ]]
	echo "PASS proceed: 2 回目の読み直しの $change でも次へ進まない"
done
