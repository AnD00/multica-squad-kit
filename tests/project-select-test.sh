#!/usr/bin/env bash
# ZIP のルートから bash tests/project-select-test.sh で実行する。
# リポジトリの紐付けの失敗と、質問後の選択の読み直し
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

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
