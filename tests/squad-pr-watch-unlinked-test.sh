#!/usr/bin/env bash
# 紐付けの判定を、実物の空の一覧と、見本なしとして宣言した要素の欄で確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"

# 要素はまだ採取できていないため、約束で宣言した html_url だけをテストに使う。
assert_jq '.entries["issue-pull-requests"].items.fields == [{path:"html_url",class:"required",nullable:false}]' "$test_dir/contracts.json"
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-} ${2-} ${3-}" == 'issue pull-requests test-issue' ]]; then
	[[ "$*" == 'issue pull-requests test-issue --output json' ]]
	jq -cn --args '$ARGS.positional' -- "$@" >>"$PR_WATCH_TEST_DIR/calls.jsonl"
	[[ ! -f $PR_WATCH_TEST_DIR/fail-pulls ]] || exit 1
	cat "$PR_WATCH_TEST_DIR/pulls.json"
else
	exec "$PR_WATCH_TEST_DIR/bin/multica-base" "$@"
fi
EOF
chmod +x "$test_dir/bin/multica"

pr=https://github.com/Example/Repo/pull/67
other=https://github.com/Example/Repo/pull/68
link_reset() {
	reset_fixture
	rm -f "$test_dir/fail-pulls"
	jq --arg pr "$pr" '.metadata.pr_url = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
	jq '.[0]' tests/fixtures/cli/issue-pull-requests.json >"$test_dir/pulls.json"
}
linked_urls() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url: .}]}' -- "$@" >"$test_dir/pulls.json"
}
check_link() {
	check_output "$1" link-check test-issue
	[[ ! -s $test_dir/posted.jsonl && ! -s $test_dir/wakeups.jsonl ]]
	assert_jq -s 'all(.[]; .[0:2] == ["issue","get"] or .[0:2] == ["issue","pull-requests"] or . == ["version"])' "$test_dir/calls.jsonl"
}
unknown_link() {
	local line
	line=$(cd "$test_dir" && bash "$script" link-check test-issue)
	[[ $line == "紐付け: 未確認 pr: $1 理由: "* && $line != *$'\n'* ]]
}

link_reset
check_link "紐付け: 紐付いていない pr: $pr"
echo 'PASS link-check: 読めた空の一覧だけを紐付いていないとし、何も書き込まない'

for value in absent null empty; do
	link_reset
	case $value in
	absent) jq 'del(.metadata.pr_url)' "$test_dir/task.json" ;;
	null) jq '.metadata.pr_url = null' "$test_dir/task.json" ;;
	empty) jq '.metadata.pr_url = ""' "$test_dir/task.json" ;;
	esac >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
	check_link '紐付け: pr_url なし pr: 不明'
	linked_urls "$other" "$pr"
	check_link "紐付け: pr_url なし pr: 不明 紐付いた PR: $other, $pr"
done
echo 'PASS link-check: pr_url がなければ、一覧から自動で選ばず、正規形の URL を並べる'

link_reset
linked_urls "$other" https://github.com/Another/Repo/pull/67
check_link "紐付け: 食い違い pr: $pr 紐付いた PR: $other, https://github.com/Another/Repo/pull/67"
echo 'PASS link-check: 一覧に別の PR だけがあれば、食い違いと両方の URL を出す'

for url in "$pr" https://GITHUB.COM/example/REPO/pull/67/ 'https://github.com/EXAMPLE/repo/pull/67/files?diff=split'; do
	link_reset
	linked_urls "$other" "$url"
	check_link "紐付け: 紐付いている pr: $pr"
done
link_reset
pr_suffix='https://github.com/EXAMPLE/repo/pull/67/files?diff=split'
jq --arg pr "$pr_suffix" '.metadata.pr_url = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/task.json"
linked_urls "$pr"
check_link "紐付け: 紐付いている pr: https://github.com/EXAMPLE/repo/pull/67"
echo 'PASS link-check: 複数 PR、大文字・小文字、末尾の /・files・クエリを同じ PR と読む'

link_reset
touch "$test_dir/fail-pulls"
unknown_link "$pr"
for response in '{}' '{"pull_requests":null}' '{"pull_requests":{}}' '{"pull_requests":[{}]}' '{"pull_requests":[{"html_url":null}]}' '{"pull_requests":[{"html_url":42}]}' 'not-json'; do
	link_reset
	printf '%s\n' "$response" >"$test_dir/pulls.json"
	unknown_link "$pr"
done
echo 'PASS link-check: 一覧の読み取り失敗・欄の欠落・null・形の不正は未確認を 1 行で出し、0 で終える'

link_reset
echo 'issue get test-issue' >"$test_dir/fail"
unknown_link 不明
link_reset
jq 'del(.metadata)' "$test_dir/task.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/task.json"
touch "$test_dir/allow-missing-fields"
unknown_link 不明
echo 'PASS link-check: タスクを読めないときも未確認を出す'

for args in 'link-check' 'link-check test-issue extra'; do
	status=0
	# 引数の不足と過剰は、使い方と終了コード 2 を返す。
	# shellcheck disable=SC2086
	bash "$script" $args >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 2 && ! -s $test_dir/output ]]
	grep -q '使い方: squad-pr-watch link-check <タスク>' "$test_dir/error"
done
echo 'PASS link-check: 引数の数が違えば使い方を標準エラーに出し、2 で終える'
