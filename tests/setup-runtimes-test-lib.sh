#!/usr/bin/env bash
# setup-runtimes-*-test.sh が読み込む共通の処理。選んだランタイムを $runtime_selections で受け、それぞれの入口を通す。単独では実行しない。
# $runtime_part で流す範囲を絞れる（既定は all）。both は setup.sh を 6 回通し、1 ファイルでは macOS の CI の上限（150 秒）を超えるため、
# main（再実行と配置した見張り）、issues（起票の失敗と復旧）、changes（更新を飛ばした場合）に分け、初回の準備から各ファイルで流す。
runtime_part=${runtime_part:-all}
# ホストの BASH_ENV・ZDOTDIR は、子のシェルの PATH の先頭へ本物の関所を足す。関所が入ったホストでは、
# テストの関所と本物の関所が互いを「次の gh」として呼び合い、setup.sh が止まらなくなるので、ここで外す。
unset BASH_ENV ZDOTDIR SQUAD_KIT_ALLOWED_REPOS
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/setup-runtimes.XXXXXX")
scenario_dir=$test_dir
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$scenario_dir/out" "$scenario_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/package" "$test_dir/tools"
cp "$root/setup.sh" "$root/VERSION" "$test_dir/package/"
cp -R "$root/lib" "$root/common" "$root/skeleton" "$test_dir/package/"
mkdir -p "$test_dir/package/tests/fixtures/cli"
cp "$root/tests/fixtures/cli/VERSION" "$test_dir/package/tests/fixtures/cli/"
python=$(command -v python3)
for tool in awk basename bash cat chmod cmp cp cut date dirname env find git grep head jq mkdir mktemp mv python3 rm sed seq shasum sleep sort stat tail tr unzip zip; do
 ln -s "$(command -v "$tool")" "$test_dir/tools/$tool"
done
# コピーした原本だけの配布物検査も、実際の入口で通す。
(
 cd "$test_dir/package"
 manifest_files=()
 while IFS= read -r file; do manifest_files+=("$file"); done < <(find . -type f | LC_ALL=C sort)
 shasum -a 256 "${manifest_files[@]}"
) >"$test_dir/package-manifest"
cp "$test_dir/package-manifest" "$test_dir/package/MANIFEST"

for selected in $runtime_selections; do
 scenario_dir="$test_dir/$selected"
 mkdir -p "$scenario_dir/bin"
 : >"$scenario_dir/out"; : >"$scenario_dir/err"
 case $selected in claude) runtime_words=claude; choice=2 ;; codex) runtime_words=codex; choice=3 ;; both) runtime_words='claude codex'; choice=1 ;; esac
 "$python" - "$scenario_dir" "$runtime_words" <<'PY'
import json
import sys
from pathlib import Path
scenario, runtimes = Path(sys.argv[1]), sys.argv[2].split()
db = dict(runtimes=runtimes, running=False, projects=[], resources=[], labels=[],
          skills=[], agents=[], envs={}, squads=[], roster=[], autopilots=[],
          triggers={}, issues=[])
(scenario / 'db.json').write_text(json.dumps(db))
PY
 printf '#!/bin/bash\nexec %q %q %q "$@"\n' "$python" "$root/tests/setup-runtime-cli.py" "$scenario_dir" >"$scenario_dir/bin/multica"
 printf '#!/bin/bash\nexec /bin/cat %q\n' "$scenario_dir/process-env" >"$scenario_dir/bin/ps"
 printf '#!/bin/bash\necho Darwin\n' >"$scenario_dir/bin/uname"
 {
  printf '#!/bin/bash\n'
  printf 'if [[ $1 == api && ${2:-} == repos/* ]]; then exec %q %q %q "$@"; fi\n' "$python" "$root/tests/webhook-gh.py" "$scenario_dir"
  printf 'exec /bin/bash %q "$@"\n' "$root/tests/guard-backend.sh"
 } >"$scenario_dir/bin/gh"
 for runtime in $runtime_words; do
  {
   printf '#!/bin/bash\nset -euo pipefail\nscenario_dir=%q\n' "$scenario_dir"
   printf 'fixture_root=%q\n' "$root"
   printf 'printf "%%s\\n" "%s $*" >>"$scenario_dir/runtime-calls"\n' "$runtime"
   if [[ $runtime == claude ]]; then
    cat <<'STUB'
case "$*" in
'auth status') [[ $CLAUDE_CONFIG_DIR == "$scenario_dir/host/claude" ]]; echo '{"loggedIn":true}' ;;
'-p /usage --output-format json')
 printf '{"is_error":false,"result":"Current session: %s%% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}\n' "${TEST_USAGE_PERCENT:-0}" >"$scenario_dir/claude.json"
 python3 "$fixture_root/tests/usage-fixture.py" claude-usage "$scenario_dir/claude.json" ;;
*) echo 'Unexpected Claude invocation' >&2; exit 90 ;;
esac
STUB
   else
    cat <<'STUB'
case "$*" in
'login status') [[ $CODEX_HOME == "$scenario_dir/host/codex" ]] ;;
'--version') jq -r '.versions.codex' "$fixture_root/tests/fixtures/cli/USAGE-CAPTURE.json" ;;
app-server)
 for _ in 1 2 3; do IFS= read -r request; done
 printf '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":%s,"resetsAt":0},"secondary":null}}}}\n' "${TEST_USAGE_PERCENT:-0}" >"$scenario_dir/codex.jsonl"
 python3 "$fixture_root/tests/usage-fixture.py" codex-rate-limits "$scenario_dir/codex.jsonl"
 cat >/dev/null ;;
*) echo 'Unexpected Codex invocation' >&2; exit 90 ;;
esac
STUB
   fi
  } >"$scenario_dir/bin/$runtime"
 done
 chmod +x "$scenario_dir/bin/"*
 export PATH="$scenario_dir/bin:$test_dir/tools"
 export TEMPLATE_STATE_ROOT="$scenario_dir/answers" TEMPLATE_AGENT_HOME="$scenario_dir/host" TEMPLATE_DAEMON_ID_FILE="$scenario_dir/daemon.id"
 unset MULTICA_SERVER_URL MULTICA_WORKSPACE_ID USAGE_CHECK_RUNTIMES
 printf '\n1\nRuntime test\ndemo\n1\nowner\n1\n%s\n0\n2\nyes\n' "$choice" >"$scenario_dir/input"
 /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
 grep -q '^✔ ' "$scenario_dir/out"
 "$python" - "$scenario_dir" <<'PY'
import json
import re
import sys
from pathlib import Path

scenario = Path(sys.argv[1])
db = json.loads((scenario / 'db.json').read_text())
answers = json.loads((scenario / 'answers/ws-a/demo.json').read_text())
runtimes = db['runtimes']
assert answers['schema'] == 1 and answers['runtimes'] == runtimes
assert answers['excluded_roles'] == []
roles = set('orchestrator planner designer qa claude-implementer claude-fixer codex-implementer codex-fixer claude-principal codex-principal code-reviewer ux-reviewer security-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger'.split())
for runtime in ('claude', 'codex'):
    if runtime not in runtimes:
        roles -= {runtime + '-implementer', runtime + '-fixer', runtime + '-principal'}
agents = {a['name'].removeprefix('demo-').removesuffix('-owner'): a for a in db['agents']}
assert set(agents) == roles
monitors = {'ci-monitor', 'usage-monitor', 'dependabot-merger'}
claude_roles = {'orchestrator', 'planner', 'designer', 'qa', 'claude-implementer', 'claude-fixer', 'claude-principal'}
medium = {'planner', 'qa', 'ux-reviewer', 'performance-reviewer'}
for role, agent in agents.items():
    provider = runtimes[0] if len(runtimes) == 1 else ('claude' if role in claude_roles else 'codex')
    model = 'gpt-6.1-sol'
    if provider == 'claude':
        model = 'claude-opus-5-5' if role in {'planner', 'designer'} else 'claude-sonnet-5-5'
    if role.endswith('-principal'):
        model = 'claude-fable-5-2' if provider == 'claude' else 'gpt-6-astra'
    assert agent['model'] == model and agent['runtime_id'] == 'runtime-' + provider, role
    assert agent['thinking_level'] == ('low' if role in {'ci-monitor', 'usage-monitor'} else 'medium' if role in medium else 'high'), role
    assert agent['max_concurrent_tasks'] == (1 if role in monitors else 6), role
    assert agent['permission_mode'] == 'public_to'
    assert agent['invocation_targets'] == [{'target_type': 'workspace'}]
    assert agent['instructions'] and '{{' not in agent['instructions'] and '<!-- IF' not in agent['instructions']
    env = db['envs'][agent['id']]
    assert env['SQUAD_KIT_ALLOWED_REPOS'] == str(scenario / 'host/allowed-repos.d/projects-1')
    assert env['GIT_CONFIG_VALUE_0'] == str(scenario / 'host/git-hooks')
    needs_claude = provider == 'claude' or (role == 'usage-monitor' and 'claude' in runtimes)
    assert ('CLAUDE_CONFIG_DIR' in env) == needs_claude, role
    assert ('CLAUDE_CODE_SHELL' in env) == (provider == 'claude'), role
    if provider == 'claude':
        assert env['CLAUDE_ENV_FILE'] == env['BASH_ENV'] == str(scenario / 'host/template/shell/projects-1/env.sh'), role
    else:
        assert 'CLAUDE_ENV_FILE' not in env, role
    assert ('SQUAD_KIT_GH_DEPENDABOT_MERGE' in env) == (role == 'dependabot-merger')
    assert bool(agent['skills']) == (role not in monitors), role
assert db['squads'][0]['leader_id'] == agents['orchestrator']['id']
assert {m['member_id'] for m in db['roster']} == {a['id'] for r, a in agents.items() if r not in monitors} | {'member-a'}
assert len(db['roster']) == len(roles) - 2
assert len(db['autopilots']) == 3
assert {a['assignee_id'] for a in db['autopilots']} == {agents[r]['id'] for r in ('security-reviewer', 'usage-monitor', 'dependabot-merger')}
for pilot in db['autopilots']:
    kinds = sorted(t['kind'] for t in db['triggers'][pilot['id']])
    assert kinds == (['schedule', 'webhook'] if pilot['assignee_id'] == agents['dependabot-merger']['id'] else ['schedule'])
assert len(db['github_hooks']) == 1
assert '✔ 配信 200' in (scenario / 'out').read_text()
display = (scenario / 'out').read_text()
assert display.count('\n  ✔ ') == 6 + len(roles) + 1 + len(db['autopilots']) + len(runtimes)
assert '\n  ! ' not in display and '記録なし' not in display
assert display.index('\n  ✔ ') < display.index('✔ トリガー') < display.index('\n  + ')
issues = {i['metadata']['squad_kit_task']: i for i in db['issues']}
assert set(issues) == {'dependabot-filter', 'repository-rules', 'project-instructions', 'squad-trial'}
for kind, issue in issues.items():
    assert issue['project_id'] == db['projects'][0]['id']
    assert issue['assignee_id'] == (db['squads'][0]['id'] if kind == 'repository-rules' else 'member-a')
    assert issue['status'] == ('backlog' if kind == 'repository-rules' else 'todo')
    assert issue['labels'] and '/manual.md#' in issue['description']
calls = [json.loads(line) for line in (scenario / 'calls.jsonl').read_text().splitlines()]
first_issue = next(n for n, call in enumerate(calls) if call[:2] == ['issue', 'create'])
last_registration = max(n for n, call in enumerate(calls) if call[:2] == ['agent', 'update'] or call[:2] == ['autopilot', 'trigger-add'])
assert first_issue > last_registration
assert (scenario / 'out').read_text().count('\n  + ') == 4
assert '✖' not in (scenario / 'out').read_text()
pilot = next(a for a in db['autopilots'] if a['assignee_id'] == agents['usage-monitor']['id'])
value = re.search(r'USAGE_CHECK_RUNTIMES に "([^"]+)"', pilot['description'])[1]
assert value == ' '.join(runtimes)
(scenario / 'usage-runtimes').write_text(value)
assert (scenario / 'host/codex/config.toml').exists() == ('codex' in runtimes)
assert (scenario / 'host/allowed-repos.d/projects-1').read_text() == 'example/project\n'
calls = (scenario / 'runtime-calls').read_text().splitlines()
assert calls == [r + (' auth status' if r == 'claude' else ' login status') for r in runtimes]
(scenario / 'first-db.json').write_text(json.dumps(db))
PY
 # 旧回答も含め、同じ設定の再実行で登録・割り当てを増やさない。
 if [[ $selected == both && $runtime_part != issues ]]; then
  jq 'del(.runtimes)' "$TEMPLATE_STATE_ROOT/ws-a/demo.json" >"$scenario_dir/old-answer"
  mv "$scenario_dir/old-answer" "$TEMPLATE_STATE_ROOT/ws-a/demo.json"
 fi
 : >"$scenario_dir/calls.jsonl"
 printf '\n1\n1\ndemo\n1\nowner\n1\n\n0\n\nyes\n' >"$scenario_dir/input"
 if [[ $runtime_part != changes ]]; then
 if [[ $runtime_part != issues ]]; then
 /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
 grep -q '^✔ [^+]*$' "$scenario_dir/out"
 "$python" - "$scenario_dir" <<'PY'
import json
import sys
from pathlib import Path
scenario = Path(sys.argv[1])
assert json.loads((scenario / 'first-db.json').read_text()) == json.loads((scenario / 'db.json').read_text())
assert (scenario / 'out').read_text().count('\n  · ') == 4
PY
 ! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or .[1]=="import" or .[1]=="trigger-add" or .[0:3]==["agent","env","set"] or .[0:3]==["agent","skills","set"] or .[0:3]==["squad","member","add"])' "$scenario_dir/calls.jsonl" >/dev/null
 jq -e --arg words "$runtime_words" '.runtimes==($words|split(" ")) and .excluded_roles==[]' "$TEMPLATE_STATE_ROOT/ws-a/demo.json" >/dev/null
 fi
 # 最後の起票に失敗しても登録済みの完了を表示し、入口の終了コードを 0 以外にする。
 if [[ $selected == both && $runtime_part != main ]]; then
  jq '.issues |= map(select(.metadata.squad_kit_task!="squad-trial"))' "$scenario_dir/db.json" >"$scenario_dir/new"
  mv "$scenario_dir/new" "$scenario_dir/db.json"
  printf '%s\n' 'スクワッドの動きを試す' >"$scenario_dir/fail-issue"
  if /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"; then exit 1; fi
  grep -q '^✔ ' "$scenario_dir/out"
  grep -qF '  ✖ スクワッドの動きを試す  タスクを作れませんでした。' "$scenario_dir/out"
  jq -e '.issues|length==3' "$scenario_dir/db.json" >/dev/null
  rm "$scenario_dir/fail-issue"
  /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
  [[ $(grep -c '^  + ' "$scenario_dir/out") == 1 && $(grep -c '^  · ' "$scenario_dir/out") == 3 ]]
  jq -e '.issues|length==4' "$scenario_dir/db.json" >/dev/null
 fi
 # 登録されたオートパイロットの選択を、実際に配置した見張りへ渡す。
 if [[ $runtime_part != issues ]]; then
 if [[ $selected == codex ]]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR="$scenario_dir/host/claude"; fi
 USAGE_CHECK_RUNTIMES=$(cat "$scenario_dir/usage-runtimes") USAGE_CHECK_ASSIGNEE=Owner USAGE_CHECK_PROJECT=projects-1 USAGE_CHECK_MEMBER=owner USAGE_CHECK_STATE_ROOT="$scenario_dir/usage-state" TEST_USAGE_PERCENT=80 CODEX_HOME="$scenario_dir/host/codex" "$scenario_dir/host/bin/squad-usage-check" >"$scenario_dir/out" 2>"$scenario_dir/err"
 "$python" - "$scenario_dir" <<'PY'
import json
import sys
from pathlib import Path
scenario = Path(sys.argv[1])
db = json.loads((scenario / 'db.json').read_text())
usage_issues = [i for i in db['issues'] if not i['metadata'].get('squad_kit_task')]
assert len(usage_issues) == len(db['runtimes'])
assert all(i['project_id'] == 'projects-1' and i['assignee'] == 'Owner' and i['label_id'] for i in usage_issues)
state = json.loads((scenario / 'usage-state/projects-1/owner.state').read_text())
assert {key.split(':')[0] for key in state} == set(db['runtimes'])
PY
 fi
 fi
 # 更新の権限がない共通スキルと、既存の検証スキルから消えた選択を入口から確認する。
 if [[ $selected == both && $runtime_part != main && $runtime_part != issues ]]; then
  jq '.members=[{user_id:"member-a",name:"Owner",role:"member"},{user_id:"creator",name:"Creator",role:"member"}] |
   .skills |= map(if .name=="squad-handoff" then .content="older content" | .created_by="creator"
    elif .name=="demo-verify" then .content += "\n## `example/removed`\n前からある検証手順\n" else . end)' "$scenario_dir/db.json" >"$scenario_dir/new"
  mv "$scenario_dir/new" "$scenario_dir/db.json"
  /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
  grep -qF '! squad-handoff  更新を飛ばしました。更新できる人' "$scenario_dir/err"
  jq -e 'any(.issues[]; .metadata.squad_kit_task=="handoff-skill-update" and .assignee_id=="creator" and .status=="todo") and
   any(.issues[]; .metadata.squad_kit_task=="repository-change" and .metadata.squad_kit_targets=="[\"removed:example/removed\"]") and
   any(.skills[]; .name=="demo-verify" and (.content|contains("前からある検証手順")))' "$scenario_dir/db.json" >/dev/null
  before_issues=$(jq '.issues|length' "$scenario_dir/db.json")
  /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
  [[ $(jq '.issues|length' "$scenario_dir/db.json") == "$before_issues" ]]
  echo 'PASS setup changes: 更新を飛ばしたスキルの作成者への起票と既存の検証スキルとの差を入口から確認し、再実行で重ねない'
 fi
 if [[ $runtime_part != changes && $runtime_part != issues ]]; then
  echo "PASS setup runtimes: $selected の入口・ホスト・登録・再実行・配置した見張りが通り、使わない側を求めない"
 fi
 if [[ $runtime_part == issues ]]; then
  echo 'PASS setup issues: 最後の起票の失敗でも登録済みの完了を表示し、再実行で残りの一件を復旧する'
 fi
done
