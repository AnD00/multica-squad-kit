#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/metrics.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

python3 "$root/tests/metrics-traces-check.py" "$root" "$test_dir"
cmp "$test_dir/trace-first/traces.json" "$test_dir/trace-second/traces.json"
cmp "$test_dir/trace-first/traces.md" "$test_dir/trace-second/traces.md"

# These are normalized, synthetic snapshots, not fabricated CLI responses.
fixture="$root/tests/fixtures/metrics/snapshot.json"
plan="$root/tests/fixtures/metrics/plan.json"
count() {
	python3 "$root/scripts/metrics.py" count "$fixture" \
		--cutoff 2026-01-01T00:10:00Z --truncate 2026-01-01T00:10:00Z \
		--human human-one --human human-two --project-key foo-bar --member-key m-n "$@"
}
count --compare "$plan" --output "$test_dir/first"
count --compare "$plan" --output "$test_dir/second"
cmp "$test_dir/first/metrics.json" "$test_dir/second/metrics.json"
cmp "$test_dir/first/metrics.md" "$test_dir/second/metrics.md"
echo 'PASS metrics: 同じ入力の JSON と Markdown が 1 バイトも違わない'

python3 - "$test_dir/first" "$fixture" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

result = json.loads((Path(sys.argv[1]) / 'metrics.json').read_text())
assert result['input']['snapshot_sha256'] == hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
assert result['input']['cli_version'] == 'synthetic-1'
assert result['input']['collected_at'] == '2026-01-01T01:00:00Z'
a, b = result['issues']
assert [a['identifier'], b['identifier']] == ['EXAMPLE-A', 'EXAMPLE-B']
assert (a['human_comments'], b['human_comments']) == (2, 1)
assert (a['human_calls'], b['human_calls']) == (1, 1)
assert (a['in_review_transitions'], b['in_review_transitions']) == (1, 1)
print('PASS metrics: 小数秒の区切り・メンバーのコメント・複数の人間の呼び出し・状態の変化')
assert (a['run_count'], b['run_count']) == (5, 2)
assert (a['run_seconds'], b['run_seconds']) == (241, 3)
assert (a['fixer_runs'], b['fixer_runs']) == (2, 1)
assert a['roles']['claude-fixer']['run_count'] == 1
assert a['roles']['codex-fixer']['run_count'] == 1
assert a['roles']['codex-implementer']['run_count'] == 1
print('PASS metrics: 区切りをまたぐ終了・終了なし・打ち切り後の開始・開始前の取り消し・修正の両役')
assert a['roles']['claude-fixer']['tokens'] == {
    'input_tokens':11, 'cache_write_tokens':22, 'cache_read_tokens':33,
    'output_tokens':44, 'total_tokens':110}
assert a['roles']['codex-fixer']['tokens'] is None
assert a['roles']['codex-fixer']['unconfirmed_runs'] == 1
assert a['roles']['codex-implementer']['tokens']['total_tokens'] == 0
assert a['roles']['codex-implementer']['confirmed_runs'] == 1
other = a['roles']['その他']
assert other['agent_names'] == ['foo-bar-plannerish-m-n', 'outside|worker']
assert (other['confirmed_runs'], other['unconfirmed_runs']) == (1, 1)
assert other['tokens']['total_tokens'] == 26
print('PASS metrics: 使用量の複数行・確認済みの 0・未確認・規則に合わない役とエージェントの名前')
total = result['totals']
assert {k: total[k] for k in ('issue_count','human_comments','human_calls','run_seconds','run_count','fixer_runs','in_review_transitions')} == {
    'issue_count':2, 'human_comments':3, 'human_calls':2, 'run_seconds':244,
    'run_count':7, 'fixer_runs':3, 'in_review_transitions':2}
assert total['run_minutes'] == '4.1'
assert total['roles']['claude-fixer']['tokens']['total_tokens'] == 114
assert total['roles']['その他']['unconfirmed_runs'] == 1
assert result['per_issue']['run_minutes'] == '2.0'
assert result['per_issue']['fixer_runs'] == '1.5'
assert result['per_issue']['roles']['claude-fixer']['tokens']['total_tokens'] == '57.0'
compare = result['comparison']
assert compare['metrics']['run_seconds'] == {'plan':240,'actual':244,'difference':4}
assert compare['metrics']['human_comments']['difference'] == -2
assert compare['roles']['claude-fixer']['difference'] == 14
assert compare['roles']['codex-fixer'] == {'plan':None,'actual':None,'difference':None,'unconfirmed_runs':1}
assert compare['roles']['designer']['actual'] is None
assert compare['roles']['その他'] == {'plan':None,'actual':26,'difference':None,'unconfirmed_runs':1}
md = (Path(sys.argv[1]) / 'metrics.md').read_text()
assert '| EXAMPLE-A | 2 | 1 | 241 | 4.0 | 5 | 2 | 1 |' in md
assert '| 合計 | 3 | 2 | 244 | 4.1 | 7 | 3 | 2 |' in md
assert '| run_seconds | 240 | 244 | 4 |' in md
assert '未確認' in md and 'outside\\|worker' in md
print('PASS metrics: 合計・平均・丸めた分・計画との差・Markdown の表')
PY

count --from 2026-01-01T00:05:00Z --output "$test_dir/range"
count --cutoff 2026-01-01T00:10:01Z --truncate 2026-01-01T00:11:00Z --output "$test_dir/later"
count --cutoff 2025-12-31T00:00:00Z --output "$test_dir/empty"
count --truncate 2026-01-01T00:06:01Z --output "$test_dir/truncated"
python3 - "$test_dir" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
def read(name): return json.loads((root / name / 'metrics.json').read_text())
selected = read('range')
assert [issue['identifier'] for issue in selected['issues']] == ['EXAMPLE-B']
assert selected['totals']['run_count'] == 2
assert selected['totals']['run_seconds'] == 3
later = read('later')
assert len(later['issues']) == 3
assert later['totals']['human_comments'] == 5
assert later['totals']['human_calls'] == 3
assert later['totals']['run_count'] == 9
assert later['totals']['run_seconds'] == 573
empty = read('empty')
assert empty['totals']['issue_count'] == 0
assert empty['totals']['run_seconds'] == 0
assert empty['per_issue']['run_count'] is None
assert empty['per_issue']['run_minutes'] is None
assert empty['comparison'] is None
truncated = read('truncated')
assert truncated['totals']['run_seconds'] == 2
assert truncated['totals']['roles'] == read('first')['totals']['roles']
print('PASS metrics: 範囲の始めは含み、区切りと打ち切りを替えられる。対象 0 件も出力できる')
PY

# Reordering normalized arrays and using an equivalent timezone must not change counts.
python3 - "$fixture" "$test_dir" <<'PY'
import json
from pathlib import Path
import sys
snapshot = json.loads(Path(sys.argv[1]).read_text())
for key in ('issues','comments','transitions','runs','agents'):
    snapshot[key].reverse()
Path(sys.argv[2], 'reordered.json').write_text(json.dumps(snapshot))
PY
fixture="$test_dir/reordered.json" count --output "$test_dir/reordered"
count --cutoff 2026-01-01T09:10:00+09:00 --truncate 2026-01-01T09:10:00+09:00 --output "$test_dir/offset"
python3 - "$test_dir" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
def read(name): return json.loads((root / name / 'metrics.json').read_text())
base = read('first')
for name in ('reordered','offset'):
    result = read(name)
    for key in ('issues','totals','per_issue'):
        assert result[key] == base[key], (name, key)
print('PASS metrics: 記録の並びとタイムゾーンが違っても同じ数になる')
PY

# Fail visibly on missing data, never turn a malformed snapshot into zero usage.
python3 - "$root/scripts/metrics.py" "$fixture" "$test_dir" <<'PY'
import copy
import json
from pathlib import Path
import subprocess
import sys
script, fixture, work = map(Path, sys.argv[1:])
snapshot = json.loads(fixture.read_text())
broken = []
missing = copy.deepcopy(snapshot)
del missing['runs'][0]['usage']
broken.append(missing)
missing = copy.deepcopy(snapshot)
del missing['runs'][0]['usage'][0]['input_tokens']
broken.append(missing)
missing = copy.deepcopy(snapshot)
missing['runs'][0]['agent_id'] = 'not-present'
broken.append(missing)
for index, value in enumerate(broken):
    path = work / f'broken-{index}.json'
    path.write_text(json.dumps(value))
    output = work / f'broken-{index}'
    result = subprocess.run([sys.executable, str(script), 'count', str(path),
        '--cutoff','2026-01-01T00:10:00Z','--truncate','2026-01-01T00:10:00Z',
        '--human','human-one','--project-key','foo-bar','--member-key','m-n',
        '--output',str(output)], capture_output=True, text=True)
    assert result.returncode != 0 and 'エラー:' in result.stderr
    assert not output.exists()
print('PASS metrics: 必須欄と使用量の欠け、エージェントの欠けはエラーにする')
PY
