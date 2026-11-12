#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-retry-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の rebase・recreate の依頼と再試行を確かめる。
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

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'; command=rebase
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; command=recreate; fi
	run_advance waiting
	jq -e --arg command "@dependabot $command" --arg head "$reviewed" 'length == 1 and
		(.[0].body | startswith($command + "\n\n")) and (.[0].body | contains($head))' "$test_dir/comments.json" >/dev/null
	# 依頼したファイルは残さず、2 回目は同じ依頼を繰り返さない。
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/body-files"
	run_advance waiting
	jq -e 'length == 1' "$test_dir/comments.json" >/dev/null
	if [[ $state == CONFLICTING ]]; then
		add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
		edit_pr ".headRefOid = \"$head2\""
		: >"$test_dir/calls.jsonl"
		run_advance conflict
		no_writes
	fi
done
echo 'PASS advance: 未反映の rebase・recreate は重複依頼せず、作り直し後も衝突なら conflict'

advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
# 過去の実行・別の作者の依頼は、今回の依頼として数えない。ページもまたぐ。
printf '[{"id":1,"user":{"login":"test-user"},"created_at":"1970-01-03T07:33:19Z","body":"@dependabot rebase"}]\n[{"id":2,"user":{"login":"other"},"created_at":"1970-01-03T07:33:20Z","body":"@dependabot rebase"}]\n' >"$test_dir/comments.json"
# mock の追記は配列 1 個を扱うため、まず既存のページをまとめる。
jq -s add "$test_dir/comments.json" >"$test_dir/comments-flat.json"
mv "$test_dir/comments-flat.json" "$test_dir/comments.json"
run_advance waiting
jq -e 'length == 3' "$test_dir/comments.json" >/dev/null
# 今回の依頼が 2 ページ目にあっても、追加で依頼しない。
jq '.[2:]' "$test_dir/comments.json" >"$test_dir/comments-page2.json"
jq '.[0:2]' "$test_dir/comments.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/comments.json"
cat "$test_dir/comments-page2.json" >>"$test_dir/comments.json"
: >"$test_dir/calls.jsonl"
run_advance waiting
no_writes
echo 'PASS advance: 過去の実行と他の作者の依頼は今回の依頼に混ぜない'

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
	run_advance waiting --retry
	# 反映の待ちは、呼び出した時刻ではなく依頼コメントの時刻から数える。
	printf '200599\n' >"$test_dir/now"
	: >"$test_dir/calls.jsonl"
	run_advance waiting --retry
	no_writes
	printf '200600\n' >"$test_dir/now"
	run_advance no-response
	no_writes
	run_advance waiting --retry
	jq -e 'length == 2 and (.[1].body | contains("<!-- squad-dependabot-merger retry -->"))
		and .[1].created_at == "1970-01-03T07:43:20Z"' "$test_dir/comments.json" >/dev/null
	: >"$test_dir/calls.jsonl"
	printf '201199\n' >"$test_dir/now"
	run_advance waiting --retry
	no_writes
	printf '201200\n' >"$test_dir/now"
	run_advance no-response --retry
	run_advance no-response --retry
	no_writes
	jq -e 'length == 2' "$test_dir/comments.json" >/dev/null
done
echo 'PASS advance: rebase・recreate は 10 分で no-response、--retry は呼び直しても 1 回だけ'

