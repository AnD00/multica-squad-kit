#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/webhooks-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/package"
cp "$root/VERSION" "$test_dir/package/"
cp -R "$root/lib" "$root/common" "$test_dir/package/"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/setup-runtime-cli.py" >"$test_dir/bin/multica"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/webhook-gh.py" >"$test_dir/bin/gh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$TEST_DB/sleeps"\n' >"$test_dir/bin/sleep"
chmod +x "$test_dir/bin/"*
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
cd "$root"
die() { printf '%s\n' "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
source "$root/lib/check.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/webhooks.sh"
server_url=https://example.test; workspace_id=workspace-a
project_id=project-a; project_key=demo; host_owner_id=actor
records='{"dependabot-merger":{"id":"dep"}}'
enabled=${TEST_ENABLED:-dependabot-merger}
dependabot_webhook=${TEST_WEBHOOK:-true}
selected_repositories='[{"repository":"example/one"},{"repository":"example/two"}]'
project_work=$TEST_DB/work
mkdir -p "$project_work"
setup_webhook_rows='[]'; setup_webhook_leftovers='[]'; setup_issue_rows='[]'; setup_issue_failures='[]'
prepare_project_webhooks
project_webhook_completion
project_issue_completion
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
export PATH="$test_dir/bin:$PATH" TEST_PACKAGE="$test_dir/package"
new_case() {
 TEST_DB="$test_dir/$1"; export TEST_DB
 mkdir -p "$TEST_DB"
 python3 "$root/tests/project-issues-fixture.py" "$test_dir/package" "$TEST_DB/db.json"
 jq '.autopilots=[{id:"one",title:"Dependabot の PR の週次の確認 demo example/one",project_id:"project-a",assignee_id:"dep",assignee_type:"agent"},{id:"two",title:"Dependabot の PR の週次の確認 demo example/two",project_id:"project-a",assignee_id:"dep",assignee_type:"agent"}] |
  .triggers={one:[{id:"schedule-one",kind:"schedule",cron_expression:"0 10 * * 2",timezone:"Asia/Tokyo"}],two:[{id:"schedule-two",kind:"schedule",cron_expression:"0 10 * * 2",timezone:"Asia/Tokyo"}]}' "$TEST_DB/db.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/db.json"
 : >"$test_dir/out"; : >"$test_dir/err"
}
edit() { jq "$1" "$TEST_DB/db.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/db.json"; }
run() { /bin/bash "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"; }
no_leak() {
 python3 - "$test_dir" <<'PY'
import sys
from pathlib import Path
canary = ('https://' + 'webhook-canary.example.test/').encode()
for path in Path(sys.argv[1]).rglob('*'):
    if path.is_file() and canary in path.read_bytes():
        raise AssertionError(f'credential leaked into {path.name}')
PY
}

new_case created
run
jq -e '(.github_hooks|length)==2 and (.issues|length)==0 and all(.triggers[]; length==2 and .[0].kind=="schedule" and .[0].cron_expression=="0 10 * * 2" and .[1].kind=="webhook")' "$TEST_DB/db.json" >/dev/null
[[ $(grep -c 'トリガー 作成、登録 作成、配信 成功（HTTP 200）' "$test_dir/out") == 2 ]]
no_leak
cp "$TEST_DB/db.json" "$test_dir/first.json"
: >"$TEST_DB/calls.jsonl"; : >"$TEST_DB/gh-calls.jsonl"
run
cmp "$test_dir/first.json" "$TEST_DB/db.json"
[[ $(grep -c 'トリガー 既存、登録 既存、配信 成功（HTTP 200）' "$test_dir/out") == 2 ]]
! jq -es 'any(.[]; index("POST")!=null or .[1]=="trigger-add" or (.[1]|endswith("/pings")))' "$TEST_DB/calls.jsonl" "$TEST_DB/gh-calls.jsonl" >/dev/null
no_leak
echo 'PASS webhooks: 週次を残してトリガーと pull_request の登録を作り、ping の HTTP 状態を表示し、再実行は既存を使って送信しない'
edit '.webhook_cases["example/one"].event="pull_request" | .webhook_cases["example/one"].status=202'
run
grep -q '登録 既存、配信 成功（HTTP 202）' "$test_dir/out"
no_leak
echo 'PASS webhooks: 既存の Webhook は ping 以外も含めて最新の配信を表示する'

for mismatch in inactive events extra-events form missing-active missing-events missing-content-type; do
 new_case "existing-$mismatch"
 run
 case $mismatch in
 inactive) edit '.github_hooks[0].active=false' ;;
 events) edit '.github_hooks[0].events=["push"]' ;;
 extra-events) edit '.github_hooks[0].events=["pull_request","push"]' ;;
 form) edit '.github_hooks[0].content_type="form"' ;;
 missing-active) edit '.github_hooks[0].active=null' ;;
 missing-events) edit '.github_hooks[0].events=null' ;;
 missing-content-type) edit '.github_hooks[0].content_type=null' ;;
 esac
 cp "$TEST_DB/db.json" "$test_dir/hooks-before.json"
 : >"$TEST_DB/gh-calls.jsonl"
 /bin/bash -x "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"
 jq -e '.github_hooks==input.github_hooks' "$TEST_DB/db.json" "$test_dir/hooks-before.json" >/dev/null
 jq -e '.issues | length==1 and .[0].metadata.squad_kit_task=="dependabot-webhook" and .[0].metadata.repository=="example/one"' "$TEST_DB/db.json" >/dev/null
 grep -q 'example/one:.*登録 飛ばした、配信 記録なし.*既存の GitHub Webhook の設定' "$test_dir/out"
 grep -q 'example/two:.*配信 成功' "$test_dir/out"
 ! jq -es 'any(.[]; index("POST")!=null or index("PATCH")!=null or .[1]=="repos/example/one/hooks/1/deliveries")' "$TEST_DB/gh-calls.jsonl" >/dev/null
 run
 jq -e '.github_hooks|length==2' "$TEST_DB/db.json" >/dev/null
 jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
 no_leak
done
echo 'PASS webhooks: 既存の有効・pull_request のみ・JSON を検証し、不一致は変更せず理由と起票を残す。過去の HTTP 200 を成功扱いにしない'

for state in false null; do
 new_case "disabled-trigger-$state"
 run
 edit ".triggers.one[1].enabled=$state"
 cp "$TEST_DB/db.json" "$test_dir/triggers-before.json"
 : >"$TEST_DB/calls.jsonl"; : >"$TEST_DB/gh-calls.jsonl"
 /bin/bash -x "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"
 jq -e '.triggers==input.triggers' "$TEST_DB/db.json" "$test_dir/triggers-before.json" >/dev/null
 jq -e '.issues | length==1 and .[0].metadata.squad_kit_task=="dependabot-webhook" and .[0].metadata.repository=="example/one"' "$TEST_DB/db.json" >/dev/null
 grep -q 'example/one:.*トリガー 既存、登録 飛ばした、配信 記録なし.*トリガーが有効ではありません' "$test_dir/out"
 grep -q 'example/two:.*配信 成功' "$test_dir/out"
 ! jq -es 'any(.[]; .[0]=="autopilot" and (.[1]=="trigger-add" or .[1]=="trigger-update"))' "$TEST_DB/calls.jsonl" >/dev/null
 ! jq -es 'any(.[]; .[1]|startswith("repos/example/one"))' "$TEST_DB/gh-calls.jsonl" >/dev/null
 run
 jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
 no_leak
done
echo 'PASS webhooks: 無効か有効状態が不明のトリガーは再開・重複作成せず、理由と起票を残してほかのリポジトリを続ける'

new_case excluded
TEST_ENABLED=orchestrator run
[[ ! -e $TEST_DB/calls.jsonl && ! -e $TEST_DB/gh-calls.jsonl ]]
echo 'PASS webhooks: Dependabot の役を外したときは読み取りも登録も起票もしない'

new_case unused
TEST_WEBHOOK=false run
[[ ! -e $TEST_DB/gh-calls.jsonl ]]
! jq -es 'any(.[]; .[0]=="autopilot" and (.[1]|test("^trigger-")))' "$TEST_DB/calls.jsonl" >/dev/null || exit 1
jq -e '.issues|length==0' "$TEST_DB/db.json" >/dev/null
[[ $(grep -c 'Webhook の登録:\|警告:' "$test_dir/out") == 0 ]]
echo 'PASS webhooks: Webhook を使わない答えなら、Dependabot の役を残しても GitHub を読まず、登録も起票もしない'

# 前の実行のトリガーが残っていれば、消さずに警告して外すタスクを起票する。読めないリポジトリは警告だけ。
new_case leftover
edit '.triggers.one+=[{id:"webhook-one",kind:"webhook",enabled:true}] | .autopilots|=map(select(.id!="two"))'
cp "$TEST_DB/db.json" "$test_dir/leftover-before.json"
TEST_WEBHOOK=false run
[[ ! -e $TEST_DB/gh-calls.jsonl ]]
jq -e '.triggers==input.triggers' "$TEST_DB/db.json" "$test_dir/leftover-before.json" >/dev/null
jq -e '.issues | length==1 and (.[0] | .title=="example/one の Dependabot の Webhook を外す" and .assignee_id=="actor" and .metadata.squad_kit_task=="dependabot-webhook-removal" and .metadata.repository=="example/one")' "$TEST_DB/db.json" >/dev/null
grep -qxF '警告: example/one: Webhook を使わない答えですが、前の実行で作った Webhook のトリガーが残っています。外すよう起票しました。' "$test_dir/out"
grep -qxF '警告: example/two: 前の実行で作った Webhook のトリガーが残っているかを確認できませんでした。Multica の画面で確認してください。' "$test_dir/out"
TEST_WEBHOOK=false run
jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
no_leak
echo 'PASS webhooks: Webhook を使わない答えでも、残ったトリガーは消さずに警告して外すタスクを一度だけ起票し、読めなければ警告する'

for failure in can-write trigger secrets signed missing-url admin hooks create deliveries ping; do
 new_case "$failure"
 case $failure in
 can-write) edit '.autopilots[0].can_write=false' ;;
 trigger) edit '.autopilots[0].fail_trigger=true' ;;
 secrets) edit '.autopilots[0].fail_secrets=true' ;;
 signed) edit '.autopilots[0].signed=true' ;;
 missing-url) edit '.autopilots[0].missing_url=true' ;;
 admin) edit '.webhook_cases["example/one"].admin=false' ;;
 hooks) edit '.webhook_cases["example/one"].deny_hooks=true' ;;
 create) edit '.webhook_cases["example/one"].fail_create=true' ;;
 deliveries) edit '.webhook_cases["example/one"].deny_deliveries=true' ;;
 ping) edit '.webhook_cases["example/one"].status=500' ;;
 esac
 run
 jq -e '.issues | length==1 and (.[0] | .title=="example/one に Dependabot の Webhook を登録する" and .assignee_id=="actor" and .status=="todo" and .metadata.repository=="example/one" and .metadata.squad_kit_task=="dependabot-webhook" and .labels[0].id=="ops")' "$TEST_DB/db.json" >/dev/null
 grep -q 'example/two:.*配信 成功' "$test_dir/out"
 if [[ $failure == admin ]]; then grep -q '管理者ではありません' "$test_dir/out"; fi
 if [[ $failure == hooks ]]; then grep -q 'admin:repo_hook' "$test_dir/out"; fi
 if [[ $failure == signed || $failure == missing-url || $failure == secrets ]]; then
  ! jq -es 'any(.[]; .[1]=="repos/example/one/hooks" and index("POST")!=null)' "$TEST_DB/gh-calls.jsonl" >/dev/null
 fi
 no_leak
done
echo 'PASS webhooks: トリガー・署名・管理者・token の範囲・登録・配信の失敗を起票して理由を出し、ほかのリポジトリを続ける'

new_case pending
edit '.webhook_cases["example/one"].missing_delivery=true'
run
[[ $(wc -l <"$TEST_DB/sleeps" | tr -d ' ') == 6 ]]
grep -q '配信 記録なし' "$test_dir/out"
jq -e '.issues|length==1' "$TEST_DB/db.json" >/dev/null
no_leak
new_case delayed
edit '.webhook_cases["example/one"].delay=2 | .webhook_cases["example/one"].status=204'
run
[[ $(wc -l <"$TEST_DB/sleeps" | tr -d ' ') == 2 ]]
grep -q '成功（HTTP 204）' "$test_dir/out"
jq -e '.issues|length==0' "$TEST_DB/db.json" >/dev/null
no_leak
echo 'PASS webhooks: 新規の ping を最大 30 秒待ち、記録なしは起票し、遅れて届いた 2xx を成功として扱う'

new_case issue-failed
edit '.webhook_cases["example/one"].admin=false'
printf '%s\n' 'example/one に Dependabot の Webhook を登録する' >"$TEST_DB/fail-issue"
if run; then exit 1; fi
grep -qF '起票できなかったタスク:' "$test_dir/out"
grep -q 'example/two:.*配信 成功' "$test_dir/out"
no_leak
echo 'PASS webhooks: 代わりの起票が失敗してもほかの登録と完了の表示へ進み、失敗を返す'

new_case traced
/bin/bash -x "$test_dir/driver" >"$test_dir/out" 2>"$test_dir/err"
no_leak
echo 'PASS webhooks: 見張り用 URL が stdout・stderr・起票本文・一時ファイル・引数の記録と xtrace のどこにも出ない'
