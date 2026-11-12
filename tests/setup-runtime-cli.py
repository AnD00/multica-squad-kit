"""Offline Multica CLI for the setup entrypoint integration test."""
import json
import os
import re
import sys
import zipfile
from copy import deepcopy
from pathlib import Path
from tempfile import NamedTemporaryFile

scenario = Path(sys.argv[1])
args = sys.argv[2:]
path = scenario / 'db.json'
db = json.loads(path.read_text())
before = deepcopy(db)
with (scenario / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args, ensure_ascii=False) + '\n')


def option(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default


def content(flag):
    return Path(option(flag)).read_text()


def record(collection, id_):
    return next(item for item in db[collection] if item['id'] == id_)


def create(collection, **values):
    item = {'id': f'{collection}-{len(db[collection]) + 1}', **values}
    db[collection].append(item)
    return item


def skill_data(files, config):
    text = files.pop('SKILL.md')
    fields = dict(re.findall(r'^(name|description): (.+)$', text, re.M))
    return dict(name=fields['name'], description=fields['description'],
                content=text, created_by='member-a', config=config,
                files=[dict(id=f'file-{n}', path=name, content=value)
                       for n, (name, value) in enumerate(sorted(files.items()))])


event = tuple(args[:2])
failure = scenario / 'fail-read'
if failure.exists() and failure.read_text().strip() in (' '.join(event), ' '.join(args[:3])):
    print('read denied', file=sys.stderr)
    sys.exit(71)
malformed = scenario / 'bad-read'
if malformed.exists() and malformed.read_text().strip() in (' '.join(event), ' '.join(args[:3])):
    print('{}')
    sys.exit()
result = {}
if event == ('config', 'show'):
    print('server_url: https://example.test')
    sys.exit(0)
elif event == ('auth', 'status'):
    pass
elif event == ('user', 'profile'):
    result = dict(id='member-a', name='Owner', email='owner@example.test')
elif event == ('workspace', 'list'):
    result = [dict(id='ws-a', name='Workspace A')]
elif event == ('workspace', 'member'):
    result = db.get('members', [dict(user_id='member-a', name='Owner', role='owner')])
elif event == ('repo', 'list'):
    result = [dict(url='https://github.com/example/project')]
elif event == ('daemon', 'status'):
    result = dict(status='running' if db['running'] else 'stopped',
                  pid=4242 if db['running'] else None, daemon_id='daemon-a',
                  active_task_count=0, running_task_count=0,
                  server_url='https://example.test')
elif event == ('daemon', 'start'):
    db['running'] = True
    db['daemon_env'] = f'CODEX_HOME={os.environ["CODEX_HOME"]} PATH={os.environ["PATH"]}'
    (scenario / 'process-env').write_text(db['daemon_env'])
elif event == ('runtime', 'list'):
    result = [dict(id=f'runtime-{runtime}', owner_id='member-a',
                   daemon_id='daemon-a', provider=runtime, status=db.get('runtime_status', {}).get(runtime, 'online'))
              for runtime in db['runtimes']] if db['running'] else []
elif event == ('label', 'list'):
    prototype = json.loads((Path(__file__).resolve().parent / 'fixtures/cli/label-list.json').read_text())[0][0]
    result = [{**prototype, **label} for label in db['labels']]
elif event == ('label', 'create'):
    result = create('labels', name=option('--name'), color=option('--color'),
                    description=option('--description'))
elif event == ('skill', 'list'):
    result = db['skills']
elif event == ('skill', 'get'):
    result = record('skills', args[2])
elif event == ('skill', 'import'):
    url = option('--url')
    if url:
        version = (scenario.parent / 'package/VERSION').read_text().strip()
        assert f'/tree/{version}/common/skills/' in url, url
        folder = scenario.parent / 'package/common/skills' / url.rsplit('/', 1)[1]
        files = {str(p.relative_to(folder)): p.read_text()
                 for p in folder.rglob('*') if p.is_file()}
        config = dict(origin=dict(type='github', source_url=url))
    else:
        with zipfile.ZipFile(option('--file')) as archive:
            files = {name: archive.read(name).decode()
                     for name in archive.namelist() if not name.endswith('/')}
        config = {}
    item = create('skills', **skill_data(files, config))
    result = dict(status='created', skill=item)
elif event == ('project', 'list'):
    result = db['projects']
elif event == ('project', 'create'):
    result = create('projects', title=option('--title'), description=option('--description'))
    db['resources'] = [dict(resource_type='github_repo', resource_ref=dict(url=option('--repo')))]
elif event == ('project', 'get'):
    result = record('projects', args[2])
elif tuple(args[:3]) == ('project', 'resource', 'list'):
    result = db['resources']
elif event == ('agent', 'list'):
    result = db['agents']
elif event == ('agent', 'get'):
    result = record('agents', args[2])
elif event == ('agent', 'create'):
    result = create('agents', name=option('--name'), owner_id='member-a',
                    model=option('--model'), runtime_id=option('--runtime-id'),
                    thinking_level=option('--thinking-level'),
                    max_concurrent_tasks=int(option('--max-concurrent-tasks')),
                    instructions=option('--instructions'),
                    permission_mode=option('--permission-mode'),
                    custom_args=json.loads(option('--custom-args')),
                    invocation_targets=[], skills=[])
    db['envs'][result['id']] = json.loads(content('--custom-env-file'))
elif event == ('agent', 'update'):
    result = record('agents', args[2])
    for flag in ('model', 'runtime-id', 'thinking-level', 'description',
                 'instructions', 'permission-mode'):
        if f'--{flag}' in args:
            result[flag.replace('-', '_')] = option(f'--{flag}')
    if '--max-concurrent-tasks' in args:
        result['max_concurrent_tasks'] = int(option('--max-concurrent-tasks'))
    if '--mcp-config' in args:
        result['mcp_config'] = json.loads(option('--mcp-config'))
    if '--custom-args' in args:
        result['custom_args'] = json.loads(option('--custom-args'))
    if '--public-to-workspace' in args:
        result['invocation_targets'] = [dict(target_type='workspace')]
elif tuple(args[:3]) == ('agent', 'env', 'get'):
    result = dict(custom_env=db['envs'][args[3]])
elif tuple(args[:3]) == ('agent', 'env', 'set'):
    db['envs'][args[3]] = json.loads(content('--custom-env-file'))
elif tuple(args[:3]) == ('agent', 'skills', 'set'):
    record('agents', args[3])['skills'] = [dict(id=id_) for id_ in option('--skill-ids').split(',') if id_]
elif event == ('squad', 'list'):
    result = db['squads']
elif event == ('squad', 'create'):
    result = create('squads', name=option('--name'), creator_id='member-a',
                    leader_id=option('--leader'), instructions='')
    db['roster'] = [dict(member_id=result['leader_id'], member_type='agent', role='leader')]
elif event == ('squad', 'get'):
    result = record('squads', args[2])
elif event == ('squad', 'update'):
    result = record('squads', args[2])
    result.update(leader_id=option('--leader'), instructions=option('--instructions'))
elif tuple(args[:3]) == ('squad', 'member', 'list'):
    result = db['roster']
elif tuple(args[:3]) == ('squad', 'member', 'add'):
    db['roster'].append(dict(member_id=option('--member-id'),
                             member_type=option('--type'), role=option('--role')))
elif event == ('autopilot', 'list'):
    result = dict(autopilots=db['autopilots'])
elif event == ('autopilot', 'create'):
    result = create('autopilots', title=option('--title'), description=option('--description'),
                    execution_mode=option('--mode'), project_id=option('--project'),
                    assignee_id=option('--agent'), assignee_type='agent', status='active')
    db['triggers'][result['id']] = []
elif event == ('autopilot', 'get'):
    pilot = record('autopilots', args[2])
    result = dict(autopilot={**pilot, 'can_write': pilot.get('can_write', True)},
                  triggers=[dict(t) for t in db['triggers'][args[2]]])
    if '--show-secrets' in args and pilot.get('fail_secrets'):
        print('https://' + 'webhook-canary.example.test/' + args[2], file=sys.stderr)
        sys.exit(71)
    for trigger in result['triggers']:
        if trigger['kind'] == 'webhook':
            trigger['has_signing_secret'] = pilot.get('signed', False)
            trigger['webhook_url'] = ('https://' + 'webhook-canary.example.test/' + args[2]
                                      if ('--show-secrets' in args or pilot.get('canary_on_default_get')) and not pilot.get('missing_url') else None)
            if '--show-secrets' in args:
                print('unsafe credential warning', file=sys.stderr)
elif event == ('autopilot', 'trigger-list'):
    result = dict(triggers=db['triggers'][args[2]])
elif event == ('autopilot', 'trigger-add'):
    if option('--kind') == 'webhook' and record('autopilots', args[2]).get('fail_trigger'):
        print('https://' + 'webhook-canary.example.test/' + args[2], file=sys.stderr)
        sys.exit(71)
    db['triggers'][args[2]].append(dict(id=f'trigger-{option("--kind")}-{args[2]}', kind=option('--kind'),
                                      cron_expression=option('--cron'),
                                      timezone=option('--timezone'), enabled=True))
elif event == ('issue', 'create'):
    failure = scenario / 'fail-issue'
    if failure.exists() and failure.read_text().strip() == option('--title'):
        print('issue creation denied', file=sys.stderr)
        sys.exit(71)
    result = create('issues', title=option('--title'), description=content('--description-file'),
                    project_id=option('--project'), assignee=option('--assignee'),
                    assignee_id=option('--assignee-id'), status=option('--status', 'todo'),
                    identifier=f'TEST-{len(db["issues"]) + 1}', metadata={}, labels=[])
elif event == ('issue', 'list'):
    issues = [i for i in db['issues'] if i['project_id'] == option('--project')]
    metadata = option('--metadata')
    if metadata:
        key, value = metadata.split('=', 1)
        issues = [i for i in issues if i['metadata'].get(key) == value]
    offset, limit = int(option('--offset', '0')), int(option('--limit', '100'))
    result = dict(issues=issues[offset:offset + limit], has_more=offset + limit < len(issues))
elif tuple(args[:3]) == ('issue', 'metadata', 'set'):
    assert option('--type') == 'string'
    record('issues', args[3])['metadata'][option('--key')] = option('--value')
elif tuple(args[:3]) == ('issue', 'label', 'add'):
    issue = record('issues', args[3])
    issue['label_id'] = args[4]
    if not any(label['id'] == args[4] for label in issue['labels']):
        issue['labels'].append(dict(id=args[4]))
elif event == ('issue', 'status'):
    issue = record('issues', args[2])
    assert issue['labels'] and issue['metadata']['squad_kit_task']
    issue['status'] = args[3]
else:
    raise AssertionError(f'Unexpected CLI call: {args}')

# 読み取りだけの呼び出しでは、大きな DB の保存を繰り返さない。
# Webhook のパイプでは別の CLI が同じ DB を読む。変更時も途中の JSON を見せない。
if db != before:
    with NamedTemporaryFile(mode='w', encoding='utf-8', dir=scenario, delete=False) as saved:
        json.dump(db, saved, ensure_ascii=False)
    Path(saved.name).replace(path)
print(json.dumps(result, ensure_ascii=False))
