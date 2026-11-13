#!/usr/bin/env bash
# 別の作業ディレクトリの 2 実行が重なっても、定期確認を 1 規則にする。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
export MULTICA_AGENT_ID=orchestrator
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/race.py" <<'PY'
import fcntl, json, os, sys, time
from pathlib import Path
work = Path(os.environ['PR_WATCH_TEST_DIR'])
caller = os.environ['PR_WATCH_CALLER']
args = sys.argv[1:]
action = args[2]

def barrier(kind):
    (work / (kind + '-' + caller)).touch()
    end = time.monotonic() + 15
    while len(list(work.glob(kind + '-*'))) < 2:
        if time.monotonic() > end:
            raise RuntimeError('同時実行の待ち合わせが時間切れ')
        time.sleep(0.01)

status = 0
with (work / 'rules.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    rules = json.loads((work / 'rules.json').read_text())
    if action == 'list':
        response = rules
        first = not (work / ('created-' + caller)).exists()
    elif action == 'create':
        instruction = Path(args[args.index('--instruction-file') + 1]).read_text()
        prototype = json.loads((work / 'wakeup-prototype.json').read_text())
        prototype['id'] = 'rule-z' if caller == 'first' else 'rule-a'
        prototype['instruction'] = instruction
        # 日時と ID のどちらを優先したかを、両方のケースで確認する。
        prototype['created_at'] = ('2026-01-01T00:00:00Z' if caller == 'first' or
                                   os.environ['PR_WATCH_SAME_TIME'] == '1' else '2026-01-02T00:00:00Z')
        stored = json.loads((work / "race-rule-prototype.json").read_text())
        stored.update({key: prototype[key] for key in ("id", "instruction", "created_at")})
        rules.append(stored)
        (work / 'rules.json').write_text(json.dumps(rules))
        (work / ('created-' + caller)).touch()
        response = prototype
    elif action == 'delete':
        new = [r for r in rules if r['id'] != args[4]]
        status = 4 if len(new) == len(rules) else 0
        (work / 'rules.json').write_text(json.dumps(new))
        response = {}
    else:
        raise AssertionError(args)
if action == 'list':
    if first:
        # 両方が同じ登録前の一覧を読む。
        barrier('listed')
    else:
        # 両方の作成が終わった一覧を、両方が取得してから削除へ進む。
        barrier('created')
        with (work / 'rules.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            response = json.loads((work / 'rules.json').read_text())
        barrier('snapshot')
print(json.dumps(response))
raise SystemExit(status)
PY
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1-} ${2-} ${3-}" in
'issue wakeup list' | 'issue wakeup create' | 'issue wakeup delete')
	exec python3 "$PR_WATCH_TEST_DIR/race.py" "$@" ;;
*) exec "$PR_WATCH_TEST_DIR/bin/multica-base" "$@" ;;
esac
STUB
chmod +x "$test_dir/bin/multica"
for same in 0 1; do
	reset_fixture
	fixture issue-wakeups >"$test_dir/race-rule-prototype.json"
	rm -f "$test_dir/created-first" "$test_dir/created-second" "$test_dir/listed-first" "$test_dir/listed-second" "$test_dir/snapshot-first" "$test_dir/snapshot-second"
	fixture issue-wakeups | jq '[. + {id:"ci",instruction:"PR の CI が終わりました。"}]' >"$test_dir/rules.json"
	mkdir -p "$test_dir/first" "$test_dir/second"
	(cd "$test_dir/first" && PR_WATCH_CALLER=first PR_WATCH_SAME_TIME=$same bash "$script" unlinked test-issue trigger-comment monitor) >"$test_dir/first-output" 2>"$test_dir/first-error" &
	first_pid=$!
	(cd "$test_dir/second" && PR_WATCH_CALLER=second PR_WATCH_SAME_TIME=$same bash "$script" unlinked test-issue trigger-comment monitor) >"$test_dir/second-output" 2>"$test_dir/second-error" &
	second_pid=$!
	first_status=0 second_status=0
	wait "$first_pid" || first_status=$?
	wait "$second_pid" || second_status=$?
	if [[ $first_status != 0 || $second_status != 0 ]]; then cat "$test_dir/first-error" "$test_dir/second-error" >&2; exit 1; fi
	if [[ $same == 0 ]]; then expected=rule-z; else expected=rule-a; fi
	assert_jq --arg expected "$expected" '[.[].id] | sort == (["ci",$expected] | sort)' "$test_dir/rules.json"
	for who in first second; do grep -q '^見張り: 1 時間おき、' "$test_dir/$who-output"; done
done
echo 'PASS unlinked: 別の作業場所で重なる 2 登録を、作成日時・同じなら ID の順で 1 規則にする'
