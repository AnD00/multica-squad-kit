#!/usr/bin/env bash
# ZIP のルートから bash tests/project-runtimes-test.sh で実行する。
# ランタイムの選び直しと拡張の固定モデル
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

make_completed
make_extension

# 同じエージェントを両方から片方へ移し、以前のランタイムの環境を残さない。
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
jq '.custom_args=["--keep","value"]' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-orchestrator-owner.json"
jq '.+{EXTRA:"keep"}' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-orchestrator-owner.json"
for selected in claude codex; do
 export TEST_RUNTIMES="[\"$selected\"]"
 if [[ $selected == claude ]]; then absent=codex; expected=claude-sonnet-5-5; else absent=claude; expected=gpt-6.1-sol; fi
 : >"$TEST_DB/calls"
 run
 grep -qF 'エージェント 14 件の既存設定' "$test_dir/err"
 grep -qF '今回作った件数: エージェント 0 件' "$test_dir/out"
 ! jq -es --arg prefix "agent-demo-$absent-" 'any(.[]; .[0]=="agent" and (.[2] // ""|startswith($prefix)))' "$TEST_DB/calls" >/dev/null
 for role in orchestrator planner designer qa code-reviewer security-reviewer ux-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger; do
  role_model=$expected
  if [[ $selected == claude && ( $role == planner || $role == designer ) ]]; then role_model=claude-opus-5-5; fi
  jq -e --arg role "$role" --arg model "$role_model" --arg runtime "runtime-$selected" '.id==("agent-demo-"+$role+"-owner") and .model==$model and .runtime_id==$runtime' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
  jq -e --arg selected "$selected" --arg env "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh" 'if $selected=="claude" then .CLAUDE_ENV_FILE==$env else .CLAUDE_ENV_FILE==null end' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  role_args='[]'
  if [[ $role == orchestrator ]]; then role_args='["--keep","value"]'; fi
  jq -e --arg selected "$selected" --argjson prefix "$role_args" '.custom_args==($prefix+(if $selected=="codex" then ["-c","allow_login_shell=false","-c","features.shell_snapshot=false"] else [] end))' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
 done
 jq -e --arg selected "$selected" --arg model "$(if [[ $selected == claude ]]; then echo claude-fable-5-2; else echo gpt-6-astra; fi)" '.model==$model and .runtime_id==("runtime-"+$selected) and .thinking_level=="high"' "$TEST_DB/agents/agent-demo-$selected-principal-owner.json" >/dev/null
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
