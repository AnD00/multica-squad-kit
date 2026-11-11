#!/usr/bin/env bash
# ZIP のルートから bash tests/project-environment-test.sh で実行する。
# 環境変数・拡張の追記・既存スクワッドの表記の違い
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

make_completed

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
make_extension
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
