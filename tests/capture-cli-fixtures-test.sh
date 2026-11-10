#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
python3 - <<'PY'
import copy
import json
import runpy
from pathlib import Path

capture = runpy.run_path('tests/capture-cli-fixtures.py')
fixtures = Path('tests/fixtures/cli')
entries = capture['contracts']()

def structure(value):
    if isinstance(value, dict):
        return {k: structure(v) for k, v in value.items()}
    if isinstance(value, list):
        return [structure(v) for v in value]
    return type(value).__name__

# 実物の見本の自由文を置き換え、キーと型が変わらず、自由文が残らないこと。
response = json.loads((fixtures / 'member-list.json').read_text())[0]
original = copy.deepcopy(response)
original[0]['name'] = 'PRIVATE_PERSON_SENTINEL'
original[0]['email'] = 'PRIVATE_EMAIL_SENTINEL@private.invalid'
masked = capture['redact'](original)
assert structure(masked) == structure(original)
assert 'PRIVATE_' not in json.dumps(masked)
assert masked[0]['user_id'] == original[0]['user_id']
original = json.loads((fixtures / 'agent-get.json').read_text())
original[0]['instructions'] = 'PRIVATE_INSTRUCTION_SENTINEL'
original[0]['avatar_url'] = 'https://private.invalid/PRIVATE_AVATAR_SENTINEL'
masked = capture['redact'](original)
assert structure(masked) == structure(original)
assert 'PRIVATE_' not in json.dumps(masked)
assert masked[0]['id'] == original[0]['id']
original = json.loads((fixtures / 'issue-get.json').read_text())
assert capture['redact'](original)[0]['creator_type'] == original[0]['creator_type']
original = json.loads((fixtures / 'gh-pr-checks.json').read_text())
assert capture['redact'](original)[0]['headRefOid'] == original[0]['headRefOid']
print('PASS redact: 鍵・型を保ち、名前・指示・URL を匿名化する')

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
PY
