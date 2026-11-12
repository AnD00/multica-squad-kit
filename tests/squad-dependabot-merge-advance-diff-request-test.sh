#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-diff-request-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の差分を取得できない場合の依頼と反映を確かめる。
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

# 依頼前の差分が比べられなくても、head が安定していれば、ハッシュなしで依頼して先に進む。
for failure in api empty malformed binary; do
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	case $failure in
	api) printf 'repos/example/template/pulls/1 -H\n' >"$test_dir/fail" ;;
	empty) : >"$test_dir/pr.diff" ;;
	malformed) printf '{"message":"Unavailable"}\n' >"$test_dir/pr.diff" ;;
	binary) printf 'diff --git a/logo.png b/logo.png\nindex 1111111..2222222 100644\nBinary files a/logo.png and b/logo.png differ\n' >"$test_dir/pr.diff" ;;
	esac
	run_advance waiting
	# 再確認後の呼び直しも、同じ head のまま、依頼を重ねずに反映を待つ。
	run_advance waiting
	[[ $(jq length "$test_dir/comments.json") == 1 ]]
	jq -e --arg head "$reviewed" '.[0].body | startswith("@dependabot rebase\n") and contains("<!-- squad-dependabot-merger head: " + $head + " -->")
		and (contains("diff:") | not)' "$test_dir/comments.json" >/dev/null
	# 反映後は、ハッシュがないので必ず確認し直し、確認済みの head を替えれば進める。
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\" | .mergeStateStatus = \"CLEAN\""
	rm -f "$test_dir/fail"
	run_advance changed
	reviewed=$head2
	run_advance merged
done
echo 'PASS advance: head が安定したまま依頼前の差分を比べられなくても、ハッシュなしで依頼し、反映後は changed を経て進む'

advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
touch "$test_dir/changed-head"
run_advance changed
no_writes
echo 'PASS advance: 依頼前の差分取得中に head が変わったら changed、書き込みなし'

