#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-escalate-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。escalate のタスクの作成と、引数・契約の検査を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/dependabot-merge-escalate-test-lib.sh"

escalate_fixture
run_escalate 'TEST-9000 created'
jq -e '.title == "Dependabot の PR を確認する: Bump #1（example/template#1）"
	and .project_id == "project-a"
	and .assignee_id == "member-a" and .status == "in_review"' "$test_dir/created.json" >/dev/null
jq -e '.[0].id == "label-a"' "$test_dir/issue-labels.json" >/dev/null
jq -Rse 'startswith("[@Owner Name](mention://member/member-a)\n\nPR: https://github.com/example/template/pull/1\n\n")
	and contains("理由: 必須 CI の失敗\n\n確認の結果:") and contains("文字列の \\n と `code`")' "$test_dir/created-body.md" >/dev/null
while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
echo 'PASS escalate: プロジェクト・メンバーの user_id・in_review・運用ラベル、メンションと本文を設定'

jq -se 'length == 1 and (.[0] | index("https://multica.example.test/api/issues/issue-a/pull-requests") != null
	and index("{\"url\":\"https://github.com/example/template/pull/1\"}") != null
	and index("X-Workspace-ID: workspace-a") != null and all(.[]; contains("mat_test-token") | not))' "$test_dir/curl-calls.jsonl" >/dev/null
[[ $(<"$test_dir/curl-config") == 'header = "Authorization: Bearer mat_test-token"' ]]
jq -e '.pr_url == "https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
echo 'PASS escalate: 作ったタスクに PR を API で紐付け、トークンは引数に出さず、metadata の pr_url に残す'

: >"$test_dir/multica-calls.jsonl"
run_escalate 'TEST-9000 exists'
no_issue_writes
# 人間が閉じた タスクも返し、担当・状態・タイトルは変更しない。
jq '.issues[0].status = "done" | .issues[0].title = "以前のバージョン（example/template#1）"' "$test_dir/search.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/search.json"
run_escalate 'TEST-9000 exists'
no_issue_writes
[[ $(wc -l <"$test_dir/curl-calls.jsonl") -eq 1 ]]
echo 'PASS escalate: 再実行・閉じたタスク・タイトルが変わった タスクも重複作成しない'
echo 'PASS escalate: 紐付け済みのタスクは、人間が外した紐付けも戻さない'

for failure in status env metadata; do
	escalate_fixture
	case $failure in
	status) printf '404' >"$test_dir/curl-status" ;;
	env) unset MULTICA_TOKEN ;;
	metadata) printf 'issue metadata list\n' >"$test_dir/multica-fail" ;;
	esac
	bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
	[[ $(<"$test_dir/output") == 'TEST-9000 created' ]]
	grep -q 'TEST-9000 に PR を紐付けられませんでした' "$test_dir/error"
	jq -e 'has("pr_url") | not' "$test_dir/metadata.json" >/dev/null
	export MULTICA_TOKEN=mat_test-token
	rm -f "$test_dir/multica-fail"
	printf '200' >"$test_dir/curl-status"
	: >"$test_dir/curl-calls.jsonl"
	run_escalate 'TEST-9000 exists'
	[[ $(wc -l <"$test_dir/curl-calls.jsonl") -eq 1 ]]
	jq -e '.pr_url == "https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
done
echo 'PASS escalate: 紐付けに失敗してもタスクを返して警告し、次の回に同じタスクへ補う'

escalate_fixture
cli_fixture issue-search | jq '.issues[0] as $base | .issues = [range(1;26) | $base + {id:(tostring), identifier:("TEST-"+tostring),
	 title:"別の PR（example/template#10）", description:"example/template#1 に言及"}]' >"$test_dir/search.json"
run_escalate 'TEST-9000 created'
echo 'PASS escalate: 本文だけの言及や似た PR 番号は同じタスクと取り違えない（既定の 20 件以上も検索）'
