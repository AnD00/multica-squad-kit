#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-ci-change-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の待ち中の PR の変化と、API・コメントの失敗を確かめる。
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

head2=$(printf '%040d' 2)

advance_fixture
cp "$test_dir/checks.json" "$test_dir/next-checks.json"
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance merged
[[ $(<"$test_dir/now") == 200010 ]]
advance_fixture
printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >"$test_dir/checks.json"
run_advance ci-failed
no_writes
echo 'PASS advance: 待つ間の CI 成功でマージ、CI の失敗では ci-failed'

advance_fixture
add_pr 2 dependabot/go_modules/api/example "$(metadata minor | sed 's/1.2.3/1.3.0/')"
edit_pr ".headRefOid = \"$head2\""
cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
edit_pr ".headRefOid = \"$reviewed\""
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance changed
no_writes
echo 'PASS advance: CI 待ちの間にバージョンが変わった場合も changed'

for branch in dependabot/go_modules/api/example dependabot/npm_and_yarn/e2e/example \
	dependabot/github_actions/example dependabot/docker/debian dependabot/docker_compose/debian; do
	for timing in before waiting; do
		advance_fixture
		edit_pr ".headRefName = \"$branch\""
		add_pr 2 "$branch" "$(metadata patch)"
		# 名前とバージョンは同じでも、未確認の依存差分と通常コードを加えた head。
		jq '. + {files:[{filename:"api/go.sum",patch:"+unreviewed checksum"},
			{filename:"viewer/auth.go",patch:"-validateToken()"}]}' "$test_dir/$head2.json" >"$test_dir/edit.json"
		mv "$test_dir/edit.json" "$test_dir/$head2.json"
		edit_pr ".headRefOid = \"$head2\""
		if [[ $timing == waiting ]]; then
			cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
			edit_pr ".headRefOid = \"$reviewed\""
			printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
		fi
		run_advance changed
		no_writes
		if [[ $timing == waiting ]]; then [[ $(<"$test_dir/now") == 200010 ]]; fi
	done
done
echo 'PASS advance: 全 ecosystem で同じ名前・バージョンの未確認差分も、開始時・CI 待ち中に changed'

for initial_kind in patch minor; do
	for timing in before waiting; do
		advance_fixture
		jq --arg message "$(metadata "$initial_kind")" '.commit.message = $message' "$test_dir/$reviewed.json" >"$test_dir/edit.json"
		mv "$test_dir/edit.json" "$test_dir/$reviewed.json"
		add_pr 2 dependabot/go_modules/api/example "$(metadata major | sed 's/1.2.3/2.0.0/')"
		head2=$(printf '%040d' 2)
		edit_pr ".headRefOid = \"$head2\""
		if [[ $timing == waiting ]]; then
			cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
			edit_pr ".headRefOid = \"$reviewed\""
			printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
		fi
		run_advance changed
		if [[ $timing == waiting ]]; then [[ $(<"$test_dir/now") == 200010 ]]; fi
		# changed を受けた呼び出し側が再取得し、メジャーとして人間に回せる。
		run_list
		assert_output '[.[] | select(.number == 1)] | length == 1 and .[0].update_type == "major"'
		no_writes
	done
done
echo 'PASS advance: 確認済みの patch・minor が開始時・CI 待ち中に major へ変われば changed、再取得で major'

for endpoint in /check-runs /comments; do
	advance_fixture
	printf '214385\n' >"$test_dir/now"
	[[ $endpoint != /comments ]] || edit_pr '.mergeStateStatus = "BEHIND"'
	printf '%s\n' "$endpoint" >"$test_dir/tick-on"
	if [[ $endpoint == /check-runs ]]; then run_advance merged
	else run_advance run-timeout; no_writes; fi
done
echo 'PASS advance: API 取得中に締め切りを超えてもマージ可能なら merged、追従の依頼はしない'

advance_fixture
touch "$test_dir/merge-fail"
run_advance merge-failed
grep -q 'mock merge rejected head mismatch' "$test_dir/output"
echo 'PASS advance: GitHub の拒否を merge-failed と 1 行の理由で返す'

for failure in rules/branches /check-runs /statuses 'pr comment' /comments; do
	advance_fixture
	if [[ $failure == 'pr comment' || $failure == /comments ]]; then edit_pr '.mergeStateStatus = "BEHIND"'; fi
	printf '%s\n' "$failure" >"$test_dir/fail"
	if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output && -s $test_dir/error ]]
	if [[ $failure != 'pr comment' ]]; then no_writes; fi
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/body-files"
done
echo 'PASS advance: API・コメントの失敗で操作を続けず、成功した結果も出さない'
