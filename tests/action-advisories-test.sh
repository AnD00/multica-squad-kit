#!/usr/bin/env bash
# 実応答の写しを gh のスタブで返し、外部の API を呼ばずに検査する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/action-advisories.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 -I - "$root" "$test_dir" <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
fixtures = root / 'tests/fixtures/action-advisories'
checker = root / 'tests/check-action-advisories.py'
vulnerable = json.loads((fixtures / 'vulnerable.json').read_text())
fixed = json.loads((fixtures / 'fixed.json').read_text())
mixed = json.loads((fixtures / 'mixed.json').read_text())
sha_old = (fixtures / 'v4.1.2.sha').read_text().strip()
sha_fixed = (fixtures / 'v4.1.3.sha').read_text().strip()
sha_checkout = (fixtures / 'v7.0.1.sha').read_text().strip()
old = f'actions/download-artifact@{sha_old} # v4.1.2'
patched = f'actions/download-artifact@{sha_fixed} # v4.1.3'
ghsa = 'GHSA-cxww-7g56-2vh6'
prefix = 'name: Probe\non:\n  workflow_dispatch:\njobs:\n  probe:\n    runs-on: ubuntu-24.04\n    steps:\n'
bin_dir = scratch / 'bin'
bin_dir.mkdir()
stub = bin_dir / 'gh'
stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
case = Path(os.environ['ADVISORY_CASE'])
args = sys.argv[1:]
with (case / 'calls.jsonl').open('a') as output:
    output.write(json.dumps(args) + '\\n')
mode = os.environ.get('ADVISORY_MODE', '')
if len(args) == 4 and args[0] == 'api' and args[1].startswith('repos/') and args[2:] == ['--jq', '.sha']:
    if mode == 'tag-failure':
        sys.exit(1)
    if mode == 'tag-shape':
        print('null')
        sys.exit(0)
    mapping = json.loads((case / 'commits.json').read_text())
    if args[1] not in mapping:
        sys.exit(2)
    print(mapping[args[1]])
elif args[:4] == ['api', '-X', 'GET', '/advisories']:
    required = ['ecosystem=actions', 'type=reviewed', 'is_withdrawn=false', 'per_page=100', '--paginate', '--slurp']
    if not all(value in args for value in required) or mode == 'api-failure':
        sys.exit(1)
    print((case / 'response.json').read_text())
else:
    sys.exit(2)
''', encoding='utf-8')
stub.chmod(0o755)


def run(name, uses, response, expected, mode='', filename='probe.yml', directory='workflows'):
    case = scratch / name
    (case / 'workflows').mkdir(parents=True)
    (case / 'workflows' / filename).write_text(prefix + ''.join('      - uses: ' + value + '\n' for value in uses), encoding='utf-8')
    (case / 'response.json').write_text(response if isinstance(response, str) else json.dumps(response), encoding='utf-8')
    mapping = {'repos/actions/download-artifact/commits/v4.1.2': sha_old,
               'repos/actions/download-artifact/commits/v4.1.3': sha_fixed,
               'repos/actions/checkout/commits/v7.0.1': sha_checkout}
    (case / 'commits.json').write_text(json.dumps(mapping))
    (case / 'calls.jsonl').write_text('')
    (case / 'summary.md').write_text('previous\n')
    environment = {**os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                   'ADVISORY_CASE': str(case), 'ADVISORY_MODE': mode,
                   'GITHUB_STEP_SUMMARY': str(case / 'summary.md')}
    result = subprocess.run(['python3', '-I', str(checker), '--sarif', 'result.sarif', directory],
                            cwd=case, env=environment, capture_output=True, text=True)
    assert result.returncode == expected, (name, result.returncode, result.stdout, result.stderr)
    assert not result.stderr, (name, result.stderr)
    sarif = json.loads((case / 'result.sarif').read_text())
    assert sarif['version'] == '2.1.0'
    report = sarif['runs'][0]
    assert report['tool']['driver']['name'] == 'action-advisories'
    assert report['invocations'][0]['executionSuccessful'] == (expected != 2)
    assert (case / 'summary.md').read_text() == 'previous\n' + result.stdout
    if expected == 0:
        assert not report['results'] and 'PASS action-advisories' in result.stdout
    elif expected == 1:
        assert report['results'] and 'FAIL action-advisories' in result.stdout
    else:
        assert 'ERROR action-advisories' in result.stdout and 'PASS action-advisories' not in result.stdout
        assert report['invocations'][0]['toolExecutionNotifications'][0]['level'] == 'error'
    calls = [json.loads(line) for line in (case / 'calls.jsonl').read_text().splitlines()]
    return report, calls


def location(result):
    return result['locations'][0]['physicalLocation']


report, calls = run('vulnerable', [old], vulnerable, 1)
assert [result['ruleId'] for result in report['results']] == [ghsa]
assert location(report['results'][0]) == {'artifactLocation': {'uri': 'workflows/probe.yml'}, 'region': {'startLine': 8}}
assert report['tool']['driver']['rules'][0]['helpUri'] == 'https://github.com/advisories/' + ghsa
run('fixed', [patched], fixed, 0)
print('PASS action-advisories: 実応答で脆弱なバージョンを検出し、修正済みのバージョンを通し、SARIF の場所と要約を確かめる')

report, calls = run('mismatch', [f'actions/download-artifact@{sha_old} # v4.1.3'], fixed, 1)
assert [result['ruleId'] for result in report['results']] == ['version-mismatch']
assert len(calls) == 1 and 'commits/v4.1.3' in calls[0][1]
for name, value in [('tag', 'actions/download-artifact@v4'),
                    ('short', 'actions/download-artifact@eaceaf8 # v4.1.2'),
                    ('no-version', old.split(' #')[0])]:
    report, calls = run(name, [value], fixed, 1)
    assert not calls and report['results'][0]['ruleId'] == 'version-mismatch'
report, calls = run('local', ['./local-action'], fixed, 0)
assert not calls
print('PASS action-advisories: 注記と SHA の食い違い、固定やバージョンの欠落を拒み、手元のアクションを飛ばす')

uses = [old, old.replace('download-artifact@', 'download-artifact/subpath@'), patched,
        f'actions/checkout@{sha_checkout} # v7.0.1']
report, calls = run('mixed', uses, mixed, 1)
assert [location(result)['region']['startLine'] for result in report['results']] == [8, 9]
queries = [args for args in calls if args[:4] == ['api', '-X', 'GET', '/advisories']]
assert len(calls) == 4 and len(queries) == 1
assert 'affects=actions/checkout@7.0.1,actions/download-artifact@4.1.2,actions/download-artifact@4.1.3' in queries[0]
report, _ = run('second-page', [old], [[], vulnerable[0]], 1)
assert len(report['results']) == 1
report, _ = run('duplicate-pages', [old], [vulnerable[0], vulnerable[0]], 1)
assert len(report['results']) == 1
report, _ = run('yaml-spaces', [old], vulnerable, 1, filename='probe extra.yaml')
assert location(report['results'][0])['artifactLocation']['uri'] == 'workflows/probe%20extra.yaml'
print('PASS action-advisories: バージョンごとに照合し、サブパスを除いて一括照会し、全ページと両拡張子を読む')

for mode in ('tag-failure', 'tag-shape', 'api-failure'):
    run(mode, [old], vulnerable, 2, mode=mode)
for name, response in [('invalid-json', '{'), ('null-response', None), ('object-page', [{}])]:
    run(name, [old], response, 2)
for field in ('ghsa_id', 'summary', 'severity', 'type', 'withdrawn_at', 'vulnerabilities'):
    response = copy.deepcopy(vulnerable)
    del response[0][0][field]
    run('missing-' + field, [old], response, 2)
for field in ('package', 'vulnerable_version_range'):
    response = copy.deepcopy(vulnerable)
    del response[0][0]['vulnerabilities'][0][field]
    run('missing-' + field, [old], response, 2)
for index, value in enumerate((False, 'unreadable')):
    response = copy.deepcopy(vulnerable)
    response[0][0]['withdrawn_at'] = value
    run('invalid-withdrawn-' + str(index), [old], response, 2)
response = copy.deepcopy(vulnerable)
response[0][0]['withdrawn_at'] = '2024-09-03T20:55:34Z'
run('withdrawn', [old], response, 0)
response = copy.deepcopy(vulnerable)
response[0][0]['vulnerabilities'][0]['vulnerable_version_range'] = '^4.0.0'
run('unreadable-range', [old], response, 2)
run('missing-directory', [], fixed, 2, directory='missing')
print('PASS action-advisories: API の失敗・不正な応答・欄や入力の欠落・読めない範囲は終了コード 2 と失敗の SARIF にする')

for index, (expression, expected) in enumerate([
    ('< 4.1.3', 1), ('<= 4.1.2', 1), ('= 4.1.2', 1), ('> 4.1.2', 0),
    ('>= 4.1.2', 1), ('< 4.1.2', 0), ('<= 4.1.1', 0), ('>= 0', 1),
    ('< 4.1.2-rc.1', 0), ('>= 4.1.2-rc.1', 1), ('< 4.1.10', 1), ('>= 4.1.10', 0),
]):
    response = copy.deepcopy(vulnerable)
    response[0][0]['vulnerabilities'][0]['vulnerable_version_range'] = expression
    run('range-' + str(index), [old], response, expected)
print('PASS action-advisories: 範囲の上下限・等号・桁・安定したバージョンとプレリリースの順を数として比べる')
PY
