#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-ci-origin-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の CI の締め切りの起点を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

for committed_at in 190000 200900; do
	advance_fixture
	commit_time "$reviewed" "$committed_at"
	printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
	ci_origin=$committed_at
	((ci_origin >= 200000)) || ci_origin=200000
	printf '%s\n' "$((ci_origin + 1799))" >"$test_dir/now"
	run_advance ci-timeout
	[[ $(<"$test_dir/now") == "$((ci_origin + 1800))" ]]
	no_writes
done
rebase_fixture
commit_time "$head2" 201000
printf '201500\n' >"$test_dir/now"
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance waiting
[[ $(<"$test_dir/now") == 201800 ]]
printf '202799\n' >"$test_dir/now"
run_advance ci-timeout
[[ $(<"$test_dir/now") == 202800 ]]
no_writes
echo 'PASS advance: CI は GitHub のコミット時刻と実行開始の遅いほうから 30 分、rebase 後は新しい head が起点'

