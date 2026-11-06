#!/usr/bin/env bash
set -euo pipefail
root=$1 run_dir=$2 id=$3 test=$4
work="$run_dir/$id"
cd "$root"
started=$(date +%s)
status=0
HOME="$work/home" TMPDIR="$work/tmp/" BASH_ENV="$root/tests/run-hook.sh" SQUAD_KIT_TEST_ERROR_FILE="$work/error" \
	bash "$test" >"$work/log" 2>&1 || status=$?
elapsed=$(($(date +%s) - started))
printf '%s %s\n' "$status" "$elapsed" >"$work/result"
outcome=FAIL
if [[ $status == 0 ]]; then outcome=PASS; fi
printf 'done %s %s %ss\n' "$outcome" "$test" "$elapsed"
# テストの失敗によって xargs が残りを起こさなくなるのを防ぐ。
exit 0
