#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-escalate-contract-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。escalate のタスクの作成と、引数・契約の検査を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/dependabot-merge-escalate-test-lib.sh"

for defect in resource-type search-project member-email issue-label-id create-id create-identifier; do
 escalate_fixture
 touch "$test_dir/allow-missing-fields"
 case $defect in
 resource-type) reading=label-list; field=resource_type; source=labels; filter='map(del(.resource_type))' ;;
 search-project) existing_escalation; reading=issue-search; field=project_id; source=search; filter='del(.issues[0].project_id)' ;;
 member-email) reading=member-list; field=email; source=members; filter='map(del(.email))' ;;
 issue-label-id) existing_escalation; reading=issue-labels; field=id; source=issue-labels; filter='map(del(.id))' ;;
 create-id|create-identifier)
  reading=issue-create; field=id; [[ $defect != create-identifier ]] || field=identifier
  source=create-response; cp "$test_dir/create-prototype.json" "$test_dir/create-response.json"; filter="del(.$field)" ;;
 esac
 jq "$filter" "$test_dir/$source.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/$source.json"
 status=0
 bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/curl-calls.jsonl ]]
 expected_field=$field
 [[ $reading != issue-search ]] || expected_field="issues[].$field"
 grep -F "$reading の $expected_field" "$test_dir/error" >/dev/null
 if [[ $reading == issue-create ]]; then
  jq -se '[.[] | select(.[0:2]==["issue","create"])] | length==1' "$test_dir/multica-calls.jsonl" >/dev/null
  jq -se 'all(.[]; .[0:3] != ["issue","label","add"])' "$test_dir/multica-calls.jsonl" >/dev/null
 else no_issue_writes; fi
 echo "PASS contract: $reading の $field の欠落を欄名で返し、後続を書かない"
done
