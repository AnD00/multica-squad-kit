#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/followup-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/package"
cp -R "$root/lib" "$root/common" "$test_dir/package/"
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(jq -nc --args '$ARGS.positional' -- "$@")" >>"$TEST_DB/calls"
option() { local key=$1; shift; while [[ $# -gt 0 ]]; do if [[ $1 == "$key" ]]; then printf '%s' "$2"; return; fi; shift; done; }
event="$1 $2"; [[ $event != 'squad member' ]] || event="$event $3"
[[ ${TEST_FAIL:-} != "$event" ]] || exit 71
case "$event" in
'repo list') printf '%s\n' '[{"url":"https://github.com/example/project"},{"url":"https://github.com/example/client"},{"url":"https://github.com/example/linked"}]' ;;
'agent list') cat "$TEST_DB/agents.json" ;;
'squad get') cat "$TEST_DB/squad.json" ;;
'squad update')
 jq --arg leader "$(option --leader "$@")" --arg instructions "$(option --instructions "$@")" '.leader_id=$leader | .instructions=$instructions' "$TEST_DB/squad.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/squad.json"; echo '{}' ;;
'squad member list')
 if [[ ${TEST_BAD_ROSTER:-no} == yes ]]; then echo '{}'; else cat "$TEST_DB/roster.json"; fi ;;
'squad member add')
 id=$(option --member-id "$@"); type=$(option --type "$@"); role=$(option --role "$@")
 jq -e --arg id "$id" --arg type "$type" 'all(.[]; .member_id!=$id or .member_type!=$type)' "$TEST_DB/roster.json" >/dev/null
 jq --arg id "$id" --arg type "$type" --arg role "$role" '.+[{member_id:$id,member_type:$type,role:$role}]' "$TEST_DB/roster.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/roster.json"; echo '{}' ;;
'squad member set-role')
 jq --arg id "$(option --member-id "$@")" --arg type "$(option --member-type "$@")" --arg role "$(option --role "$@")" 'map(if .member_id==$id and .member_type==$type then .role=$role else . end)' "$TEST_DB/roster.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/roster.json"; echo '{}' ;;
'squad member remove')
 jq --arg id "$(option --member-id "$@")" --arg type "$(option --type "$@")" 'map(select(.member_id!=$id or .member_type!=$type))' "$TEST_DB/roster.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/roster.json"; echo '{}' ;;
'autopilot list')
 if [[ ${TEST_BAD_AUTOPILOTS:-no} == yes ]]; then echo '{"autopilots":null}'; else jq '{autopilots:.,total:length}' "$TEST_DB/autopilots.json"; fi ;;
'autopilot get') jq --arg id "$3" --arg transfer "${TEST_TRANSFER_AUTO:-}" '{autopilot:(.[]|select(.id==$id)|if .id==$transfer then .assignee_id="foreign-agent" else . end),triggers:[]}' "$TEST_DB/autopilots.json" ;;
'autopilot create')
 n=$(cat "$TEST_DB/next"); echo $((n+1)) >"$TEST_DB/next"; id=auto-$n
 jq -n --arg id "$id" --arg title "$(option --title "$@")" --arg description "$(option --description "$@")" --arg mode "$(option --mode "$@")" --arg project "$(option --project "$@")" --arg assignee "$(option --agent "$@")" '{id:$id,title:$title,description:$description,execution_mode:$mode,project_id:$project,assignee_type:"agent",assignee_id:$assignee,status:"active"}' >"$TEST_DB/created"
 jq --slurpfile created "$TEST_DB/created" '.+$created' "$TEST_DB/autopilots.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/autopilots.json"; echo '[]' >"$TEST_DB/triggers-$id.json"; cat "$TEST_DB/created" ;;
'autopilot update')
 [[ ${TEST_FAIL_PAUSE:-no} != yes || $(option --status "$@") != paused ]] || exit 73
 jq --arg id "$3" --arg description "$(option --description "$@")" --arg mode "$(option --mode "$@")" --arg project "$(option --project "$@")" --arg assignee "$(option --agent "$@")" --arg status "$(option --status "$@")" 'map(if .id==$id then
  (if $description!="" then .description=$description else . end) |
  (if $mode!="" then .execution_mode=$mode else . end) |
  (if $project!="" then .project_id=$project else . end) |
  (if $assignee!="" then .assignee_id=$assignee else . end) |
  (if $status!="" then .status=$status else . end)
 else . end)' "$TEST_DB/autopilots.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/autopilots.json"; echo '{}' ;;
'autopilot delete') jq --arg id "$3" 'map(select(.id!=$id))' "$TEST_DB/autopilots.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/autopilots.json"; echo '{}' ;;
'autopilot trigger-list') jq '{triggers:.,total:length}' "$TEST_DB/triggers-$3.json" ;;
'autopilot trigger-add')
 if [[ $(option --kind "$@") == webhook ]]; then
  jq --arg id "webhook-$3" '.+[{id:$id,kind:"webhook",enabled:true}]' "$TEST_DB/triggers-$3.json" >"$TEST_DB/new"
  mv "$TEST_DB/new" "$TEST_DB/triggers-$3.json"; echo '{}'; exit
 fi
 [[ $(option --kind "$@") == schedule ]]
 jq --arg id "schedule-$3" --arg cron "$(option --cron "$@")" --arg timezone "$(option --timezone "$@")" '.+[{id:$id,kind:"schedule",cron_expression:$cron,timezone:$timezone,enabled:true}]' "$TEST_DB/triggers-$3.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/triggers-$3.json"; echo '{}' ;;
'autopilot trigger-update')
 jq --arg id "$4" --arg cron "$(option --cron "$@")" --arg timezone "$(option --timezone "$@")" 'map(if .id==$id then .+{cron_expression:$cron,timezone:$timezone} else . end)' "$TEST_DB/triggers-$3.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/triggers-$3.json"; echo '{}' ;;
*) echo "Unexpected call: $*" >&2; exit 90 ;;
esac
STUB
chmod +x "$test_dir/bin/multica"
printf '#!/bin/bash\necho "Unexpected gh call" >&2\nexit 90\n' >"$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
source "$root/lib/check.sh"
source "$root/lib/answers.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/webhooks.sh"
source "$root/lib/installation.sh"
source "$root/lib/squad.sh"
source "$root/lib/autopilots.sh"
project_work=$TEST_DB/work
mkdir -p "$project_work"
server_url=https://example.test
workspace_id=workspace-a
project_id=project-a
project_key=demo
member_key=owner
host_owner_id=actor
squad_id=squad-a
people='[{"user_id":"actor","name":"Owner"},{"user_id":"person-b","name":"Reader"}]'
member_ids='["actor","person-b"]'
excluded_roles=${TEST_EXCLUDED:-[]}
repo_names=${TEST_REPOSITORIES:-'["example/project"]'}
selected_repositories=$(jq 'map({repository:.})' <<<"$repo_names")
repositories=$(jq 'map(.+{url:("https://github.com/"+.repository)})' <<<"$selected_repositories")
resolve_link_repositories
# エージェントの指示はこの試験の入力。同じ構成の準備だけを再利用する。
# 試験対象の squad/autopilots の展開と DB の読み書きは毎回本体を通す。
fixture_key=$(printf '%s\n' "$excluded_roles" "$repo_names" | shasum -a 256 | cut -d ' ' -f 1)
fixture=$TEST_FIXTURES/$fixture_key
if [[ ! -d $fixture ]]; then
mkdir -p "$fixture"
saved_work=$project_work
project_work=$fixture
records='{}'; enabled=''
for role in $template_roles; do
 if ! jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles"; then
  enabled+=" $role"
  records=$(jq -c --arg role "$role" '.+{($role):{id:("agent-"+$role),name:("demo-"+$role+"-owner")}}' <<<"$records")
 fi
done
jq -n --argjson records "$records" --argjson repos "$selected_repositories" '{project_id:"project-a",project_key:"demo",project_name:"Demo",member_key:"owner",member_name:"Owner",repository:$repos[0].repository,repositories:($repos|map("`"+.repository+"`")|join("、")),squad_id:"squad-a",squad_mention:"[@Demo](mention://squad/squad-a)",owner_mention:"[@Owner](mention://member/actor)",model:"model-for-test",thinking_level:"high"} |
 reduce ($records|to_entries[]) as $r (.; .["agent."+$r.key+".name"]=$r.value.name | .["agent."+$r.key+".id"]=$r.value.id | .["agent."+$r.key+".mention"]=("[@Role](mention://agent/"+$r.value.id+")"))' >"$project_work/values.json"
for role in $enabled; do
 template_filter "$enabled" "$root/common/agents/$role.md" >"$project_work/filter"
 template_apply "$project_work/values.json" "$project_work/filter" >"$project_work/$role.rendered"
done
printf '%s\n' "$records" >"$fixture/records.json"
printf '%s\n' "$enabled" >"$fixture/enabled"
project_work=$saved_work
fi
records=$(cat "$fixture/records.json")
enabled=$(cat "$fixture/enabled")
dependabot_webhook=${TEST_WEBHOOK:-true}
cp "$fixture/values.json" "$fixture/"*.rendered "$project_work/"
created_agents=0; created_squads=0; created_autopilots=0
project_name=Demo; workspace_name="Workspace A"; agent_home="$TEST_DB/agent home"
setup_removed_targets='[]'
complete_project
printf '%s\n' "$setup_removed_targets" >"$TEST_DB/removed-targets.json"
project_completion
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package" TEST_DB="$test_dir/db" TEST_FIXTURES="$test_dir/fixtures"
source "$root/lib/render.sh"
reset_db() {
 rm -rf "$TEST_DB"; mkdir -p "$TEST_DB"
 jq -n --arg roles "$template_roles" '[($roles|split(" ")[]) as $role | {id:("agent-"+$role),name:("demo-"+$role+"-owner"),owner_id:"actor"}]+[{id:"other-agent",name:"other-planner-owner",owner_id:"actor"}]' >"$TEST_DB/agents.json"
 echo '{"id":"squad-a","creator_id":"actor","leader_id":"agent-orchestrator","instructions":"old","description":"Keep description"}' >"$TEST_DB/squad.json"
 echo '[{"member_type":"agent","member_id":"agent-orchestrator","role":"leader"},{"member_type":"agent","member_id":"other-agent","role":"keep"},{"member_type":"member","member_id":"extra-person","role":"manual expertise"}]' >"$TEST_DB/roster.json"
 echo '[]' >"$TEST_DB/autopilots.json"; echo 1 >"$TEST_DB/next"; : >"$TEST_DB/calls"
}
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then echo 'unexpected success'; exit 1; fi; [[ -s $test_dir/err ]]; ! grep -q '今回作った件数' "$test_dir/out"; }
no_writes() { ! jq -es 'any(.[]; .[1]=="update" or .[1]=="create" or .[1]=="delete" or .[1]=="trigger-add" or .[1]=="trigger-update" or (.[1]=="member" and .[2]!="list"))' "$TEST_DB/calls" >/dev/null; }
no_autopilot_writes() { ! jq -es 'any(.[]; .[0]=="autopilot" and (.[1]=="create" or .[1]=="update" or .[1]=="delete" or .[1]=="trigger-add" or .[1]=="trigger-update"))' "$TEST_DB/calls" >/dev/null; }
reset_db
run
jq -e '.leader_id=="agent-orchestrator" and (.instructions|contains("agent-orchestrator")) and .description=="Keep description"' "$TEST_DB/squad.json" >/dev/null
jq -e 'length==16 and any(.[]; .member_id=="person-b" and .member_type=="member") and any(.[]; .member_id=="other-agent" and .role=="keep") and any(.[]; .member_id=="extra-person" and .role=="manual expertise") and all(.[]; .member_id!="agent-ci-monitor" and .member_id!="agent-usage-monitor" and .member_id!="agent-dependabot-merger")' "$TEST_DB/roster.json" >/dev/null
echo 'PASS followup: 作成済みの器へ指示と有効な12役・選んだ人間を合わせ、見張りを入れず、手で加えたメンバーを保つ'
jq -e 'length==3 and all(.[]; .project_id=="project-a") and any(.[]; .title=="使用上限の見張り demo-owner" and .execution_mode=="run_only") and any(.[]; .assignee_id=="agent-security-reviewer" and .execution_mode=="create_issue") and any(.[]; .assignee_id=="agent-dependabot-merger" and .execution_mode=="run_only")' "$TEST_DB/autopilots.json" >/dev/null
[[ $(jq -sr '[.[][] | select(.kind=="schedule" and .timezone=="Asia/Tokyo")]|length' "$TEST_DB"/triggers-*.json) == 3 ]]
jq -e '.[0].cron_expression=="0 10 * * 1"' "$TEST_DB/triggers-auto-1.json" >/dev/null
jq -e '.[0].cron_expression=="0 10 * * 2"' "$TEST_DB/triggers-auto-2.json" >/dev/null
jq -e '.[0].cron_expression=="*/30 * * * *"' "$TEST_DB/triggers-auto-3.json" >/dev/null
grep -qF '今回作った件数: エージェント 0 件、スクワッド 0 件、オートパイロット 3 件' "$test_dir/out"
for index in $(seq 0 3); do grep -qF "オートパイロット $index/3" "$test_dir/err"; done
echo 'PASS progress: 選んだオートパイロットの件数に合わせ、0から設定中の位置を表示する'

for message in '表示した issue を対象のプロジェクトで開き' 'skeleton/' 'Dependabot のイベントフィルター' '人間が行う Webhook の登録' 'CLAUDE_CONFIG_DIR=' 'CODEX_HOME='; do grep -qF "$message" "$test_dir/out"; done
! grep -qF 'Multica の画面で、スクワッド' "$test_dir/out"
! grep -qF '選んだ各リポジトリに Dependabot の Webhook を登録してください' "$test_dir/out"
echo 'PASS completion: 作成件数と起票された issue・ひな形・残る Webhook の手順・ログインを案内し、自動の作業を手で頼まない'
TEST_WEBHOOK=false run
grep -qF 'Dependabot の PR は週次のスケジュールだけで扱うため、Webhook の登録は不要です。' "$test_dir/out"
! grep -qF '人間が行う Webhook の登録' "$test_dir/out" || exit 1
echo 'PASS completion: Webhook を使わない答えなら、週次だけで扱い登録は不要と案内する'
echo 'PASS followup: 3つのオートパイロットを実 ID・指示・実行モード・プロジェクト・時刻とタイムゾーンで登録する'
# 後続ケースの初期状態は、ここで実際に作って検証したものを複製する。
cp -R "$TEST_DB" "$test_dir/completed-one"
restore_completed() {
 rm -rf "$TEST_DB"
 cp -R "$test_dir/completed-$1" "$TEST_DB"
}
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
[[ $(jq length "$TEST_DB/roster.json") == 16 ]]
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
jq -e 'length==7 and any(.[]; .member_id=="agent-codex-implementer")' "$TEST_DB/roster.json" >/dev/null
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
grep -qF '今回作った件数: エージェント 0 件、スクワッド 0 件、オートパイロット 5 件' "$test_dir/out"
grep -qF 'オートパイロット 5/5 を設定中' "$test_dir/err"
echo 'PASS completion: 二リポジトリの実作成5件を数え、予定数や更新した数に置き換えない'
echo 'PASS autopilots: リポジトリごとに二種類を一つずつ作り、指示と実 ID・モード・スケジュールを分け、使用上限は一つに保つ'
cp -R "$TEST_DB" "$test_dir/completed-two"

cp "$TEST_DB/autopilots.json" "$test_dir/two-repos"
: >"$TEST_DB/calls"; run; no_writes
TEST_REPOSITORIES='["example/project","example/client","example/third"]' run
[[ $(jq length "$TEST_DB/autopilots.json") == 7 ]]
grep -qF '今回作った件数: エージェント 0 件、スクワッド 0 件、オートパイロット 2 件' "$test_dir/out"
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

# スケジュールなしの拡張を、実際の登録処理へ渡す。
export TEST_EXCLUDED='[]' TEST_REPOSITORIES='["example/project"]'
cat >>"$TEST_PACKAGE/common/autopilots.md" <<'WEBHOOK'

## Issue events {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.orchestrator.name}}
- 実行: `run_only`
- トリガー: `webhook`

```text
{{repository}} の issue のイベントを扱う。
```
WEBHOOK
reset_db
run
webhook_auto=$(jq -r '.[]|select(.title=="Issue events demo example/project")|.id' "$TEST_DB/autopilots.json")
[[ -n $webhook_auto ]]
jq -e 'length==1 and .[0].kind=="webhook"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
! jq -es --arg id "$webhook_auto" 'any(.[]; .[0:3]==["autopilot","trigger-add",$id] and index("schedule")!=null)' "$TEST_DB/calls" >/dev/null
# 手で設定したフィルターや停止状態、URL 用の値を、再実行で替えない。
jq '.[0]+={enabled:false,event_filter:{issues:["edited"]},webhook_token:"private-fixture"}' "$TEST_DB/triggers-$webhook_auto.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/triggers-$webhook_auto.json"
cp "$TEST_DB/triggers-$webhook_auto.json" "$test_dir/webhook-before"
: >"$TEST_DB/calls"
run
no_autopilot_writes
cmp "$test_dir/webhook-before" "$TEST_DB/triggers-$webhook_auto.json"
echo 'PASS webhook: スケジュールなしで作り、再実行で ID・URL 用の値・フィルター・停止状態を保つ'

# 作成後のトリガー追加が失敗しても、同じオートパイロットで再開する。
echo '[]' >"$TEST_DB/triggers-$webhook_auto.json"
TEST_FAIL='autopilot trigger-add' deny
[[ $(jq length "$TEST_DB/autopilots.json") == 4 ]]
run
jq -e 'length==1 and .[0].kind=="webhook"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
echo 'PASS webhook: 追加失敗を返し、同じ ID へ一つだけトリガーを追加して復旧する'

# 意図しない定期実行が残る場合は、削除も成功扱いもせずに止まる。
echo '[{"id":"manual-schedule","kind":"schedule"}]' >"$TEST_DB/triggers-$webhook_auto.json"
deny
grep -q '既存のスケジュールがあります' "$test_dir/err"
jq -e 'length==1 and .[0].id=="manual-schedule"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
echo 'PASS webhook: 既存のスケジュールがある場合は人間へ返し、手動のトリガーを消さない'

# リポジトリ単位の拡張も、紐付け専用の一覧には展開しない。
for title in 'Project scan' 'Project report'; do
 cat >>"$TEST_PACKAGE/common/autopilots.md" <<SCHEDULE

## $title {{project_key}} {{repository}}

- 範囲: \`repository\`
- 担当: {{agent.orchestrator.name}}
- 実行: \`run_only\`
- スケジュール: \`0 0 * * 1\`（Asia/Tokyo）

\`\`\`text
{{repository}} を確認する。
\`\`\`
SCHEDULE
done
reset_db
run
jq -e 'length==6' "$TEST_DB/autopilots.json" >/dev/null
cp "$TEST_DB/autopilots.json" "$test_dir/one-code"
printf '["example/linked"]\n' >"$TEST_PACKAGE/extension-link-repositories.json"
: >"$TEST_DB/calls"; run; no_autopilot_writes
cmp "$test_dir/one-code" "$TEST_DB/autopilots.json"
! jq -es 'any(.[]; any(.[]; type=="string" and contains("example/linked")))' "$TEST_DB/calls" >/dev/null
[[ $(jq -sr '[.[][]|select(.kind=="webhook")]|length' "$TEST_DB"/triggers-*.json) == 1 ]]
echo 'PASS scope: 紐付け先を追加しても単一選択の6件と Webhook 1件を保ち、追加先の定期処理を作らない'
rm "$TEST_PACKAGE/extension-link-repositories.json"
reset_db
TEST_REPOSITORIES='["example/project","example/client"]' run
jq -e 'length==11' "$TEST_DB/autopilots.json" >/dev/null
[[ $(jq -sr '[.[][]|select(.kind=="webhook")]|length' "$TEST_DB"/triggers-*.json) == 2 ]]
echo 'PASS scope: 追加指定なしの二選択は従来どおり11件と Webhook 2件を作る'
