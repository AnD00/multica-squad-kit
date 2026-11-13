#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-followup-test-lib.sh"

# 復旧のケースは、本体を通して検証した登録済みの状態から始める。
followup_completed_one >"$test_dir/seed-out"
reset_db
printf '\n{{missing_value}}\n' >>"$TEST_PACKAGE/common/squad.md"
deny; no_writes
cp "$root/common/squad.md" "$TEST_PACKAGE/common/squad.md"
cp "$TEST_PACKAGE/common/autopilots.md" "$test_dir/autopilots-original"
sed 's/USAGE_WARN_PERCENT/{{missing_value}}/' "$test_dir/autopilots-original" >"$TEST_PACKAGE/common/autopilots.md"
deny; no_writes
cp "$test_dir/autopilots-original" "$TEST_PACKAGE/common/autopilots.md"
echo 'PASS followup: スクワッドかオートパイロットの値が不足したら、どちらにも書き込まない'
TEST_BAD_ROSTER=yes deny; no_writes
TEST_FAIL='squad member list' deny; no_writes
TEST_FAIL='agent list' deny; no_writes
echo 'PASS followup: 名簿・エージェントの取得失敗や不正な名簿は空集合と読み替えず止まる'
TEST_FAIL='squad update' deny; no_autopilot_writes
run
echo 'PASS followup: スクワッド更新の失敗を返し、再実行で続けられる'

reset_db
TEST_FAIL='squad member add' deny; no_autopilot_writes
run
[[ $(jq length "$TEST_DB/roster.json") == 18 ]]
echo 'PASS followup: メンバー追加の失敗後も、再実行で重複なく名簿がそろう'
reset_db
TEST_FAIL='autopilot trigger-add' deny
[[ $(jq length "$TEST_DB/autopilots.json") == 1 ]]
run
[[ $(jq length "$TEST_DB/autopilots.json") == 3 ]]
echo 'PASS followup: 作成後のトリガー追加で失敗しても、再実行で同じオートパイロットに追加する'
: >"$TEST_DB/calls"; TEST_BAD_AUTOPILOTS=yes deny; no_autopilot_writes
echo 'PASS followup: 不正なオートパイロット一覧を未作成と扱わず、重ねて作らない'

reset_db
export TEST_EXCLUDED='["planner","designer","claude-implementer","claude-fixer","code-reviewer","ux-reviewer","security-reviewer","performance-reviewer","qa","ci-monitor","usage-monitor","dependabot-merger"]'
run
jq -e 'length==9 and any(.[]; .member_id=="agent-codex-implementer")' "$TEST_DB/roster.json" >/dev/null
[[ $(jq length "$TEST_DB/autopilots.json") == 0 ]]
grep -qF 'この役の Webhook の登録は不要' "$test_dir/out"
echo 'PASS followup: 最小構成は3役と選んだ人間で、外した役のオートパイロットを作らない'
export TEST_EXCLUDED='[]'
reset_db
jq '.creator_id="another"' "$TEST_DB/squad.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/squad.json"
deny; no_writes
echo 'PASS followup: スクワッドの所有者が変わったときは設定の書き込みを行わない'

restore_completed one
jq 'map(if .assignee_id=="agent-security-reviewer" then .assignee_id="agent-planner" | .description="old" else . end)' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
export TEST_EXCLUDED='["planner"]'
run
jq -e 'any(.[]; .assignee_id=="agent-security-reviewer" and .description!="old")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS followup: 共有の現在の担当が外した自分の役でも、自分のものと照合して有効な担当へ直す'
export TEST_EXCLUDED='[]'
jq 'map(.description="old")' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
TEST_FAIL='autopilot update' deny
run
[[ $(jq length "$TEST_DB/autopilots.json") == 3 ]]
jq -e 'all(.[]; .description!="old")' "$TEST_DB/autopilots.json" >/dev/null
jq 'map(.cron_expression="0 0 * * *")' "$TEST_DB/triggers-auto-1.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/triggers-auto-1.json"
TEST_FAIL='autopilot trigger-update' deny
run
jq -e '.[0].cron_expression=="0 10 * * 1"' "$TEST_DB/triggers-auto-1.json" >/dev/null
echo 'PASS followup: オートパイロットとスケジュールの更新失敗を返し、再実行で ID を保って直す'

jq '.+[{id:"manual-a",title:"Manual demo",project_id:"project-a",assignee_type:"agent",assignee_id:"agent-usage-monitor",description:"Keep"}]' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
export TEST_EXCLUDED='["security-reviewer","usage-monitor","dependabot-merger"]'
TEST_FAIL='autopilot update' deny
run
jq -e 'length==4 and any(.[]; .id=="manual-a" and .description=="Keep") and all(.[]|select(.id!="manual-a"); .status=="paused")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS followup: 外した役の停止失敗を返し、再実行でも定義にない手動のオートパイロットを残す'

export TEST_EXCLUDED='[]'
restore_completed one
jq 'map(if .id=="agent-security-reviewer" then .owner_id="another" else . end)' "$TEST_DB/agents.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents.json"
export TEST_EXCLUDED='["security-reviewer"]'
run
jq -e 'any(.[]; .member_id=="agent-security-reviewer")' "$TEST_DB/roster.json" >/dev/null
jq -e 'any(.[]; .assignee_id=="agent-security-reviewer")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS followup: 外した役の完成名が同じでも所有者が違えば名簿とオートパイロットを変更しない'
jq -e 'all(.[]; contains("security-reviewer")|not)' "$TEST_DB/removed-targets.json" >/dev/null

