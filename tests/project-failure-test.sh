#!/usr/bin/env bash
# ZIP のルートから bash tests/project-failure-test.sh で実行する。
# 途中の失敗・最小構成・別の所有者・関所の確認
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

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
