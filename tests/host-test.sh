#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/host-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
cat >"$test_dir/bin/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
mode=$(cat "$base/mode")
printf '%s\n' "$*" >>"$base/calls"
if [[ -f $base/fail && $(cat "$base/fail") == "$*" ]]; then echo 'intentional CLI failure' >&2; exit 77; fi
case "$*" in
'user profile get --output json') echo '{"id":"member-a"}' ;;
'daemon status --output json')
 case $mode in
 stopped|desktop) echo '{"status":"stopped","pid":null}' ;;
 busy) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","running_task_count":3,"active_task_count":3,"server_url":"https://example.test"}' ;;
 unknown) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a"}' ;;
 *) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","running_task_count":0,"active_task_count":0,"server_url":"https://example.test"}' ;;
 esac ;;
'runtime list --output json')
 if [[ $mode == stopped || -f $base/no-runtimes ]]; then echo '[]'; elif [[ -n ${TEST_RUNTIME_LIST:-} ]]; then cat "$TEST_RUNTIME_LIST"; else
  echo '[{"id":"runtime-claude","owner_id":"member-a","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"runtime-codex","owner_id":"member-a","daemon_id":"daemon-a","provider":"codex","status":"online"},{"id":"foreign","owner_id":"member-b","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"other-host","owner_id":"member-a","daemon_id":"daemon-b","provider":"codex","status":"online"}]'
 fi ;;
'daemon stop') echo stopped >"$base/mode" ;;
'daemon start')
 [[ -z ${VSCODE_TEST_MARKER:-} && -z ${MULTICA_WORKSPACE_ID:-} && $SHELL == /bin/zsh ]] || exit 78
 printf 'CODEX_HOME=%s PATH=%s\n' "$CODEX_HOME" "$PATH" >"$base/process-env"
 printf '%s\n' "$MULTICA_SERVER_URL" >"$base/started-server"
 echo running >"$base/mode" ;;
*) echo "unexpected CLI call: $*" >&2; exit 90 ;;
esac
STUB
cat >"$test_dir/bin/ps" <<'STUB'
#!/bin/bash
base=$(cd "$(dirname "$0")/.." && pwd)
cat "$base/process-env"
STUB
cat >"$test_dir/bin/claude" <<'STUB'
#!/bin/bash
base=$(cd "$(dirname "$0")/.." && pwd)
[[ $* == 'auth status' && $CLAUDE_CONFIG_DIR == */claude ]] || exit 91
if [[ -t 0 ]]; then
 echo 'error: EINVAL: invalid argument, kqueue' >&2
 exit 1
fi
printf 'notty\n' >"$base/claude-stdin"
if [[ -n ${TEST_CLAUDE_STDOUT:-} ]]; then
 cat "$TEST_CLAUDE_STDOUT"
 cat "$TEST_CLAUDE_STDERR" >&2
 exit "$TEST_CLAUDE_EXIT"
fi
if [[ -f $base/no-claude-auth ]]; then echo '{"loggedIn":false}'; else echo '{"loggedIn":true}'; fi
STUB
cat >"$test_dir/bin/codex" <<'STUB'
#!/bin/bash
base=$(cd "$(dirname "$0")/.." && pwd)
[[ $* == 'login status' && $CODEX_HOME == */codex ]] || exit 92
[[ ! -f $base/no-codex-auth ]]
STUB
printf '#!/bin/bash\nexit 0\n' >"$test_dir/bin/sleep"
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH" TEMPLATE_AGENT_HOME="$test_dir/agent's home" TEMPLATE_DAEMON_ID_FILE="$test_dir/daemon.id"
export VSCODE_TEST_MARKER=must-not-be-inherited
printf daemon-a >"$TEMPLATE_DAEMON_ID_FILE"
cat >"$test_dir/run.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/host.sh"
die() { ui_phase_fail; ui_error "$*"; exit 1; }
mc() { multica "$@"; }
server_url=https://example.test
runtimes=${TEST_RUNTIMES:-[\"claude\",\"codex\"]}
command() {
 if [[ $* == "-v ${TEST_MISSING_RUNTIME:-__none__}" ]]; then return 1; fi
 builtin command "$@"
}
mktemp() {
 local path
 path=$(builtin command mktemp "$@") || return
 case $path in */claude-auth.*) printf '%s\n' "$path" >>"${TEMPLATE_DAEMON_ID_FILE%/*}/auth-work" ;; esac
 printf '%s\n' "$path"
}
if [[ ${TEST_AUTH_READER_FAIL:-no} == yes ]]; then
 test_python=$(type -P python3)
 python3() {
  if [[ ${2:-} == */claude-auth.*/stdout ]]; then
   echo 'reader exception: private-reader-value' >&2
   return 1
  fi
  "$test_python" "$@"
 }
fi
if [[ ${TEST_HOST_STEPS:-no} == yes ]]; then
 ui_init
 ui_steps_begin err 2 'ホストを準備'
 ui_phase_start 1
fi
prepare_host
RUN
run() { /bin/bash "$test_dir/run.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then exit 1; fi; [[ -s $test_dir/err ]]; }
set_mode() { printf '%s\n' "$1" >"$test_dir/mode"; : >"$test_dir/calls"; }
agent_env() { printf 'CODEX_HOME=%s/codex PATH=%s/bin:/usr/bin\n' "$TEMPLATE_AGENT_HOME" "$TEMPLATE_AGENT_HOME" >"$test_dir/process-env"; }
set_mode stopped
run
for file in "$root/common/monitor/"squad-*; do
 if [[ ${file##*/} == squad-cli-lib ]]; then
  cmp <(sed '/^SQUAD_CLI_VERIFIED_VERSION=/d' "$file") <(sed '/^SQUAD_CLI_VERIFIED_VERSION=/d' "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib")
  expected_version=$(head -n 1 "$root/tests/fixtures/cli/VERSION")
  actual_version=$(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib")
  [[ $actual_version == "$expected_version" ]]
 else
  cmp "$file" "$TEMPLATE_AGENT_HOME/bin/$(basename "$file")"
 fi
 [[ -x $TEMPLATE_AGENT_HOME/bin/$(basename "$file") ]]
done
cmp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cmp "$root/common/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
[[ -d $TEMPLATE_AGENT_HOME/claude && ! -e $TEMPLATE_AGENT_HOME/allowed-repos ]]
grep -qx 'daemon start' "$test_dir/calls"
grep -qx 'https://example.test' "$test_dir/started-server"
echo 'PASS host: 新しいホストへ共有ファイルと見張りを配置し、専用環境で一つのデーモンを起動する'
# 入口から /dev/tty を受け継ぐ場合も、ファイルやパイプの場合も同じ確認を通す。
printf 'input for setup\n' >"$test_dir/stdin"
for input in tty pipe file; do
 set_mode running
 agent_env
 rm -f "$test_dir/claude-stdin"
 case $input in
 tty)
  python3 -I "$root/tests/stdin-tty-run.py" tty /dev/null /dev/null "$test_dir/out" "$test_dir/err" -- \
   /bin/bash -c 'exec </dev/tty; [[ -t 0 ]] || exit 93; exec /bin/bash "$@"' -- "$test_dir/run.sh" "$root"
  ;;
 pipe) cat "$test_dir/stdin" | run ;;
 file) run <"$test_dir/stdin" ;;
 esac
 grep -qx 'notty' "$test_dir/claude-stdin"
 grep -qx 'daemon status --output json' "$test_dir/calls"
 ! grep -q 'ログインしてください' "$test_dir/err"
 echo "PASS host: 標準入力が $input でも Claude の確認には端末を渡さず、デーモンの確認へ進む"
done
(
 # 原本の VERSION を変えずに、バージョンを取り直したセットアップを再現する。
 source "$root/lib/host.sh"
 mkdir -p "$test_dir/version-kit/common/monitor" "$test_dir/version-kit/tests/fixtures/cli"
 cp "$root/common/monitor/squad-cli-lib" "$test_dir/version-kit/common/monitor/"
 printf "multica fixture-next (captured 'version')\ngh ignored\n" >"$test_dir/version-kit/tests/fixtures/cli/VERSION"
 root="$test_dir/version-kit"
 agent_home=$TEMPLATE_AGENT_HOME
 die() { echo "$*" >&2; exit 1; }
 host_cli_library
 actual_version=$(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$agent_home/bin/squad-cli-lib")
 [[ $actual_version == "multica fixture-next (captured 'version')" ]]
 [[ -z $(find "$root/tmp" -type f -print) ]]
 # 拡張を足した作業用コピーには tests がない。採取バージョンは原本から読む。
 kit_root=$root
 mkdir -p "$test_dir/combined/common/monitor"
 cp "$root/common/monitor/squad-cli-lib" "$test_dir/combined/common/monitor/"
 root="$test_dir/combined"
 host_cli_library
 [[ $(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$agent_home/bin/squad-cli-lib") == "$actual_version" ]]
)
run
[[ $(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib") == "$expected_version" ]]
echo 'PASS host: 見本のバージョンを取り直すとライブラリの採取バージョンも更新し、先頭行の値をそのまま保持する'
for file in squad-pr-link squad-pr-link-lib; do
 [[ $(PATH="$TEMPLATE_AGENT_HOME/bin:$PATH" command -v "$file") == "$TEMPLATE_AGENT_HOME/bin/$file" ]]
done
echo 'PASS host: 新しい導入で PR の紐付けコマンドと共有関数を bin に置き、名前で解決できる'
set_mode busy
agent_env
run
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: 設定と両ランタイムが一致するデーモンは稼働中でも起動し直さない'
set_mode running
printf wrong >"$test_dir/process-env"
run
[[ $(grep -c '^daemon stop$' "$test_dir/calls") == 1 && $(grep -c '^daemon start$' "$test_dir/calls") == 1 ]]
echo 'PASS host: 設定が違う場合はタスクがないことを確認して停止・起動する'
set_mode busy
printf wrong >"$test_dir/process-env"
deny
grep -q '実行中のタスク' "$test_dir/err"
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
set_mode unknown
deny
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: 実行中のタスクがあるか件数が不明なら停止しない'
set_mode desktop
deny
grep -q 'CLI 以外' "$test_dir/err"
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: CLI 以外のデーモンへ重ねて起動しない'
set_mode running
agent_env
touch "$test_dir/no-claude-auth"
deny
grep -q 'ログインしてください' "$test_dir/err"
[[ ! -s $test_dir/calls ]]
rm "$test_dir/no-claude-auth"
touch "$test_dir/no-codex-auth"
deny
grep -q 'codex login' "$test_dir/err"
[[ ! -s $test_dir/calls ]]
rm "$test_dir/no-codex-auth"
echo 'PASS host: 専用の認証がなければログインを案内し、デーモン操作をしない'
# 最初の JSON の値と終了コードの組み合わせで、ログインの案内と確認失敗を分ける。
(
 export TEST_CLAUDE_STDOUT="$test_dir/auth-stdout" TEST_CLAUDE_STDERR="$test_dir/auth-stderr"
 for auth_case in false0 false1 crash malformed missing string null array boolean number empty whitespace prefix true1 true1-kqueue suffix stderr invalid-utf8 invalid-suffix control stderr-einval stderr-kqueue; do
  printf '{"loggedIn":true}\n' >"$TEST_CLAUDE_STDOUT"
  : >"$TEST_CLAUDE_STDERR"
  export TEST_CLAUDE_EXIT=0
  expected=failed
  first='JSON として読めない'
  category='CLI の出力を読めない（詳細は省略）'
  case $auth_case in
  false0|false1)
   printf '{"loggedIn":false}\n' >"$TEST_CLAUDE_STDOUT"
   TEST_CLAUDE_EXIT=${auth_case#false}
   expected=login
   ;;
  crash)
   : >"$TEST_CLAUDE_STDOUT"
   printf 'error: EINVAL: invalid argument, kqueue\n      at emitError (node:events:65:13)\nBun v1.4.4 (macOS arm64)\n' >"$TEST_CLAUDE_STDERR"
   TEST_CLAUDE_EXIT=1
   first=空
   category='Claude の CLI の既知の不具合（kqueue）'
   ;;
  malformed) printf 'not JSON' >"$TEST_CLAUDE_STDOUT" ;;
  missing) printf '{}' >"$TEST_CLAUDE_STDOUT"; first='loggedIn が真偽値でない' ;;
  string) printf '{"loggedIn":"true"}' >"$TEST_CLAUDE_STDOUT"; first='loggedIn が真偽値でない' ;;
  null) printf 'null' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  array) printf '[{"loggedIn":true}]' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  boolean) printf 'true' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  number) printf '42' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  empty) : >"$TEST_CLAUDE_STDOUT"; first=空 ;;
  whitespace) printf ' \t\r\n' >"$TEST_CLAUDE_STDOUT"; first=空 ;;
  prefix) printf 'warning\n{"loggedIn":true}\n' >"$TEST_CLAUDE_STDOUT" ;;
  true1|true1-kqueue|invalid-suffix)
   TEST_CLAUDE_EXIT=1
   first='loggedIn が true'
   category='CLI がログイン済みと答えたまま失敗した'
   if [[ $auth_case == true1-kqueue ]]; then
    printf 'EINVAL\nkqueue\n' >"$TEST_CLAUDE_STDERR"
    category='Claude の CLI の既知の不具合（kqueue）'
   elif [[ $auth_case == invalid-suffix ]]; then
    printf '\377\033[?1l' >>"$TEST_CLAUDE_STDOUT"
   fi
   ;;
  suffix) printf ' \n{"loggedIn":true}\n\033[?1l{"loggedIn":false}' >"$TEST_CLAUDE_STDOUT"; expected=pass ;;
  stderr) printf 'warning from CLI\n' >"$TEST_CLAUDE_STDERR"; expected=pass ;;
  invalid-utf8) printf '\377{"loggedIn":true}' >"$TEST_CLAUDE_STDOUT" ;;
  control) printf '\033[31m{"loggedIn":true}' >"$TEST_CLAUDE_STDOUT" ;;
  stderr-einval|stderr-kqueue)
   : >"$TEST_CLAUDE_STDOUT"
   printf '%s\n' "${auth_case#stderr-}" >"$TEST_CLAUDE_STDERR"
   if [[ $auth_case == stderr-einval ]]; then printf 'EINVAL\n' >"$TEST_CLAUDE_STDERR"; fi
   first=空
   ;;
  esac
  # ダミーの個人情報・認証値・未知の値を、正常な JSON とその前後にも置く。
  # 失敗の診断は全行を照合し、成功・未ログイン時も両出力への漏れを確認する。
  case $auth_case in
  false0|false1|true1|prefix|suffix|stderr|true1-kqueue|invalid-suffix)
   python3 - "$TEST_CLAUDE_STDOUT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes().replace(
    b'"loggedIn":',
    b'"email":"private-mail@example.test","orgId":"private-org-id",'
    b'"orgName":"private-org-name","unknown-private-key":"private-unknown-value","loggedIn":',
)
path.write_bytes(data + b'\nprivate-after-json\xff\x1b[31m')
PY
   ;;
  malformed) printf 'private-before-json\n{"email":"private-mail@example.test"' >"$TEST_CLAUDE_STDOUT" ;;
  esac
  if [[ $auth_case != empty ]]; then
   printf 'Bearer private-auth-value private-stderr-value\377\033[31m\n' >>"$TEST_CLAUDE_STDERR"
  fi
  set_mode running
  agent_env
  rc=0
  run || rc=$?
  ! grep -aEq 'private-|Bearer|invalid argument|emitError|Bun v|warning from CLI' "$test_dir/out" "$test_dir/err"
  if [[ $expected == pass ]]; then
   [[ $rc == 0 ]]
   grep -qx 'daemon status --output json' "$test_dir/calls"
   ! grep -qE 'ログインしてください|ログインを確認できませんでした|warning from CLI' "$test_dir/err"
  else
   [[ $rc == 1 && ! -s $test_dir/calls ]]
   [[ ! -s $test_dir/out ]]
   if [[ $expected == login ]]; then
    grep -qxF "エラー: エージェント用の Claude にログインしてください: CLAUDE_CONFIG_DIR=$TEMPLATE_AGENT_HOME/claude claude" "$test_dir/err"
    ! grep -q 'ログインを確認できませんでした' "$test_dir/err"
   else
    ! grep -q 'ログインしてください' "$test_dir/err"
    python3 - "$test_dir/err" "$TEST_CLAUDE_STDOUT" "$TEST_CLAUDE_EXIT" "$TEMPLATE_AGENT_HOME" "$first" "$category" "$TEST_CLAUDE_STDERR" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_text()
home = sys.argv[4]
message = f"使用する gh の関所: {home}/bin/gh\n使用する git push の関所: {home}/git-hooks/pre-push\n使用する Codex の設定: {home}/codex/config.toml\n"
message += f"エラー: エージェント用の Claude のログインを確認できませんでした。ログインが切れているとは限りません。端末から CLAUDE_CONFIG_DIR={home}/claude claude auth status を流して、ログインの状態を確認してから流し直してください。問い合わせるときは、下の診断の行だけを添えてください。\n"
message += f"  診断（claude auth status）:\n    分類: {sys.argv[6]}\n    終了コード: {sys.argv[3]}\n    標準出力の最初の値: {sys.argv[5]}\n"
message += "    標準出力: " + ("あり（内容は省略）" if Path(sys.argv[2]).stat().st_size else "なし") + "\n"
message += "    標準エラー: " + ("あり（内容は省略）" if Path(sys.argv[7]).stat().st_size else "なし") + "\n"
assert actual == message, actual
PY
   fi
  fi
  while IFS= read -r work; do [[ ! -e $work ]]; done <"$test_dir/auth-work"
  echo "PASS host: Claude の確認 $auth_case は $expected に分け、生出力を表示せず、一時ファイルを残さない"
 done
 # 読み取りの失敗で入力を含む例外が出ても、固定文だけで止まる。
 set_mode running
 TEST_AUTH_READER_FAIL=yes deny
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 grep -qx 'エラー: Claude のログインの確認の出力を読めませんでした。' "$test_dir/err"
 ! grep -aEq 'private-|reader exception|診断（' "$test_dir/err"
 while IFS= read -r work; do [[ ! -e $work ]]; done <"$test_dir/auth-work"
 echo 'PASS host: 出力を読む処理が失敗しても、生出力や例外を表示せず固定文で止まる'
 # 作る間の一覧を使う場合も、失敗した手順、エラー、診断の順に出す。
 : >"$TEST_CLAUDE_STDOUT"
 printf 'CLI failure\n' >"$TEST_CLAUDE_STDERR"
 export TEST_CLAUDE_EXIT=7 TEST_HOST_STEPS=yes
 set_mode running
 deny
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 python3 - "$test_dir/err" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_text()
assert actual.index("  ✖ ホストを準備") < actual.index("エラー: エージェント用の Claude のログインを確認できませんでした") < actual.index("  診断（claude auth status）:"), actual
assert actual.endswith("  診断（claude auth status）:\n    分類: CLI の出力を読めない（詳細は省略）\n    終了コード: 7\n    標準出力の最初の値: 空\n    標準出力: なし\n    標準エラー: あり（内容は省略）\n"), actual
assert "ログインしてください" not in actual and "CLI failure" not in actual, actual
PY
 echo 'PASS host: 一覧を書き換えない画面も、手順の失敗、エラー、固定の診断の順に出す'
 env -u NO_COLOR TERM=xterm-256color python3 -I "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- \
  /bin/bash -c '/bin/bash "$1" "$2"; printf "%s\n" "$?" >"$3"' -- "$test_dir/run.sh" "$root" "$test_dir/auth-exit"
 grep -qx '1' "$test_dir/auth-exit"
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 python3 - "$test_dir/err" <<'PY'
from pathlib import Path
import re
import sys

raw = Path(sys.argv[1]).read_text()
assert re.search(r"\x1b\[\d+A", raw), raw
actual = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw).replace("\r", "")
assert actual.index("  ✖ ホストを準備") < actual.index("エラー: エージェント用の Claude のログインを確認できませんでした") < actual.index("  診断（claude auth status）:"), actual
assert actual.endswith("  診断（claude auth status）:\n    分類: CLI の出力を読めない（詳細は省略）\n    終了コード: 7\n    標準出力の最初の値: 空\n    標準出力: なし\n    標準エラー: あり（内容は省略）\n"), actual
assert "ログインしてください" not in actual and "CLI failure" not in actual, actual
PY
 echo 'PASS host: 一覧を書き換える端末でも、手順の失敗のあとにエラーと固定の診断を出す'
)
for fail in 'daemon status --output json' 'runtime list --output json'; do
 set_mode running
 printf '%s\n' "$fail" >"$test_dir/fail"
 deny
 if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
done
rm "$test_dir/fail"
echo 'PASS host: 状態・ランタイムの取得失敗を、停止してよい状態と扱わない'
set_mode running
printf wrong >"$test_dir/process-env"
printf 'daemon stop\n' >"$test_dir/fail"
deny
if grep -q '^daemon start$' "$test_dir/calls"; then exit 1; fi
set_mode stopped
printf 'daemon start\n' >"$test_dir/fail"
deny
rm "$test_dir/fail"
set_mode stopped
touch "$test_dir/no-runtimes"
deny
grep -q 'オンラインになりません' "$test_dir/err"
[[ $(grep -c '^daemon start$' "$test_dir/calls") == 1 ]]
rm "$test_dir/no-runtimes"
echo 'PASS host: 停止・起動の失敗とオンライン待ちの上限を失敗として返す'
# 使わない側はコマンドなし・未ログイン・オフラインでも準備できる。
for selected in claude codex; do
 (
  export TEST_RUNTIMES="[\"$selected\"]" TEST_RUNTIME_LIST="$test_dir/selected-runtime.json"
  export TEMPLATE_AGENT_HOME="$test_dir/$selected-only"
  if [[ $selected == claude ]]; then export TEST_MISSING_RUNTIME=codex; else export TEST_MISSING_RUNTIME=claude; fi
  touch "$test_dir/no-$TEST_MISSING_RUNTIME-auth"
  printf '[{"id":"runtime-%s","owner_id":"member-a","daemon_id":"daemon-a","provider":"%s","status":"online"}]\n' "$selected" "$selected" >"$TEST_RUNTIME_LIST"
  set_mode stopped
  run
  grep -qx 'daemon start' "$test_dir/calls"
  if [[ $selected == claude ]]; then
   [[ ! -e $TEMPLATE_AGENT_HOME/codex/config.toml ]]
   ! grep -q '使用する Codex の設定' "$test_dir/err"
   printf 'invalid existing config\n' >"$TEMPLATE_AGENT_HOME/codex/config.toml"
  else
   cmp "$root/common/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
  fi
  set_mode busy
  agent_env
  run
  ! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
  if [[ $selected == claude ]]; then grep -qx 'invalid existing config' "$TEMPLATE_AGENT_HOME/codex/config.toml"; fi
  touch "$test_dir/no-$selected-auth"
  : >"$test_dir/calls"
  deny
  grep -q 'ログインしてください' "$test_dir/err"
  [[ ! -s $test_dir/calls ]]
  rm "$test_dir/no-$selected-auth" "$test_dir/no-$TEST_MISSING_RUNTIME-auth"
 )
 echo "PASS host: $selected だけで起動・再利用し、選んだ側の認証を求め、使わない側は求めない"
done
# 同居する既存システムの Mac の代わり。印のないファイルと資格情報を残す。
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/pre-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
printf '# existing codex config\nallow_login_shell = false\n' >"$TEMPLATE_AGENT_HOME/codex/config.toml"
printf 'original allowed repository\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
printf 'existing credential\n' >"$TEMPLATE_AGENT_HOME/claude/credentials.json"
printf 'existing codex credential\n' >"$TEMPLATE_AGENT_HOME/codex/auth.json"
mkdir "$test_dir/original"
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do
 mkdir -p "$test_dir/original/$(dirname "$file")"
 cp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"
done
set_mode running
agent_env
printf "# multica-squad-kit-managed\nchanged\n" >"$TEMPLATE_AGENT_HOME/bin/squad-pr-watch"
for file in squad-pr-link squad-pr-link-lib; do
 printf '# multica-squad-kit-managed\nold\n' >"$TEMPLATE_AGENT_HOME/bin/$file"
 chmod 644 "$TEMPLATE_AGENT_HOME/bin/$file"
done
run
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do cmp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"; done
cmp "$root/common/monitor/squad-pr-watch" "$TEMPLATE_AGENT_HOME/bin/squad-pr-watch"
grep -q '印のない既存' "$test_dir/err"
echo 'PASS host: 印のない同居環境の関所・設定・資格情報・共有許可ファイルを変えず、専用の見張りだけ更新する'
for file in squad-pr-link squad-pr-link-lib; do
 cmp "$root/common/monitor/$file" "$TEMPLATE_AGENT_HOME/bin/$file"
 [[ -x $TEMPLATE_AGENT_HOME/bin/$file ]]
done
echo 'PASS host: 流し直しで印のある PR の紐付けコマンドと共有関数を原本に更新し、実行権限を付ける'

for display in "使用する gh の関所: $TEMPLATE_AGENT_HOME/bin/gh" "使用する git push の関所: $TEMPLATE_AGENT_HOME/git-hooks/pre-push" "使用する Codex の設定: $TEMPLATE_AGENT_HOME/codex/config.toml"; do grep -qxF "$display" "$test_dir/err"; done
echo 'PASS host: 印のない既存を保持する場合も、使用する三つの実ファイルを明示する'
for invalid in '' 'allow_login_shell = true' 'allow_login_shell = "false"' 'allow_login_shell = 0' $'[profiles.other]\nallow_login_shell = false' $'allow_login_shell = false\nallow_login_shell = false' 'allow_login_shell = ['; do
 printf '%s\n' "$invalid" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/invalid-config"
 : >"$test_dir/calls"
 deny
 cmp "$test_dir/invalid-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 grep -qF 'allow_login_shell = false を確認できません' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
done
cp "$test_dir/original/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: 確認した起動ファイルを使えない Codex の既存設定は保持し、直し方を出してデーモン操作前に止まる'

for valid in '"allow_login_shell" = false' "'allow_login_shell' = false" $'allow_login_shell = false # comment\n[profiles.other]\nallow_login_shell = true'; do
 printf '%s\n' "$valid" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/valid-config"
 set_mode running
 agent_env
 run
 cmp "$test_dir/valid-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 grep -q '^daemon status' "$test_dir/calls"
done
echo 'PASS host: TOML の引用キーとトップレベルの真偽値 false を読み、別テーブルの同名キーを混同しない'

for delimiter in '"""' "'''"; do
 printf '%s\n' "model_instructions = $delimiter" 'allow_login_shell = false' "$delimiter" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/multiline-config"
 : >"$test_dir/calls"
 deny
 cmp "$test_dir/multiline-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 grep -qF 'allow_login_shell = false を確認できません' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
 # 文字列内に true があっても、本物のトップレベルの false を使う。
 printf '%s\n' 'allow_login_shell = false' "model_instructions = $delimiter" 'allow_login_shell = true' "$delimiter" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/multiline-config"
 run
 cmp "$test_dir/multiline-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
done
cp "$test_dir/original/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: 基本・リテラルの複数行文字列をキーと扱わず、本物のトップレベルの値だけを判定する'

for spec in 'guard/gh:bin/gh' 'guard/pre-push:git-hooks/pre-push' 'codex/config.toml:codex/config.toml'; do
 target=${spec#*:}
 printf '# multica-squad-kit-managed\nold\n' >"$TEMPLATE_AGENT_HOME/$target"
done
run
cmp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cmp "$root/common/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: 印のある共有ファイルは 原本の内容へ更新する'
# ID を受け取る関数を、実際の bash と zsh の起動ファイルで確認する。
cat >"$test_dir/project.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/host.sh"
die() { echo "$*" >&2; exit 1; }
shift
prepare_project_host "$@"
RUN
/bin/bash "$test_dir/project.sh" "$root" project-a example/one
/bin/bash "$test_dir/project.sh" "$root" project-b example/two
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/two ]]
for id in project-a project-b; do
 shell_dir="$TEMPLATE_AGENT_HOME/template/shell/$id"
 ! grep -q '{{' "$shell_dir/.zshenv"
 cmp "$shell_dir/.zshenv" "$shell_dir/env.sh"
 BASH_ENV="$shell_dir/env.sh" /bin/bash -c 'test "$SQUAD_KIT_ALLOWED_REPOS" = "$1"' -- "$TEMPLATE_AGENT_HOME/allowed-repos.d/$id"
 ZDOTDIR="$shell_dir" /bin/zsh -c 'test "$SQUAD_KIT_ALLOWED_REPOS" = "$1"' -- "$TEMPLATE_AGENT_HOME/allowed-repos.d/$id"
done
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
cp "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$test_dir/previous-project"
/bin/bash "$test_dir/project.sh" "$root" project-b example/updated
cmp "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$test_dir/previous-project"
if /bin/bash "$test_dir/project.sh" "$root" '../bad' example/no >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
echo 'PASS host: プロジェクトごとの許可ファイルが、引用符や空白のある保存先でも bash・zsh の子へ届く'

/bin/bash "$test_dir/project.sh" "$root" project-a example/one EXAMPLE/TWO example/one
printf 'example/one\nexample/two\n' >"$test_dir/selected"
cmp "$test_dir/selected" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == 600 ]]
before_inode=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a")
/bin/bash "$test_dir/project.sh" "$root" project-a example/one example/two
[[ $(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == "$before_inode" ]]
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/updated ]]
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
echo 'PASS host: 選んだ全件を一行ずつ小文字で重複なく許し、同じ選択の再実行と別プロジェクト・共有ファイルを保つ'

# 起動ファイルと共有の関所は本体を使い、送信先の gh だけを PATH で差し替える。
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
export HOST_GH_CALLS="$test_dir/gh-calls" PATH="$TEMPLATE_AGENT_HOME/bin:$PATH"
unset GH_HOST
: >"$HOST_GH_CALLS"
mkdir "$test_dir/repository"
git -C "$test_dir/repository" init -q
shell_dir="$TEMPLATE_AGENT_HOME/template/shell/project-a"
probe() (
 cd "$test_dir/repository"
 ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" "$1" -c "$2" -- "$3" "$4" >"$test_dir/out" 2>"$test_dir/err"
)
for shell in /bin/bash /bin/zsh; do
 for repo in example/one example/two; do
  probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' "$repo" ''
  probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "https://github.com/$repo"
 done
 before=$(wc -l <"$HOST_GH_CALLS")
 if probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/updated ''; then exit 1; fi
 [[ $(wc -l <"$HOST_GH_CALLS") == "$before" ]]
 if probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" https://github.com/example/updated; then exit 1; fi
done
[[ $(wc -l <"$HOST_GH_CALLS" | tr -d ' ') == 4 ]]
echo 'PASS host: bash・zsh の起動ファイルから両方の選択が gh と pre-push まで届き、別プロジェクトは送信前に拒否する'

/bin/bash "$test_dir/project.sh" "$root" project-a example/one >"$test_dir/out" 2>"$test_dir/err"
grep -qx '許すリポジトリから外しました: example/two' "$test_dir/err"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
for shell in /bin/bash /bin/zsh; do
 probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/one ''
 before=$(wc -l <"$HOST_GH_CALLS")
 if probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/two ''; then exit 1; fi
 [[ $(wc -l <"$HOST_GH_CALLS") == "$before" ]]
 if probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" https://github.com/example/two; then exit 1; fi
done
/bin/bash "$test_dir/project.sh" "$root" project-a example/one >"$test_dir/out" 2>"$test_dir/err"
! grep -q '許すリポジトリから外しました' "$test_dir/err"
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/updated ]]
echo 'PASS host: 外した全件を許可から消して表示し、既存の起動ファイルのまま次の gh・push で拒否する'

for invalid in '' 'bad/repo/path' $'example/two\nexample/three'; do
 if /bin/bash "$test_dir/project.sh" "$root" project-a example/one "$invalid" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 [[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
done
if /bin/bash "$test_dir/project.sh" "$root" project-new >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-new ]]
echo 'PASS host: 空の選択や後ろの不正な値で前の許可を壊さず、空の許可ファイルも作らない'

# 本物の gh が PATH の先でも、起動時と Claude の順の両方を確認する。
export TEST_GUARD_CALLS="$test_dir/guard-calls"
: >"$TEST_GUARD_CALLS"
PATH="$test_dir/bin:$TEMPLATE_AGENT_HOME/bin:$PATH" /bin/bash "$test_dir/project.sh" "$root" project-a example/one example/two >"$test_dir/out" 2>"$test_dir/err"
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 2 ]]
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 4 ]]
for repo in one two; do
 [[ $(grep -c "repos/example/$repo/git/refs" "$TEST_GUARD_CALLS") == 2 ]]
done
echo 'PASS host: 本物の gh が先でも起動時と Claude の順で確認し、許可の通信は各リポジトリ・シェルにつき 1 回に保つ'

for target in allowed-repos.d/project-a template/shell/project-a/.zshenv template/shell/project-a/env.sh; do
 cp "$TEMPLATE_AGENT_HOME/$target" "$test_dir/before-${target##*/}"
done
assert_previous_project() {
 for target in allowed-repos.d/project-a template/shell/project-a/.zshenv template/shell/project-a/env.sh; do
  cmp "$test_dir/before-${target##*/}" "$TEMPLATE_AGENT_HOME/$target"
 done
 [[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-new && ! -e $TEMPLATE_AGENT_HOME/template/shell/project-new ]]
 [[ ! -s $TEST_GUARD_CALLS ]]
 grep -q '従来の許可とシェル起動ファイルを保って停止' "$test_dir/err"
}
mkdir -p "$test_dir/package/lib" "$test_dir/package/common"
cp "$root/lib/host.sh" "$root/lib/ui.sh" "$test_dir/package/lib/"
cp -R "$root/common/shell" "$test_dir/package/common/"
# .zshenv は起動時に直せても、env.sh がコマンド直前に戻さなければ止める。
head -n 2 "$root/common/shell/env.sh" >"$test_dir/package/common/shell/env.sh"
for id in project-a project-new; do
 : >"$TEST_GUARD_CALLS"
 if PATH="$test_dir/bin:$TEMPLATE_AGENT_HOME/bin:$PATH" /bin/bash "$test_dir/project.sh" "$test_dir/package" "$id" example/changed >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 grep -q 'Claude の実行の順で gh が関所を選びません' "$test_dir/err"
 grep -q 'ひな形の env.sh' "$test_dir/err"
 assert_previous_project
done
echo 'PASS host: env.sh が PATH を戻さなければ Claude の順で通信前に止まり、既存の許可・起動ファイルを保ち新規にも書かない'

# 関所以外に gh がない PATH でも、ほかのホストの本物を探しに行かない。
mkdir "$test_dir/no-gh-bin"
for tool in tr cat; do ln -s "$(command -v "$tool")" "$test_dir/no-gh-bin/$tool"; done
for id in project-a project-new; do
 : >"$TEST_GUARD_CALLS"
 if PATH="$TEMPLATE_AGENT_HOME/bin:$test_dir/no-gh-bin" /bin/bash "$test_dir/project.sh" "$root" "$id" example/changed >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 grep -q '本物の gh が関所の外の PATH に見つかりません' "$test_dir/err"
 assert_previous_project
done
echo 'PASS host: 関所の外に gh がなければ理由を出し、従来の許可・起動ファイルを保って止まる'
