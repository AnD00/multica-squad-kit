#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-gh-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance での GH の応答の欠落・null を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

for defect in pulls-number rule-context pr-author commit-message check-app status-context file-additions head comments-body viewer-login; do
 advance_fixture
 action=list
 args=()
 case $defect in
 pulls-number) reading=gh-dependabot-pulls; field=number; filter='[del(.number)]' ;;
 rule-context) reading=gh-branch-rules; field=context; filter='[del(.parameters.required_status_checks[0].context)]' ;;
 pr-author) reading=gh-dependabot-pr; field=author.login; filter='del(.author.login)' ;;
 commit-message) reading=gh-commit; field=commit.message; filter='del(.commit.message)' ;;
 check-app) reading=gh-check-runs; field=app.id; filter='del(.check_runs[0].app.id)' ;;
 status-context) reading=gh-statuses; field=context; filter='[del(.context)]' ;;
 file-additions|head)
  edit_pr '.headRefName="dependabot/docker/example"'
  digest_files >"$test_dir/files.json"
  if [[ $defect == head ]]; then reading=gh-pr-head; field=headRefOid; filter='del(.headRefOid)'
  else reading=gh-pr-files; field=additions; filter='[del(.additions)]'; fi ;;
 comments-body|viewer-login)
  action=advance
  args=(1 --reviewed-head "$reviewed" --run-deadline "$run_deadline")
  edit_pr '.mergeStateStatus="BEHIND"'
  if [[ $defect == comments-body ]]; then reading=gh-pr-comments; field=body; filter='[del(.body)]'
  else reading=gh-viewer; field=login; filter='del(.login)'; fi ;;
 esac
 gh_fixture "$reading" | jq "$filter" >"$test_dir/gh-defect.$reading.json"
 status=0
 bash "$script" example/template project-a "$action" "${args[@]}" >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status != 0 && ! -s $test_dir/output ]]
 grep -F "$reading の " "$test_dir/error" >/dev/null
 grep -F "$field" "$test_dir/error" >/dev/null
 no_writes
 echo "PASS GH contract: $reading の $field の欠落を欄名で返す"
done

# 差分の取得を呼び出す分岐でも、JSON の欠落を changed の成功応答に変えない。
advance_fixture
edit_pr '.mergeStateStatus="BEHIND"'
gh_fixture gh-pr-head | jq 'del(.headRefOid)' >"$test_dir/gh-defect.gh-pr-head.json"
if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -F 'gh-pr-head の headRefOid' "$test_dir/error" >/dev/null
no_writes
echo 'PASS GH contract: 差分の確認中の head の欠落も、操作せず失敗する'

# 公開元では見本がない nullable な親も、公式スキーマどおり受け入れる。
reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
gh_fixture gh-dependabot-pulls | jq '[.user=null]' >"$test_dir/gh-defect.gh-dependabot-pulls.json"
run_list
assert_output '.==[]'
reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
edit_pr '.author=null'
run_list
assert_output '.==[]'
echo 'PASS GH nullable: 作者が null の PR は分類の対象にしない'

for app in any specified; do
 reset_fixture
 add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
 jq --arg app "$app" '.[0].parameters.required_status_checks[0].integration_id=(if $app=="any" then null else 15368 end)' \
  "$test_dir/rules.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/rules.json"
 jq '.check_runs[0].app=null' "$test_dir/checks.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/checks.json"
 run_list
 if [[ $app == any ]]; then assert_output '.[0].ci=="success"'; else assert_output '.[0].ci=="pending"'; fi
done
echo 'PASS GH nullable: app が null のチェックでも App の指定の有無を区別する'

advance_fixture
edit_pr '.mergeStateStatus="BEHIND"'
gh_fixture gh-pr-comments | jq '[.user=null]' >"$test_dir/gh-defect.gh-pr-comments.json"
run_advance waiting
jq -se '[.[] | select(.[0:2]==["pr","comment"])] | length==1' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS GH nullable: 作者が null のコメントを今回の依頼と取り違えない'
