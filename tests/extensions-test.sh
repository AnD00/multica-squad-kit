#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/extensions.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$root" "$test_dir" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

kit, work = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('extensions', kit / 'lib/extensions.py')
module = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(module)
ext = work / 'extension'
ext.mkdir()
(ext / 'kit-version').write_text('v1.0.0\n')
(ext / 'instructions').mkdir()
(ext / 'instructions/qa.md').write_text('## Project checks\n\nRead the project test manual.\n')
patch = {'qa': {'skills': ['browser-check'], 'max_concurrent_tasks': 2, 'mcp_config': {'mcpServers': {'browser': {'command': 'browser-tool'}}}, 'instructions_file': 'instructions/qa.md'}}
(ext / 'additions.json').write_text(json.dumps(patch))
(ext / 'agents').mkdir()
(ext / 'agents/helper.md').write_text('---\nname: "{{project_key}}-helper-{{member_key}}"\ndescription: Extra helper\nmodel: gpt-6.1-sol\nthinking_level: high\nskills: squad-handoff\n---\n\nHelp the project.\n')
(ext / 'monitor').mkdir()
(ext / 'monitor/squad-custom-check').write_text('#!/bin/bash\n# multica-squad-kit-managed\necho check\n')
(ext / 'skills/browser-check').mkdir(parents=True)
(ext / 'skills/browser-check/SKILL.md').write_text('---\nname: browser-check\ndescription: Project browser checks\n---\n\nRun project checks.\n')
(ext / 'autopilots.md').write_text('## Extra {{project_key}} {{member_key}}\n\n- 範囲: `member`\n- 担当: {{agent.helper.name}}\n- 実行: `run_only`\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\nRun checks.\n```\n')
module.materialize(kit, ext, work / 'combined')
qa = (work / 'combined/common/agents/qa.md').read_text()
assert 'skills: squad-handoff, verify, browser-check' in qa
assert 'max_concurrent_tasks: 2' in qa
assert qa.endswith('Read the project test manual.\n\n')
assert (kit / 'common/agents/qa.md').read_text() in qa.replace('skills: squad-handoff, verify, browser-check', 'skills: squad-handoff, verify').replace('\nmax_concurrent_tasks: 2', '')
assert (work / 'combined/extension-roles').read_text() == 'helper'
assert json.loads((work / 'combined/extension-mcp.json').read_text())['qa'] == patch['qa']['mcp_config']
assert (work / 'combined/skeleton/.agents/skills/browser-check/SKILL.md').exists()
assert (work / 'combined/common/monitor/squad-custom-check').exists()
print('PASS extensions: 原本を変えず、指示・スキル・MCP・上限・役・見張り・オートパイロットを足す')

def deny(name):
    try:
        module.materialize(kit, ext, work / name)
    except ValueError:
        return
    raise AssertionError('extension was accepted: ' + name)

(ext / 'kit-version').write_text('v0.0.0\n')
deny('wrong-version')
assert not (work / 'wrong-version').exists()
(ext / 'kit-version').write_text('v1.0.0\n')
(ext / 'additions.json').write_text(json.dumps({'qa': {'instructions': 'replace'}}))
deny('replace-instructions')
(ext / 'additions.json').write_text('{}')
(ext / 'agents/qa.md').write_text('replace')
deny('replace-agent')
(ext / 'agents/qa.md').unlink()
(ext / 'monitor/squad-pr-watch').write_text('replace')
deny('replace-monitor')
(ext / 'monitor/squad-pr-watch').unlink()
print('PASS extensions: 版の違いは配置前に止め、指示・役・見張りの置き換えを拒否する')
PY
# 前の拡張を外したときも、停止対象を原本とは別に引き継ぐ。
/bin/bash -s -- "$root" "$test_dir" <<'SH'
set -euo pipefail
root=$1; kit_root=$1; test_dir=$2
source "$root/lib/render.sh"
source "$root/lib/extensions.sh"
state_root=$test_dir/state
workspace_id=ws-a; project_key=demo; member_key=membera
mkdir -p "$state_root/$workspace_id"
printf '%s\n' '{"roles":["helper"],"autopilots":"## Old demo membera\n"}' >"$state_root/ws-a/demo-membera.extensions.json"
load_extension_inventory
[[ " $template_roles " == *' helper '* && " $extension_disabled_roles " == *' helper '* ]]
grep -q '^## Old demo membera' "$autopilots_known_source"
save_extension_inventory
jq -e '.roles==[] and .autopilots==""' "$extension_inventory" >/dev/null
SH
echo 'PASS extensions: 消した拡張の役とオートパイロットを、停止・切り離しの管理対象に残す'
