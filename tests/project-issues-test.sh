#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/project-issues-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" "${TEST_DB:-$test_dir}/work/issue-error" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/package"
cp "$root/VERSION" "$test_dir/package/"
cp -R "$root/lib" "$root/common" "$test_dir/package/"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/setup-runtime-cli.py" >"$test_dir/bin/multica"
chmod +x "$test_dir/bin/multica"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
cd "$root"
source "$root/lib/check.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
server_url=https://example.test
workspace_id=workspace-a
project_id=project-a
host_owner_id=actor
squad_id=squad-a
project_work=$TEST_DB/work
mkdir -p "$project_work"
enabled=${TEST_ENABLED:-'orchestrator dependabot-merger'}
selected_repositories='[{"repository":"example/one"},{"repository":"example/two"}]'
project_name=Demo; workspace_name=Workspace
created_agents=0; created_squads=0; created_autopilots=0
runtimes='["codex"]'; agent_home=$TEST_DB/host
setup_issue_rows='[]'; setup_issue_failures='[]'
prepare_project_issues
project_completion
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package"
new_case() {
 TEST_DB="$test_dir/$1"; export TEST_DB
 mkdir -p "$TEST_DB"
 printf '%s\n' '{"issues":[],"labels":[{"id":"ops","name":"運用"},{"id":"instructions","name":"指示の改善"},{"id":"trial","name":"検証"}]}' >"$TEST_DB/db.json"
 : >"$test_dir/out"; : >"$test_dir/err"
}
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then exit 1; fi; }
new_case selected
run
jq -e '.issues | length==6 and
 all(.[]; .project_id=="project-a" and (.labels|length)==1 and
  (if .metadata.squad_kit_task=="repository-rules" then .assignee_id=="squad-a" and .status=="backlog"
   else .assignee_id=="actor" and .status=="todo" end)) and
 ([.[]|select(.metadata.repository!=null)|.metadata.repository]|sort)==["example/one","example/one","example/two","example/two"] and
 all(.[]; (.metadata.squad_kit_targets|fromjson)==[.metadata.repository // "project"])
' "$TEST_DB/db.json" >/dev/null
for title in 'example/one の Dependabot の Webhook のフィルターを設定する' 'example/two の Dependabot の Webhook のフィルターを設定する' 'example/one に AGENTS.md と作業別のルールを置く' 'example/two に AGENTS.md と作業別のルールを置く' 'プロジェクトの説明と検証スキルを記入する' 'スクワッドの動きを試す'; do
 grep -qF "${title}（新規）" "$test_dir/out"
done
[[ $(grep -c '^  TEST-' "$test_dir/out") == 6 ]]
! grep -qF '起票できなかった issue:' "$test_dir/out"
cp "$TEST_DB/db.json" "$test_dir/first.json"
run
cmp "$test_dir/first.json" "$TEST_DB/db.json"
[[ $(grep -c '（既存）' "$test_dir/out") == 6 ]]
echo 'PASS project issues: 選んだリポジトリごとの 2 種とプロジェクトの 2 種を正しい担当・状態・ラベルで作り、新規・既存を表示する'

new_case excluded
TEST_ENABLED=orchestrator run
jq -e '.issues | length==4 and all(.[]; .metadata.squad_kit_task!="dependabot-filter")' "$TEST_DB/db.json" >/dev/null
! grep -q 'フィルターを設定する' "$test_dir/out"
echo 'PASS project issues: Dependabot の役を外したときはフィルターの設定を起票しない'

new_case failed
printf '%s\n' 'example/one の Dependabot の Webhook のフィルターを設定する' >"$TEST_DB/fail-issue"
deny
jq -e '.issues|length==5 and any(.[];.metadata.squad_kit_task=="squad-trial")' "$TEST_DB/db.json" >/dev/null
grep -qF 'プロジェクトの設定が終わりました' "$test_dir/out"
grep -qF '今回作った件数:' "$test_dir/out"
grep -qF '起票できなかった issue:' "$test_dir/out"
grep -qF 'example/one の Dependabot の Webhook のフィルターを設定する: issue を作れませんでした。' "$test_dir/out"
[[ $(grep -c '（新規）' "$test_dir/out") == 5 ]]
rm "$TEST_DB/fail-issue"
run
jq -e '.issues|length==6' "$TEST_DB/db.json" >/dev/null
[[ $(grep -c '（新規）' "$test_dir/out") == 1 && $(grep -c '（既存）' "$test_dir/out") == 5 ]]
! grep -qF '起票できなかった issue:' "$test_dir/out"
echo 'PASS project issues: 途中の起票失敗でも残りを起票し、題と理由を表示して失敗を返し、流し直すと未起票分だけ作る'
