#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/project-changes-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/package"
cp "$root/VERSION" "$test_dir/package/"
cp -R "$root/lib" "$root/common" "$test_dir/package/"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/setup-runtime-cli.py" >"$test_dir/bin/multica"
chmod +x "$test_dir/bin/multica"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
cd "$root"
die() { printf '%s\n' "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/workspace.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/project-changes.sh"
server_url=https://example.test; workspace_id=workspace-a
project_id=project-a; host_owner_id=actor
people=$(mc workspace member list --output json)
project_work=$TEST_DB/work
mkdir -p "$project_work"
kit_version=${TEST_TAG:-$(cat "$root/VERSION")}
selected_repositories='[{"repository":"example/current"},{"repository":"example/added"}]'
setup_removed_targets=${TEST_REMOVED:-[]}
project_previous_repositories=${TEST_BEFORE:-null}
setup_issue_rows='[]'; setup_issue_failures='[]'
prepare_project_change_issues
project_issue_completion
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package"
new_case() {
 TEST_DB="$test_dir/$1"; export TEST_DB
 mkdir -p "$TEST_DB"
 python3 "$root/tests/project-issues-fixture.py" "$test_dir/package" "$TEST_DB/db.json"
 : >"$test_dir/out"; : >"$test_dir/err"
}
edit() { jq "$1" "$TEST_DB/db.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/db.json"; }
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then exit 1; fi; }
count() { [[ $(jq '.issues|length' "$TEST_DB/db.json") == "$1" ]]; }

new_case current
run
count 0
echo 'PASS changes: 原本と同じ共通スキルと、今回作った検証スキルでは起票しない'

new_case skipped
edit '.skills[0].content="old" | .skills[0].created_by="creator"'
run
count 1
jq -e --arg target "squad-handoff@$(cat "$root/VERSION")" '.issues[0] | .metadata.squad_kit_task=="handoff-skill-update" and (.metadata.squad_kit_targets|fromjson)==[$target] and .assignee_id=="creator" and .status=="todo" and .labels[0].id=="instructions"' "$TEST_DB/db.json" >/dev/null
run
count 1
grep -q '（既存）' "$test_dir/out"
echo 'PASS changes: 更新できなかった共通スキルは作成者に頼み、同じタグでは二重に起票しない'

new_case creator-left
edit '.skills[0].content="old" | .skills[0].created_by="absent-member"'
run
jq -e '.issues[0].assignee_id=="actor"' "$TEST_DB/db.json" >/dev/null
echo 'PASS changes: 共通スキルの作成者がメンバーにいないときは実行した人を担当にする'

new_case tags
edit '.skills[0].config.origin.source_url="old-tag"'
run
TEST_TAG=v9.8.7 run
count 2
jq -e '.issues[1].metadata.squad_kit_targets=="[\"squad-handoff@v9.8.7\"]"' "$TEST_DB/db.json" >/dev/null
echo 'PASS changes: 本文が同じでも取り込み元のタグが違えば起票し、対象をタグごとに分ける'

new_case removed
TEST_REMOVED='["demo-planner-owner","停止したオートパイロット"]' run
count 1
jq -e '.issues[0] | .metadata.squad_kit_task=="removed-roles" and .assignee_id=="actor" and (.metadata.squad_kit_targets|fromjson|length)==2 and (.description|contains("demo-planner-owner")) and (.description|contains("停止したオートパイロット"))' "$TEST_DB/db.json" >/dev/null
TEST_REMOVED='["demo-planner-owner","停止したオートパイロット","demo-designer-owner"]' run
count 2
jq -e '.issues[1] | .metadata.squad_kit_targets=="[\"demo-designer-owner\"]" and (.description|contains("demo-planner-owner")|not)' "$TEST_DB/db.json" >/dev/null
TEST_REMOVED='["demo-planner-owner","停止したオートパイロット","demo-designer-owner"]' run
count 2
echo 'PASS changes: 残したエージェントと一時停止したオートパイロットの未起票分だけをまとめる'

new_case repositories
TEST_BEFORE='["example/current","example/removed"]' run
count 2
jq -e '.issues | all(.[]; .metadata.squad_kit_task=="repository-change" and .assignee_id=="actor" and .status=="todo") and
 any(.[]; .metadata.repository=="example/added" and .metadata.squad_kit_targets=="[\"added:example/added\"]") and
 any(.[]; .metadata.repository=="example/removed" and .metadata.squad_kit_targets=="[\"removed:example/removed\"]")' "$TEST_DB/db.json" >/dev/null
TEST_BEFORE='["example/current","example/removed"]' run
count 2
echo 'PASS changes: 既存の検証スキルとの差から追加・削除をリポジトリごとに起票し、流し直しても重ねない'

source "$root/lib/project-changes.sh"
content=$(printf '%s\n' '## `Example/One`' '```text' '## `example/not-a-section`' '```' '### `example/not-a-repository`' '## `example/two`' '## `Example/One`')
[[ $(project_verify_repositories "$(jq -nc --arg content "$content" '{content:$content}')") == '["example/one","example/two"]' ]]
echo 'PASS changes: 検証スキルのリポジトリの節だけを読み、コードの中の見出しを対象にしない'

for failure in 'skill list' 'skill get'; do
 new_case "read-${failure// /-}"
 printf '%s\n' "$failure" >"$TEST_DB/fail-read"
 deny
 count 0
 grep -qF '共通スキルを読み直せなかったため' "$test_dir/out"
done
echo 'PASS changes: 読み直しの失敗を未更新や不存在とみなして起票せず、完了の失敗一覧へ出す'
