#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-register-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。見張りの登録・通知先の選択・契約の検査を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/pr-watch-test-lib.sh"

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
