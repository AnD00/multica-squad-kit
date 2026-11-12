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
(ext / 'kit-version').write_text((kit / 'VERSION').read_text())
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
assert json.loads((work / 'combined/extension-link-repositories.json').read_text()) == []
(ext / 'link-repositories.json').write_text(json.dumps(['Example/Tools', 'example/tools']))
module.materialize(kit, ext, work / 'with-links')
assert json.loads((work / 'with-links/extension-link-repositories.json').read_text()) == ['example/tools']
assert (work / 'with-links/common/autopilots.md').read_text() == (work / 'combined/common/autopilots.md').read_text()
print('PASS extensions: 紐付け先を正規化し、共通の定義を置き換えずに渡す')

def deny(name):
    try:
        module.materialize(kit, ext, work / name)
    except ValueError:
        return
    raise AssertionError('extension was accepted: ' + name)

for i, invalid in enumerate(({}, 'example/tools', [False], ['https://github.com/example/tools'], ['example/..'], ['example/tools\n'])):
    (ext / 'link-repositories.json').write_text(json.dumps(invalid))
    deny('bad-links-' + str(i))
    assert not (work / ('bad-links-' + str(i))).exists()
(ext / 'link-repositories.json').write_text('{')
deny('bad-links-json')
(ext / 'link-repositories.json').unlink()
print('PASS extensions: 不正な紐付け先は結合ファイルを作る前に拒否する')

(ext / 'kit-version').write_text('v0.0.0\n')
deny('wrong-version')
assert not (work / 'wrong-version').exists()
(ext / 'kit-version').write_text((kit / 'VERSION').read_text())
(ext / 'additions.json').write_text(json.dumps({'qa': {'instructions': 'replace'}}))
deny('replace-instructions')
(ext / 'additions.json').write_text('{}')
(ext / 'agents/qa.md').write_text('replace')
deny('replace-agent')
(ext / 'agents/qa.md').unlink()
for reserved in ('claude-principal', 'codex-principal'):
    (ext / 'agents' / (reserved + '.md')).write_text('replace')
    deny('replace-' + reserved)
    (ext / 'agents' / (reserved + '.md')).unlink()
(ext / 'monitor/squad-pr-watch').write_text('replace')
deny('replace-monitor')
(ext / 'monitor/squad-pr-watch').unlink()
print('PASS extensions: バージョンの違いは配置前に止め、指示・役・見張りの置き換えを拒否する')
PY
# 前の拡張を外したときも、停止対象を原本とは別に引き継ぐ。
/bin/bash -s -- "$root" "$test_dir" <<'SH'
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
root=$1; test_dir=$2
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
source "$root/lib/render.sh"
source "$root/lib/extensions.sh"
# 新しい clone と同じく tmp がない原本から、拡張なしを選ぶ。
mkdir "$test_dir/fresh-clone"
cp -R "$root/common" "$root/skeleton" "$root/VERSION" "$test_dir/fresh-clone/"
root=$test_dir/fresh-clone
[[ ! -e $root/tmp ]]
choose_extension <<<''
[[ ! -e $kit_root/tmp ]]
state_root=$test_dir/state
workspace_id=ws-a; project_key=demo; member_key=membera
mkdir -p "$state_root/$workspace_id"
printf '%s\n' '{"roles":["helper"],"autopilots":"## Old demo membera\n"}' >"$state_root/ws-a/demo-membera.extensions.json"
load_extension_inventory
[[ -d $extension_work && $root == "$extension_work" && $root != "$kit_root" ]]
cmp "$kit_root/common/autopilots.md" "$root/common/autopilots.md"
[[ " $template_roles " == *' helper '* && " $extension_disabled_roles " == *' helper '* ]]
grep -q '^## Old demo membera' "$autopilots_known_source"
save_extension_inventory
jq -e '.roles==[] and .autopilots==""' "$extension_inventory" >/dev/null
SH
echo 'PASS extensions: tmp のない原本で拡張なしを選んでも、消した役とオートパイロットを停止・切り離しの管理対象に残す'

# 以前の拡張が原本の役と同名のキーを使っていたとき、外しても原本の役を登録から消さず、登録の前に止める。
for stale in claude-principal codex-principal; do
	stale_out=$test_dir/stale-${stale}.out
	if /bin/bash -s -- "$root" "$test_dir" "$stale" >"$stale_out" 2>&1 <<'SH'
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
root=$1; test_dir=$2; stale=$3
source "$root/lib/render.sh"
source "$root/lib/extensions.sh"
kit_root=$root
state_root=$test_dir/state-stale
workspace_id=ws-a; project_key=demo; member_key=membera
mkdir -p "$state_root/$workspace_id"
printf '{"roles":["%s"],"autopilots":""}\n' "$stale" >"$state_root/ws-a/demo-membera.extensions.json"
load_extension_inventory
printf '%s\n' "登録対象から外れた役: ${extension_disabled_roles:-}"
SH
	then
		cat "$stale_out" >&2
		echo "FAIL extensions: 以前の拡張の ${stale} が原本の役と衝突しても止まらない" >&2
		exit 1
	fi
	grep -q "以前の拡張の役のキー「${stale}」が原本の役と同じです" "$stale_out"
	! grep -q '登録対象から外れた役' "$stale_out"
done
# 原本の役と衝突しない以前の拡張のキーは、今までどおり外れた役として扱う。
/bin/bash -s -- "$root" "$test_dir" <<'SH'
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
root=$1; test_dir=$2
source "$root/lib/render.sh"
source "$root/lib/extensions.sh"
kit_root=$root
state_root=$test_dir/state-stale-ok
workspace_id=ws-a; project_key=demo; member_key=membera
mkdir -p "$state_root/$workspace_id"
printf '%s\n' '{"roles":["helper"],"autopilots":""}' >"$state_root/ws-a/demo-membera.extensions.json"
load_extension_inventory
[[ " $extension_disabled_roles " == *' helper '* && " $extension_disabled_roles " != *' claude-principal '* && " $extension_disabled_roles " != *' codex-principal '* ]]
for principal in claude-principal codex-principal; do [[ " $template_roles " == *" $principal "* ]]; done
SH
echo 'PASS extensions: 以前の拡張のキーが原本の最上位の役と同名なら、登録の前に止め、衝突しないキーは外れた役として扱う'

source "$root/lib/autopilots.sh"
cat >"$test_dir/webhook.md" <<'WEBHOOK'
## Issue events {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.orchestrator.name}}
- 実行: `run_only`
- トリガー: `webhook`

```text
Handle issue events.
```
WEBHOOK
autopilot_sections "$test_dir/webhook.md" >"$test_dir/sections.json"
jq -e 'length==1 and .[0].trigger=="webhook" and (.[0]|has("cron")|not)' "$test_dir/sections.json" >/dev/null
for variant in missing unknown mixed; do
 case $variant in
 missing) sed '/^- トリガー:/d' "$test_dir/webhook.md" >"$test_dir/bad.md" ;;
 unknown) sed 's/`webhook`/`other`/' "$test_dir/webhook.md" >"$test_dir/bad.md" ;;
 mixed) sed '/^- トリガー:/a\
- スケジュール: `0 0 * * *`（Asia/Tokyo）
' "$test_dir/webhook.md" >"$test_dir/bad.md" ;;
 esac
 if autopilot_sections "$test_dir/bad.md" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 [[ -s $test_dir/err ]]
done
echo 'PASS extensions: Webhook の明示を受け取り、指定漏れ・未知の種類・スケジュールの混在を拒否する'

# 不正な行が reduce の蓄積を消し、正常な共通定義を失ったまま成功しない。
autopilot_sections "$root/common/autopilots.md" >"$test_dir/common.json"
jq -e 'length==3' "$test_dir/common.json" >/dev/null
for variant in no-backticks trailing-space; do
 case $variant in
 no-backticks) sed 's/`webhook`/webhook/' "$test_dir/webhook.md" >"$test_dir/bad.md" ;;
 trailing-space) sed 's/`webhook`$/`webhook` /' "$test_dir/webhook.md" >"$test_dir/bad.md" ;;
 esac
 for position in end middle; do
  cat "$root/common/autopilots.md" "$test_dir/bad.md" >"$test_dir/combined.md"
  if [[ $position == middle ]]; then cat "$test_dir/webhook.md" >>"$test_dir/combined.md"; fi
  if autopilot_sections "$test_dir/combined.md" >"$test_dir/out" 2>"$test_dir/err"; then
   echo "不正なトリガー行を受け付けました: $variant ($position)" >&2
   exit 1
  fi
  grep -q 'オートパイロットの定義が不正' "$test_dir/err"
 done
done
echo 'PASS extensions: 正常な共通定義の後・途中にあるバッククォート欠落と行末空白はエラーで止まる'
