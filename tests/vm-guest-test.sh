#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/vm-guest.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
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

for file in vm/lima.sh vm/guest/start-daemon vm/guest/provision.sh vm/guest/verify.sh; do
 [[ $(git -C "$root" check-attr eol -- "$file") == "$file: eol: lf" ]]
done
echo 'PASS vm guest: ホストとゲストのシェルスクリプトを LF に固定する'
