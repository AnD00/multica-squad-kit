#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-retry-limit-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の rebase・recreate の合計回数と実行全体の上限を確認する。
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

for mixed in false true; do
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	for n in 2 3 4; do
		add_pr "$n" dependabot/go_modules/api/example "$(metadata patch)"
		new_head=$(printf '%040d' "$n")
		edit_pr ".headRefOid = \"$new_head\" | .mergeable = \"MERGEABLE\" | .mergeStateStatus = \"BEHIND\""
		if [[ $mixed == true && $n == 2 ]]; then edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
		: >"$test_dir/calls.jsonl"
		if [[ $n == 4 ]]; then run_advance behind-limit --retry; no_writes
		else run_advance waiting --retry; fi
		jq -e --argjson expected "$((n < 4 ? n : 3))" 'length == $expected' "$test_dir/comments.json" >/dev/null
	done
done
echo 'PASS advance: 反映後に main に遅れれば頼み直し、rebase・recreate の合計 3 回で behind-limit'

retries_after_response() {
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	printf '200600\n' >"$test_dir/now"
	run_advance waiting --retry
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\""
	# 反映後の再依頼も、全体の 3 回の中に含める。
	run_advance waiting --retry
	jq -e 'length == 3 and ([.[] | select(.body | contains("<!-- squad-dependabot-merger retry -->"))] | length) == 1' "$test_dir/comments.json" >/dev/null
}
retries_after_response
printf '201200\n' >"$test_dir/now"
: >"$test_dir/calls.jsonl"
run_advance no-response --retry
no_writes
echo 'PASS advance: 無反応への頼み直しも合計 3 回に含め、head が変わっても無反応の再依頼は増やさない'

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
	printf '214400\n' >"$test_dir/now"
	run_advance run-timeout --retry
	no_writes
done
advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
printf '214390\n' >"$test_dir/now"
run_advance waiting
printf '214400\n' >"$test_dir/now"
: >"$test_dir/calls.jsonl"
run_advance run-timeout --retry
no_writes
echo 'PASS advance: 実行全体の上限では、新しい依頼も反映待ちも run-timeout'
