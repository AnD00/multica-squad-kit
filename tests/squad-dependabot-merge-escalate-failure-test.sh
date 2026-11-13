#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-escalate-failure-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。escalate のタスクの作成と、引数・契約の検査を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-escalate-test-lib.sh"

for invalid in unknown duplicate missing-id; do
	escalate_fixture
	case $invalid in
	unknown) printf '[]' >"$test_dir/members.json" ;;
	duplicate) jq '.[0] as $base | . + [$base + {user_id:"member-b"}]' "$test_dir/members.json" >"$test_dir/edit.json"; mv "$test_dir/edit.json" "$test_dir/members.json" ;;
	missing-id) touch "$test_dir/allow-missing-fields"; jq 'map(del(.user_id))' "$test_dir/members.json" >"$test_dir/edit.json"; mv "$test_dir/edit.json" "$test_dir/members.json" ;;
	esac
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	no_issue_writes
done
echo 'PASS escalate: メンバー不明・同名・user_id なしは作成せず拒否'

for target in labels search pr; do
	escalate_fixture
	case $target in
	labels) printf '[]\n' >"$test_dir/labels.json" ;;
	search) touch "$test_dir/allow-missing-fields"; printf '{}'  >"$test_dir/search.json" ;;
	pr) edit_pr '.author.login = "human"' ;;
	esac
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	no_issue_writes
done
escalate_fixture
cli_fixture issue-search | jq '.issues[0] as $base | .issues = [range(0;1000) | $base + {title:"別のタスク"}]' >"$test_dir/search.json"
if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
grep -q '検索結果が上限' "$test_dir/error"
no_issue_writes
echo 'PASS escalate: ラベル不明・検索結果の異常や上限・対象外の PR は作成しない'

for failure in 'issue search' 'label list' 'workspace member' 'issue create'; do
	escalate_fixture
	printf '%s\n' "$failure" >"$test_dir/multica-fail"
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	grep -q 'Multica mock failure' "$test_dir/error"
	[[ ! -e $test_dir/created.json ]]
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
done
echo 'PASS escalate: CLI の取得・作成失敗を伝え、一時本文を片付ける'

escalate_fixture
printf 'issue label add\n' >"$test_dir/multica-fail"
if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -f $test_dir/created.json ]]
grep -q '同じタスクに補います' "$test_dir/error"
while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
rm "$test_dir/multica-fail"
run_escalate 'TEST-9000 exists'
jq -se '[.[] | select(.[0:2] == ["issue","create"])] | length == 1' "$test_dir/multica-calls.jsonl" >/dev/null
jq -e '.[0].name == "運用"' "$test_dir/issue-labels.json" >/dev/null
echo 'PASS escalate: ラベル付与の失敗後も新規作成せず、同じタスクにラベルを補う'
