#!/usr/bin/env bash
# 定期確認の停止条件、通知先、重複の防止、一覧を読めないときの継続を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
pr=https://github.com/example/repo/pull/67
other=https://github.com/example/repo/pull/68
mark='紐付いていない PR のマージ待ちの見張りで起きました。'
# 要素の実物は未採取なので、宣言された必須欄だけをケースに使う。
assert_jq '.entries["issue-pull-requests"].items.fields == [{path:"html_url",class:"required",nullable:false}]' "$test_dir/contracts.json"
update_task() {
	jq "$1" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
}
update_pr() {
	jq "$1" "$test_dir/mergeable.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/mergeable.json"
}
linked_urls() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url:.}]}' -- "$@" >"$test_dir/pulls.json"
}
reset_unlinked() {
	reset_fixture
	update_task ".status = \"in_review\" | .metadata.pr_url = \"$pr\""
	fixture issue-wakeups | jq --arg mark "$mark" '. as $base | [$base + {id:"mine",instruction:($mark + "\n確認")},
		$base + {id:"other",instruction:"PR の CI が終わりました。"}]' >"$test_dir/rules.json"
}
run_unlinked() { (cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator "$@"); }
assert_mine_deleted() { assert_jq 'map(.id) == ["other"]' "$test_dir/rules.json"; }

for value in done cancelled merged closed in-progress linked; do
	reset_unlinked
	case $value in
	done | cancelled) update_task ".status_category = \"$value\"" ;;
	merged | closed) update_pr ".state = \"$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')\"" ;;
	in-progress) update_task '.status = "in_progress"' ;;
	linked) linked_urls "$other" "$pr" ;;
	esac
	line=$(run_unlinked monitor)
	[[ $line == /note$'\n止めた: '* && $line != *'CI abcdef0:'* && $line != *'コンフリクト:'* ]]
	assert_mine_deleted
	[[ ! -s $test_dir/posted.jsonl ]]
	assert_jq -s 'all(.[]; .[4] == "state,headRefOid,mergeable")' "$test_dir/gh-calls.jsonl"
done
echo 'PASS unlinked-check: 終了・PR終了・マージ待ちからの離脱・紐付けで自分の規則だけを消し、CIを確認しない'

reset_unlinked
update_pr '.mergeable = "CONFLICTING"'
line=$(run_unlinked monitor)
[[ $line == $'/note\nCI abcdef0: 失敗をリーダーに知らせた\nコンフリクト: CONFLICTING head: abcdef0123456789 知らせ: 書いた' ]]
assert_jq -s 'length == 2 and all(.[]; (.body | contains("mention://squad/test-squad")))
	and (.[1].body | startswith("head: abcdef0\nコンフリクトを検出しました。\n"))
	and (.[1].body | contains("PR: https://github.com/example/repo/pull/67\nコンフリクト: CONFLICTING head: abcdef0123456789"))' "$test_dir/posted.jsonl"
line=$(run_unlinked monitor)
[[ $line == $'/note\nCI abcdef0: 失敗は知らせ済み\nコンフリクト: CONFLICTING head: abcdef0123456789 知らせ: 知らせ済み' ]]
assert_jq -s 'length == 2' "$test_dir/posted.jsonl"
update_pr '.headRefOid = "123456789abcdef0"'
jq '.headRefOid = "123456789abcdef0"' "$test_dir/pr.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/pr.json"
line=$(run_unlinked monitor)
[[ $line == *'CI 1234567: 失敗をリーダーに知らせた'* && $line == *'知らせ: 書いた' ]]
assert_jq -s 'length == 4' "$test_dir/posted.jsonl"
echo 'PASS unlinked-check: CIとコンフリクトをスクワッドへ知らせ、同じheadは重ねず、新しいheadは知らせる'

reset_unlinked
update_pr '.mergeable = "CONFLICTING"'
line=$(run_unlinked)
[[ $line == $'/note\nCI abcdef0: 失敗あり\nコンフリクト: CONFLICTING head: abcdef0123456789 知らせ: 書いた' ]]
assert_jq -s 'length == 2 and all(.[]; (.body | contains("mention://") | not))' "$test_dir/posted.jsonl"
line=$(run_unlinked)
[[ $line == *'知らせ: 知らせ済み' ]]
assert_jq -s 'length == 2' "$test_dir/posted.jsonl"
echo 'PASS unlinked-check: 見張り役がなければメンションなしで記録し、書いた・知らせ済みを行で返す'

for monitor in monitor none; do
	reset_unlinked
	linked_urls "$other"
	args=()
	if [[ $monitor != none ]]; then args=(monitor); fi
	line=$(run_unlinked ${args[@]+"${args[@]}"})
	[[ $line == "/note"$'\n'"紐付け: 食い違い pr: $pr 紐付いた PR: $other" ]]
	assert_mine_deleted
	assert_jq -s 'length == 1 and (.[0].body | startswith("紐付けの食い違いを検出しました。\n紐付け: 食い違い pr:"))
		and (.[0].body | contains("https://github.com/example/repo/pull/67"))
		and (.[0].body | contains("https://github.com/example/repo/pull/68"))' "$test_dir/posted.jsonl"
	if [[ $monitor == monitor ]]; then
		assert_jq -s '.[0].body | contains("mention://squad/test-squad")' "$test_dir/posted.jsonl"
	else
		assert_jq -s '.[0].body | contains("mention://") | not' "$test_dir/posted.jsonl"
	fi
	assert_jq -s 'length == 1' "$test_dir/gh-calls.jsonl"
done
echo 'PASS unlinked-check: 食い違いは両方のURLを書き、見張り役に応じて通知し、CIとコンフリクトを確認しない'

reset_unlinked
linked_urls "$other"
echo 'issue wakeup delete' >"$test_dir/fail"
for attempt in 1 2; do
	status=0
	run_unlinked monitor >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 ]]
	assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
done
rm "$test_dir/fail"
linked_urls https://github.com/example/repo/pull/69
line=$(run_unlinked monitor)
assert_jq -s 'length == 2' "$test_dir/posted.jsonl"
assert_mine_deleted
echo 'PASS unlinked-check: 規則を消せず再実行しても食い違いを重ねず、一覧が変われば新しく知らせる'

for value in cli missing-field missing-url; do
	reset_unlinked
	case $value in
	cli) echo 'issue pull-requests test-issue' >"$test_dir/fail" ;;
	missing-field) echo '{}' >"$test_dir/pulls.json" ;;
	missing-url) echo '{"pull_requests":[{}]}' >"$test_dir/pulls.json" ;;
	esac
	line=$(run_unlinked monitor)
	[[ $line == /note$'\n紐付け: 未確認 '* && $line == *'CI abcdef0: 失敗をリーダーに知らせた'* && $line == *'コンフリクト: MERGEABLE head: abcdef0123456789 知らせ: なし' ]]
	assert_jq 'length == 2' "$test_dir/rules.json"
done
echo 'PASS unlinked-check: 一覧の読み取りや欄の検証が失敗しても、未確認を添えてCIとコンフリクトを確認する'

reset_unlinked
touch "$test_dir/fail-conflicts"
status=0
run_unlinked monitor >"$test_dir/output" 2>"$test_dir/error" || status=$?
[[ $status == 1 ]]
assert_jq -s 'length == 1 and (.[0].body | contains("CI の失敗を検出しました。"))' "$test_dir/posted.jsonl"
if grep -q 'コンフリクト:' "$test_dir/output"; then exit 1; fi
reset_unlinked
echo 'issue runs test-issue' >"$test_dir/fail"
status=0
run_unlinked monitor >"$test_dir/output" 2>"$test_dir/error" || status=$?
[[ $status == 1 && ! -s $test_dir/posted.jsonl ]]
echo 'PASS unlinked-check: CI・コンフリクトのCLI失敗は非0で返し、確認できたという行に置き換えない'
