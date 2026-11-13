#!/usr/bin/env bash
# マージ待ちの定期確認の登録と、以前の規則だけを消すことを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
export MULTICA_AGENT_ID=orchestrator
mark='紐付いていない PR のマージ待ちの見張りで起きました。'
rule() {
	fixture issue-wakeups | jq --arg id "$1" --arg instruction "$2" '.id=$id | .instruction=$instruction'
}
deleted_ids() { jq -sr '[.[] | select(.[0:3] == ["issue","wakeup","delete"]) | .[4]] | sort | join(",")' "$test_dir/calls.jsonl"; }

reset_fixture
printf '%s\n' "$(rule old "$mark"$'\n古い指示')" "$(rule disabled "$mark")" \
	"$(rule ci 'PR の CI が終わりました。')" "$(rule other "${mark}別の文")" | jq -s . >"$test_dir/rules.json"
(cd "$test_dir" && bash "$script" unlinked test-issue trigger-comment monitor) >"$test_dir/output"
[[ $(deleted_ids) == disabled,old ]]
assert_jq '[.[].id] | sort == ["ci","other"]' "$test_dir/rules.json"
assert_jq -s 'length == 1 and (.[] | .args as $args |
	all([["--kind","every"],["--every","1h"],["--expires-in","72h"],["--on-timeout","end"],
		["--max-fires","100"],["--agent-id","monitor"],["--parent","ci-thread"]][];
		. as $pair | ($args | index($pair[0])) as $i | $i != null and $args[$i+1] == $pair[1]))
	and (.[0].body | startswith("紐付いていない PR のマージ待ちの見張りで起きました。\n"))
	and (.[0].body | contains("squad-pr-watch unlinked-check test-issue orchestrator monitor"))' "$test_dir/wakeups.jsonl"
python3 - "$test_dir/output" <<'PY'
import json, re, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
assert json.loads('\n'.join(lines[:-1]))['id']
match = re.fullmatch(r'見張り: 1 時間おき、(\d{4}-\d\d-\d\dT\d\d:\d\dZ) まで', lines[-1])
assert match, lines
expiry = datetime.strptime(match[1], '%Y-%m-%dT%H:%MZ').replace(tzinfo=timezone.utc)
remaining = expiry - datetime.now(timezone.utc)
assert timedelta(hours=72, minutes=-2) < remaining <= timedelta(hours=72)
PY
echo 'PASS unlinked: 自分の古い規則だけを削除し、1時間おき・72時間・上限100回・見張り役・記録先を登録する'

reset_fixture
jq 'del(.metadata.ci_watch_thread)' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
(cd "$test_dir" && bash "$script" unlinked test-issue trigger-comment) >"$test_dir/output"
assert_jq '.metadata.ci_watch_thread == "trigger-comment"' "$test_dir/task.json"
assert_jq -s 'length == 1 and (.[0].args | index("--agent-id") as $i | .[$i+1] == "orchestrator")
	and (.[0].args | index("--parent") as $i | .[$i+1] == "trigger-comment")
	and (.[0].body | contains("squad-pr-watch unlinked-check test-issue orchestrator\n"))
	and (.[0].body | contains("紐付け: 食い違い"))
	and (.[0].body | contains("紐付け: 作業先と違う、紐付け: 不正な pr_url"))
	and (.[0].body | contains("タスクの画面で metadata の pr_url か repository を直してもらってください"))
	and (.[0].body | contains("元の値は写さず"))
	and (.[0].body | contains("CI <SHA>: 失敗あり"))
	and (.[0].body | contains("コンフリクト: CONFLICTING"))
	and (.[0].body | contains("記録のスレッド: trigger-comment"))' "$test_dir/wakeups.jsonl"
echo 'PASS unlinked: 見張り役がなければリーダーを起こし、きっかけを保存して行ごとの動きを指示する'

for operation in delete create; do
	reset_fixture
	printf '%s\n' "$(rule old "$mark")" | jq -s . >"$test_dir/rules.json"
	printf 'issue wakeup %s' "$operation" >"$test_dir/fail"
	status=0
	(cd "$test_dir" && bash "$script" unlinked test-issue trigger-comment monitor) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/wakeups.jsonl ]]
done
reset_fixture
status=0
(unset MULTICA_AGENT_ID; cd "$test_dir" && bash "$script" unlinked test-issue trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/calls.jsonl ]]
echo 'PASS unlinked: 登録・削除の失敗やリーダー不明を、登録できたという出力に置き換えない'

for command in unlinked unlinked-check; do
	args=(test-issue trigger-or-leader monitor extra)
	for count in 0 1 4; do
		status=0
		bash "$script" "$command" "${args[@]:0:$count}" >"$test_dir/output" 2>"$test_dir/error" || status=$?
		[[ $status == 2 && ! -s $test_dir/output ]]
		grep -qF '使い方:' "$test_dir/error"
	done
done
echo 'PASS unlinked: 両方のコマンドは引数の不足・過剰を終了コード2で返す'

# 重複の整理に読む作成日時は、見本にある必須欄として確認する。
assert_jq '.entries["issue-wakeups"].items.fields | any(.[]; .path == "created_at" and .class == "required" and .nullable == false)' "$test_dir/contracts.json"
for value in absent null; do
	reset_fixture
	if [[ $value == absent ]]; then filter='del(.created_at)'; else filter='.created_at=null'; fi
	fixture issue-wakeups | jq "$filter | [. + {id:\"old\",instruction:\"$mark\"}]" >"$test_dir/rules.json"
	status=0
	(cd "$test_dir" && bash "$script" unlinked test-issue trigger-comment monitor) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/wakeups.jsonl ]]
	assert_jq 'map(.id) == ["old"]' "$test_dir/rules.json"
done
echo 'PASS unlinked: 作成日時が欠けた一覧では、規則を変えずに失敗を返す'
