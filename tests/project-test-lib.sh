#!/usr/bin/env bash
# project-*-test.sh が読み込む共通の準備（スタブ・ドライバー・補助関数）。単独では実行しない。
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/project-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/package"
cp "$root/VERSION" "$test_dir/package/VERSION"
cp -R "$root/lib" "$root/common" "$root/skeleton" "$test_dir/package/"
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=$(jq -nc --args '$ARGS.positional' -- "$@")
printf '%s\n' "$args" >>"$TEST_DB/calls"
option() { local key=$1; shift; while [[ $# -gt 0 ]]; do if [[ $1 == "$key" ]]; then printf '%s' "$2"; return; fi; shift; done; }
event="$1 $2"; [[ $event != "agent env" && $event != 'project resource' && $event != 'agent skills' ]] || event="$event $3"
[[ ${TEST_FAIL:-} != "$event" ]] || exit 71
case "$event" in
'user profile') echo '{"id":"actor"}' ;;
'workspace member') echo '[{"user_id":"actor","name":"Owner"}]' ;;
'repo list')
 if [[ ${TEST_REPO_REMOVED:-no} == yes && -f $TEST_DB/repo-read ]]; then printf '%s\n' "$TEST_SELECTED_REPOSITORIES"
 else printf '%s\n' "${TEST_REGISTERED_REPOSITORIES:-$TEST_SELECTED_REPOSITORIES}"; fi
 touch "$TEST_DB/repo-read" ;;
'project list')
 if [[ -f $TEST_DB/selection-ready ]]; then
  if [[ -f $TEST_DB/actual-project-ready ]]; then
   [[ ${TEST_RECHECK_FAIL_LIST:-no} != yes ]] || exit 71
   if [[ -n ${TEST_RECHECK_LIST:-} ]]; then printf '%s\n' "$TEST_RECHECK_LIST"; exit; fi
  fi
  if [[ ${TEST_RECHECK_NEW_NEIGHBOR:-no} == yes ]]; then
   echo '{"id":"new-neighbor","title":"New Neighbor"}' >"$TEST_DB/projects/neighbor.json"
  fi
 fi
 jq -s . "$TEST_DB"/projects/*.json ;;
'project get') touch "$TEST_DB/actual-project-ready"; cat "$TEST_DB/projects/$3.json" ;;
'project create')
 jq -n --arg title "$(option --title "$@")" --arg description "$(option --description "$@")" '{id:"project-a",title:$title,description:$description}' >"$TEST_DB/projects/project-a.json"
 jq -n --arg url "$(option --repo "$@")" '[{id:"resource-a",resource_type:"github_repo",resource_ref:{url:$url}}]' >"$TEST_DB/resources.json"
 touch "$TEST_DB/actual-project-ready"
 cat "$TEST_DB/projects/project-a.json" ;;
'project update')
 jq --arg description "$(option --description "$@")" '.description=$description' "$TEST_DB/projects/$3.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/projects/$3.json"; cat "$TEST_DB/projects/$3.json" ;;
'project resource list')
 if [[ $4 != project-a ]]; then
  if [[ ${TEST_RECHECK_AFTER_GUARD:-no} == yes && ! -f $TEST_DB/guard-checked ]]; then echo '[]'; exit; fi
  if [[ -f $TEST_DB/selection-ready ]]; then
   [[ ${TEST_RECHECK_FAIL_RESOURCES:-no} != yes ]] || exit 71
   if [[ ${TEST_RECHECK_NEW_NEIGHBOR:-no} == yes && $4 != new-neighbor ]]; then echo '[]'
   else printf '%s\n' "${TEST_RECHECK_RESOURCES:-[]}"; fi
  else printf '%s\n' "${TEST_OTHER_RESOURCES:-[]}"; fi
 elif [[ -n ${TEST_RESOURCE_RESPONSE:-} ]]; then printf '%s\n' "$TEST_RESOURCE_RESPONSE"
 else cat "$TEST_DB/resources.json"; fi ;;
'project resource add')
 url=$(option --url "$@")
 [[ ${TEST_FAIL_REPO:-} != "$url" ]] || exit 72
 jq --arg url "$url" '.+[{id:("resource-"+(length|tostring)),resource_type:"github_repo",resource_ref:{url:$url}}]' "$TEST_DB/resources.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/resources.json"; echo '{}' ;;
'agent list') jq -s . "$TEST_DB"/agents/*.json ;;
'agent get') cat "$TEST_DB/agents/$3.json" ;;
'agent create')
	grep -qF "エージェント 0/${TEST_ROLE_COUNT}（ID の準備）" "${TEST_DB%/*}/err"
 [[ -f $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
 jq -ne --argjson selected "$TEST_SELECTED_REPOSITORIES" --argjson expected "${TEST_EXPECTED_ALLOWED:-null}" --rawfile allowed "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" '($expected // ($selected|map(.repository|ascii_downcase))|unique|sort)==($allowed|split("\n")|map(select(length>0))|unique|sort)' >/dev/null
 [[ -f $TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv ]]
 [[ $(option --permission-mode "$@") == private ]]
 [[ $(option --instructions "$@") == *停止* && $(option --instructions "$@") != *'{{'* ]]
 name=$(option --name "$@"); id="agent-$name"
 envfile=$(option --custom-env-file "$@")
 [[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$envfile") == 600 ]]
 jq -e --arg z "$TEMPLATE_AGENT_HOME/template/shell/project-a" '.ZDOTDIR==$z and .BASH_ENV==($z+"/env.sh") and (.SQUAD_KIT_ALLOWED_REPOS|endswith("/allowed-repos.d/project-a"))' "$envfile" >/dev/null
 jq -e --arg model "$(option --model "$@")" --arg z "$TEMPLATE_AGENT_HOME/template/shell/project-a" 'if ($model|startswith("claude-")) then .CLAUDE_ENV_FILE==($z+"/env.sh") else .CLAUDE_ENV_FILE==null end' "$envfile" >/dev/null
 custom_args=$(option --custom-args "$@")
 jq -ne --arg model "$(option --model "$@")" --argjson args "$custom_args" '$args == (if ($model|startswith("gpt-")) then ["-c","allow_login_shell=false","-c","features.shell_snapshot=false"] else [] end)' >/dev/null
 cp "$envfile" "$TEST_DB/env/$id.json"
 jq -n --arg id "$id" --arg name "$name" --arg model "$(option --model "$@")" --arg runtime "$(option --runtime-id "$@")" --arg thinking "$(option --thinking-level "$@")" --arg instructions "$(option --instructions "$@")" --argjson max "$(option --max-concurrent-tasks "$@")" --argjson args "$custom_args" '{id:$id,name:$name,owner_id:"actor",model:$model,runtime_id:$runtime,thinking_level:$thinking,instructions:$instructions,max_concurrent_tasks:$max,permission_mode:"private",invocation_targets:[],skills:[],custom_args:$args}' >"$TEST_DB/agents/$id.json"
 cat "$TEST_DB/agents/$id.json" ;;
'agent env get') jq '{custom_env:.}' "$TEST_DB/env/$4.json" ;;
'agent env set') cp "$(option --custom-env-file "$@")" "$TEST_DB/env/$4.json"; echo '{}' ;;
'agent update')
 id=$3
 if [[ " $* " == *' --instructions '* ]]; then
  # 全有効役とスクワッドの実 ID が、この時点ですでに存在する。
  [[ $(find "$TEST_DB/agents" -name 'agent-demo-*.json' | wc -l | tr -d ' ') == "$TEST_ROLE_COUNT" ]]
  [[ -f $TEST_DB/squad.json ]]
  jq --arg instructions "$(option --instructions "$@")" --arg description "$(option --description "$@")" --arg model "$(option --model "$@")" --arg runtime "$(option --runtime-id "$@")" --arg thinking "$(option --thinking-level "$@")" --argjson max "$(option --max-concurrent-tasks "$@")" --argjson mcp "$(option --mcp-config "$@")" --argjson args "$(option --custom-args "$@")" '.+{instructions:$instructions,description:$description,model:$model,runtime_id:$runtime,thinking_level:$thinking,max_concurrent_tasks:$max,mcp_config:$mcp,custom_args:$args}' "$TEST_DB/agents/$id.json" >"$TEST_DB/new"
 else
  # 最初の公開の前に、全役の本指示とスキルの反映が終わっている。
  jq -es 'all(.[] | select(.name|startswith("demo-")); (.instructions|contains("このプロジェクトの値")))' "$TEST_DB"/agents/*.json >/dev/null
  jq '.+{permission_mode:"public_to",invocation_targets:[{target_type:"workspace"}]}' "$TEST_DB/agents/$id.json" >"$TEST_DB/new"
 fi
 mv "$TEST_DB/new" "$TEST_DB/agents/$id.json"; echo '{}' ;;
'agent skills set')
 jq --arg ids "$(option --skill-ids "$@")" '.skills=($ids|split(",")|map(select(length>0)|{id:.}))' "$TEST_DB/agents/$4.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/agents/$4.json"; echo '{}' ;;
'squad list') if [[ -f $TEST_DB/squad.json ]]; then jq '[.]' "$TEST_DB/squad.json"; else echo '[]'; fi ;;
'squad get') cat "$TEST_DB/squad.json" ;;
'squad create')
 [[ -f $TEST_DB/agents/$(option --leader "$@").json ]]
 jq -n --arg name "$(option --name "$@")" --arg leader "$(option --leader "$@")" '{id:"squad-a",name:$name,creator_id:"actor",leader_id:$leader,instructions:"",members:[]}' >"$TEST_DB/squad.json"
 cat "$TEST_DB/squad.json" ;;
'skill list') jq -s . "$TEST_DB"/skills/*.json ;;
'skill get') jq -s --arg id "$3" '.[] | select(.id==$id)' "$TEST_DB"/skills/*.json ;;
'skill import')
 mkdir -p "$TEST_DB/imported"
 unzip -qo "$(option --file "$@")" -d "$TEST_DB/imported"
 grep -qx 'name: demo-verify' "$TEST_DB/imported/SKILL.md"
 jq -n --rawfile content "$TEST_DB/imported/SKILL.md" '{id:"verify-a",name:"demo-verify",content:$content}' >"$TEST_DB/skills/verify.json"
 jq '{status:"created",skill:.}' "$TEST_DB/skills/verify.json" ;;
*) printf 'Unexpected call: %s\n' "$*" >&2; exit 90 ;;
esac
STUB
# glob の空集合は既知の空 JSON ファイルで避ける。
chmod +x "$test_dir/bin/multica"
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/workspace.sh"
source "$root/lib/extensions.sh"
source "$root/lib/check.sh"
source "$root/lib/answers.sh"
source "$root/lib/host.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/project-changes.sh"
# エージェント登録の試験ではスクワッドの設定を差し替え、呼び出す順序を確認する。
complete_project() { echo "followup after agents"; }
prepare_project_issues() { :; }
prepare_project_webhooks() { :; }
project_webhook_completion() { :; }
verify_project_installation() { :; }
project_installation_completion() { :; }
server_url=https://example.test
workspace_id=workspace-a
project_name='Demo & literal $HOME'
project_key=demo
member_key=owner
repository_url=https://github.com/example/project
repository=example/project
repositories='[{"url":"https://github.com/example/project","repository":"example/project"},{"url":"git@github.com:EXAMPLE/SECOND.git","repository":"example/second"},{"url":"https://github.com/example/third","repository":"example/third"}]'
repositories=${TEST_REPOSITORIES:-$repositories}
export TEST_SELECTED_REPOSITORIES="$repositories"
host_owner_id=actor
claude_runtime_id=runtime-claude
codex_runtime_id=runtime-codex
runtimes=${TEST_RUNTIMES:-[\"claude\",\"codex\"]}
agent_home=$TEMPLATE_AGENT_HOME
excluded_roles=$TEST_EXCLUDED
if [[ ${TEST_RECHECK:-no} == yes ]]; then
 # 選択時には全件が候補だった。その後の別セットアップによる変更を再現する。
 projects=$(read_list プロジェクト project list)
 repository_choices "$repositories" "$projects" project-a
 [[ $(jq length <<<"$eligible_repos") == $(jq length <<<"$repositories") ]]
 touch "$TEST_DB/selection-ready"
 # 保存済みの ID でなく、名前から読み直した実 ID で自分自身を除外する。
 project_id=stale-saved-id
fi
if [[ -n ${TEST_EXTENSION_DIR:-} ]]; then
 choose_extension <<<"$TEST_EXTENSION_DIR"
fi
prepare_project
[[ $excluded_roles == "$TEST_EXCLUDED" ]]
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package"
export TEST_DB="$test_dir/db" TEMPLATE_AGENT_HOME="$test_dir/host"
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
reset_db() {
 rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
 mkdir -p "$TEST_DB/projects" "$TEST_DB/agents" "$TEST_DB/skills" "$TEST_DB/env" "$TEMPLATE_AGENT_HOME/bin" "$TEMPLATE_AGENT_HOME/git-hooks"
 cp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
 cp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 chmod +x "$TEMPLATE_AGENT_HOME/bin/gh" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 echo '{"id":"unrelated-project","title":"Other","description":"keep"}' >"$TEST_DB/projects/other.json"
 echo '{"id":"other-agent","name":"other-role-person","owner_id":"other","instructions":"keep"}' >"$TEST_DB/agents/other.json"
 echo '{"id":"handoff-a","name":"squad-handoff"}' >"$TEST_DB/skills/handoff.json"
 : >"$TEST_DB/calls"
}
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then echo 'unexpected success'; exit 1; fi; [[ -s $test_dir/err ]]; ! grep -q '今回作った件数' "$test_dir/out"; }
assert_no_final() {
 ! jq -es 'any(.[]; .[0:2]==["agent","update"] or .[0:3]==["agent","skills","set"] or .[0:2]==["skill","import"])' "$TEST_DB/calls" >/dev/null
}
# 初回の登録を終えた全17役の状態を、あとの試験の出発点として控える。
make_completed() {
 reset_db
 run
 mkdir -p "$test_dir/completed"
 cp -R "$TEST_DB" "$test_dir/completed/db"
 cp -R "$TEMPLATE_AGENT_HOME" "$test_dir/completed/host"
}
# 拡張のディレクトリ（QA の追記だけを持つ）を作る。
make_extension() {
 mkdir -p "$test_dir/extension/instructions"
 cp "$root/VERSION" "$test_dir/extension/kit-version"
 printf '{"qa":{"max_concurrent_tasks":2,"mcp_config":{"mcpServers":{"browser":{"command":"browser-tool"}}},"instructions_file":"instructions/qa.md"}}\n' >"$test_dir/extension/additions.json"
 printf '\n## Project checks\n\nRead the project test manual.\n' >"$test_dir/extension/instructions/qa.md"
}
