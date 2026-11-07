"""Definitions and independently mutable remote state for installation checks."""
import json
import sys
from pathlib import Path

scenario = Path(sys.argv[1])
path = scenario / 'db.json'
db = json.loads(path.read_text())
work = scenario / 'work'
work.mkdir()
records, agents, roster = {}, [], []
for role, description in [('orchestrator', 'leader'), ('codex-implementer', '実装'),
                          ('ci-monitor', ''), ('dependabot-merger', '')]:
    id_ = 'agent-' + role
    record = dict(id=id_, name=f'demo-{role}-owner', model='gpt-6.1-sol',
                  thinking_level='high', runtime_id='runtime-codex', max_concurrent_tasks=6)
    records[role] = record
    skill_ids = ['handoff', 'verify'] if description else []
    agents.append({**record, 'owner_id': 'actor', 'permission_mode': 'public_to',
                   'invocation_targets': [dict(target_type='workspace')],
                   'skills': [dict(id=id_) for id_ in skill_ids]})
    (work / (role + '.skills')).write_text(','.join(skill_ids))
    (work / (role + '.rendered')).write_text(f'---\nrole: {description}\n---\n')
    if description:
        roster.append(dict(member_id=id_, member_type='agent', role=description))
roster += [dict(member_id='actor', member_type='member', role='member'),
           dict(member_id='manual-member', member_type='member', role='専門家'),
           dict(member_id='manual-agent', member_type='agent', role='専門家')]
agents.append(dict(id='manual-agent', name='personal-expert', owner_id='someone-else'))
definitions, pilots, triggers = [], [], {}
for id_, kind in [('scheduled', 'schedule'), ('event-only', 'webhook')]:
    title, instructions = '検証用 ' + id_, 'オートパイロットの指示 ' + id_
    desired = dict(title=title, instructions=instructions, agent=records['dependabot-merger']['name'],
                   mode='run_only', trigger=kind, cron='0 10 * * 2', timezone='Asia/Tokyo')
    definitions.append(desired)
    pilots.append(dict(id=id_, title=title, description=instructions, project_id='project-a',
                       status='active', assignee_type='agent', assignee_id='agent-dependabot-merger',
                       execution_mode='run_only'))
    triggers[id_] = [dict(id=id_ + '-trigger', kind=kind, enabled=True,
                         cron_expression=desired['cron'], timezone=desired['timezone'])]
db.update(agents=agents, roster=roster, autopilots=pilots, triggers=triggers,
          runtimes=['codex'], running=True,
          squads=[dict(id='squad-a', name='DEMO-OWNER', creator_id='actor',
                       leader_id='agent-orchestrator', instructions='スクワッドの指示')])
db['labels'].append(dict(id='development', name='開発'))
path.write_text(json.dumps(db, ensure_ascii=False))
(work / 'records.json').write_text(json.dumps(records))
(work / 'autopilots.json').write_text(json.dumps(definitions, ensure_ascii=False))
(work / 'squad.instructions').write_text('スクワッドの指示\n')
