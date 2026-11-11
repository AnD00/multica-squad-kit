#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
python3 - <<'PY'
import copy
import json
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

capture = runpy.run_path('tests/capture-cli-fixtures.py')
fixtures = Path('tests/fixtures/cli')
entries = capture['contracts']()

def structure(value):
    if isinstance(value, dict):
        return {k: structure(v) for k, v in value.items()}
    if isinstance(value, list):
        return [structure(v) for v in value]
    return type(value).__name__

def sample_id(number):
    # 配布物には UUID を書かず、実行中だけ入力を作る。
    return '%08x-%04x-%04x-%04x-%012x' % (number, 0, 0, 0, number)

# 実物の見本の自由文を置き換え、キーと型が変わらず、自由文が残らないこと。
response = json.loads((fixtures / 'member-list.json').read_text())[0]
original = copy.deepcopy(response)
original[0]['name'] = 'PRIVATE_PERSON_SENTINEL'
original[0]['email'] = 'PRIVATE_EMAIL_SENTINEL@private.invalid'
original[0]['user_id'] = sample_id(2)
masked = capture['redact'](original)
assert structure(masked) == structure(original)
assert 'PRIVATE_' not in json.dumps(masked)
assert masked[0]['user_id'] != original[0]['user_id']
original = json.loads((fixtures / 'agent-get.json').read_text())
original[0]['instructions'] = 'PRIVATE_INSTRUCTION_SENTINEL'
original[0]['avatar_url'] = 'https://private.invalid/PRIVATE_AVATAR_SENTINEL'
original[0]['id'] = sample_id(2)
masked = capture['redact'](original)
assert structure(masked) == structure(original)
assert 'PRIVATE_' not in json.dumps(masked)
assert masked[0]['id'] != original[0]['id']
original = json.loads((fixtures / 'issue-get.json').read_text())
assert capture['redact'](original)[0]['creator_type'] == original[0]['creator_type']
original = json.loads((fixtures / 'gh-pr-checks.json').read_text())
assert capture['redact'](original)[0]['headRefOid'] == original[0]['headRefOid']
print('PASS redact: 鍵・型を保ち、名前・指示・URL を匿名化する')

# 同一性・比較順・埋め込みを確認し、同じ値の衝突やファイル別の採番を防ぐ。
low, high = sample_id(1), sample_id(10)
original = {'first': [{'id': high, 'parent_id': low, 'nullable': None}],
            'second': [{'id': low, 'agent_id': high, 'url': 'https://example.invalid/' + high}],
            'more': [{'id': sample_id(n)} for n in range(1, 13)]}
masked = capture['redact'](original)
assert structure(masked) == structure(original)
assert masked['first'][0]['id'] == masked['second'][0]['agent_id']
assert masked['first'][0]['parent_id'] == masked['second'][0]['id']
assert masked['second'][0]['id'] < masked['first'][0]['id']
assert masked['second'][0]['url'].endswith('/' + masked['first'][0]['id'])
ordered = [item['id'] for item in masked['more']]
assert ordered == sorted(ordered) and len(set(ordered)) == 12
assert not capture['UUID'].search(json.dumps(masked))
assert original['first'][0]['id'] == high
assert capture['redact'](dict(reversed(list(original.items())))) == masked
print('PASS redact IDs: 同一性・比較順・埋め込み・鍵・型・省略を保ち、UUID を残さない')

# 実際の保存経路でも、全ファイルに共通の対応表と採取記録を使う。
responses = {name: json.loads((fixtures / f'{name}.json').read_text())
             for name in ('agent-get', 'member-list')}
responses['agent-get'][0]['id'] = high
responses['member-list'][0][0]['user_id'] = high
responses['member-list'][0][0]['id'] = low
real_run = subprocess.run
def run(command, **kwargs):
    if command == ['multica', 'version'] or command == ['gh', '--version']:
        return subprocess.CompletedProcess(command, 0, 'captured-version\n', '')
    return real_run(command, **kwargs)

Path('tmp').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir='tmp', prefix='capture-test.') as directory:
    with patch.dict(capture['main'].__globals__, {
        'contracts': lambda: {name: entries[name] for name in responses},
        'capture': lambda *args: responses,
    }), patch.object(subprocess, 'run', side_effect=run), patch.object(
        sys, 'argv', ['capture', 'fixture-issue', '--output-dir', directory]
    ):
        assert capture['main']() == 0
    output = Path(directory)
    agent = json.loads((output / 'agent-get.json').read_text())[0]
    member = json.loads((output / 'member-list.json').read_text())[0][0]
    assert agent['id'] == member['user_id'] and member['id'] < agent['id']
    assert (output / 'VERSION').read_text() == 'captured-version\ncaptured-version\n'
    coverage = json.loads((output / 'CAPTURE.json').read_text())
    assert coverage['agent-get'][0]['count'] == len(responses['agent-get'])
    assert coverage['member-list'][0]['count'] == len(responses['member-list'][0])
    assert not any(capture['UUID'].search(p.read_text()) for p in output.iterdir())
print('PASS capture IDs: ファイル間の同一性・比較順と、版・件数の記録を保存する')

# 実物から取り込んだ配布見本自体にも、UUID を残さない。
assert not any(capture['UUID'].search(p.read_text()) for p in fixtures.glob('*.json'))
print('PASS fixtures: 配布する全見本に UUID がない')

response = json.loads((fixtures / 'issue-comments.json').read_text())
before = copy.deepcopy(response)
selected, coverage, missing = capture['select_samples'](response, entries['issue-comments'])
assert not missing
assert response == before
assert all(item in response[0] for item in selected[0])
print('PASS select: 実物の要素だけを選び、入力を変更しない')

# 実物の人間のコメントを除くと、足りない形の名前が返る。
without_members = [[item for item in response[0] if item['author_type'] != 'member']]
_, _, missing = capture['select_samples'](without_members, entries['issue-comments'])
assert missing == ['member'], missing
print('PASS select: 足りない形の名前を知らせる')

_, coverage, missing = capture['select_samples']([], entries['gh-pr-checks'])
assert missing == ['CheckRun']
assert coverage[1]['count'] == 0 and coverage[1]['unavailable']
print('PASS select: 見本なしの形を、採取漏れと分ける')
# GitHub の採取は読み取りのコマンドだけ。自由文・人の login・URL を残さない。
gh = runpy.run_path('tests/capture-gh-fixtures.py')
assert gh['read_only'](['gh','api','repos/example/public/pulls','--paginate'])
assert gh['read_only'](['gh','pr','view','1','--repo','example/public','--json','title'])
for flag in ('--method=POST','-XPOST','--field=x=y','-fbody=x','--input=-'):
    assert not gh['read_only'](['gh','api','repos/example/public/issues',flag])
assert not gh['read_only'](['gh','pr','merge','1'])
original={'body':'PRIVATE_BODY','commit':{'message':'PRIVATE_MESSAGE'},'user':{'login':'PRIVATE_LOGIN'},
          'avatar_url':'https://private.invalid/PRIVATE_AVATAR','patch':None,'text':'PRIVATE_TEXT','payload':'PRIVATE_PAYLOAD'}
masked=gh['redact'](original,{})
assert structure(masked)==structure(original) and 'PRIVATE_' not in json.dumps(masked)
print('PASS GitHub capture: 書き込みのオプションを拒み、自由文・login・URL を匿名化する')

PY
