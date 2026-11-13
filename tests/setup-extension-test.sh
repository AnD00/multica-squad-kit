#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest

# 拡張のディレクトリだけは引数で受け、質問で答えたときと同じ確認をする。
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
