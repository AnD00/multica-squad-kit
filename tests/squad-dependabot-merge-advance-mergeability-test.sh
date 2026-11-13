#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-mergeability-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の CI 成功後のマージ可否の待ちを確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

advance_fixture
edit_pr '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
printf '202000\n' >"$test_dir/now"
run_advance waiting
[[ $(<"$test_dir/now") == 202300 ]]
printf '214399\n' >"$test_dir/now"
run_advance run-timeout
[[ $(<"$test_dir/now") == 214400 ]]
no_writes
echo 'PASS advance: CI 成功後のマージ可否待ちは CI の上限にせず、5 分の呼び出し・実行全体の上限で返す'

