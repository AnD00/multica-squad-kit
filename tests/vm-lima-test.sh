#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/vm-lima.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
host_os=$(uname -s)
mkdir -p "$test_dir/bin" "$test_dir/guest-bin"
cat >"$test_dir/bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' Darwin
STUB
printf '#!%s\n' "$(command -v python3)" >"$test_dir/bin/limactl"
cat >>"$test_dir/bin/limactl" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

base = Path(__file__).resolve().parent.parent
state_file = base / 'state.json'
state = json.loads(state_file.read_text())
args = sys.argv[1:]
with (base / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
action = args[0]
if state.get('fail') == action:
    sys.exit('intentional Lima failure')
if action == '--version':
    print(state.get('version', 'limactl version 1.0.0'))
elif action == 'list':
    if args == ['list', '--quiet']:
        print('unrelated-vm')
        if 'instance' in state:
            print(state['instance']['name'])
    else:
        assert args == ['list', '--json', state['instance']['name']], args
        if state.get('bad_json'):
            print('invalid json')
        else:
            print(json.dumps(state['instance']))
elif action == 'create':
    assert args[1:3] == ['--tty=false', '--name'] and args[-1] == 'template://ubuntu-24.04', args
    assert 'instance' not in state
    config = dict(ssh=dict(forwardAgent=False, forwardX11=False, loadDotSSHPubKeys=False),
                  containerd=dict(system=False, user=False), user=dict(name='vm-user'))
    config.update(state.get('config_override', {}))
    state['instance'] = dict(name=args[3], status='Stopped', config=config)
elif action in ('start', 'stop', 'delete'):
    assert args[-1] == state['instance']['name'], args
    if action == 'delete':
        assert state['instance']['status'] == 'Stopped' or '--force' in args
        del state['instance']
    else:
        state['instance']['status'] = 'Running' if action == 'start' else 'Stopped'
elif action == 'copy':
    assert [Path(path).name for path in args[1:-1]] == ['provision.sh', 'start-daemon', 'verify.sh'], args
    assert all(Path(path).is_file() for path in args[1:-1])
    assert args[-1] == state['instance']['name'] + ':/tmp/multica-squad-vm.Test123/'
elif action == 'shell':
    assert args[1] == state['instance']['name'], args
    guest = args[2:]
    if guest == ['mktemp', '-d', '/tmp/multica-squad-vm.XXXXXX']:
        print('/tmp/multica-squad-vm.Test123')
    elif guest[:2] == ['sudo', 'bash']:
        assert guest == ['sudo', 'bash', '/tmp/multica-squad-vm.Test123/provision.sh', 'lima', 'vm-user'], args
        if state.get('provision_fail'):
            sys.exit('intentional provision failure')
    elif guest == ['bash', '/usr/local/lib/multica-squad-vm/verify.sh', 'lima']:
        if state.get('verify_fail'):
            sys.exit('intentional verify failure')
    elif guest[:2] == ['bash', '-lc']:
        assert len(guest) == 3
        # 関所の判断は、本物の bash と jq でゲスト側のスクリプトを流して確かめる。
        script = guest[2]
        if state.get('cli_missing'):
            script = 'command() { if [[ $* == "-v multica" ]]; then return 1; fi; builtin command "$@"; };\n' + script
        env = dict(os.environ, PATH=str(base / 'guest-bin') + ':' + os.environ['PATH'])
        sys.exit(subprocess.run(['/bin/bash', '-c', script], env=env).returncode)
    else:
        assert guest == ['rm', '-rf', '--', '/tmp/multica-squad-vm.Test123'], args
else:
    raise AssertionError(args)
state_file.write_text(json.dumps(state))
PY
printf '#!%s\n' "$(command -v python3)" >"$test_dir/guest-bin/multica"
cat >>"$test_dir/guest-bin/multica" <<'PY'
import json
import sys
from pathlib import Path
base = Path(__file__).resolve().parent.parent
state = json.loads((base / 'state.json').read_text())
assert sys.argv[1:] == ['daemon', 'status', '--output', 'json'], sys.argv
status = state.get('daemon', dict(status='running', active_task_count=0))
print(status if isinstance(status, str) else json.dumps(status))
sys.exit(state.get('status_code', 0))
PY
if [[ $host_os != Darwin ]]; then
 # Linux の CI だけ plutil もスタブにする。Mac は標準の plutil で全ケースを流す。
 printf '#!%s\n' "$(command -v python3)" >"$test_dir/bin/plutil"
 cat >>"$test_dir/bin/plutil" <<'PY'
import json
import sys
try:
    args = sys.argv[1:]
    data = json.load(sys.stdin)
    for key in args[1].split('.'):
        data = data[key]
    kind = 'any' if data is None else {bool: 'bool', int: 'integer', str: 'string', dict: 'dictionary', list: 'array'}[type(data)]
    if args[0] == '-type':
        assert args[2:] == ['-']
        print(kind)
    else:
        assert args[0] == '-extract' and args[2:4] == ['raw', '-expect'] and args[5:] == ['-o', '-', '-']
        if kind != args[4]:
            sys.exit(1)
        print(len(data) if kind == 'array' else str(data).lower() if kind == 'bool' else data)
except (ValueError, KeyError, TypeError):
    sys.exit(1)
PY
fi
chmod +x "$test_dir/bin/"* "$test_dir/guest-bin/multica"
export PATH="$test_dir/bin:$PATH"
reset() { printf '{}\n' >"$test_dir/state.json"; : >"$test_dir/calls.jsonl"; }
configure() {
 python3 - "$test_dir/state.json" "$1" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state.update(json.loads(sys.argv[2]))
path.write_text(json.dumps(state))
PY
}
existing() {
 configure '{"instance":{"name":"multica-squad","status":"Running","config":{"ssh":{"forwardAgent":false,"forwardX11":false,"loadDotSSHPubKeys":false},"containerd":{"system":false,"user":false},"user":{"name":"vm-user"}}}}'
}
run() { /bin/bash "$root/vm/lima.sh" "$@" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run "$@"; then echo 'Lima の操作が失敗すべきケースで成功しました' >&2; exit 1; fi; [[ -s $test_dir/err ]]; }
no_mutation() {
 python3 - "$test_dir/calls.jsonl" <<'PY'
import json
import sys
from pathlib import Path
assert all(json.loads(line)[0] in ('--version', 'list', 'shell') for line in Path(sys.argv[1]).read_text().splitlines())
PY
}
reset
run create
python3 - "$test_dir/calls.jsonl" <<'PY'
import json
import sys
from pathlib import Path
calls = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
create = next(call for call in calls if call[0] == 'create')
assert create[create.index('--set') + 1] == '.mounts = [] | .ssh.forwardAgent = false | .ssh.forwardX11 = false | .ssh.loadDotSSHPubKeys = false | .containerd.system = false | .containerd.user = false | .cpus = 4 | .memory = "8GiB" | .disk = "100GiB"'
start = calls.index(['start', '--tty=false', 'multica-squad'])
assert calls.index(['list', '--json', 'multica-squad']) < start
copy = next(i for i, call in enumerate(calls) if call[0] == 'copy')
provision = next(i for i, call in enumerate(calls) if call[0] == 'shell' and call[2:4] == ['sudo', 'bash'])
verify = calls.index(['shell', 'multica-squad', 'bash', '/usr/local/lib/multica-squad-vm/verify.sh', 'lima'])
assert start < copy < provision < verify
assert not any(call[0] == 'delete' for call in calls)
PY
grep -q 'limactl shell multica-squad' "$test_dir/out"
grep -q manual.md "$test_dir/out"
echo 'PASS Lima: 共有・鍵・containerd を切って指定の資源で作り、実効設定を確かめてから起動・配置・準備・検証をする'

reset
configure '{"version":"limactl version 2.0.0"}'
run create --name custom_vm --cpus 2 --memory 4 --disk 40
grep -q '\.cpus = 2.*4GiB.*40GiB' "$test_dir/calls.jsonl"
grep -q 'custom_vm' "$test_dir/out"
reset
existing
deny create
no_mutation
for version in 'limactl version 0.23.2' 'limactl version 1.0.0-rc.1' 'unknown'; do
 reset
 configure "{\"version\":\"$version\"}"
 deny create
 no_mutation
done
for args in 'create --memory 0' 'create --cpus nope' 'create --name ../escape' 'stop --disk 40' 'create --force' 'start --yes' 'create --name' 'unknown'; do
 reset
 read -r -a arguments <<<"$args"
 deny "${arguments[@]}"
 [[ ! -s $test_dir/calls.jsonl ]]
done
echo 'PASS Lima: 名前と資源の指定を渡し、同じ名前・版の不足・不正な引数では何も変えない'

for config in '{"mounts":[{"location":"~"}]}' '{"mounts":{}}' '{"ssh":{"forwardAgent":true,"forwardX11":false,"loadDotSSHPubKeys":false}}' '{"ssh":{"forwardAgent":false,"forwardX11":true,"loadDotSSHPubKeys":false}}' '{"ssh":{"forwardAgent":false,"forwardX11":false,"loadDotSSHPubKeys":true}}' '{"ssh":{}}' '{"containerd":{"system":false,"user":true}}'; do
 reset
 configure "{\"config_override\":$config}"
 deny create
 grep -q _config/default.yaml "$test_dir/err"
 python3 - "$test_dir" <<'PY'
import json
import sys
from pathlib import Path
base = Path(sys.argv[1])
calls = [json.loads(line) for line in (base / 'calls.jsonl').read_text().splitlines()]
assert ['delete', '--force', 'multica-squad'] in calls
assert not any(call[0] == 'start' for call in calls)
assert 'instance' not in json.loads((base / 'state.json').read_text())
PY
done
for state in '{"bad_json":true}' '{"fail":"start"}' '{"fail":"copy"}' '{"provision_fail":true}' '{"verify_fail":true}'; do
 reset
 configure "$state"
 deny create
 grep -q '\["delete", "--force", "multica-squad"\]' "$test_dir/calls.jsonl"
done
reset
configure '{"fail":"create"}'
deny create
! grep -q '^\["delete"' "$test_dir/calls.jsonl"
echo 'PASS Lima: 既定や上書きによる共有・鍵の持ち込みを起動前に検出し、作成後の失敗では作った VM を削除する'

reset
existing
run start
! grep -q '^\["start"' "$test_dir/calls.jsonl"
run verify
configure '{"instance":{"name":"multica-squad","status":"Stopped","config":{"ssh":{"forwardAgent":false,"forwardX11":false,"loadDotSSHPubKeys":false},"containerd":{"system":false,"user":false}}}}'
deny verify
run start
grep -q '^\["start", "--tty=false", "multica-squad"\]' "$test_dir/calls.jsonl"
configure '{"instance":{"name":"multica-squad","status":"Stopped","config":{"mounts":[{"location":"~"}]}}}'
: >"$test_dir/calls.jsonl"
deny start
no_mutation
echo 'PASS Lima: 起動済みは保ち、停止中だけ起動し、共有が戻った VM は起動しない。verify は起動中だけ中で流す'

for daemon in '{"status":"running","active_task_count":1}' '{"status":"running","active_task_count":0,"resource_wait_task_count":2}' '{"status":"running"}' '{"status":"running","active_task_count":"0"}' '{"status":"unknown"}' '"invalid json"'; do
 for action in stop delete; do
  reset
  existing
  configure "{\"daemon\":$daemon}"
  if [[ $action == delete ]]; then deny delete --yes; else deny stop; fi
  no_mutation
 done
done
for state in '{"daemon":{"status":"running","active_task_count":0,"running_task_count":0}}' '{"daemon":{"status":"stopped"},"status_code":1}' '{"daemon":{"status":"not_running"},"status_code":1}' '{"cli_missing":true}'; do
 reset
 existing
 configure "$state"
 run stop
 grep -q '^\["stop", "multica-squad"\]' "$test_dir/calls.jsonl"
done
reset
existing
configure '{"status_code":1}'
deny stop
no_mutation
reset
existing
configure '{"daemon":{"status":"running","active_task_count":3}}'
run stop --force
grep -q '^\["stop", "--force", "multica-squad"\]' "$test_dir/calls.jsonl"
! grep -q 'daemon status' "$test_dir/calls.jsonl"
echo 'PASS Lima: タスク数の最大が正か不明なら止めず、停止中・CLI なし・ゼロ件だけ通し、--force だけは明示的に進める'

reset
existing
deny delete </dev/null
no_mutation
printf 'n\n' | deny delete
no_mutation
printf 'y\n' | run delete
grep -q 'ログインと作業コピー' "$test_dir/err"
grep -q '^\["delete", "multica-squad"\]' "$test_dir/calls.jsonl"
python3 - "$test_dir/calls.jsonl" <<'PY'
import json
import sys
from pathlib import Path
calls = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert calls.index(['stop', 'multica-squad']) < calls.index(['delete', 'multica-squad'])
PY
reset
existing
configure '{"fail":"stop"}'
deny delete --yes
! grep -q '^\["delete"' "$test_dir/calls.jsonl"
reset
existing
run delete --yes --force
grep -q '^\["delete", "--force", "multica-squad"\]' "$test_dir/calls.jsonl"
echo 'PASS Lima: 削除は対象と失うものを示して確認し、通常は停止してから削除する。--yes のときだけ確認を省く'
