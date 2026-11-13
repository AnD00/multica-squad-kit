#!/usr/bin/env bash
# project-followup のテストが読み込む準備と、検証済みの登録状態。単独では実行しない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/followup-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
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
deny() { if run; then echo 'unexpected success'; exit 1; fi; [[ -s $test_dir/err ]]; ! grep -q '^✔ ' "$test_dir/out"; }
no_writes() { ! jq -es 'any(.[]; .[1]=="update" or .[1]=="create" or .[1]=="delete" or .[1]=="trigger-add" or .[1]=="trigger-update" or (.[1]=="member" and .[2]!="list"))' "$TEST_DB/calls" >/dev/null; }
no_autopilot_writes() { ! jq -es 'any(.[]; .[0]=="autopilot" and (.[1]=="create" or .[1]=="update" or .[1]=="delete" or .[1]=="trigger-add" or .[1]=="trigger-update"))' "$TEST_DB/calls" >/dev/null; }

restore_completed() {
 rm -rf "$TEST_DB"
 cp -R "$test_dir/completed-$1" "$TEST_DB"
}

followup_completed_one() {
reset_db
run
jq -e '.leader_id=="agent-orchestrator" and (.instructions|contains("agent-orchestrator")) and .description=="Keep description"' "$TEST_DB/squad.json" >/dev/null
jq -e 'length==18 and any(.[]; .member_id=="person-b" and .member_type=="member") and any(.[]; .member_id=="other-agent" and .role=="keep") and any(.[]; .member_id=="extra-person" and .role=="manual expertise") and all(.[]; .member_id!="agent-ci-monitor" and .member_id!="agent-usage-monitor" and .member_id!="agent-dependabot-merger")' "$TEST_DB/roster.json" >/dev/null
echo 'PASS followup: 作成済みの器へ指示と有効な12役・選んだ人間を合わせ、見張りを入れず、手で加えたメンバーを保つ'
jq -e 'length==3 and all(.[]; .project_id=="project-a") and any(.[]; .title=="使用上限の見張り demo-owner" and .execution_mode=="run_only") and any(.[]; .assignee_id=="agent-security-reviewer" and .execution_mode=="create_issue") and any(.[]; .assignee_id=="agent-dependabot-merger" and .execution_mode=="run_only")' "$TEST_DB/autopilots.json" >/dev/null
[[ $(jq -sr '[.[][] | select(.kind=="schedule" and .timezone=="Asia/Tokyo")]|length' "$TEST_DB"/triggers-*.json) == 3 ]]
jq -e '.[0].cron_expression=="0 10 * * 1"' "$TEST_DB/triggers-auto-1.json" >/dev/null
jq -e '.[0].cron_expression=="0 10 * * 2"' "$TEST_DB/triggers-auto-2.json" >/dev/null
jq -e '.[0].cron_expression=="*/30 * * * *"' "$TEST_DB/triggers-auto-3.json" >/dev/null
grep -qE '^✔ .*  \+3 オートパイロット$' "$test_dir/out"
! grep -qE '^✔ .*(エージェント|スクワッド)' "$test_dir/out"
for index in $(seq 0 3); do grep -qF "オートパイロット $index/3" "$test_dir/err"; done
echo 'PASS progress: 選んだオートパイロットの件数に合わせ、0から設定中の位置を表示する'

for message in '表示したタスクを対象のプロジェクトで開き' 'skeleton/' 'Dependabot のイベントフィルター' '人間が行う Webhook の登録' 'CLAUDE_CONFIG_DIR=' 'CODEX_HOME='; do grep -qF "$message" "$test_dir/out"; done
! grep -qF 'Multica の画面で、スクワッド' "$test_dir/out"
! grep -qF '選んだ各リポジトリに Dependabot の Webhook を登録してください' "$test_dir/out"
echo 'PASS completion: 作成件数と起票されたタスク・ひな形・残る Webhook の手順・ログインを案内し、自動の作業を手で頼まない'
TEST_WEBHOOK=false run
grep -qF 'Dependabot の PR は週次のスケジュールだけで扱うため、Webhook の登録は不要です。' "$test_dir/out"
! grep -qF '人間が行う Webhook の登録' "$test_dir/out" || exit 1
echo 'PASS completion: Webhook を使わない答えなら、週次だけで扱い登録は不要と案内する'
echo 'PASS followup: 3つのオートパイロットを実 ID・指示・実行モード・プロジェクト・時刻とタイムゾーンで登録する'
# 後続ケースの初期状態は、ここで実際に作って検証したものを複製する。
cp -R "$TEST_DB" "$test_dir/completed-one"
}
