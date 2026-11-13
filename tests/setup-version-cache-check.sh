#!/usr/bin/env bash
# setup-version-test.sh から呼ぶ、再利用の境界の確認。PASS 行は増やさない。
set -euo pipefail
scratch=$1/cache-check
repo=$2
mkdir -p "$scratch/cache"
root=$scratch
printf 'package-one\n' >"$root/MANIFEST"
export TEST_SETUP_VERSION_CACHE="$scratch/cache" TEST_SETUP_VERSION_STUB="$scratch/stub"
printf 'fixture-one\n' >"$TEST_SETUP_VERSION_STUB"
answers=answers-one
ui_color_out=no ui_color_err=no ui_live_out=no ui_live_err=no
confirmation_plan() {
 printf 'plan\n' >>"$scratch/calls"
 cat "$TEST_SETUP_VERSION_STUB"
 printf '%s\n' "$answers"
 if [[ ${TEST_CACHE_FAILURE:-no} == yes ]]; then
  echo 'expected failure' >&2
  return 13
 fi
}
confirmation_show() {
 printf 'show\n' >>"$scratch/calls"
 printf 'stdout:%s\n' "$1"
 printf 'stderr:%s\n' "$1" >&2
}
source "$repo/tests/setup-version-cache.sh"
# 失敗した結果は再利用せず、終了コードと両出力を保つ。
export TEST_CACHE_FAILURE=yes
for attempt in 1 2; do
 status=0
 value=$(confirmation_plan 2>"$scratch/error") || status=$?
 [[ $status == 13 && $value == $'fixture-one\nanswers-one' ]]
 grep -qxF 'expected failure' "$scratch/error"
done
[[ $(grep -c '^plan$' "$scratch/calls") == 2 ]]
unset TEST_CACHE_FAILURE
value=$(confirmation_plan)
[[ $value == $'fixture-one\nanswers-one' ]]
[[ $(confirmation_plan) == "$value" ]]
[[ $(grep -c '^plan$' "$scratch/calls") == 3 ]]
# 回答と CLI の状態を別々に変え、古い結果を使わない。
answers=answers-two
[[ $(confirmation_plan) == $'fixture-one\nanswers-two' ]]
printf 'fixture-two\n' >"$TEST_SETUP_VERSION_STUB"
[[ $(confirmation_plan) == $'fixture-two\nanswers-two' ]]
[[ $(grep -c '^plan$' "$scratch/calls") == 5 ]]
# 外から応答のファイルを指定した場合は、同じ入力でも再利用しない。
export TEST_AGENTS_FILE="$scratch/agents.json"
[[ $(confirmation_plan) == $'fixture-two\nanswers-two' ]]
[[ $(confirmation_plan) == $'fixture-two\nanswers-two' ]]
[[ $(grep -c '^plan$' "$scratch/calls") == 7 ]]
unset TEST_AGENTS_FILE
# 表示は両出力をそのまま再利用し、予定が違えば元の処理を通す。
confirmation_show plan-one >"$scratch/out-one" 2>"$scratch/err-one"
confirmation_show plan-one >"$scratch/out-two" 2>"$scratch/err-two"
cmp "$scratch/out-one" "$scratch/out-two"
cmp "$scratch/err-one" "$scratch/err-two"
[[ $(grep -c '^show$' "$scratch/calls") == 1 ]]
confirmation_show plan-two >"$scratch/out-two" 2>"$scratch/err-two"
grep -qxF 'stdout:plan-two' "$scratch/out-two"
grep -qxF 'stderr:plan-two' "$scratch/err-two"
[[ $(grep -c '^show$' "$scratch/calls") == 2 ]]
# 表示の内部で失敗したときも、元の errexit を無効にしない。
cat >"$scratch/errexit.sh" <<'CHILD'
set -euo pipefail
root=$1
answers=errexit-case
confirmation_plan() { :; }
confirmation_show() { false; echo unreachable; }
source "$2/tests/setup-version-cache.sh"
confirmation_show plan-errexit
CHILD
status=0
/bin/bash "$scratch/errexit.sh" "$scratch" "$repo" >"$scratch/errexit-out" 2>"$scratch/errexit-err" || status=$?
[[ $status == 1 ]]
[[ ! -s $scratch/errexit-out ]]
