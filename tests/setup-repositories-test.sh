#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest

# リポジトリの複数選択と保存した一覧からの再実行。
export TEMPLATE_STATE_ROOT="$test_dir/multiple"
export TEST_REPOS_FILE="$test_dir/repos.json"
echo '[{"url":"https://github.com/example/one.git"},{"url":"git@github.com:example/two.git"},{"url":"ssh://git@github.com/EXAMPLE/ONE.git"},{"url":"https://github.com/example/three"}]' >"$TEST_REPOS_FILE"
printf '1\n1\nmulti\n2,1 2\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
multiple="$TEMPLATE_STATE_ROOT/ws-a/multi.json"
jq -e '.schema==1 and [.repositories[].repository]==["example/two","example/one"]' "$multiple" >/dev/null
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$multiple") == 600 ]]
echo 'PASS repositories: 空白とカンマで複数を選び、番号と URL 表記の重複を除き、選択順を保存する'
cp "$multiple" "$test_dir/multi-before"
printf '1\n\n\n\n\n\n\n\n\nyes\n' >"$test_dir/input"
run
cmp "$multiple" "$test_dir/multi-before"
echo 'PASS repositories: 複数の保存値を既定にして、ws を選んだあとは Enter で同じ順序と内容で再実行する'
export TEST_PROJECTS_FILE="$test_dir/projects.json" TEST_RESOURCES_DIR="$test_dir/resources"
mkdir -p "$TEST_RESOURCES_DIR"
echo '[{"id":"project-a","title":"Existing project"},{"id":"project-b","title":"Neighbor"}]' >"$TEST_PROJECTS_FILE"
echo '[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/one"}}]' >"$TEST_RESOURCES_DIR/project-a.json"
echo '[{"resource_type":"github_repo","resource_ref":{"url":"ssh://git@github.com/EXAMPLE/TWO.git"}},{"resource_type":"local_directory","resource_ref":{"local_path":"not-a-repo"}}]' >"$TEST_RESOURCES_DIR/project-b.json"
printf '1\n1\nfiltered\n1,2\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '[.repositories[].repository]==["example/one","example/three"]' "$TEMPLATE_STATE_ROOT/ws-a/filtered.json" >/dev/null
grep -q '別プロジェクト: Neighbor' "$test_dir/err"
grep -q 'project resource list project-b' "$TEST_CALLS"
echo 'PASS repositories: 他プロジェクトの HTTPS/SSH・大小文字の表記差を同じものと判定し、自己のリポジトリは候補に残す'

# 保存した選択がすべて他プロジェクトへ移ったときは既定へ戻さない。
jq '.repositories |= map(select(.repository=="example/two"))' "$multiple" >"$test_dir/blocked-answer"
mv "$test_dir/blocked-answer" "$multiple"
printf '1\n1\nmulti\n\n1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '[.repositories[].repository]==["example/one"]' "$multiple" >/dev/null
grep -q '1つ以上の番号' "$test_dir/err"
echo 'PASS repositories: 保存したリポジトリでも、今は選べなければ既定から外して再入力を待つ'

printf '1\nFresh project\nfresh\n\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '.project_id=="" and [.repositories[].repository]==["example/three"]' "$TEMPLATE_STATE_ROOT/ws-a/fresh.json" >/dev/null
echo 'PASS repositories: 新規プロジェクトでは全既存プロジェクトを照合し、候補が一つならそれを既定にする'

cp "$TEST_RESOURCES_DIR/project-b.json" "$test_dir/resource-before"
echo '[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/two"}},{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/three"}}]' >"$TEST_RESOURCES_DIR/project-b.json"
printf '1\nNew project\nempty\n' >"$test_dir/input"
TEMPLATE_STATE_ROOT="$test_dir/zero-candidates" deny
[[ ! -e $test_dir/zero-candidates ]]
grep -q 'GitHub 連携とリポジトリの紐付け' "$test_dir/err"
grep -qF 'ワークスペースの設定 → コード' "$test_dir/err"
grep -qF 'GitHub App が未設定なら' "$test_dir/err"
grep -qF 'multica repo list --output json' "$test_dir/err"
grep -q 'Existing project' "$test_dir/err"
grep -q 'Neighbor' "$test_dir/err"
echo 'PASS repositories: 全候補が他プロジェクトに属すと、理由と案内を出して保存前に止まる'
cp "$test_dir/resource-before" "$TEST_RESOURCES_DIR/project-b.json"
cp "$multiple" "$test_dir/multi-safe"
printf '1\n1\nmulti\n' >"$test_dir/input"
TEST_FAIL=resources deny
cmp "$multiple" "$test_dir/multi-safe"
echo '{}' >"$TEST_RESOURCES_DIR/project-b.json"
deny
cmp "$multiple" "$test_dir/multi-safe"
echo '[{"resource_type":"github_repo","resource_ref":{"url":"https://elsewhere.test/example/two"}}]' >"$TEST_RESOURCES_DIR/project-b.json"
deny
cmp "$multiple" "$test_dir/multi-safe"
cp "$test_dir/resource-before" "$TEST_RESOURCES_DIR/project-b.json"
echo 'PASS repositories: 他プロジェクトの取得失敗・不正な応答・未知の URL は未所有と見なさず、保存値を保つ'

unset TEST_PROJECTS_FILE TEST_RESOURCES_DIR
printf '1\n1\ninvalid\n0\n99\nx\n\n2 1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '[.repositories[].repository]==["example/two","example/one"]' "$TEMPLATE_STATE_ROOT/ws-a/invalid.json" >/dev/null
[[ $(grep -c '1つ以上の番号' "$test_dir/err") == 4 ]]
echo 'PASS repositories: 0・候補外・文字・空の選択は同じ質問へ戻り、1つ以上の選択だけを受け付ける'

for damage in '.repositories=[]' '.repositories[0].repository="example/other"' '.schema=9' '.excluded_roles=["claude-principal"]' '.excluded_roles=["codex-principal"]'; do
 jq "$damage" "$test_dir/multi-safe" >"$multiple"
 cp "$multiple" "$test_dir/damaged"
 printf '1\n1\nmulti\n' >"$test_dir/input"
 deny
 cmp "$multiple" "$test_dir/damaged"
done
echo 'PASS repositories: 空の保存一覧・URL と違うリポジトリ名・未知の保存形式・外せない最上位の役の除外は拒否して上書きしない'
