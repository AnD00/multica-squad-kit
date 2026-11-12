#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-followup-test-lib.sh"

# スケジュールなしの拡張を、実際の登録処理へ渡す。
export TEST_EXCLUDED='[]' TEST_REPOSITORIES='["example/project"]'
cat >>"$TEST_PACKAGE/common/autopilots.md" <<'WEBHOOK'

## Issue events {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.orchestrator.name}}
- 実行: `run_only`
- トリガー: `webhook`

```text
{{repository}} の GitHub の issue のイベントを扱う。
```
WEBHOOK
reset_db
run
webhook_auto=$(jq -r '.[]|select(.title=="Issue events demo example/project")|.id' "$TEST_DB/autopilots.json")
[[ -n $webhook_auto ]]
jq -e 'length==1 and .[0].kind=="webhook"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
! jq -es --arg id "$webhook_auto" 'any(.[]; .[0:3]==["autopilot","trigger-add",$id] and index("schedule")!=null)' "$TEST_DB/calls" >/dev/null
# 手で設定したフィルターや停止状態、URL 用の値を、再実行で替えない。
jq '.[0]+={enabled:false,event_filter:{issues:["edited"]},webhook_token:"private-fixture"}' "$TEST_DB/triggers-$webhook_auto.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/triggers-$webhook_auto.json"
cp "$TEST_DB/triggers-$webhook_auto.json" "$test_dir/webhook-before"
: >"$TEST_DB/calls"
run
no_autopilot_writes
cmp "$test_dir/webhook-before" "$TEST_DB/triggers-$webhook_auto.json"
echo 'PASS webhook: スケジュールなしで作り、再実行で ID・URL 用の値・フィルター・停止状態を保つ'

# 作成後のトリガー追加が失敗しても、同じオートパイロットで再開する。
echo '[]' >"$TEST_DB/triggers-$webhook_auto.json"
TEST_FAIL='autopilot trigger-add' deny
[[ $(jq length "$TEST_DB/autopilots.json") == 4 ]]
run
jq -e 'length==1 and .[0].kind=="webhook"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
echo 'PASS webhook: 追加失敗を返し、同じ ID へ一つだけトリガーを追加して復旧する'

# 意図しない定期実行が残る場合は、削除も成功扱いもせずに止まる。
echo '[{"id":"manual-schedule","kind":"schedule"}]' >"$TEST_DB/triggers-$webhook_auto.json"
deny
grep -q '既存のスケジュールがあります' "$test_dir/err"
jq -e 'length==1 and .[0].id=="manual-schedule"' "$TEST_DB/triggers-$webhook_auto.json" >/dev/null
echo 'PASS webhook: 既存のスケジュールがある場合は人間へ返し、手動のトリガーを消さない'

# リポジトリ単位の拡張も、紐付け専用の一覧には展開しない。
for title in 'Project scan' 'Project report'; do
 cat >>"$TEST_PACKAGE/common/autopilots.md" <<SCHEDULE

## $title {{project_key}} {{repository}}

- 範囲: \`repository\`
- 担当: {{agent.orchestrator.name}}
- 実行: \`run_only\`
- スケジュール: \`0 0 * * 1\`（Asia/Tokyo）

\`\`\`text
{{repository}} を確認する。
\`\`\`
SCHEDULE
done
reset_db
run
jq -e 'length==6' "$TEST_DB/autopilots.json" >/dev/null
cp "$TEST_DB/autopilots.json" "$test_dir/one-code"
printf '["example/linked"]\n' >"$TEST_PACKAGE/extension-link-repositories.json"
: >"$TEST_DB/calls"; run; no_autopilot_writes
cmp "$test_dir/one-code" "$TEST_DB/autopilots.json"
! jq -es 'any(.[]; any(.[]; type=="string" and contains("example/linked")))' "$TEST_DB/calls" >/dev/null
[[ $(jq -sr '[.[][]|select(.kind=="webhook")]|length' "$TEST_DB"/triggers-*.json) == 1 ]]
echo 'PASS scope: 紐付け先を追加しても単一選択の6件と Webhook 1件を保ち、追加先の定期処理を作らない'
rm "$TEST_PACKAGE/extension-link-repositories.json"
reset_db
TEST_REPOSITORIES='["example/project","example/client"]' run
jq -e 'length==11' "$TEST_DB/autopilots.json" >/dev/null
[[ $(jq -sr '[.[][]|select(.kind=="webhook")]|length' "$TEST_DB"/triggers-*.json) == 2 ]]
echo 'PASS scope: 追加指定なしの二選択は従来どおり11件と Webhook 2件を作る'
