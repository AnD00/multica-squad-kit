#!/usr/bin/env bash
# ZIP のルートから bash tests/project-create-test.sh で実行する。
# プロジェクトの新規登録と、既存のエージェント・スクワッドの再実行・修復
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

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
jq -e '.CLAUDE_CONFIG_DIR!=null and .CLAUDE_CODE_SHELL==null and .CLAUDE_ENV_FILE==null' "$TEST_DB/env/agent-demo-usage-monitor-owner.json" >/dev/null
jq -e --arg env "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh" '.CLAUDE_CODE_SHELL=="/bin/zsh" and .ENABLE_CLAUDEAI_MCP_SERVERS=="false" and .CLAUDE_ENV_FILE==$env' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE=="1"' "$TEST_DB/env/agent-demo-dependabot-merger-owner.json" >/dev/null
jq -e '.SQUAD_KIT_GH_DEPENDABOT_MERGE==null' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '[.skills[].id]|sort==["handoff-a","verify-a"]' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >/dev/null
echo 'PASS completion: 成功したエージェント15件とスクワッド1件だけを作成件数に出す'
echo 'PASS project: 初回はホスト準備後に private と停止指示と環境を作り、全 ID と指示検証後に割り当て、最後に公開する'
! jq -es 'any(.[]; .[0:2]==["squad","update"] or .[0:2]==["squad","member"] or .[0]=="autopilot")' "$TEST_DB/calls" >/dev/null
echo 'PASS project: プロジェクトの登録でスクワッドの器を作り、設定の反映を最後に行う'
echo 'PASS project: 新規プロジェクトでは選んだ全件をエージェント作成前の許可ファイルと紐付けに反映する'

jq -es 'all(.[]|select(.name|startswith("demo-")); (.instructions|contains("`example/project`、`example/second`、`example/third`")))' "$TEST_DB"/agents/*.json >/dev/null
for repo in example/project example/second example/third; do
 jq -e --arg repo "$repo" '.description|contains("| `"+$repo+"` | [記入:")' "$TEST_DB/projects/project-a.json" >/dev/null
 jq -e --arg repo "$repo" '.content|split("\n")|index("## `"+$repo+"`")!=null' "$TEST_DB/skills/verify.json" >/dev/null
done
jq -e '.content|split("\n")|map(select(startswith("## `")))|length==3' "$TEST_DB/skills/verify.json" >/dev/null
jq -e '.description|contains("{{")|not' "$TEST_DB/projects/project-a.json" >/dev/null
jq -e '.content|contains("{{")|not' "$TEST_DB/skills/verify.json" >/dev/null
jq -e '.content|contains("[記入: 実際に使うコマンドと実行順]")' "$TEST_DB/skills/verify.json" >/dev/null
for repo in example/project example/second example/third; do
 jq -e --arg repo "$repo" '.content|contains("### コンフリクトを解消したときの検証（"+$repo+"）")' "$TEST_DB/skills/verify.json" >/dev/null
done
jq -e '.content|split("\n")|map(select(startswith("### コンフリクトを解消したときの検証（")))|length==3' "$TEST_DB/skills/verify.json" >/dev/null
jq -e '.content|contains("[記入: 衝突したファイルと PR が変えたファイルから、関わるテストを選ぶ方法とコマンド。")' "$TEST_DB/skills/verify.json" >/dev/null
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
echo 'PASS custom args: 作成時に Codex にだけ 2 設定を渡し、同じ内容の再実行では設定を書かない'
echo 'PASS project: HTTPS・SSH・大小文字・末尾の違いは重ねて紐付けず、既存の ref と別種のリソースも保つ'

jq '.custom_args=["--keep","value","--enable","shell_snapshot","--enable=shell_snapshot","--enable","shell_tool","--enable=unified_exec","-c","other=true","-c","allow_login_shell=true","--config","features.shell_snapshot=true","--config=allow_login_shell=true","--config=features.shell_snapshot=true","-c","features.shell_snapshot_extra=true"]' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-codex-implementer-owner.json"
jq '.custom_args=["--claude-extra","--enable=shell_snapshot","--enable","shell_snapshot","-c","features.shell_snapshot=false","--config","allow_login_shell=false","--config=features.shell_snapshot=false","--config=allow_login_shell=false","--other","value","-c","allow_login_shell_other=true"]' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-orchestrator-owner.json"
: >"$TEST_DB/calls"
run
jq -e '.custom_args==["--keep","value","--enable","shell_tool","--enable=unified_exec","-c","other=true","-c","features.shell_snapshot_extra=true","-c","allow_login_shell=false","-c","features.shell_snapshot=false"]' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '.custom_args==["--claude-extra","--other","value","-c","allow_login_shell_other=true"]' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" >/dev/null
[[ $(jq -s '[.[]|select(.[0:2]==["agent","update"])]|length' "$TEST_DB/calls") == 2 ]]
echo 'PASS custom args: 引数だけの不一致でも更新し、両形式の上書きと重複を除き、ほかの引数の順を保つ'
echo 'PASS custom args: shell_snapshot の両形式の --enable を除き、ほかの機能の有効化は順も保つ'

jq '.model="old" | .instructions="old"' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-codex-implementer-owner.json"
jq '.ZDOTDIR="old" | .CLAUDE_ENV_FILE="old"' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-codex-implementer-owner.json"
jq '.CLAUDE_ENV_FILE="old" | .EXTRA="keep"' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-orchestrator-owner.json"
run
jq -e '.model=="gpt-6.1-sol" and (.instructions|contains("このプロジェクトの値"))' "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e '.EXTRA=="keep" and (.ZDOTDIR|endswith("/project-a")) and .CLAUDE_ENV_FILE==null' "$TEST_DB/env/agent-demo-codex-implementer-owner.json" >/dev/null
jq -e --arg env "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh" '.EXTRA=="keep" and .CLAUDE_ENV_FILE==$env' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
echo 'PASS project: 既存のエージェントの本指示・モデル・環境を ID を変えずに合わせる'
echo 'PASS Claude env: 古い CLAUDE_ENV_FILE を Claude では修復し、Codex では除き、追加の環境を保つ'

TEST_REPOSITORIES='[{"url":"https://github.com/example/project","repository":"example/project"}]' run
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/project ]]
grep -qx '許すリポジトリから外しました: example/second' "$test_dir/err"
grep -qx '許すリポジトリから外しました: example/third' "$test_dir/err"
cmp "$test_dir/resources-before" "$TEST_DB/resources.json"
! jq -es 'any(.[]; .[0:3]==["project","resource","remove"])' "$TEST_DB/calls" >/dev/null
echo 'PASS project: 選択を一つに減らすと外した全件を許可から消して表示し、過去の紐付けは消さない'
