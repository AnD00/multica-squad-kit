#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/vm-guest.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home's space/.local/bin"

# 起動時の PATH には multica を置かず、ログインの PATH にだけ置く。
cat >"$test_dir/bin/bash" <<'STUB'
#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 2 && $1 == -lc && $2 == 'printf "%s\n" "$PATH"' ]] || exit 90
echo login-path >>"$base/calls"
[[ ! -f $base/login-fail ]] || exit 71
cat "$base/login-path"
STUB
cat >"$test_dir/home's space/.local/bin/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")/../../.." && pwd)
printf '%s\n' "$*" >>"$base/calls"
case "$*" in
'daemon status --output json')
 cat "$base/status"
 exit "$(cat "$base/status-code")" ;;
'config show')
 [[ ! -f $base/config-fail ]] || exit 72
 cat "$base/config" ;;
'daemon start --foreground')
 env >"$base/started-env"
 printf '%s\n' "$$" >"$base/started-pid" ;;
*) echo "unexpected CLI call: $*" >&2; exit 91 ;;
esac
STUB
chmod +x "$test_dir/bin/bash" "$test_dir/home's space/.local/bin/multica"
printf '%s\n' "$test_dir/home's space/.local/bin:$PATH" >"$test_dir/login-path"
printf '{"status":"stopped","pid":null}\n' >"$test_dir/status"
printf '1\n' >"$test_dir/status-code"
printf 'server_url: https://example.test/\n' >"$test_dir/config"
: >"$test_dir/calls"
run() {
 HOME="$test_dir/home's space" USER=vm-user PATH="$test_dir/bin:/usr/bin:/bin" \
 VSCODE_TEST_MARKER=must-not-be-inherited MULTICA_WORKSPACE_ID=must-not-be-inherited \
 CODEX_HOME=/wrong/codex SHELL=/wrong/shell DOCKER_HOST=must-not-be-inherited \
 /bin/bash -c 'printf "%s\n" "$$" >"$2/launcher-pid"; exec /bin/bash "$1/vm/guest/start-daemon"' -- "$root" "$test_dir" >"$test_dir/out" 2>"$test_dir/err"
}
deny() {
 : >"$test_dir/calls"
 if run; then echo '起動が失敗すべきケースで成功しました' >&2; exit 1; fi
 [[ -s $test_dir/err ]]
 ! grep -q '^daemon start' "$test_dir/calls"
}
unset MULTICA_SERVER_URL
run
[[ ! -s $test_dir/calls && ! -e $test_dir/started-env ]]
echo 'PASS vm guest: セットアップ前は CLI を呼ばずに成功する'

mkdir -p "$test_dir/home's space/.multica-agent/bin"
touch "$test_dir/home's space/.multica-agent/bin/gh"
printf '{"status":"running","pid":4242}\n' >"$test_dir/status"
printf '0\n' >"$test_dir/status-code"
run
grep -qx 'daemon status --output json' "$test_dir/calls"
! grep -Eq '^config show|^daemon start' "$test_dir/calls"
[[ ! -e $test_dir/started-env ]]
echo 'PASS vm guest: 起動済みのデーモンへ重ねて起動しない'

check_started() {
 grep -qx 'daemon start --foreground' "$test_dir/calls"
 cmp "$test_dir/launcher-pid" "$test_dir/started-pid"
 grep -qxF "HOME=$test_dir/home's space" "$test_dir/started-env"
 grep -qxF 'USER=vm-user' "$test_dir/started-env"
 grep -qxF 'SHELL=/bin/zsh' "$test_dir/started-env"
 grep -qxF "CODEX_HOME=$test_dir/home's space/.multica-agent/codex" "$test_dir/started-env"
 grep -qxF "PATH=$test_dir/home's space/.multica-agent/bin:$(cat "$test_dir/login-path")" "$test_dir/started-env"
 grep -qxF "MULTICA_SERVER_URL=$1" "$test_dir/started-env"
 ! grep -Eq '^(VSCODE_TEST_MARKER|MULTICA_WORKSPACE_ID|DOCKER_HOST|BASH_ENV)=' "$test_dir/started-env"
}
for stopped in stopped not_running; do
 for code in 0 1; do
  printf '{"status":"%s","pid":null}\n' "$stopped" >"$test_dir/status"
  printf '%s\n' "$code" >"$test_dir/status-code"
  : >"$test_dir/calls"
  run
  check_started https://example.test
 done
done
echo 'PASS vm guest: 停止中はログインの PATH を読み、関所を先頭にした専用環境で前面へ exec する'

printf 'server_url: https://configured.test/\n' >"$test_dir/config"
MULTICA_SERVER_URL=https://override.test/base/ run
check_started https://override.test/base
echo 'PASS vm guest: 環境変数の URL を CLI の設定より優先し、末尾のスラッシュを外す'

for config in 'server_url: (not set)' 'other: value' 'server_url: http://example.test' 'server_url: https://user@example.test' 'server_url: https://example.test/?query'; do
 printf '%s\n' "$config" >"$test_dir/config"
 deny
done
printf 'server_url: https://example.test/\n' >"$test_dir/config"
MULTICA_SERVER_URL=http://invalid.test deny
touch "$test_dir/config-fail"
deny
rm "$test_dir/config-fail"
echo 'PASS vm guest: URL の未設定・不正と設定の取得失敗は理由を出して失敗する'

# 記録した接続先は、環境変数より後、CLI の設定より先に読む。
record_file="$test_dir/home's space/.config/multica-squad-vm/server-url"
mkdir -p "$(dirname "$record_file")"
printf 'https://recorded.test:8443/base\n' >"$record_file"
printf 'server_url: https://configured.test/\n' >"$test_dir/config"
: >"$test_dir/calls"
run
check_started https://recorded.test:8443/base
! grep -qx 'config show' "$test_dir/calls"
printf 'server_url: (not set)\n' >"$test_dir/config"
: >"$test_dir/calls"
run
check_started https://recorded.test:8443/base
: >"$test_dir/calls"
MULTICA_SERVER_URL=https://override.test run
check_started https://override.test
! grep -qx 'config show' "$test_dir/calls"
rm "$record_file"
printf 'server_url: https://configured.test/\n' >"$test_dir/config"
: >"$test_dir/calls"
run
check_started https://configured.test
grep -qx 'config show' "$test_dir/calls"
echo 'PASS vm guest: 接続先を環境変数、記録、CLI の設定の順に読み、記録は CLI の設定がなくても使う'

# 最初にある値が正しくなければ、次の読み先へ進まず、別のサーバーへつながない。
for recorded in 'http://recorded.test' 'https://user@recorded.test' '' $'https://recorded.test\nhttps://other.test'; do
 printf '%s\n' "$recorded" >"$record_file"
 deny
 ! grep -qx 'config show' "$test_dir/calls"
done
ln -sfn "$test_dir/missing-record" "$record_file"
deny
! grep -qx 'config show' "$test_dir/calls"
rm "$record_file"
echo 'PASS vm guest: 記録した接続先が正しくなければ、CLI の設定へ進まず理由を出して失敗する'

for status in '{}' 'not json' '{"status":"unknown"}' '{"status":"running"}'; do
 printf '%s\n' "$status" >"$test_dir/status"
 deny
done
printf '{"status":"unknown"}\n' >"$test_dir/status"
printf '0\n' >"$test_dir/status-code"
deny
touch "$test_dir/login-fail"
deny
rm "$test_dir/login-fail"
echo 'PASS vm guest: 状態の取得失敗・不正な応答とログインの PATH の取得失敗は起動しない'

python3 - "$root" <<'PY'
import re
import shlex
import sys
from pathlib import Path

root = Path(sys.argv[1])

def env_names(source):
    lines = [line for line in source.splitlines() if re.match(r'\s*(exec )?env -i ', line)]
    assert len(lines) == 1, lines
    words = shlex.split(lines[0])
    assignments = words[words.index('-i') + 1:words.index('multica')]
    assert all(re.match(r'^[A-Z_]+=', word) for word in assignments), assignments
    return sorted(word.split('=', 1)[0] for word in assignments)

host = (root / 'lib/host.sh').read_text().split('prepare_daemon() {', 1)[1]
guest = (root / 'vm/guest/start-daemon').read_text()
assert env_names(host) == env_names(guest), (env_names(host), env_names(guest))
PY
echo 'PASS vm guest: prepare_daemon と start-daemon の env -i の変数名が一致する'

for file in vm/lima.sh vm/guest/start-daemon vm/guest/record-server vm/guest/provision.sh vm/guest/verify.sh; do
 [[ $(git -C "$root" check-attr eol -- "$file") == "$file: eol: lf" ]]
done
echo 'PASS vm guest: ホストとゲストのシェルスクリプトを LF に固定する'

# Mac 標準の bash 3.2 は、UTF-8 では、変数名の直後の日本語を名前の一部として読み、unbound variable で止まる。
# CI の bash では起きないので、書き方を見て止める。
python3 - "$root" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
for name in ('vm/lima.sh', 'vm/guest/start-daemon', 'vm/guest/record-server', 'vm/guest/provision.sh', 'vm/guest/verify.sh'):
    for number, line in enumerate((root / name).read_text(encoding='utf-8').splitlines(), 1):
        assert not re.search(r'\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]', line), f'{name}:{number}: 変数名の直後が日本語です。${{名前}} にしてください。'
PY
echo 'PASS vm guest: 変数名の直後に日本語を置かない（bash 3.2 の UTF-8 対策）'

# 以降の特権コマンドと VM の状態は、専用の根とスタブだけで扱う。
mkdir -p "$test_dir/guest-bin" "$test_dir/guest-root"
printf '#!%s\n' "$(command -v python3)" >"$test_dir/guest-stub"
cat >>"$test_dir/guest-stub" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

base = Path(__file__).resolve().parent
root = base / 'guest-root'
home = root / 'home/vm-user'
state_file = base / 'guest-state.json'
state = json.loads(state_file.read_text())
name, args = Path(sys.argv[0]).name, sys.argv[1:]
call = ' '.join([name] + args)
with (base / 'guest-calls.jsonl').open('a') as log:
    log.write(json.dumps(dict(command=name, args=args, env=dict(os.environ))) + '\n')
if state.get('fail') == call:
    sys.exit('intentional guest command failure')

if name == 'id':
    if args == ['-u']:
        print(state.get('uid', 0))
    elif args == ['-un']:
        print('vm-user')
    elif args == ['-nG', 'vm-user']:
        print(state.get('groups', 'vm-user'))
    else:
        raise AssertionError(args)
elif name == 'getent':
    assert args == ['passwd', 'vm-user'], args
    if not state.get('user_exists'):
        sys.exit(2)
    print(f'vm-user:x:1000:1000::{home}:/bin/bash')
elif name == 'useradd':
    assert args == ['--create-home', '--shell', '/bin/bash', 'vm-user'], args
    state['user_exists'] = True
    home.mkdir(parents=True, exist_ok=True)
    for kind in ('subuid', 'subgid'):
        with (root / 'etc' / kind).open('a') as target:
            target.write('vm-user:100000:65536\n')
elif name == 'usermod':
    option, span, user = args
    assert user == 'vm-user' and option in ('--add-subuids', '--add-subgids'), args
    first, last = map(int, span.split('-'))
    with (root / 'etc' / ('subuid' if option == '--add-subuids' else 'subgid')).open('a') as target:
        target.write(f'{user}:{first}:{last-first+1}\n')
elif name == 'apt-get':
    assert args == ['update'] or args[:2] == ['install', '-y'], args
elif name == 'curl':
    assert args[:2] == ['-fsSL', 'https://download.docker.com/linux/ubuntu/gpg'] or args[:2] == ['-fsSL', 'https://cli.github.com/packages/githubcli-archive-keyring.gpg'], args
    Path(args[args.index('-o') + 1]).write_text('test repository key\n')
elif name == 'dpkg':
    assert args == ['--print-architecture'], args
    print('arm64')
elif name == 'loginctl':
    if args == ['enable-linger', 'vm-user']:
        pass
    else:
        assert args == ['show-user', 'vm-user', '-p', 'Linger', '--value'], args
        print(state.get('linger', 'yes'))
elif name == 'systemctl':
    if args == ['is-enabled', '--quiet', 'multica-squad-daemon.service']:
        sys.exit(0 if state.get('enabled', True) else 1)
    if args == ['is-enabled', '--quiet', 'multica-squad-record-server.timer']:
        sys.exit(0 if state.get('timer_enabled', True) else 1)
    assert args in (
        ['disable', '--now', 'docker.service', 'docker.socket'],
        ['start', 'user@1000.service'], ['--user', 'enable', '--now', 'docker.service'],
        ['daemon-reload'], ['enable', 'multica-squad-daemon.service'], ['enable', '--now', 'multica-squad-record-server.timer'],
    ), args
elif name == 'runuser':
    assert args[:3] == ['-u', 'vm-user', '--'], args
    sys.exit(subprocess.run(args[3:]).returncode)
elif name == 'dockerd-rootless-setuptool.sh':
    assert args == ['install'], args
    assert os.environ['USER'] == 'vm-user' and os.environ['HOME'] == str(home)
    assert os.environ['XDG_RUNTIME_DIR'] == str(root / 'run/user/1000')
    assert os.environ['DBUS_SESSION_BUS_ADDRESS'] == f'unix:path={root}/run/user/1000/bus'
    assert 'DOCKER_HOST' not in os.environ and 'MULTICA_WORKSPACE_ID' not in os.environ
elif name == 'docker':
    if args == ['context', 'use', 'rootless']:
        assert os.environ['USER'] == 'vm-user' and 'DOCKER_HOST' not in os.environ
    elif args == ['info', '--format', '{{json .SecurityOptions}}']:
        print(json.dumps(state.get('security', ['name=seccomp,profile=builtin', 'name=rootless'])))
    else:
        assert args == ['run', '--rm', 'hello-world'], args
        if state.get('post_mount_directory'):
            (root / 'mnt/c').mkdir(parents=True, exist_ok=True)
        if state.get('post_mount'):
            with open(root / 'proc/self/mountinfo', 'a') as mountinfo:
                mountinfo.write('11 1 0:2 / /mnt/c rw - 9p C:\\ rw\n')
elif name == 'sudo':
    assert args == ['-n', 'true'], args
    sys.exit(0 if state.get('sudo') else 1)
elif name == 'cmd.exe':
    assert args == ['/c', 'exit', '0'], args
    sys.exit(0 if state.get('windows_exec') else 1)
elif name == 'bash':
    assert args == ['-lc', 'printf "%s\\n" "$PATH"'], args
    print(os.environ['PATH'])
elif name == 'multica':
    assert args == ['daemon', 'status', '--output', 'json'], args
    print(json.dumps(state.get('daemon', dict(status='running', pid=4242, server_url=state.get('server_url', 'https://example.test/')))))
elif name == 'ps':
    assert args == ['eww', '-o', 'command=', '-p', '4242'], args
    print(state.get('daemon_env', f'multica CODEX_HOME={home}/.multica-agent/codex PATH={home}/.multica-agent/bin:/usr/bin'))
else:
    raise AssertionError(call)
state_file.write_text(json.dumps(state))
PY
chmod +x "$test_dir/guest-stub"
for tool in id getent useradd usermod apt-get curl dpkg loginctl systemctl runuser dockerd-rootless-setuptool.sh docker sudo cmd.exe bash multica ps; do
 ln -s ../guest-stub "$test_dir/guest-bin/$tool"
done
guest_root=$test_dir/guest-root
guest_home=$guest_root/home/vm-user
reset_guest() {
 rm -rf -- "$guest_root"
 mkdir -p "$guest_root/etc" "$guest_root/home/vm-user" "$guest_root/proc/self"
 printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$guest_root/etc/os-release"
 printf 'other:100000:65536\n' >"$guest_root/etc/subuid"
 cp "$guest_root/etc/subuid" "$guest_root/etc/subgid"
 printf '10 1 0:1 / / rw - ext4 /dev/root rw\n' >"$guest_root/proc/self/mountinfo"
 printf '{}\n' >"$test_dir/guest-state.json"
 : >"$test_dir/guest-calls.jsonl"
}
guest_state() {
 python3 - "$test_dir/guest-state.json" "$1" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state.update(json.loads(sys.argv[2]))
path.write_text(json.dumps(state))
PY
}
guest_state_replace() { printf '%s\n' "$1" >"$test_dir/guest-state.json"; }
# セットアップ後の状態: gh と、provision.sh が置く record-server。
finish_setup() {
 mkdir -p "$guest_home/.multica-agent/bin" "$guest_root/usr/local/lib/multica-squad-vm"
 touch "$guest_home/.multica-agent/bin/gh"
 cp "${record_server:-$root/vm/guest/record-server}" "$guest_root/usr/local/lib/multica-squad-vm/record-server"
 chmod +x "$guest_root/usr/local/lib/multica-squad-vm/record-server"
}
provision() {
 SQUAD_VM_ROOT="$guest_root" PATH="$test_dir/guest-bin:$PATH" \
 MULTICA_WORKSPACE_ID=must-not-be-inherited DOCKER_HOST=must-not-be-inherited \
 /bin/bash "${provision_script:-$root/vm/guest/provision.sh}" "$@" >"$test_dir/out" 2>"$test_dir/err"
}
verify() {
 HOME="$guest_home" SQUAD_VM_ROOT="$guest_root" PATH="$test_dir/guest-bin:$PATH" SSH_AUTH_SOCK="${test_agent_socket:-}" \
 /bin/bash "$root/vm/guest/verify.sh" "$@" >"$test_dir/out" 2>"$test_dir/err"
}
reset_guest
provision wsl vm-user
python3 - "$test_dir" "$root" <<'PY'
import json
import sys
from pathlib import Path
base, source = map(Path, sys.argv[1:])
root = base / 'guest-root'
conf = (root / 'etc/wsl.conf').read_text()
assert conf == '''[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=vm-user
''', conf
unit = (root / 'etc/systemd/system/multica-squad-daemon.service').read_text()
design = (source / 'docs/vm.md').read_text().split('```ini\n')[2].split('```')[0]
assert unit == design.replace('User=USER', 'User=vm-user'), unit
for name in ('provision.sh', 'start-daemon', 'record-server', 'verify.sh'):
    installed = root / 'usr/local/lib/multica-squad-vm' / name
    assert installed.read_bytes() == (source / 'vm/guest' / name).read_bytes()
    assert installed.stat().st_mode & 0o777 == 0o755
calls = [json.loads(line) for line in (base / 'guest-calls.jsonl').read_text().splitlines()]
commands = [' '.join([item['command']] + item['args']) for item in calls]
packages = [item['args'][2:] for item in calls if item['command'] == 'apt-get' and item['args'][0] == 'install']
assert {'bash', 'zsh', 'git', 'jq', 'zip', 'unzip', 'python3', 'tzdata', 'libdigest-sha-perl', 'coreutils', 'findutils', 'procps', 'ca-certificates', 'curl', 'uidmap', 'dbus-user-session', 'apparmor'} <= set(packages[0])
# gh は Ubuntu の標準の apt からは入れず、公式のリポジトリの鍵と sources を置いたあとの 2 回目の導入で入れる。
assert 'gh' not in packages[0] and packages[1] == ['gh'], packages
assert {'docker-ce', 'docker-ce-rootless-extras', 'docker-buildx-plugin', 'docker-compose-plugin'} <= set(packages[2])
gh_key = 'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o ' + str(root) + '/etc/apt/keyrings/githubcli-archive-keyring.gpg'
install_gh = [index for index, command in enumerate(commands) if command == 'apt-get install -y gh']
assert len(install_gh) == 1 and commands.index('apt-get install -y gh') > commands.index(gh_key) + 1
assert commands[commands.index(gh_key) + 1] == 'apt-get update', commands
assert commands.index('systemctl disable --now docker.service docker.socket') < commands.index('dockerd-rootless-setuptool.sh install')
assert commands.index('loginctl enable-linger vm-user') < commands.index('systemctl start user@1000.service') < commands.index('dockerd-rootless-setuptool.sh install')
assert 'systemctl --user enable --now docker.service' in commands
assert 'docker context use rootless' in commands
assert 'systemctl enable multica-squad-daemon.service' in commands
assert commands.index('systemctl daemon-reload') < commands.index('systemctl enable --now multica-squad-record-server.timer')
record_service = (root / 'etc/systemd/system/multica-squad-record-server.service').read_text()
assert record_service == '''[Unit]
Description=Record the Multica daemon server URL for multica-squad-kit

[Service]
Type=oneshot
User=vm-user
ExecStart=/usr/local/lib/multica-squad-vm/record-server
''', record_service
record_timer = (root / 'etc/systemd/system/multica-squad-record-server.timer').read_text()
assert record_timer == '''[Unit]
Description=Record the Multica daemon server URL every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
''', record_timer
assert not any(item['command'] in ('multica', 'sudo') for item in calls)
sources = (root / 'etc/apt/sources.list.d/docker.sources').read_text()
assert 'URIs: https://download.docker.com/linux/ubuntu\n' in sources
assert 'Architectures: arm64\n' in sources and 'Suites: noble\n' in sources
assert (root / 'etc/apt/keyrings/githubcli-archive-keyring.gpg').read_text() == 'test repository key\n'
assert (root / 'etc/apt/keyrings/githubcli-archive-keyring.gpg').stat().st_mode & 0o777 == 0o644
gh_sources = (root / 'etc/apt/sources.list.d/github-cli.sources').read_text()
assert gh_sources == '''Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
''', gh_sources
PY
cp "$guest_root/etc/wsl.conf" "$test_dir/first-wsl.conf"
cp "$guest_root/etc/apt/sources.list.d/github-cli.sources" "$test_dir/first-gh-sources"
cp "$guest_root/etc/systemd/system/multica-squad-daemon.service" "$test_dir/first-unit"
cp "$guest_root/etc/systemd/system/multica-squad-record-server.service" "$test_dir/first-record-service"
cp "$guest_root/etc/systemd/system/multica-squad-record-server.timer" "$test_dir/first-record-timer"
provision_script=$guest_root/usr/local/lib/multica-squad-vm/provision.sh provision wsl vm-user
cmp "$test_dir/first-wsl.conf" "$guest_root/etc/wsl.conf"
cmp "$test_dir/first-gh-sources" "$guest_root/etc/apt/sources.list.d/github-cli.sources"
cmp "$test_dir/first-unit" "$guest_root/etc/systemd/system/multica-squad-daemon.service"
cmp "$test_dir/first-record-service" "$guest_root/etc/systemd/system/multica-squad-record-server.service"
cmp "$test_dir/first-record-timer" "$guest_root/etc/systemd/system/multica-squad-record-server.timer"
[[ $(grep -c '^vm-user:' "$guest_root/etc/subuid") == 1 ]]
echo 'PASS vm guest: WSL の使う人・道具・gh の公式の apt のリポジトリ・rootless Docker・linger・unit と記録の timer・閉じ込め設定を作り、配置済みから再実行しても同じになる'

reset_guest
guest_state '{"user_exists":true,"groups":"vm-user sudo"}'
printf 'preserve Lima settings\n' >"$guest_root/etc/wsl.conf"
provision lima vm-user
grep -qx 'preserve Lima settings' "$guest_root/etc/wsl.conf"
grep -qx 'vm-user:165536:65536' "$guest_root/etc/subuid"
grep -qx 'vm-user:165536:65536' "$guest_root/etc/subgid"
! grep -q '"command": "useradd"' "$test_dir/guest-calls.jsonl"
provision lima vm-user
[[ $(grep -c '^vm-user:' "$guest_root/etc/subuid") == 1 ]]
echo 'PASS vm guest: Lima の既存の使う人と sudo を保ち、重ならない従属 ID を一度だけ割り当てる'

for state in '{"user_exists":true,"groups":"vm-user sudo"}' '{"user_exists":true,"groups":"vm-user docker"}' '{"uid":1000}'; do
 reset_guest
 guest_state "$state"
 if provision wsl vm-user; then exit 1; fi
 [[ -s $test_dir/err ]]
 ! grep -q '"command": "dockerd-rootless-setuptool.sh"' "$test_dir/guest-calls.jsonl"
done
for failure in 'apt-get update' 'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o ROOT/etc/apt/keyrings/githubcli-archive-keyring.gpg' 'apt-get install -y gh' 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o ROOT/etc/apt/keyrings/docker.asc' 'systemctl start user@1000.service' 'dockerd-rootless-setuptool.sh install' 'docker context use rootless'; do
 reset_guest
 failure=${failure/ROOT/$guest_root}
 guest_state "{\"fail\":\"$failure\"}"
 if provision wsl vm-user; then exit 1; fi
 [[ -s $test_dir/err ]]
 [[ ! -e $guest_root/etc/systemd/system/multica-squad-daemon.service ]]
done
echo 'PASS vm guest: 権限の誤りと導入コマンドの失敗を成功扱いせず、デーモンの unit を有効にしない'

reset_guest
guest_state '{"uid":1000}'
verify lima
grep -q '^SKIP verify: セットアップ前' "$test_dir/out"
verify wsl
grep -q '"command": "docker", "args": \["run", "--rm", "hello-world"\]' "$test_dir/guest-calls.jsonl"
grep -q '^PASS verify: 接続先を記録する timer が有効' "$test_dir/out"
! grep -q '記録した接続先' "$test_dir/out"
[[ ! -e $guest_home/.config/multica-squad-vm/server-url ]]
finish_setup
verify wsl
grep -q '^PASS verify: 起動中のデーモンの環境' "$test_dir/out"
grep -q '^PASS verify: 記録した接続先が起動中のデーモンと同じ' "$test_dir/out"
[[ $(cat "$guest_home/.config/multica-squad-vm/server-url") == https://example.test ]]
echo 'PASS vm guest: 両 VM の閉じ込め・Docker・自動起動を確認し、セットアップ後はデーモンの環境と記録した接続先も確認する'

verify_denied() {
 if verify "$1"; then echo 'verify が失敗すべきケースで成功しました' >&2; exit 1; fi
 grep -q 'FAIL verify:' "$test_dir/err"
}
for state in '{"sudo":true}' '{"windows_exec":true}' '{"security":["name=seccomp"]}' '{"security":"invalid"}' '{"post_mount":true}' '{"enabled":false}' '{"timer_enabled":false}' '{"linger":"no"}' '{"fail":"docker run --rm hello-world"}' '{"fail":"docker info --format {{json .SecurityOptions}}"}'; do
 reset_guest
 guest_state '{"uid":1000}'
 guest_state "$state"
 verify_denied wsl
done
for path in mnt/c/Users mnt/wsl/docker-desktop mnt/wsl/docker-desktop-bind-mounts proc/sys/fs/binfmt_misc/WSLInterop; do
 reset_guest
 guest_state '{"uid":1000}'
 mkdir -p "$guest_root/$path"
 verify_denied wsl
done
# 初回起動が作った空のマウント先は、共有ではない。Docker の使用後にも残る。
reset_guest
guest_state '{"uid":1000}'
mkdir -p "$guest_root/mnt/c"
verify wsl
guest_state '{"post_mount_directory":true}'
verify wsl
reset_guest
guest_state '{"uid":1000}'
mkdir -p "$guest_root/mnt"
ln -s /elsewhere "$guest_root/mnt/c"
verify_denied wsl
reset_guest
guest_state '{"uid":1000}'
mkdir "$guest_root/Users"
verify_denied lima
reset_guest
guest_state '{"uid":1000}'
test_agent_socket=/forwarded/agent.sock verify_denied lima
for mount in '10 1 0:1 / /Users rw - virtiofs mount rw' '10 1 0:1 / /host rw - 9p host rw' '10 1 0:1 / /host rw - fuse.sshfs host rw'; do
 printf '%s\n' "$mount" >"$guest_root/proc/self/mountinfo"
 verify_denied lima
done
for mount in '10 1 0:1 / /mnt/c rw - ext4 /dev/sdb rw' '10 1 0:1 / /mnt/d rw - drvfs D: rw' '10 1 0:1 / /mnt/d rw - 9p D: rw' '10 1 0:1 / /mnt/d rw - 9p none rw,aname=drvfs;path=D:'; do
 printf '%s\n' "$mount" >"$guest_root/proc/self/mountinfo"
 verify_denied wsl
done
rm "$guest_root/proc/self/mountinfo"
verify_denied wsl
echo 'PASS vm guest: 共有・鍵・Windows の実行・sudo・Desktop 統合・Docker・自動起動の各不一致と Docker 使用後の共有を検出する'

for state in '{"daemon":{"status":"stopped","pid":null}}' '{"daemon_env":"multica CODEX_HOME=/wrong PATH=/usr/bin"}' '{"fail":"multica daemon status --output json"}' '{"fail":"ps eww -o command= -p 4242"}'; do
 reset_guest
 guest_state '{"uid":1000}'
 guest_state "$state"
 finish_setup
 verify_denied wsl
 [[ ! -e $guest_home/.config/multica-squad-vm/server-url ]]
done
echo 'PASS vm guest: セットアップ後の停止・違うデーモン環境・状態や環境の読み取り失敗を検出する'

# 起動直後で記録がまだなくても、古い記録があっても、verify が今のデーモンの接続先にそろえる。
reset_guest
guest_state '{"uid":1000,"server_url":"https://after.test/base/"}'
finish_setup
mkdir -p "$guest_home/.config/multica-squad-vm"
printf 'https://stale.test\n' >"$guest_home/.config/multica-squad-vm/server-url"
verify wsl
[[ $(cat "$guest_home/.config/multica-squad-vm/server-url") == https://after.test/base ]]
# 記録を作れない、または記録が違うときは通さない。
for state in '{"server_url":"http://bad.test"}' '{"server_url":5}' '{"daemon":{"status":"running","pid":4242}}'; do
 reset_guest
 guest_state '{"uid":1000}'
 guest_state "$state"
 finish_setup
 verify_denied wsl
 [[ ! -e $guest_home/.config/multica-squad-vm/server-url ]]
done
for fake in 'exit 0' 'mkdir -p "$HOME/.config/multica-squad-vm"; echo https://other.test >"$HOME/.config/multica-squad-vm/server-url"' 'exit 1'; do
 reset_guest
 guest_state '{"uid":1000}'
 printf '#!/bin/bash\n%s\n' "$fake" >"$test_dir/fake-record-server"
 record_server=$test_dir/fake-record-server finish_setup
 verify_denied wsl
 grep -q 'FAIL verify: 記録した接続先' "$test_dir/err"
done
echo 'PASS vm guest: verify は記録を今のデーモンの接続先にそろえ、記録できないときと記録が違うときは通さない'

record() {
 HOME="$guest_home" PATH="${record_path:-}$test_dir/guest-bin:$PATH" /bin/bash "$root/vm/guest/record-server" >"$test_dir/out" 2>"$test_dir/err"
}
record_dir=$guest_home/.config/multica-squad-vm
record_calls() { grep -c '"command": "multica"' "$test_dir/guest-calls.jsonl" || true; }
# 何もしないケース: セットアップ前、デーモンが止まっている、手で起動した別の環境のデーモン。
reset_guest
guest_state '{"uid":1000}'
record
[[ $(record_calls) == 0 && ! -e $record_dir ]]
for state in '{"daemon":{"status":"stopped","pid":null}}' '{"daemon":{"status":"not_running","pid":null}}' '{"daemon_env":"multica CODEX_HOME=/wrong PATH=/usr/bin"}' '{"daemon_env":"multica CODEX_HOME=/home/other/.multica-agent/codex PATH=/usr/bin"}'; do
 reset_guest
 guest_state '{"uid":1000}'
 guest_state "$state"
 finish_setup
 record
 [[ ! -e $record_dir/server-url ]]
done
echo 'PASS vm guest: record-server はセットアップ前・停止中・環境の違うデーモンのときに記録を作らない'

# 記録する・変わらなければ書き直さない・変わったら置き換える。
reset_guest
guest_state '{"uid":1000}'
finish_setup
record
[[ $(cat "$record_dir/server-url") == https://example.test ]]
[[ $(ls -A "$record_dir") == server-url ]]
python3 - "$test_dir/guest-calls.jsonl" "$guest_home/.multica-agent/bin:" <<'CHECK'
import json
import sys
calls = [json.loads(line) for line in open(sys.argv[1])]
status = [call for call in calls if call['command'] == 'multica']
assert status and all(call['env']['PATH'].startswith(sys.argv[2]) for call in status), status
CHECK
first_inode=$(ls -i "$record_dir/server-url")
record
[[ $(ls -i "$record_dir/server-url") == "$first_inode" ]]
guest_state '{"server_url":"https://other.test:8443/base/"}'
record
[[ $(cat "$record_dir/server-url") == https://other.test:8443/base ]]
[[ $(ls -A "$record_dir") == server-url ]]
echo 'PASS vm guest: record-server は動いているデーモンの接続先を末尾のスラッシュなしで記録し、同じ間は書き直さない'

# 正しくない接続先と取得の失敗は、理由を出して失敗し、今の記録を残す。
for state in '{"server_url":"http://bad.test"}' '{"server_url":"https://user@bad.test"}' '{"server_url":"https://bad.test/?q"}' '{"server_url":""}' '{"server_url":5}' '{"daemon":{"status":"running","pid":4242}}' '{"daemon":{"status":"unknown"}}' '{"daemon":{"status":"running","pid":0,"server_url":"https://example.test"}}' '{"fail":"multica daemon status --output json"}'; do
 guest_state_replace '{"uid":1000}'
 guest_state "$state"
 if record; then echo 'record-server が失敗すべきケースで成功しました' >&2; exit 1; fi
 [[ -s $test_dir/err ]]
 [[ $(cat "$record_dir/server-url") == https://other.test:8443/base ]]
done
echo 'PASS vm guest: record-server は不正な接続先と状態の取得失敗で失敗し、今の記録を残す'

# 置き換えに失敗しても、今の記録を壊さず、一時のファイルを残さない。
guest_state_replace '{"uid":1000,"server_url":"https://changed.test"}'
mkdir -p "$test_dir/failing-mv"
printf '#!/bin/sh\nexit 1\n' >"$test_dir/failing-mv/mv"
chmod +x "$test_dir/failing-mv/mv"
if record_path=$test_dir/failing-mv: record; then echo 'record-server が失敗すべきケースで成功しました' >&2; exit 1; fi
[[ $(cat "$record_dir/server-url") == https://other.test:8443/base ]]
[[ $(ls -A "$record_dir") == server-url ]]
echo 'PASS vm guest: record-server は置き換えに失敗しても今の記録を壊さず、一時のファイルを残さない'
