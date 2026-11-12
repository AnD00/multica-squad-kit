#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
: >"$test_dir/input"
for os in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0 FreeBSD; do
 TEST_OS="$os" deny
 grep -q '対象外' "$test_dir/err"
 no_state
 [[ ! -e $TEST_CALLS ]]
done
TEST_OS=Linux TEST_KERNEL=4.4.0-19041-Microsoft deny
grep -q 'WSL 1 は対象外' "$test_dir/err"
no_state
[[ ! -e $TEST_CALLS ]]
echo 'PASS setup: 対象外の OS と WSL 1 は CLI と保存を行わない'
mv "$test_dir/package/MANIFEST" "$test_dir/saved-manifest"
deny
cp "$test_dir/saved-manifest" "$test_dir/package/MANIFEST"
printf damaged >>"$test_dir/package/file with spaces"
deny
printf payload >"$test_dir/package/file with spaces"
mv "$test_dir/package/lib/check.sh" "$test_dir/check.sh"
deny
mv "$test_dir/check.sh" "$test_dir/package/lib/check.sh"
printf extra >"$test_dir/package/extra"
deny
rm "$test_dir/package/extra"
no_state
[[ ! -e $TEST_CALLS ]]
echo 'PASS setup: MANIFEST の欠落・改変・ファイル不足・余分なファイルは CLI より前に止まる'
mkdir "$test_dir/restricted"
for tool in bash cat dirname uname find sort shasum awk; do ln -s "$(command -v "$tool")" "$test_dir/restricted/$tool"; done
ln -sf "$test_dir/bin/uname" "$test_dir/restricted/uname"
TEST_OS=Darwin PATH="$test_dir/restricted" deny
grep -q 'brew install multica-ai/tap/multica' "$test_dir/err"
grep -q 'brew install jq' "$test_dir/err"
grep -q 'brew install gh' "$test_dir/err"
grep -q 'brew install python' "$test_dir/err"
no_state
TEST_OS=Linux PATH="$test_dir/restricted" deny
grep -q 'sudo apt-get install' "$test_dir/err"
grep -q 'CLI_INSTALL.md' "$test_dir/err"
no_state
[[ ! -e $TEST_CALLS ]]
echo 'PASS setup: macOS と Linux の道具の不足は入れ方を表示し、何も保存しない'
mkdir "$test_dir/old-python"
printf '#!/bin/bash\nexit 1\n' >"$test_dir/old-python/python3"
chmod +x "$test_dir/old-python/python3"
PATH="$test_dir/old-python:$PATH" deny
grep -q 'Python 3.11' "$test_dir/err"
no_state
[[ ! -e $TEST_CALLS ]]
echo 'PASS setup: tomllib を使えない Python では設定の保存・登録前に止まり、入れ方を案内する'
TEST_LOGIN=no deny
grep -q 'login' "$test_dir/err"
no_state
base_input no
deny
grep -q '中止しました' "$test_dir/err"
no_state
base_input yes
run
saved="$test_dir/state/ws-a/demo.json"
jq -e '.workspace_id=="ws-a" and .project_id=="project-a" and .repositories[0].repository=="example/two" and .repositories[0].url=="git@github.com:example/two.git" and .member_ids==["member-a","member-b"] and .excluded_roles==["claude-fixer","claude-implementer","planner"] and .dependabot_webhook==false' "$saved" >/dev/null
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$saved") == 600 ]]
grep -q 'TEST-project-prepared' "$test_dir/out"
grep -qF '答えを保存しました。' "$test_dir/err"
! grep -qF "$test_dir/state" "$test_dir/err"
! grep -qF '保存先:' "$test_dir/err"
grep -q 'https://example.test|ws-a|project list' "$TEST_CALLS"
echo 'PASS setup: 確認後だけ答えを保存し、選んだ ws・repo と人間の user_id、系統の役を使う'
cp "$saved" "$test_dir/previous"
printf '1\n\n\n\n\n\n\n\n\nyes\n' >"$test_dir/input"
run
cmp "$saved" "$test_dir/previous"
echo 'PASS setup: ワークスペースだけは番号で選び、残りは保存した既定と最後の確認で同じ答えに収まる'
printf '1\n\n\n\n\n\n\n\n2\nyes\n' >"$test_dir/input"
run
jq -e '.dependabot_webhook==true' "$saved" >/dev/null
grep -qE '^✔ Dependabot の PR の Webhook +使う$' "$test_dir/err"
printf '1\n\n\n\n\n\n\n\n\nyes\n' >"$test_dir/input"
run
jq -e '.dependabot_webhook==true' "$saved" >/dev/null
grep -qxF '› 2 ' "$test_dir/err"
[[ $(grep -c '前の答えにはこの項目がありません' "$test_dir/err") == 0 ]]
jq 'del(.dependabot_webhook)' "$test_dir/previous" >"$saved"
printf '1\n\n\n\n\n\n\n\n\nyes\n' >"$test_dir/input"
run
cmp "$saved" "$test_dir/previous"
grep -qF '  ! 前の答えにはこの項目がありません。前のバージョンは聞かずに Webhook を登録していました。' "$test_dir/err"
printf '1\n\n\n\n\n\n\n12\nyes\n' >"$test_dir/input"
run
jq -e '.dependabot_webhook==false and (.excluded_roles|index("dependabot-merger")!=null)' "$saved" >/dev/null
grep -qxF '· Dependabot の PR の Webhook  Dependabot の役を外したので聞きません。' "$test_dir/err"
cp "$test_dir/previous" "$saved"
echo 'PASS setup: Webhook は既定で使わず、使う答えを保存して次の既定にし、項目のない前の答えは使わないと読み、役を外せば番号だけ進めて聞かない'
printf '2\nNew project\nother\n1\nmemberb\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '.workspace_id=="ws-b" and .project_id=="" and .project_name=="New project" and .member_ids==[] and .excluded_roles==[]' "$test_dir/state/ws-b/other.json" >/dev/null
cmp "$saved" "$test_dir/previous"
echo 'PASS setup: 新しいプロジェクトは未作成のまま答えを分け、別のワークスペースの保存を変えない'
printf '1\nOther project\nnext\n1\nmembera\n0\n1\n0\n\nno\n' >"$test_dir/input"
deny
[[ ! -e $test_dir/state/ws-a/next.json ]]
cmp "$saved" "$test_dir/previous"
echo 'PASS setup: キャンセルでは既存の答えを上書きせず、新しい保存も作らない'
base_input yes
TEST_FAIL=repo deny
grep -q 'リポジトリ を取得できません' "$test_dir/err"
TEST_FAIL=members deny
grep -q 'メンバー を取得できません' "$test_dir/err"
TEST_FAIL=project deny
grep -q 'プロジェクト を取得できません' "$test_dir/err"
TEST_MALFORMED=yes deny
TEST_NO_REPO=yes deny
grep -q 'GitHub 連携とリポジトリの紐付け' "$test_dir/err"
cmp "$saved" "$test_dir/previous"
echo 'PASS setup: CLI の失敗・不正 JSON・未連携では止め、前の答えを保つ'
printf '1\n1\ndemo\n1\nmembera\n99\n1\n1\n99\n3 4\n4 9\n\nyes\n' >"$test_dir/input"
run
jq -e '.member_ids==["member-a"] and .excluded_roles==["codex-fixer","codex-implementer","qa"]' "$saved" >/dev/null
grep -q '少なくとも一系統' "$test_dir/err"
echo 'PASS setup: 一覧にない選択・リーダーの除外・両系統の除外は聞き直す'
cp "$saved" "$test_dir/updated"
base_input yes
TEST_SAVE_FAIL=yes deny
grep -q '保存できませんでした' "$test_dir/err"
cmp "$saved" "$test_dir/updated"
[[ -z $(find "$test_dir/state" -name '.answers.*' -print) ]]
echo 'PASS setup: 保存の失敗を返し、前の答えと一時ファイルの片付けを確かめる'
printf '1\nSecond project\nsecond\n1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
jq -e '.project_name=="Second project"' "$test_dir/state/ws-a/second.json" >/dev/null
cmp "$saved" "$test_dir/updated"
echo 'PASS setup: 同じワークスペースでも別プロジェクトの答えを分ける'
printf 'https://new.example.test\n1\n1\nfresh\n1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
TEST_SERVER='(not set)' run
jq -e '.server_url=="https://new.example.test"' "$test_dir/state/ws-a/fresh.json" >/dev/null
echo 'PASS setup: 未設定のサーバーだけ質問し、CLI の設定や既定の ws は変更しない'
printf '2\n1\nenv\n1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
MULTICA_SERVER_URL=https://env.example.test MULTICA_WORKSPACE_ID=ws-b run
jq -e '.workspace_id=="ws-b" and .server_url=="https://env.example.test"' "$test_dir/state/ws-b/env.json" >/dev/null
echo 'PASS setup: CLI の環境のサーバーを使い、ws は環境に既定があっても番号で選ぶ'
printf 'https://saved.example.test\n2\n1\ndemo\n1\nmembera\n0\n1\n0\n\nyes\n' >"$test_dir/input"
TEMPLATE_STATE_ROOT="$test_dir/defaults" TEST_SERVER='(not set)' run
cp "$test_dir/defaults/ws-b/demo.json" "$test_dir/default-previous"
printf 'https://saved.example.test\n2\n\n\n\n\n\n\n\n\nyes\n' >"$test_dir/input"
TEMPLATE_STATE_ROOT="$test_dir/defaults" TEST_SERVER='(not set)' run
cmp "$test_dir/defaults/ws-b/demo.json" "$test_dir/default-previous"
echo 'PASS setup: 保存済みでも ws と未設定の URL は毎回入力し、ほかの答えの既定を使う'
if bash "$test_dir/package/setup.sh" --project ignored >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '質問に答えて' "$test_dir/err"
echo 'PASS setup: 引数での値の指定は受け付けない'

# 拡張のディレクトリだけは引数で受け、質問で答えたときと同じ確かめをする。
run_extension() { (cd "$1" && shift && /bin/bash "$test_dir/package/setup.sh" "$@" <"$test_dir/input" >"$test_dir/out" 2>"$test_dir/err"); }
mkdir -p "$test_dir/callers/extension"
cp "$test_dir/package/VERSION" "$test_dir/callers/extension/kit-version"
base_input yes
TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$test_dir" --extension "$test_dir/callers/extension"
grep -qF "· 拡張のディレクトリ  $test_dir/callers/extension" "$test_dir/err"
! grep -qF '使わない場合は Enter' "$test_dir/err"
grep -qF 'ワークスペース' "$test_dir/err"
grep -qF '? 保存して作りますか' "$test_dir/err"
jq -e '.workspace_id=="ws-a" and .project_key=="demo"' "$test_dir/ext-state/ws-a/demo.json" >/dev/null
jq -e '.roles==[]' "$test_dir/ext-state/ws-a/demo-membera.extensions.json" >/dev/null
[[ -z $(find "$test_dir/package/tmp" -mindepth 1 -print) ]]
echo 'PASS setup: --extension で渡すと拡張の質問を出さず、ワークスペースと最後の確認は聞いてから保存する'
rm -rf "$test_dir/ext-state"
TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$test_dir/callers" --extension=extension
grep -qF "· 拡張のディレクトリ  $test_dir/callers/extension" "$test_dir/err"
jq -e '.project_key=="demo"' "$test_dir/ext-state/ws-a/demo.json" >/dev/null
echo 'PASS setup: --extension= の形と、流した場所から見た相対パスを受ける'
rm -rf "$test_dir/ext-state"
base_input no
if TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$test_dir" --extension "$test_dir/callers/extension"; then exit 1; fi
grep -q '中止しました' "$test_dir/err"
[[ ! -e $test_dir/ext-state ]]
echo 'PASS setup: --extension があっても、最後の確認で no を答えると何も保存しない'
base_input yes
: >"$TEST_CALLS"
ext_deny() {
 if TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$test_dir" --extension "$1"; then exit 1; fi
 grep -qF "$2" "$test_dir/err"
 [[ ! -e $test_dir/ext-state && ! -s $TEST_CALLS ]]
 [[ -z $(find "$test_dir/package/tmp" -mindepth 1 -print) ]]
}
ext_deny "$test_dir/callers/missing" '拡張のディレクトリがありません。'
printf 'v0.0.0\n' >"$test_dir/callers/extension/kit-version"
ext_deny "$test_dir/callers/extension" '拡張が求める原本のバージョンと、流しているバージョンが違います'
cp "$test_dir/package/VERSION" "$test_dir/callers/extension/kit-version"
: >"$test_dir/callers/extension/unknown.txt"
ext_deny "$test_dir/callers/extension" '未知の拡張の項目です'
rm "$test_dir/callers/extension/unknown.txt"
echo 'PASS setup: --extension のディレクトリがない・バージョンが違う・形式が違うときは、CLI と保存の前に止まる'
for args in '--extension' '--extension=' '--extension a --extension b' '--extension=a --other'; do
 # shellcheck disable=SC2086
 if run_extension "$test_dir" $args; then exit 1; fi
 grep -qF '使い方: bash setup.sh [--extension <拡張のディレクトリ>]' "$test_dir/err"
done
if run_extension "$test_dir" --extension ''; then exit 1; fi
grep -qF '使い方: bash setup.sh [--extension' "$test_dir/err"
[[ ! -e $test_dir/ext-state && ! -s $TEST_CALLS ]]
echo 'PASS setup: 値のない・重なった --extension と、ほかの引数は使い方を出して止まる'
base_input yes
run
grep -qF '? 拡張のディレクトリ' "$test_dir/err"
! grep -qF '引数で指定' "$test_dir/err"
echo 'PASS setup: 引数がないときは、今と同じく拡張のディレクトリを質問で聞く'

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

# Linux と WSL 2 も、同じ回答で新規導入と再実行を通す。
unset TEST_REPOS_FILE
for kernel in 6.8.0-generic 6.6.87.2-microsoft-standard-WSL2; do
 export TEST_OS=Linux TEST_KERNEL="$kernel" TEMPLATE_STATE_ROOT="$test_dir/linux-$kernel"
 base_input yes
 run
 cp "$TEMPLATE_STATE_ROOT/ws-a/demo.json" "$test_dir/linux-before"
 run
 cmp "$TEMPLATE_STATE_ROOT/ws-a/demo.json" "$test_dir/linux-before"
done
echo 'PASS setup: Linux と WSL 2 の導入・再実行は同じ保存値になる'
