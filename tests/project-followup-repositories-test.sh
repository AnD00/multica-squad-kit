#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-followup-test-lib.sh"

export TEST_EXCLUDED='[]' TEST_REPOSITORIES='["example/project","example/client"]'
reset_db
run
jq -e 'length==5 and ([.[]|select(.title=="使用上限の見張り demo-owner")]|length)==1' "$TEST_DB/autopilots.json" >/dev/null
for repo in example/project example/client; do
 for role in security-reviewer dependabot-merger; do
  jq -e --arg repo "$repo" --arg role "agent-$role" 'any(.[]; (.title|endswith(" "+$repo)) and .assignee_id==$role and (.description|startswith($repo+" の")))' "$TEST_DB/autopilots.json" >/dev/null
 done
done
[[ $(jq -sr '[.[][] | select(.kind=="schedule")]|length' "$TEST_DB"/triggers-*.json) == 5 ]]
cmp "$TEST_DB/triggers-auto-1.json" <(jq 'map(.id="schedule-auto-1")' "$TEST_DB/triggers-auto-4.json")
cmp "$TEST_DB/triggers-auto-2.json" <(jq 'map(.id="schedule-auto-2")' "$TEST_DB/triggers-auto-5.json")
jq -e 'all(.[]|select(.assignee_id=="agent-security-reviewer"); (.description|contains("--key repository --value example/")) and (.description|contains("--status backlog")))' "$TEST_DB/autopilots.json" >/dev/null
grep -qE '^✔ .*  \+5 オートパイロット$' "$test_dir/out"
! grep -qE '^✔ .*(エージェント|スクワッド)' "$test_dir/out"
grep -qF 'オートパイロット 5/5 を設定中' "$test_dir/err"
echo 'PASS completion: 二リポジトリの実作成5件を数え、予定数や更新した数に置き換えない'
echo 'PASS autopilots: リポジトリごとに二種類を一つずつ作り、指示と実 ID・モード・スケジュールを分け、使用上限は一つに保つ'
cp -R "$TEST_DB" "$test_dir/completed-two"

cp "$TEST_DB/autopilots.json" "$test_dir/two-repos"
: >"$TEST_DB/calls"; run; no_writes
TEST_REPOSITORIES='["example/project","example/client","example/third"]' run
[[ $(jq length "$TEST_DB/autopilots.json") == 7 ]]
grep -qE '^✔ .*  \+2 オートパイロット$' "$test_dir/out"
! grep -qE '^✔ .*(エージェント|スクワッド)' "$test_dir/out"
jq -e --slurpfile before "$test_dir/two-repos" '. as $after|all($before[0][]; . as $old|any($after[]; .==$old))' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS autopilots: 同じ選択では書かず、追加したリポジトリの分だけ作り、既存の ID と指示を保つ'

# 管理対象の第三リポジトリを外す。他人の担当と別プロジェクト・手動名は保つ。
jq 'map(if .id=="auto-6" then .assignee_id="foreign-agent" else . end)+[{id:"foreign-project",title:"Dependabot の PR の週次の確認 demo example/elsewhere",project_id:"elsewhere",assignee_type:"agent",assignee_id:"agent-dependabot-merger",status:"active"},{id:"manual",title:"Dependabot の PR の週次の確認 demo example/not-a-repo manual",project_id:"project-a",assignee_type:"agent",assignee_id:"agent-dependabot-merger",status:"active"}]' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
run
jq -e 'any(.[]; .id=="auto-7" and .status=="paused") and all(.[]|select(.id=="auto-6" or .id=="foreign-project" or .id=="manual"); .status=="active")' "$TEST_DB/autopilots.json" >/dev/null
grep -q '一時停止しています.*Dependabot.*example/third' "$test_dir/err"
jq -e '.[0]=="Dependabot の PR の週次の確認 demo example/third" and length==1' "$TEST_DB/removed-targets.json" >/dev/null
echo 'PASS autopilots: 外したリポジトリを一時停止し、別の人の担当・別プロジェクト・手動の名前は変えない'

restore_completed two
cp "$TEST_DB/autopilots.json" "$test_dir/before-remove"
cp "$TEST_DB/triggers-auto-4.json" "$test_dir/removed-trigger"
export TEST_REPOSITORIES='["example/project"]'
run
[[ $(jq length "$TEST_DB/autopilots.json") == 5 ]]
jq -e 'all(.[]|select(.title|endswith(" example/client")); .status=="paused") and all(.[]|select(.title|endswith(" example/project")); .status=="active")' "$TEST_DB/autopilots.json" >/dev/null
jq -e --slurpfile before "$test_dir/before-remove" 'map(del(.status))==($before[0]|map(del(.status)))' "$TEST_DB/autopilots.json" >/dev/null
cmp "$test_dir/removed-trigger" "$TEST_DB/triggers-auto-4.json"
[[ $(grep -c '一時停止しています.*example/client' "$test_dir/err") == 2 ]]
: >"$TEST_DB/calls"; run; no_writes
TEST_REPOSITORIES='["example/project","example/client"]' run
jq -e 'all(.[]|select(.title|endswith(" example/client")); .status=="paused")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS autopilots: 外した二種類の ID・指示・トリガーを保ち、繰り返しても重ねて止めず、再選択でも既存の停止状態を勝手に変えない'

export TEST_REPOSITORIES='["example/project","example/client"]'
restore_completed two
export TEST_REPOSITORIES='["example/project"]'
TEST_FAIL_PAUSE=yes deny
[[ $(jq length "$TEST_DB/autopilots.json") == 5 ]]
run
jq -e 'all(.[]|select(.title|endswith(" example/client")); .status=="paused")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS autopilots: 一時停止の失敗を返し、再実行では履歴を消さず残った停止を反映する'

export TEST_REPOSITORIES='["example/project","example/client"]'
restore_completed two
export TEST_REPOSITORIES='["example/project"]'
: >"$TEST_DB/calls"
TEST_TRANSFER_AUTO=auto-4 deny
no_autopilot_writes
echo 'PASS autopilots: 一時停止直前の読み直しで担当が変われば、書き込まず失敗として返す'

export TEST_EXCLUDED='["security-reviewer","usage-monitor","dependabot-merger"]'
run
jq -e 'length==5 and all(.[]; .status=="paused")' "$TEST_DB/autopilots.json" >/dev/null
echo 'PASS autopilots: 役も同時に外したとき、すべてを停止し、履歴を保持する'

