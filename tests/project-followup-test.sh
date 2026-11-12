#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-followup-test-lib.sh"

followup_completed_one
: >"$TEST_DB/calls"; run; no_writes
grep -qF '今回作った件数: エージェント 0 件、スクワッド 0 件、オートパイロット 0 件' "$test_dir/out"
echo 'PASS followup: 同じ内容で再実行すると、スクワッド・メンバー・オートパイロット・トリガーを書かない'

jq '.instructions="old"' "$TEST_DB/squad.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/squad.json"
jq 'map(if .member_id=="agent-planner" then .role="old" else . end)' "$TEST_DB/roster.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/roster.json"
jq 'map(.description="old" | .execution_mode="run_only" | .status="paused")' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
jq 'map(.cron_expression="0 0 * * *" | .timezone="UTC" | .enabled=false)+[{id:"webhook-a",kind:"webhook",enabled:true}]' "$TEST_DB/triggers-auto-1.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/triggers-auto-1.json"
run
jq -e 'any(.[]; .member_id=="agent-planner" and .role!="old")' "$TEST_DB/roster.json" >/dev/null
jq -e 'all(.[]; .status=="paused" and .description!="old") and .[0].execution_mode=="create_issue"' "$TEST_DB/autopilots.json" >/dev/null
jq -e 'length==2 and .[0].cron_expression=="0 10 * * 1" and .[0].timezone=="Asia/Tokyo" and .[0].enabled==false and .[1].kind=="webhook"' "$TEST_DB/triggers-auto-1.json" >/dev/null
echo 'PASS followup: 既存の指示・役・担当の設定とスケジュールを更新し、停止状態と手動の Webhook を保つ'

cp "$TEST_DB/agents.json" "$test_dir/agents-before"
export TEST_EXCLUDED='["planner","claude-implementer","claude-fixer","security-reviewer","usage-monitor","dependabot-merger"]'
: >"$TEST_DB/calls"; run
jq -e 'all(.[]; .member_id!="agent-planner" and .member_id!="agent-claude-implementer" and .member_id!="agent-claude-fixer" and .member_id!="agent-security-reviewer") and any(.[]; .member_id=="other-agent")' "$TEST_DB/roster.json" >/dev/null
jq -e 'length==3 and all(.[]; .status=="paused")' "$TEST_DB/autopilots.json" >/dev/null
cmp "$TEST_DB/agents.json" "$test_dir/agents-before"
for role in planner claude-implementer claude-fixer security-reviewer usage-monitor dependabot-merger; do grep -q "demo-$role-owner" "$test_dir/err"; done
jq -e 'length==9 and index("demo-planner-owner")!=null and index("使用上限の見張り demo-owner")!=null and all(.[]; contains("other-agent")|not)' "$TEST_DB/removed-targets.json" >/dev/null
! grep -q 'demo-planner-owner' "$TEST_DB/squad.json"
echo 'PASS followup: 外した自分の役は名簿と対応するオートパイロットから外し、エージェントを消さずに名前を表示する'
export TEST_EXCLUDED='[]'
run
[[ $(jq length "$TEST_DB/autopilots.json") == 3 ]]
jq -e 'any(.[]; .member_id=="agent-planner")' "$TEST_DB/roster.json" >/dev/null
echo 'PASS followup: 役を戻すと同じ実 ID を名簿へ戻し、対応するオートパイロットを用意する'

# 他メンバーの共有の担当と、同名でも別のプロジェクトのものを保護する。
jq 'map(if .assignee_id!="agent-usage-monitor" then .assignee_id="other-member-agent" | .description="Other member" else .project_id="another-project" | .description="Other project" end)' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
cp "$TEST_DB/autopilots.json" "$test_dir/other-autopilots"
: >"$TEST_DB/calls"; run; no_autopilot_writes
cmp "$TEST_DB/autopilots.json" "$test_dir/other-autopilots"
echo 'PASS followup: 共有の担当が別の人ならその指示・担当を保ち、別のプロジェクトの同名のものにも書かない'

