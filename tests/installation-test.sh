#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/installation-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
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
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/installation.sh"
server_url=https://example.test; workspace_id=workspace-a
project_id=project-a; project_key=demo; member_key=owner; host_owner_id=actor
squad_id=squad-a; squad_name=DEMO-OWNER
member_ids='["actor"]'; runtimes='["codex"]'; codex_runtime_id=runtime-codex
enabled='orchestrator codex-implementer ci-monitor dependabot-merger'
project_work=$TEST_DB/work
records=$(cat "$project_work/records.json")
setup_installation_rows='[]'; setup_issue_rows='[]'; setup_issue_failures='[]'
verify_project_installation
project_installation_completion
project_issue_completion
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package"
new_case() {
 TEST_DB="$test_dir/$1"; export TEST_DB
 mkdir -p "$TEST_DB"
 python3 "$root/tests/project-issues-fixture.py" "$test_dir/package" "$TEST_DB/db.json"
 python3 "$root/tests/installation-fixture.py" "$TEST_DB"
 : >"$test_dir/out"; : >"$test_dir/err"
}
edit() { jq "$1" "$TEST_DB/db.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/db.json"; }
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
new_case matches
cp "$TEST_DB/db.json" "$test_dir/before"
run
cmp "$test_dir/before" "$TEST_DB/db.json"
[[ $(grep -c '^  ✔ ' "$test_dir/out") == 14 ]]
! grep -q '^  ! ' "$test_dir/out"
! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or index("--show-secrets")!=null)' "$TEST_DB/calls.jsonl" >/dev/null
echo 'PASS installation: 定義と一致する 5 群を読み直して一致を表示し、変更も起票もしない'

new_case duplicates
edit '.skills += [(.skills[0]|.id="duplicate-skill")] | .labels += [{id:"duplicate-label",name:"開発"}] |
 .agents += [(.agents[1]|.id="duplicate-agent")] | .autopilots += [(.autopilots[0]|.id="duplicate-pilot")]'
run
[[ $(grep -c '^  ! ' "$test_dir/out") == 4 ]]
echo 'PASS installation: 共通スキル・ラベル・エージェント・オートパイロットの同名の重複を要確認にする'

new_case drift
edit '.labels |= map(select(.name!="開発")) | .skills=[] | .agents[1].model="changed" |
 .roster += [{member_id:"agent-ci-monitor",member_type:"agent",role:"監視"}] |
 .autopilots[0].status="paused" | .runtime_status.codex="offline"'
run
[[ $(grep -c '^  ! ' "$test_dir/out") == 6 ]]
jq -e '.issues | length==1 and (.[0] | .title=="導入の確認で要確認になった項目を直す" and .assignee_id=="actor" and .status=="todo" and .labels[0].id=="ops" and
 .metadata.squad_kit_task=="installation-check" and (.metadata.squad_kit_targets|fromjson|length)==6 and (.description|contains("エージェント demo-codex-implementer-owner")))' "$TEST_DB/db.json" >/dev/null
run
jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
grep -q '^  · TEST-' "$test_dir/out"
grep -q '^  ! .*  定義と一致しません。' "$test_dir/out"
echo 'PASS installation: 登録時の定義と違う現在の値を 1 件にまとめ、題・担当・状態・ラベルと再実行時の重複防止を守る'

for change in 'model="other"' 'runtime_id="offline-runtime"' 'permission_mode="private"' 'invocation_targets=[]' 'skills=[]'; do
 new_case "agent-${change%%=*}"
 edit ".agents[1].$change"
 run
 [[ $(grep -c '^  ! ' "$test_dir/out") == 1 ]]
 grep -q '^  ! エージェント demo-codex-implementer-owner  ' "$test_dir/out"
done
echo 'PASS installation: エージェントのモデル・ランタイム・公開・スキルの不一致を見逃さない'

case_number=0
for change in '.squads[0].leader_id="other"' '.squads[0].instructions="old"' '.roster[1].role="wrong"' '.roster |= map(select(.member_id!="actor"))'; do
 case_number=$((case_number+1)); new_case "squad-$case_number"
 edit "$change"
 run
 grep -q '^  ! スクワッド DEMO-OWNER  ' "$test_dir/out"
done
echo 'PASS installation: スクワッドのリーダー・指示・役・選んだ人間を確認し、手動の専門家を保つ'

for role in usage-monitor dependabot-merger planner; do
 new_case "roster-$role"
 edit ".agents += (if any(.agents[]; .id==\"agent-$role\") then [] else [{id:\"agent-$role\",name:\"demo-$role-owner\"}] end) | .roster += [{member_id:\"agent-$role\",member_type:\"agent\",role:\"unexpected\"}]"
 run
 [[ $(grep -c '^  ! ' "$test_dir/out") == 1 ]]
 grep -q '^  ! スクワッド DEMO-OWNER  ' "$test_dir/out"
done
echo 'PASS installation: 監視の 3 役と外した役が名簿に残っていれば要確認にする'

for change in '.triggers.scheduled[0].cron_expression="0 0 * * *"' '.triggers.scheduled[0].timezone="UTC"' '.triggers.scheduled[0].enabled=false' '.autopilots[0].description="old"' '.triggers["event-only"][0].enabled=false'; do
 case_number=$((case_number+1)); new_case "autopilot-$case_number"
 edit "$change"
 run
 [[ $(grep -c '^  ! ' "$test_dir/out") == 1 ]]
done
echo 'PASS installation: オートパイロットの指示・有効・スケジュール・時間帯と Webhook だけの拡張を確認する'

for failure in 'skill list' 'agent list' 'agent get' 'squad get' 'squad member list' 'autopilot list' 'autopilot get' 'runtime list'; do
 new_case "read-${failure// /-}"
 printf '%s\n' "$failure" >"$TEST_DB/fail-read"
 run
 grep -q '^  ! ' "$test_dir/out"
 grep -q 'CLI の読み直しに失敗しました。' "$test_dir/out"
 jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
done
new_case malformed
printf '%s\n' 'agent list' >"$TEST_DB/bad-read"
run
grep -q '^  ! スクワッド DEMO-OWNER  ' "$test_dir/out"
echo 'PASS installation: 読み取り失敗と不正な応答も要確認として起票し、残りの確認を続ける'

new_case label-read
printf '%s\n' 'label list' >"$TEST_DB/fail-read"
if run; then exit 1; fi
[[ $(grep -c '^  ! ラベル ' "$test_dir/out") == 5 ]]
grep -q '^  ✔ ランタイム codex$' "$test_dir/out"
grep -q '^  ✖ ' "$test_dir/out"

new_case issue-failed
edit '.runtime_status.codex="offline"'
printf '%s\n' '導入の確認で要確認になった項目を直す' >"$TEST_DB/fail-issue"
if run; then exit 1; fi
grep -q '^  ✖ 導入の確認で要確認になった項目を直す  ' "$test_dir/out"
echo 'PASS installation: 要確認の起票の失敗は表示して失敗を返す'

new_case credentials
edit '.autopilots[1].canary_on_default_get=true'
/bin/bash -x "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"
python3 - "$test_dir" <<'PY'
import sys
from pathlib import Path
canary = ('https://' + 'webhook-canary.example.test/').encode()
assert all(canary not in p.read_bytes() for p in Path(sys.argv[1]).rglob('*') if p.is_file())
PY
echo 'PASS installation: 通常の取得結果に URL があっても表示・一時ファイル・xtrace へ出さない'
