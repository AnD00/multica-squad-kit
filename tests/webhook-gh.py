"""Offline GitHub webhook API. Persist IDs, never the credential URL or input body."""
import json
import os
import subprocess
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

scenario = Path(sys.argv[1])
args = sys.argv[2:]
path = scenario / 'db.json'
db = json.loads(path.read_text())
with (scenario / 'gh-calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')

def option(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default

endpoint = args[1]
parts = endpoint.split('/')
repo = '/'.join(parts[1:3])
settings = db.get('webhook_cases', {}).get(repo, {})
base = 'https://' + 'webhook-canary.example.test/'

def fail():
    print(base + 'failure', file=sys.stderr)
    print(base + 'failure')
    sys.exit(71)

hooks = db.setdefault('github_hooks', [])
if endpoint == 'repos/AnD00/multica-squad-kit/releases/latest':
    # 更新の知らせ。既定は、流している原本と同じ最新のバージョン。
    result = dict(tag_name=os.environ.get('TEST_LATEST_TAG') or (Path(__file__).resolve().parent.parent / 'VERSION').read_text().strip())
elif len(parts) == 3:
    if settings.get('deny_repository'):
        fail()
    result = dict(permissions=dict(admin=settings.get('admin', True)))
elif len(parts) == 4 and option('--method') == 'POST':
    if settings.get('fail_create'):
        fail()
    assert option('--input') == '-'
    body = json.load(sys.stdin)
    assert body['name'] == 'web' and body['active'] is True
    assert body['events'] == ['pull_request']
    assert body['config']['content_type'] == 'json' and body['config']['insecure_ssl'] == '0'
    assert body['config']['url'].startswith(base)
    hook = dict(id=len(hooks) + 1, repository=repo, active=body['active'],
                events=body['events'], content_type=body['config']['content_type'],
                destination=body['config']['url'].removeprefix(base))
    hooks.append(hook)
    # 応答も URL を含ませ、gh の --jq で外へ出ないことを確認する。
    result = dict(id=hook['id'], config=dict(url=body['config']['url']))
elif len(parts) == 4:
    if settings.get('deny_hooks'):
        fail()
    result = [dict(id=h['id'], active=h['active'], events=h['events'],
                   config=dict(url=base + h['destination'], content_type=h['content_type']))
              for h in hooks if h['repository'] == repo]
elif len(parts) == 6 and parts[-1] == 'deliveries':
    if settings.get('deny_deliveries'):
        fail()
    reads = 1
    if settings.get('delay', 0):
        query = db.setdefault('delivery_reads', {})
        query[repo] = query.get(repo, 0) + 1
        reads = query[repo]
    if settings.get('missing_delivery') or reads <= settings.get('delay', 0):
        result = []
    else:
        result = [dict(id=1, event=settings.get('event', 'ping'),
                       delivered_at='2026-01-01T00:00:00Z', status_code=settings.get('status', 200))]
else:
    raise AssertionError(args)

# 資格情報を渡す Multica の CLI と並行して動くため、DB は一度に置き換える。
with NamedTemporaryFile(mode='w', encoding='utf-8', dir=scenario, delete=False) as saved:
    json.dump(db, saved, ensure_ascii=False)
Path(saved.name).replace(path)
if '--paginate' in args and '--slurp' in args:
    result = [result]
if '--jq' in args:
    process = subprocess.run(['jq', '-r', option('--jq')], input=json.dumps(result), text=True)
    sys.exit(process.returncode)
print(json.dumps(result))
