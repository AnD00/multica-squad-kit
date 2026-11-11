#!/usr/bin/env bash
# ZIP のルートから bash tests/project-linking-test.sh で実行する。
# 他プロジェクトの issue の紐付け
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"
make_extension

# 他プロジェクトの GitHub の issue の紐付けを許し、コード作業の対象は増やさない。
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
echo 'PASS linking: 別プロジェクトの既存の GitHub の issue のコメントと Assignees を許し、登録・指示のコード作業先・検証の節を増やさず、再実行で設定を保つ'

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
