#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/cli-lib-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
import copy
import json
import os
import runpy
import subprocess
import sys
from pathlib import Path

root = Path.cwd()
work = Path(sys.argv[1])
library = root / 'common/monitor/squad-cli-lib'
capture = runpy.run_path('tests/capture-cli-fixtures.py')
helper = runpy.run_path('tests/cli-fixture-lib.py')
entries = capture['contracts']()
check_case = helper['assert_fixture_response']
matches = helper['matches']
fixtures = root / 'tests/fixtures/cli'
versions = (fixtures / 'VERSION').read_text().splitlines()
missing = object()
counts = {'responses': 0, 'deleted': 0, 'null': 0, 'minimal': 0, 'shapes': 0}

def get(value, path):
    for key in path:
        try:
            value = value[key]
        except (KeyError, IndexError, TypeError):
            return missing
    return value

def mutate(value, path, delete=False, replacement=None):
    parent = get(value, path[:-1])
    if delete:
        del parent[path[-1]]
    else:
        parent[path[-1]] = replacement

def scopes(response, entry):
    if entry['shape'] == 'array':
        return [( [i], item, entry['items']['fields']) for i, item in enumerate(response)]
    result = [([], response, entry.get('fields', []))]
    if 'items' in entry:
        path = entry['items']['path']
        result.extend((path + [i], item, entry['items']['fields'])
                      for i, item in enumerate(get(response, path)))
    return result

def active(value, field):
    return field['class'] == 'required' or (
        field['class'] == 'conditional' and matches(value, field['when']))

def normalize(name, response, keep=False):
    version = versions[1 if entries[name]['command'][0] == 'gh' else 0]
    return subprocess.run(['bash', '-c', 'source "$1"; squad_cli_normalize "$2" "$3"',
                           'bash', str(library), name, version], input=json.dumps(response),
                          capture_output=True, text=True, env=dict(os.environ, SQUAD_CLI_TEST_KEEP_FIELDS="1" if keep else "0"))

def success(name, response):
    result = normalize(name, response)
    assert result.returncode == 0, (name, result.stderr)
    return json.loads(result.stdout)

def failure(name, response, field):
    result = normalize(name, response)
    assert result.returncode == 1 and result.stdout == '', (name, field, result)
    assert name in result.stderr and field['path'] in result.stderr, result.stderr
    kept = normalize(name, response, keep=True)
    assert kept.returncode == 1 and kept.stdout == '' and field['path'] in kept.stderr
    assert versions[1 if entries[name]['command'][0] == 'gh' else 0] in result.stderr
    if field['class'] == 'conditional':
        assert field['when'] in result.stderr, result.stderr

for name, entry in entries.items():
    responses = json.loads((fixtures / f'{name}.json').read_text())
    _, coverage, absent = capture['select_samples'](responses, entry)
    assert not absent, (name, absent)
    for record in coverage:
        counts['shapes'] += 1
        if 'unavailable' in record:
            print(f"見本なし: {name} の {record['name']}（{record['count']} 件）: {record['unavailable']}")
    groups = []
    if entry['shape'] == 'array':
        groups.append((entry['items']['fields'], [item for response in responses for item in response]))
    else:
        groups.append((entry.get('fields', []), responses))
        if 'items' in entry:
            groups.append((entry['items']['fields'],
                           [item for response in responses for item in get(response, entry['items']['path'])]))
    unavailable = [sample for sample in entry['samples'] if 'unavailable' in sample]
    for fields, values in groups:
        for field in fields:
            if field['class'] == 'optional':
                present = [get(value, field['path'].split('.')) is not missing for value in values]
                assert any(present) and not all(present), (name, field, '省略の両方の形が必要です')
            elif field['class'] == 'conditional':
                present = [matches(value, field['when']) for value in values]
                assert any(present) or any(sample['where'] == field['when'] for sample in unavailable), (name, field)
                assert not all(present) or unavailable, (name, field, '非該当の形が必要です')
    for response in responses:
        normalized = success(name, response)
        kept = normalize(name, response, keep=True)
        assert kept.returncode == 0 and json.loads(kept.stdout) == response
        counts['responses'] += 1
        for prefix, item, fields in scopes(response, entry):
            normalized_item = get(normalized, prefix)
            allowed = {field['path'].split('.')[0] for field in fields}
            assert set(normalized_item) <= allowed
            for parent_path in {tuple(field['path'].split('.')[:-1]) for field in fields if '.' in field['path']}:
                parent = get(normalized_item, parent_path)
                if parent is not None:
                    allowed = {field['path'].split('.')[-1] for field in fields
                               if tuple(field['path'].split('.')[:-1]) == parent_path}
                    assert set(parent) <= allowed
            for field in fields:
                path = field['path'].split('.')
                actual = get(item, path)
                if active(item, field):
                    assert actual is not missing, (name, field)
                    changed = copy.deepcopy(response)
                    mutate(changed, prefix + path, delete=True)
                    check_case(response, changed, entry, allow_required_deletion=True)
                    failure(name, changed, field)
                    counts['deleted'] += 1
                    changed = copy.deepcopy(response)
                    mutate(changed, prefix + path, replacement=None)
                    if field['nullable']:
                        success(name, changed)
                    else:
                        failure(name, changed, field)
                    counts['null'] += 1
        minimal = copy.deepcopy(response)
        for prefix, item, fields in scopes(response, entry):
            for field in fields:
                path = field['path'].split('.')
                if not active(item, field) and get(item, path) is not missing:
                    mutate(minimal, prefix + path, delete=True)
        check_case(response, minimal, entry)
        normalized = success(name, minimal)
        for prefix, item, fields in scopes(minimal, entry):
            normalized_item = get(normalized, prefix)
            for field in fields:
                path = field['path'].split('.')
                if not active(item, field) and get(item, path) is missing:
                    parent = get(normalized_item, path[:-1])
                    if parent is not None:
                        assert get(normalized_item, path) is missing, (name, field)
        counts['minimal'] += 1
    if entry['shape'] == 'array':
        assert success(name, []) == []

print('PASS contract:', json.dumps(counts))

# 実物から削った最小形は許し、手書きの鍵の追加と必須欄の削除は拒否する。
entry = entries['issue-runs']
original = json.loads((fixtures / 'issue-runs.json').read_text())[0]
for addition in (True, False):
    changed = copy.deepcopy(original)
    if addition:
        changed[0]['invented_field'] = True
    else:
        del changed[0]['id']
    try:
        check_case(original, changed, entry)
    except AssertionError:
        pass
    else:
        raise AssertionError('テストのケースの鍵の違いを見落としました')

# 全要素を検証し、複数の欠落と null を 1 行ずつ返す。
changed = copy.deepcopy(original)
del changed[0]['id']
changed[1]['kind'] = None
result = normalize('issue-runs', changed)
assert result.returncode == 1 and result.stdout == ''
lines = result.stderr.splitlines()
assert len(lines) == 2 and 'id' in lines[0] and 'null' in lines[1], lines
assert original[1]['id'] in lines[1]
print('PASS contract: ケースの鍵、全要素の検証、複数の欠落の診断')

# CLI を stub に替えて、読み取り・追加オプション・版・失敗時の境界を通す。
bin_dir = work / 'bin'
bin_dir.mkdir()
stub = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
work=Path(os.environ['CLI_LIB_TEST_DIR'])
with (work/'calls.jsonl').open('a') as stream:
 stream.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:]==['version']:
 if (work/'version-fail').exists():sys.exit(17)
 print('multica fixture-version\\nignored-version-line')
else:
 if (work/'command-fail').exists():sys.exit(19)
 print((work/'response.json').read_text())
'''
(bin_dir / 'multica').write_text(stub)
(bin_dir / 'multica').chmod(0o755)
env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], CLI_LIB_TEST_DIR=str(work))
valid = json.loads((fixtures / 'issue-get.json').read_text())[0]
(work / 'response.json').write_text(json.dumps(valid))

def read(*args):
    return subprocess.run(['bash', '-c', 'source "$1"; shift; squad_cli_read "$@"',
                           'bash', str(library), *args], capture_output=True, text=True, env=env)

result = read('issue-get', 'task with spaces; echo no', '--limit', '20')
assert result.returncode == 0, result.stderr
calls = [json.loads(line) for line in (work/'calls.jsonl').read_text().splitlines()]
assert calls[0][2] == 'task with spaces; echo no' and calls[0][-2:] == ['--limit', '20'], calls
before = len(calls)
assert read('issue-get', 'task', '--compact').returncode == 1
assert len((work/'calls.jsonl').read_text().splitlines()) == before
invalid = copy.deepcopy(valid)
del invalid['id']
(work / 'response.json').write_text(json.dumps(invalid))
result = read('issue-get', 'task')
assert result.returncode == 1 and result.stdout == ''
assert 'multica fixture-version' in result.stderr and 'ignored-version-line' not in result.stderr
(work / 'version-fail').touch()
result = read('issue-get', 'task')
assert result.returncode == 1 and 'id' in result.stderr and 'fixture-version' not in result.stderr
(work / 'command-fail').touch()
result = read('issue-get', 'task')
assert result.returncode == 19 and result.stdout == ''
assert read('unknown-reading').returncode == 1
print('PASS CLI: 引数・版・正常な省略・JSON の出力指定・失敗の伝播')
PY
