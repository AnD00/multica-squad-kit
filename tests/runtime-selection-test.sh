#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
cat >"$test_dir/pick.sh" <<'DRIVER'
set -euo pipefail
root=$1
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/questions.sh"
ui_init
command() {
 if [[ $# == 2 && $1 == -v && ( $2 == claude || $2 == codex ) && " $TEST_AVAILABLE " != *" $2 "* ]]; then return 1; fi
 builtin command "$@"
}
check_tools
question_number=0; question_total=1
pick_runtimes "$TEST_PREVIOUS"
printf '%s\n' "$runtimes"
DRIVER
export TEST_AVAILABLE='claude codex' TEST_PREVIOUS='{}'
pick() { /bin/bash "$test_dir/pick.sh" "$root" <"$test_dir/input" >"$test_dir/out" 2>"$test_dir/err"; }
printf '\n' >"$test_dir/input"
for available in 'claude codex' claude codex; do
 TEST_AVAILABLE=$available pick
 jq -e --arg available "$available" '.==($available|split(" "))' "$test_dir/out" >/dev/null
done
echo 'PASS runtimes: 初回の既定は、見つかったコマンドに合わせて両方・Claude・Codexになる'
TEST_AVAILABLE='' pick && exit 1
grep -qF '利用する組織の手順' "$test_dir/err"
[[ ! -e $TEST_CALLS ]]
echo 'PASS runtimes: 両コマンドがない場合は、質問とCLI取得より前に導入を案内して止まる'

TEST_PREVIOUS='{"runtimes":["codex"]}' pick
jq -e '.==["codex"]' "$test_dir/out" >/dev/null
printf '0\n9\n1 2\n2\n' >"$test_dir/input"
pick
jq -e '.==["claude"]' "$test_dir/out" >/dev/null
grep -qF '一つの番号だけ' "$test_dir/err"
printf '1\n3\n2\n' >"$test_dir/input"
TEST_AVAILABLE=claude pick
jq -e '.==["claude"]' "$test_dir/out" >/dev/null
[[ $(grep -cF 'codex がありません' "$test_dir/err") == 2 ]]
grep -qF 'codex: コマンドが見つかりません' "$test_dir/err"
echo 'PASS runtimes: 保存値を既定にし、複数の番号と未導入のランタイムを同じ質問で直す'

# 質問と保存の試験。登録とホストは setup-fixture で差し替える。
printf '1\n1\ndemo\n1\nmembera\n0\n2\n3\n0\nyes\n' >"$test_dir/input"
run
saved="$TEMPLATE_STATE_ROOT/ws-a/demo.json"
jq -e '.schema==1 and .runtimes==["claude"] and .excluded_roles==[]' "$saved" >/dev/null
grep -qF '少なくとも一系統' "$test_dir/err"
grep -qF 'Codex の実装・修正:' "$test_dir/err"
grep -qF '使うランタイムにないため外れます' "$test_dir/err"
grep -qF 'エージェント: 13件' "$test_dir/err"
printf '1\n1\ndemo\n1\nmembera\n0\n3\n4\n0\nyes\n' >"$test_dir/input"
run
jq -e '.runtimes==["codex"] and .excluded_roles==[]' "$saved" >/dev/null
grep -qF '少なくとも一系統' "$test_dir/err"
echo 'PASS runtimes: 残る系統の除外は聞き直し、ない系統の除外を説明し、自分で選んだ除外だけを保存する'

source "$root/lib/answers.sh"
jq 'del(.runtimes)' "$saved" >"$test_dir/legacy.json"
load_answers "$test_dir/legacy.json" >"$test_dir/loaded.json"
jq -e '.schema==1 and .runtimes==["claude","codex"]' "$test_dir/loaded.json" >/dev/null
cp "$test_dir/legacy.json" "$saved"
printf '1\n\n\n\n\n\n\n0\nyes\n' >"$test_dir/input"
run
jq -e '.runtimes==["claude","codex"] and .excluded_roles==[]' "$saved" >/dev/null
for value in '[]' 'null' '"claude"' '["other"]' '["claude","claude"]'; do
 jq --argjson value "$value" '.runtimes=$value' "$saved" >"$test_dir/invalid.json"
 if valid_answers "$test_dir/invalid.json"; then exit 1; fi
done
echo 'PASS runtimes: 旧回答は両方として読み、Enterで両方を保存し、空・未知・重複・型の違う選択は拒否する'
