#!/usr/bin/env bash
# setup.sh を通さず、片方だけの初回登録を本体の project・squad・autopilots・installation で確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

export TEST_COMPLETE=yes TEST_ROLE_COUNT=14
export TEST_REPOSITORIES='[{"url":"https://github.com/example/project","repository":"example/project"}]'
for selected in claude codex; do
 export TEST_RUNTIMES="[\"$selected\"]"
 reset_db
 run
 python3 - "$TEST_DB" "$TEMPLATE_AGENT_HOME" "$test_dir/out" "$selected" <<'PY'
import json
import sys
from pathlib import Path

db, home, output = map(Path, sys.argv[1:4])
selected = sys.argv[4]
agents = {p.stem.removeprefix('agent-demo-').removesuffix('-owner'): json.loads(p.read_text())
          for p in (db / 'agents').glob('agent-demo-*.json')}
roles = set('orchestrator planner designer qa code-reviewer ux-reviewer security-reviewer '
            'performance-reviewer ci-monitor usage-monitor dependabot-merger'.split())
roles |= {selected + suffix for suffix in ('-implementer', '-fixer', '-principal')}
assert set(agents) == roles
monitors = {'ci-monitor', 'usage-monitor', 'dependabot-merger'}
medium = {'planner', 'qa', 'ux-reviewer', 'performance-reviewer'}
for role, agent in agents.items():
    model = 'gpt-6.1-sol'
    if selected == 'claude':
        model = 'claude-opus-5-5' if role in {'planner', 'designer'} else 'claude-sonnet-5-5'
    if role.endswith('-principal'):
        model = 'claude-fable-5-2' if selected == 'claude' else 'gpt-6-astra'
    assert agent['model'] == model and agent['runtime_id'] == 'runtime-' + selected, role
    assert agent['thinking_level'] == ('low' if role in {'ci-monitor', 'usage-monitor'} else 'medium' if role in medium else 'xhigh' if role.endswith('-principal') else 'high'), role
    assert agent['max_concurrent_tasks'] == (1 if role in monitors else 6), role
    assert agent['permission_mode'] == 'public_to'
    assert agent['invocation_targets'] == [{'target_type': 'workspace'}]
    assert agent['instructions'] and '{{' not in agent['instructions'] and '<!-- IF' not in agent['instructions']
    env = json.loads((db / 'env' / (agent['id'] + '.json')).read_text())
    assert env['SQUAD_KIT_ALLOWED_REPOS'] == str(home / 'allowed-repos.d/project-a')
    assert env['GIT_CONFIG_VALUE_0'] == str(home / 'git-hooks')
    claude_env = {key: value for key, value in env.items() if key.startswith('CLAUDE_')}
    if selected == 'claude':
        assert claude_env == {'CLAUDE_CONFIG_DIR': str(home / 'claude'),
                              'CLAUDE_CODE_SHELL': '/bin/zsh',
                              'CLAUDE_CODE_AUTO_COMPACT_WINDOW': '150000',
                              'CLAUDE_ENV_FILE': str(home / 'template/shell/project-a/env.sh')}, role
        assert env['ENABLE_CLAUDEAI_MCP_SERVERS'] == 'false'
        assert env['CLAUDE_ENV_FILE'] == env['BASH_ENV']
    else:
        assert claude_env == {} and 'ENABLE_CLAUDEAI_MCP_SERVERS' not in env, role
    assert ('SQUAD_KIT_GH_DEPENDABOT_MERGE' in env) == (role == 'dependabot-merger')
    assert bool(agent['skills']) == (role not in monitors), role
print(f'PASS project runtimes first: {selected} だけの役の組・モデル・runtime_id・環境を初回登録する')

squad = json.loads((db / 'squad.json').read_text())
roster = json.loads((db / 'roster.json').read_text())
assert squad['leader_id'] == agents['orchestrator']['id']
assert {m['member_id'] for m in roster} == {a['id'] for r, a in agents.items() if r not in monitors} | {'actor'}
assert len(roster) == len(roles) - 2
pilots = json.loads((db / 'autopilots.json').read_text())
assert len(pilots) == 3
assert {p['assignee_id'] for p in pilots} == {agents[r]['id'] for r in ('security-reviewer', 'usage-monitor', 'dependabot-merger')}
for pilot in pilots:
    triggers = json.loads((db / ('triggers-' + pilot['id'] + '.json')).read_text())
    assert len(triggers) == 1 and triggers[0]['kind'] == 'schedule'
print(f'PASS project runtimes first: {selected} だけの名簿の組と数・オートパイロットの組を登録する')

display = output.read_text()
assert display.count('\n  ✔ ') == 6 + len(roles) + 1 + len(pilots) + 1
assert '\n  ! ' not in display and '記録なし' not in display
assert '+14 エージェント  +1 スクワッド  +3 オートパイロット' in display
assert ('CLAUDE_CONFIG_DIR=' in display) == (selected == 'claude')
assert ('CODEX_HOME=' in display) == (selected == 'codex')
print(f'PASS project runtimes first: {selected} だけの完了の ✔ の行数とログインの案内を表示する')
PY
done
