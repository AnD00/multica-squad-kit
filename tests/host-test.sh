#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/host-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
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
die() { printf '%s\n' "$*" >&2; exit 1; }
mc() { multica "$@"; }
server_url=https://example.test
runtimes=${TEST_RUNTIMES:-[\"claude\",\"codex\"]}
command() {
 if [[ $* == "-v ${TEST_MISSING_RUNTIME:-__none__}" ]]; then return 1; fi
 builtin command "$@"
}
prepare_host
RUN
run() { /bin/bash "$test_dir/run.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then exit 1; fi; [[ -s $test_dir/err ]]; }
set_mode() { printf '%s\n' "$1" >"$test_dir/mode"; : >"$test_dir/calls"; }
agent_env() { printf 'CODEX_HOME=%s/codex PATH=%s/bin:/usr/bin\n' "$TEMPLATE_AGENT_HOME" "$TEMPLATE_AGENT_HOME" >"$test_dir/process-env"; }
set_mode stopped
run
for file in "$root/common/monitor/"squad-*; do
 cmp "$file" "$TEMPLATE_AGENT_HOME/bin/$(basename "$file")"
 [[ -x $TEMPLATE_AGENT_HOME/bin/$(basename "$file") ]]
done
cmp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cmp "$root/common/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
[[ -d $TEMPLATE_AGENT_HOME/claude && ! -e $TEMPLATE_AGENT_HOME/allowed-repos ]]
grep -qx 'daemon start' "$test_dir/calls"
grep -qx 'https://example.test' "$test_dir/started-server"
echo 'PASS host: 新しいホストへ共有ファイルと見張りを配置し、専用環境で一つのデーモンを起動する'
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
run
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do cmp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"; done
cmp "$root/common/monitor/squad-pr-watch" "$TEMPLATE_AGENT_HOME/bin/squad-pr-watch"
grep -q '印のない既存' "$test_dir/err"
echo 'PASS host: 印のない同居環境の関所・設定・資格情報・共有許可ファイルを変えず、専用の見張りだけ更新する'

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
 [[ $(wc -l <"$shell_dir/.zshenv" | tr -d ' ') == 2 ]]
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
