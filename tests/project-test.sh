#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/project-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
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
 cp "$envfile" "$TEST_DB/env/$id.json"
 jq -n --arg id "$id" --arg name "$name" --arg model "$(option --model "$@")" --arg runtime "$(option --runtime-id "$@")" --arg thinking "$(option --thinking-level "$@")" --arg instructions "$(option --instructions "$@")" --argjson max "$(option --max-concurrent-tasks "$@")" '{id:$id,name:$name,owner_id:"actor",model:$model,runtime_id:$runtime,thinking_level:$thinking,instructions:$instructions,max_concurrent_tasks:$max,permission_mode:"private",invocation_targets:[],skills:[]}' >"$TEST_DB/agents/$id.json"
 cat "$TEST_DB/agents/$id.json" ;;
'agent env get') jq '{custom_env:.}' "$TEST_DB/env/$4.json" ;;
'agent env set') cp "$(option --custom-env-file "$@")" "$TEST_DB/env/$4.json"; echo '{}' ;;
'agent update')
 id=$3
 if [[ " $* " == *' --instructions '* ]]; then
  # 全有効役とスクワッドの実 ID が、この時点ですでに存在する。
  [[ $(find "$TEST_DB/agents" -name 'agent-demo-*.json' | wc -l | tr -d ' ') == "$TEST_ROLE_COUNT" ]]
  [[ -f $TEST_DB/squad.json ]]
  jq --arg instructions "$(option --instructions "$@")" --arg description "$(option --description "$@")" --arg model "$(option --model "$@")" --arg runtime "$(option --runtime-id "$@")" --arg thinking "$(option --thinking-level "$@")" --argjson max "$(option --max-concurrent-tasks "$@")" --argjson mcp "$(option --mcp-config "$@")" '.+{instructions:$instructions,description:$description,model:$model,runtime_id:$runtime,thinking_level:$thinking,max_concurrent_tasks:$max,mcp_config:$mcp}' "$TEST_DB/agents/$id.json" >"$TEST_DB/new"
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
source "$root/lib/workspace.sh"
source "$root/lib/extensions.sh"
source "$root/lib/check.sh"
source "$root/lib/answers.sh"
source "$root/lib/host.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
# エージェント登録の試験ではスクワッドの設定を差し替え、呼び出す順序を確かめる。
complete_project() { echo "followup after agents"; }
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
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=15
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
reset_db
run
grep -qx "followup after agents" "$test_dir/out"
for index in $(seq 0 15); do grep -qF "エージェント $index/15（ID の準備" "$test_dir/err"; done
for phase in 設定 公開; do
 for index in $(seq 0 15); do grep -qF "エージェントの$phase $index/15" "$test_dir/err"; done
done
[[ $(grep -c '^エージェント [0-9]*/15（ID の準備' "$test_dir/err") == 16 ]]
echo 'PASS progress: 15役のID準備・指示設定・公開を0から順に表示し、未公開のID準備を全体完了と表示しない'

grep -qF "今回作った件数: エージェント 15 件、スクワッド 1 件、オートパイロット 0 件" "$test_dir/out"
[[ $(jq -s 'length' "$TEST_DB"/agents/*.json) == 16 ]]
jq -es 'all(.[]|select(.name|startswith("demo-")); .permission_mode=="public_to" and (.instructions|contains("squad-a")) and (.instructions|contains("agent-demo-orchestrator-owner")) and (.instructions|contains("{{")|not))' "$TEST_DB"/agents/*.json >/dev/null
printf 'example/project\nexample/second\nexample/third\n' >"$test_dir/expected-repos"
cmp "$test_dir/expected-repos" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
jq -e 'length==3 and .[1].resource_ref.url=="git@github.com:EXAMPLE/SECOND.git" and .[2].resource_ref.url=="https://github.com/example/third"' "$TEST_DB/resources.json" >/dev/null
[[ $(jq -s '[.[]|select(.[0:3]==["project","resource","add"])]|length' "$TEST_DB/calls") == 2 ]]
jq -e '.model=="gpt-6.1-sol" and .max_concurrent_tasks==1' "$TEST_DB/agents/agent-demo-usage-monitor-owner.json" >/dev/null
jq -e '.CLAUDE_CONFIG_DIR!=null and .CLAUDE_CODE_SHELL==null' "$TEST_DB/env/agent-demo-usage-monitor-owner.json" >/dev/null
jq -e '.CLAUDE_CODE_SHELL=="/bin/zsh" and .ENABLE_CLAUDEAI_MCP_SERVERS=="false"' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE=="1"' "$TEST_DB/env/agent-demo-dependabot-merger-owner.json" >/dev/null
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE==null' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '[.skills[].id]|sort==["handoff-a","verify-a"]' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >/dev/null
echo 'PASS completion: 成功したエージェント15件とスクワッド1件だけを作成件数に出す'
echo 'PASS project: 初回はホスト準備後に private と停止指示と環境を作り、全 ID と指示検証後に割り当て、最後に公開する'
! jq -es 'any(.[]; .[0:2]==["squad","update"] or .[0:2]==["squad","member"] or .[0]=="autopilot")' "$TEST_DB/calls" >/dev/null
echo 'PASS project: プロジェクトの登録でスクワッドの器を作り、設定の反映を最後に行う'
echo 'PASS project: 新規プロジェクトでは選んだ全件をエージェント作成前の許可ファイルと紐付けに反映する'

jq -es 'all(.[]|select(.name|startswith("demo-")); (.instructions|contains("`example/project`、`example/second`、`example/third`")))' "$TEST_DB"/agents/*.json >/dev/null
# grep -q は一致で先に終わる。パイプにすると、jq が閉じたパイプへ書いて失敗することがあるため、先に変数へ読む。
project_description=$(jq -er '.description' "$TEST_DB/projects/project-a.json")
verify_skill=$(jq -er '.content' "$TEST_DB/skills/verify.json")
for repo in example/project example/second example/third; do
 grep -Fq "| \`$repo\` | [記入:" <<<"$project_description"
 grep -Fqx "## \`$repo\`" <<<"$verify_skill"
done
[[ $(jq -r '.content' "$TEST_DB/skills/verify.json" | grep -c '^## `') == 3 ]]
! jq -r '.description' "$TEST_DB/projects/project-a.json" | grep -q '{{'
! jq -r '.content' "$TEST_DB/skills/verify.json" | grep -q '{{'
grep -qF '[記入: 実際に使うコマンドと実行順]' <<<"$verify_skill"
echo 'PASS project: 全役へ全リポジトリを渡し、説明は各役割の行、検証スキルは各リポジトリの節へ展開する'
# 環境の修復試験の準備には、ここで本体から作った全15役の状態を使う。
mkdir -p "$test_dir/completed"
cp -R "$TEST_DB" "$test_dir/completed/db"
cp -R "$TEMPLATE_AGENT_HOME" "$test_dir/completed/host"

# 現在の ID と育てた説明・スキルを守り、同じ内容は再更新しない。
cp "$TEST_DB/projects/project-a.json" "$test_dir/original-project"
jq '.description="Edited project"' "$TEST_DB/projects/project-a.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/projects/project-a.json"
jq '.content="Edited skill"' "$TEST_DB/skills/verify.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/skills/verify.json"
jq '.+{EXTRA:"keep"}' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-codex-implementer-owner.json"
jq '.[0].resource_ref={url:"git@github.com:EXAMPLE/PROJECT.git",ref:"preserve-branch"} | .[1].resource_ref.url="https://github.com/Example/SECOND.git/" | .+[{id:"directory-a",resource_type:"local_directory",resource_ref:{local_path:"/preserve/path"}}]' "$TEST_DB/resources.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/resources.json"
cp "$TEST_DB/resources.json" "$test_dir/resources-before"
: >"$TEST_DB/calls"
run
! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or .[0:3]==["agent","env","set"] or .[0:3]==["agent","skills","set"] or .[0:2]==["skill","import"] or .[0:3]==["project","resource","add"])' "$TEST_DB/calls" >/dev/null
jq -e '.description=="Edited project"' "$TEST_DB/projects/project-a.json" >/dev/null
jq -e '.content=="Edited skill"' "$TEST_DB/skills/verify.json" >/dev/null
jq -e '.EXTRA=="keep"' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '.instructions=="keep"' "$TEST_DB/agents/other.json" >/dev/null
cmp "$test_dir/resources-before" "$TEST_DB/resources.json"
grep -qF "今回作った件数: エージェント 0 件、スクワッド 0 件、オートパイロット 0 件" "$test_dir/out"
echo 'PASS project: 再実行は実 ID・説明・プロジェクトのスキル・追加の環境と別人の設定を保ち、同じ内容は書かない'
echo 'PASS project: HTTPS・SSH・大小文字・末尾の違いは重ねて紐付けず、既存の ref と別種のリソースも保つ'

jq '.model="old" | .instructions="old"' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-codex-implementer-owner.json"
jq '.ZDOTDIR="old"' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-codex-implementer-owner.json"
run
jq -e '.model=="gpt-6.1-sol" and (.instructions|contains("このプロジェクトの値"))' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '.EXTRA=="keep" and (.ZDOTDIR|endswith("/project-a"))' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
echo 'PASS project: 既存のエージェントの本指示・モデル・環境を ID を変えずに合わせる'

TEST_REPOSITORIES='[{"url":"https://github.com/example/project","repository":"example/project"}]' run
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/project ]]
grep -qx '許すリポジトリから外しました: example/second' "$test_dir/err"
grep -qx '許すリポジトリから外しました: example/third' "$test_dir/err"
cmp "$test_dir/resources-before" "$TEST_DB/resources.json"
! jq -es 'any(.[]; .[0:3]==["project","resource","remove"])' "$TEST_DB/calls" >/dev/null
echo 'PASS project: 選択を一つに減らすと外した全件を許可から消して表示し、過去の紐付けは消さない'

reset_db
TEST_FAIL_REPO=https://github.com/example/third deny
assert_no_final
[[ $(jq length "$TEST_DB/resources.json") == 2 ]]
[[ $(find "$TEST_DB/agents" -name 'agent-demo-*.json' | wc -l | tr -d ' ') == 0 ]]
: >"$TEST_DB/calls"
run
[[ $(jq length "$TEST_DB/resources.json") == 3 ]]
[[ $(jq -s '[.[]|select(.[0:3]==["project","resource","add"])]|length' "$TEST_DB/calls") == 1 ]]
echo 'PASS project: 途中の紐付け失敗ではエージェントを作らず、再実行で済んだ追加を重ねず残りだけを反映する'

for response in invalid-json '{}' '[{"resource_type":"github_repo","resource_ref":{"url":null}}]' '[{"resource_type":"github_repo","resource_ref":{"url":"https://elsewhere.test/example/project"}}]'; do
 reset_db
 TEST_RESOURCE_RESPONSE="$response" deny
 assert_no_final
 ! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:3]==["project","resource","add"])' "$TEST_DB/calls" >/dev/null
done
reset_db
TEST_FAIL='project resource list' deny
assert_no_final
! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:3]==["project","resource","add"])' "$TEST_DB/calls" >/dev/null
echo 'PASS project: 取得失敗・不正な応答・未知の URL は未登録とみなさず、紐付けの追加とエージェント作成を止める'

for selection in '[]' '[{"url":"https://github.com/example/project","repository":"example/wrong"}]'; do
 reset_db
 TEST_REPOSITORIES="$selection" deny
 [[ ! -s $TEST_DB/calls && ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
done
echo 'PASS project: 空または URL と名前が違う選択はホストとプロジェクトを書き込む前に拒否する'

# 質問時には候補でも、許可の書き換え前に全選択の最新の紐付けを読み直す。
for kind in new existing new-neighbor list-failure list-invalid project-missing resources-failure resources-invalid resources-url-invalid; do
 reset_db
 mkdir -p "$TEMPLATE_AGENT_HOME/allowed-repos.d" "$TEMPLATE_AGENT_HOME/template/shell/project-a"
 printf 'example/previous\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
 printf 'preserve shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
 cp "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$test_dir/allowed-before"
 cp "$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv" "$test_dir/shell-before"
 if [[ $kind != new ]]; then
  echo '{"id":"project-a","title":"Demo & literal $HOME","description":"existing"}' >"$TEST_DB/projects/project-a.json"
  echo '[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/project"}}]' >"$TEST_DB/resources.json"
 fi
 export TEST_RECHECK=yes TEST_RECHECK_FAIL_LIST=no TEST_RECHECK_FAIL_RESOURCES=no TEST_RECHECK_NEW_NEIGHBOR=no
 export TEST_RECHECK_LIST='' TEST_RECHECK_RESOURCES='[]'
 case $kind in
 new|existing|new-neighbor)
  # 最後の選択だけが競合する場合も、先頭の許可だけ先に書いてはならない。
  export TEST_RECHECK_RESOURCES='[{"resource_type":"github_repo","resource_ref":{"url":"git@github.com:EXAMPLE/THIRD.git/"}}]'
  if [[ $kind == new-neighbor ]]; then export TEST_RECHECK_NEW_NEIGHBOR=yes; fi ;;
 list-failure) export TEST_RECHECK_FAIL_LIST=yes ;;
 list-invalid) export TEST_RECHECK_LIST='{}' ;;
 project-missing) export TEST_RECHECK_LIST='[]' ;;
 resources-failure) export TEST_RECHECK_FAIL_RESOURCES=yes ;;
 resources-invalid) export TEST_RECHECK_RESOURCES='[{"resource_type":"github_repo","resource_ref":{"url":null}}]' ;;
 resources-url-invalid) export TEST_RECHECK_RESOURCES='[{"resource_type":"github_repo","resource_ref":{"url":"https://outside.example/example/third"}}]' ;;
 esac
 deny
 cmp "$test_dir/allowed-before" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
 cmp "$test_dir/shell-before" "$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
 assert_no_final
 ! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:3]==["project","resource","add"])' "$TEST_DB/calls" >/dev/null
 if [[ $kind == new || $kind == existing || $kind == new-neighbor ]]; then
  grep -qF 'example/third' "$test_dir/err"
  grep -qF '従来の許可を保って停止' "$test_dir/err"
 fi
 echo "PASS project recheck: $kind は質問後の変更・取得失敗で従来の許可と起動ファイルを保って停止する"
 unset TEST_RECHECK TEST_RECHECK_FAIL_LIST TEST_RECHECK_FAIL_RESOURCES TEST_RECHECK_NEW_NEIGHBOR TEST_RECHECK_LIST TEST_RECHECK_RESOURCES
done

# 最後に処理する役の不備でも、一件も本指示・スキル・公開を書かない。
reset_db
printf '\n{{missing_value}}\n' >>"$TEST_PACKAGE/common/agents/ux-reviewer.md"
deny
assert_no_final
jq -es 'all(.[]|select(.name|startswith("demo-")); .permission_mode=="private" and (.instructions|contains("初期化中")))' "$TEST_DB"/agents/*.json >/dev/null
cp "$root/common/agents/ux-reviewer.md" "$TEST_PACKAGE/common/agents/ux-reviewer.md"
run
echo 'PASS project: 全指示の検証失敗は初期化で止まり、直して再実行すると ID を再利用して完成する'

reset_db
TEST_FAIL='squad create' deny
assert_no_final
echo 'PASS project: スクワッド作成に失敗しても仮 ID を使わず、本指示・スキル・公開は反映しない'
reset_db
TEST_FAIL='agent create' deny
grep -qF 'エージェント 0/15（ID の準備）' "$test_dir/err"
! grep -qF 'エージェント 1/15（ID の準備' "$test_dir/err"
[[ ! -f $TEST_DB/squad.json ]]
assert_no_final
echo 'PASS project: エージェント作成の失敗を成功扱いにせず、後続へ進まない'

reset_db
export TEST_EXCLUDED='["planner","designer","claude-implementer","claude-fixer","code-reviewer","ux-reviewer","security-reviewer","performance-reviewer","qa","ci-monitor","usage-monitor","dependabot-merger"]' TEST_ROLE_COUNT=3
run
[[ $(find "$TEST_DB/agents" -name 'agent-demo-*.json' | wc -l | tr -d ' ') == 3 ]]
! jq -es 'any(.[]|select(.name|startswith("demo-")); .instructions|contains("demo-planner-owner"))' "$TEST_DB"/agents/*.json >/dev/null
grep -qF 'エージェント 3/3（ID の準備' "$test_dir/err"
grep -qF 'エージェントの公開 3/3' "$test_dir/err"
echo 'PASS project: 最小構成では有効な3役だけを作り、外した役への参照がない'
jq '.owner_id="another"' "$TEST_DB/agents/agent-demo-codex-fixer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-codex-fixer-owner.json"
: >"$TEST_DB/calls"
deny
assert_no_final
echo 'PASS project: 同名のエージェントが別の所有者なら変更しない'

reset_db
TEST_FAIL='project create' deny
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
assert_no_final
echo 'PASS project: プロジェクト作成が失敗したら ID 依存のファイルやエージェントを作らない'
reset_db
TEST_FAIL='agent skills set' deny
! jq -es 'any(.[]; index("--public-to-workspace")!=null)' "$TEST_DB/calls" >/dev/null
run
echo 'PASS project: 割り当て失敗では公開せず、再実行で完成する'
jq '.creator_id="another"' "$TEST_DB/squad.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/squad.json"
: >"$TEST_DB/calls"
deny
assert_no_final
echo 'PASS project: 同名のスクワッドが別の所有者なら指示や割り当てを変えない'
reset_db
TEST_EXCLUDED='["unknown-role"]' deny
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
echo 'PASS project: 未知の役を外す指定は書き込みより前に拒否する'

reset_db
export TEST_EXCLUDED='["codex-implementer","codex-fixer"]' TEST_ROLE_COUNT=13
run
for role in code-reviewer ux-reviewer security-reviewer performance-reviewer; do
 jq -e '.model=="claude-sonnet-5-5" and .runtime_id=="runtime-claude"' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
done
echo 'PASS project: Codex系統を外すと印の評価後のモデルと Claude ランタイムでレビューを登録する'

reset_db
cp "$TEST_PACKAGE/skeleton/verify-repository.md" "$test_dir/checks-before"
printf '\n{{missing_repository_check}}\n' >>"$TEST_PACKAGE/skeleton/verify-repository.md"
deny
assert_no_final
[[ ! -f $TEST_DB/projects/project-a.json && ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
cp "$test_dir/checks-before" "$TEST_PACKAGE/skeleton/verify-repository.md"
echo 'PASS project: 検証の節の展開が不完全なら、プロジェクトやホスト・エージェントを書き込む前に止まる'

reset_db
TEST_GUARD_RESPONSE=403 deny
assert_no_final
! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:2]==["squad","create"])' "$TEST_DB/calls" >/dev/null
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
grep -q '関所の確認に失敗しました' "$test_dir/err"
echo 'PASS project: 関所を通れなければ許可を書かず、初期化用のエージェントとスクワッドも作らない'

reset_db
TEST_RECHECK=yes TEST_RECHECK_AFTER_GUARD=yes TEST_GUARD_MARKER="$TEST_DB/guard-checked" TEST_RECHECK_RESOURCES='[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/third"}}]' deny
[[ -f $TEST_DB/guard-checked && ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
! jq -es 'any(.[]; .[0:2]==["agent","create"])' "$TEST_DB/calls" >/dev/null
grep -q '別プロジェクトに紐付いたため許可できません: example/third' "$test_dir/err"
echo 'PASS project: 関所の確認の通信中に他プロジェクトへ移った選択も、許可更新直前の再確認で拒否する'

export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=15
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
for file in "$TEST_DB/env/"*.json; do
 jq '. += {SQUAD_KIT_GH_DEPENDABOT_MERGE:"1",PERSONAL_KEEP:"yes"}' "$file" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$file"
done
run
for file in "$TEST_DB/env/"*.json; do
 jq -e '.PERSONAL_KEEP=="yes" and (.SQUAD_KIT_ALLOWED_REPOS|endswith("/allowed-repos.d/project-a"))' "$file" >/dev/null
done
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE=="1"' "$TEST_DB/env/agent-demo-dependabot-merger-owner.json" >/dev/null
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE==null' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
echo 'PASS environment: リポジトリの許可を反映し、マージ権限を担当の役に限定し、無関係の環境変数を保つ'

reset_db
mkdir -p "$test_dir/extension/instructions"
cp "$root/VERSION" "$test_dir/extension/kit-version"
printf '{"qa":{"max_concurrent_tasks":2,"mcp_config":{"mcpServers":{"browser":{"command":"browser-tool"}}},"instructions_file":"instructions/qa.md"}}\n' >"$test_dir/extension/additions.json"
printf '\n## Project checks\n\nRead the project test manual.\n' >"$test_dir/extension/instructions/qa.md"
TEST_EXTENSION_DIR="$test_dir/extension" run
jq -e '.max_concurrent_tasks==2 and .mcp_config.mcpServers.browser.command=="browser-tool" and (.instructions|contains("Read the project test manual."))' "$TEST_DB/agents/agent-demo-qa-owner.json" >/dev/null
echo 'PASS extension agent: 追記の指示・MCP・同時実行の上限がサーバーへ届く'

# 大文字・小文字の違いだけなら既存のスクワッドを改名せず使う。
reset_db
printf '%s\n' '{"id":"existing-squad","name":"Demo-owner","creator_id":"actor"}' >"$TEST_DB/squad.json"
run
jq -e '.id=="existing-squad" and .name=="Demo-owner"' "$TEST_DB/squad.json" >/dev/null
! jq -es 'any(.[]; .[0:2]==["squad","create"])' "$TEST_DB/calls" >/dev/null
jq -e '.instructions|contains("[@Demo-owner](mention://squad/existing-squad)")' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" >/dev/null
: >"$TEST_DB/calls"
run
! jq -es 'any(.[]; .[0:2]==["squad","create"])' "$TEST_DB/calls" >/dev/null
echo 'PASS squad: 表記の違う既存スクワッドの ID と名前を維持し、そのメンションを指示に入れる'

# 同じエージェントを両方から片方へ移し、以前のランタイムの環境を残さない。
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=15
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
jq '.+{EXTRA:"keep"}' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-orchestrator-owner.json"
for selected in claude codex; do
 export TEST_RUNTIMES="[\"$selected\"]"
 if [[ $selected == claude ]]; then absent=codex; expected=claude-sonnet-5-5; else absent=claude; expected=gpt-6.1-sol; fi
 : >"$TEST_DB/calls"
 run
 grep -qF 'エージェント 13 件の既存設定' "$test_dir/err"
 grep -qF '今回作った件数: エージェント 0 件' "$test_dir/out"
 ! jq -es --arg prefix "agent-demo-$absent-" 'any(.[]; .[0]=="agent" and (.[2] // ""|startswith($prefix)))' "$TEST_DB/calls" >/dev/null
 for role in orchestrator planner designer qa code-reviewer security-reviewer ux-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger; do
  role_model=$expected
  if [[ $selected == claude && ( $role == planner || $role == designer ) ]]; then role_model=claude-opus-5-5; fi
  jq -e --arg role "$role" --arg model "$role_model" --arg runtime "runtime-$selected" '.id==("agent-demo-"+$role+"-owner") and .model==$model and .runtime_id==$runtime' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
 done
 jq -e '.EXTRA=="keep"' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
 if [[ $selected == codex ]]; then
  for role in orchestrator usage-monitor ci-monitor; do
   jq -e '.CLAUDE_CONFIG_DIR==null and .CLAUDE_CODE_SHELL==null and .ENABLE_CLAUDEAI_MCP_SERVERS==null and .CLAUDE_CODE_AUTO_COMPACT_WINDOW==null' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  done
  ! grep -q 'CLAUDE_CONFIG_DIR=' "$test_dir/out"
  grep -q 'CODEX_HOME=' "$test_dir/out"
 else
  jq -e '.CLAUDE_CONFIG_DIR!=null and .CLAUDE_CODE_SHELL=="/bin/zsh"' "$TEST_DB/env/agent-demo-usage-monitor-owner.json" >/dev/null
  ! grep -q 'CODEX_HOME=' "$test_dir/out"
  grep -q 'CLAUDE_CONFIG_DIR=' "$test_dir/out"
 fi
 echo "PASS project runtimes: $selected だけへ同じIDで移し、ない系統を登録せず、環境と完了の案内を合わせる"
done
unset TEST_RUNTIMES

# 拡張の固定モデルは、オンラインIDがあっても選んでいないランタイムでは使わない。
mkdir -p "$test_dir/extension/agents"
for selected in claude codex; do
 reset_db
 if [[ $selected == claude ]]; then wrong_model=gpt-6.1-sol; else wrong_model=claude-sonnet-5-5; fi
 printf '%s\n' '---' 'name: "{{project_key}}-helper-{{member_key}}"' "model: $wrong_model" 'thinking_level: high' '---' 'Help.' >"$test_dir/extension/agents/helper.md"
 TEST_RUNTIMES="[\"$selected\"]" TEST_EXTENSION_DIR="$test_dir/extension" deny
 grep -qF '使うランタイムにないモデル' "$test_dir/err"
 ! jq -es 'any(.[]; .[0:2]==["agent","create"])' "$TEST_DB/calls" >/dev/null
done
echo 'PASS extension runtimes: 選ばなかったランタイムのモデルを、全エージェントの作成前に拒否する'
rm "$test_dir/extension/agents/helper.md"

# 他プロジェクトの issue の紐付けを許し、コード作業の対象は増やさない。
reset_db
export TEST_REPOSITORIES='[{"url":"https://github.com/example/project","repository":"example/project"}]'
export TEST_REGISTERED_REPOSITORIES='[{"url":"https://github.com/example/project"},{"url":"git@github.com:EXAMPLE/LINKED.git"}]'
export TEST_EXPECTED_ALLOWED='["example/project","example/linked"]'
export TEST_OTHER_RESOURCES='[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/linked"}}]'
export TEST_EXTENSION_DIR="$test_dir/extension"
printf '["EXAMPLE/PROJECT","Example/Linked","example/linked"]\n' >"$TEST_EXTENSION_DIR/link-repositories.json"
run
printf 'example/project\nexample/linked\n' >"$test_dir/allowed"
cmp "$test_dir/allowed" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
jq -e 'length==1 and .[0].resource_ref.url=="https://github.com/example/project"' "$TEST_DB/resources.json" >/dev/null
jq -e 'all(.[]|select(.name|startswith("demo-")); (.instructions|split("### 紐付け専用のリポジトリ")|length)==2 and (.instructions|split("### 紐付け専用のリポジトリ")[0]|contains("example/linked")|not) and (.instructions|contains("`example/linked`")))' < <(jq -s . "$TEST_DB"/agents/*.json) >/dev/null
! jq -r '.description' "$TEST_DB/projects/project-a.json" | grep -q 'example/linked'
! jq -r '.content' "$TEST_DB/skills/verify.json" | grep -q 'example/linked'
cp "$TEST_DB/projects/other.json" "$test_dir/other-before"
export HOST_GH_CALLS="$test_dir/link-gh-calls"
SQUAD_KIT_ALLOWED_REPOS="$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$TEMPLATE_AGENT_HOME/bin/gh" issue comment 1 -R example/linked --body 'Link fixture'
SQUAD_KIT_ALLOWED_REPOS="$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$TEMPLATE_AGENT_HOME/bin/gh" issue edit 1 -R example/linked --add-assignee fixture-owner
[[ $(wc -l <"$HOST_GH_CALLS" | tr -d ' ') == 2 ]]
if SQUAD_KIT_ALLOWED_REPOS="$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$TEMPLATE_AGENT_HOME/bin/gh" issue comment 1 -R example/unlisted --body 'Denied' 2>"$test_dir/denied"; then exit 1; fi
[[ $(wc -l <"$HOST_GH_CALLS" | tr -d ' ') == 2 ]]
: >"$TEST_DB/calls"; run
! jq -es 'any(.[]; .[0:2]==["agent","update"] or .[0:2]==["project","update"] or .[0:3]==["project","resource","add"])' "$TEST_DB/calls" >/dev/null
cmp "$test_dir/other-before" "$TEST_DB/projects/other.json"
echo 'PASS linking: 別プロジェクトの既存 issue のコメントと Assignees を許し、登録・指示のコード作業先・検証の節を増やさず、再実行で設定を保つ'

# 既存許可を変更する直前にも登録を読み直す。失敗したら前の許可を残す。
rm "$TEST_DB/repo-read"
TEST_REPO_REMOVED=yes deny
cmp "$test_dir/allowed" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
grep -q 'ワークスペースに登録済み' "$test_dir/err"
echo 'PASS linking: ワークスペースから外れた紐付け先は拒否し、既存許可を保つ'

printf '[]\n' >"$TEST_EXTENSION_DIR/link-repositories.json"
run
printf 'example/project\n' >"$test_dir/allowed-code"
cmp "$test_dir/allowed-code" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
! jq -r '.instructions' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" | grep -q '紐付け専用のリポジトリ'
if SQUAD_KIT_ALLOWED_REPOS="$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$TEMPLATE_AGENT_HOME/bin/gh" issue edit 1 -R example/linked --add-assignee fixture-owner 2>"$test_dir/denied"; then exit 1; fi
cmp "$test_dir/other-before" "$TEST_DB/projects/other.json"
echo 'PASS linking: 空配列へ戻すと追加許可と指示を外し、相手のプロジェクトを変えない'
cp "$TEST_DB/agents/agent-demo-orchestrator-owner.json" "$test_dir/one-code-agent"
printf '["EXAMPLE/PROJECT"]\n' >"$TEST_EXTENSION_DIR/link-repositories.json"
: >"$TEST_DB/calls"; run
cmp "$test_dir/one-code-agent" "$TEST_DB/agents/agent-demo-orchestrator-owner.json"
! jq -es 'any(.[]; .[0:2]==["agent","update"])' "$TEST_DB/calls" >/dev/null
rm "$TEST_EXTENSION_DIR/link-repositories.json"
: >"$TEST_DB/calls"; run
cmp "$test_dir/one-code-agent" "$TEST_DB/agents/agent-demo-orchestrator-owner.json"
cmp "$test_dir/allowed-code" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
echo 'PASS linking: 省略・空配列・コード作業先との重複だけの指定で、単一選択の指示と許可が一致する'

reset_db
printf '["example/unregistered"]\n' >"$TEST_EXTENSION_DIR/link-repositories.json"
deny
! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or .[1]=="import")' "$TEST_DB/calls" >/dev/null
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-a ]]
echo 'PASS linking: 未登録の指定はサーバー・許可への書き込み前に止める'
