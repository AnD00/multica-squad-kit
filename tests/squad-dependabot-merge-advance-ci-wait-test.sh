#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-ci-wait-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の CI・マージ可否の待ちを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

for state in CLEAN BEHIND; do
	advance_fixture
	edit_pr ".mergeStateStatus = \"$state\""
	printf '214400\n' >"$test_dir/now"
	printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >"$test_dir/checks.json"
	run_advance ci-failed
	no_writes
done
echo 'PASS advance: 必須 CI の失敗は締め切り・rebase の依頼より先に ci-failed'

advance_fixture
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
printf '201785\n' >"$test_dir/now"
run_advance ci-timeout
[[ $(<"$test_dir/now") == 201800 ]]
no_writes
advance_fixture
edit_pr '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
run_advance waiting
[[ $(<"$test_dir/now") == 200300 ]]
no_writes
echo 'PASS advance: 必須 CI の未登録は締め切りまで、可否が不明なら最大 5 分で waiting'

advance_fixture
jq '.commit.committer.date = "invalid"' "$test_dir/$reviewed.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/$reviewed.json"
if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -s $test_dir/error ]]
no_writes
echo 'PASS advance: GitHub のコミット時刻が不正な場合は操作せずエラー'
