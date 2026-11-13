#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-escalate-scope-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。escalate のタスクの作成と、引数・契約の検査を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-escalate-test-lib.sh"

# 同じリポジトリと PR でも、別プロジェクトのタスクでは抑止しない。
escalate_fixture
run_escalate 'TEST-9000 created'
: >"$test_dir/multica-calls.jsonl"
bash "$script" example/template project-b escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
[[ $(<"$test_dir/output") == 'TEST-9000 created' && ! -s $test_dir/error ]]
jq -e '.project_id == "project-b"' "$test_dir/created.json" >/dev/null
jq -se '[.[] | select(.[0:2] == ["issue","create"])] | length == 1' "$test_dir/multica-calls.jsonl" >/dev/null
echo 'PASS 引数のプロジェクト: 指定したプロジェクトへ作り、別プロジェクトの同じ PR のタスクは再利用しない'


reject_target() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/multica-calls.jsonl"
	local code=0
	bash "$script" "$@" >"$test_dir/output" 2>"$test_dir/error" || code=$?
	[[ $code == 2 && ! -s $test_dir/output && -s $test_dir/error ]]
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/multica-calls.jsonl ]]
}
reject_target
reject_target example/template
reject_target example/template '' list
reject_target invalid-repo project-a list
reject_target example/template project-a unknown
echo 'PASS 引数の検査: 対象やコマンドが欠けているときは、CLI を呼ばず使い方を返す'

for repository in absent same other; do
 for linked in absent value null empty; do
  escalate_fixture
  existing_escalation
  jq --arg repository "$repository" --arg linked "$linked" '
   (if $repository == "same" then .repository="example/template"
    elif $repository == "other" then .repository="other/service" else del(.repository) end)
   | if $linked == "value" then .pr_url="https://github.com/example/template/pull/1"
     elif $linked == "null" then .pr_url=null
     elif $linked == "empty" then .pr_url="" else del(.pr_url) end' \
   "$test_dir/metadata.json" >"$test_dir/next.json"
  mv "$test_dir/next.json" "$test_dir/metadata.json"
  bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
  [[ $(<"$test_dir/output") == 'TEST-9000 exists' ]]
  if [[ $repository != other && $linked == absent ]]; then
   [[ $(jq -s length "$test_dir/curl-calls.jsonl") == 1 && ! -s $test_dir/error ]]
   jq -e '.pr_url=="https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
  else
   [[ ! -s $test_dir/curl-calls.jsonl ]]
   jq -se 'all(.[]; .[0:3] != ["issue","metadata","set"])' "$test_dir/multica-calls.jsonl" >/dev/null
   if [[ $repository == other ]]; then grep -F '紐付けられませんでした' "$test_dir/error" >/dev/null; else [[ ! -s $test_dir/error ]]; fi
  fi
 done
done
echo 'PASS presence: Dependabot も metadata の鍵を保ち、初回だけ紐付け、別リポジトリは拒否する'

escalate_fixture
existing_escalation
jq '.issues[0].project_id=null' "$test_dir/search.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/search.json"
run_escalate 'TEST-9000 created'
echo 'PASS project_id: プロジェクトのない検索結果を受け入れ、対象プロジェクトのタスクと取り違えない'
