#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/guard-check-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
export TEMPLATE_AGENT_HOME="$test_dir/agent's home" TEST_GUARD_CALLS="$test_dir/calls"
mkdir -p "$test_dir/bin" "$TEMPLATE_AGENT_HOME/bin" "$TEMPLATE_AGENT_HOME/git-hooks" "$TEMPLATE_AGENT_HOME/allowed-repos.d" "$TEMPLATE_AGENT_HOME/template/shell/project-a"
mkdir -p "$test_dir/package/common"
cp -R "$root/common/shell" "$test_dir/package/common/"
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"
unset GH_HOST
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/gh" >"$test_dir/shared-gh"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/pre-push" >"$test_dir/shared-push"
reset_guards() {
 cp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
 cp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 chmod +x "$TEMPLATE_AGENT_HOME/bin/gh" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 : >"$TEST_GUARD_CALLS"
}
printf 'example/old\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
printf 'old shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
printf 'old bash\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh"
printf 'example/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
source_root=$1
root=$2
die() { echo "$*" >&2; exit 1; }
source "$source_root/lib/ui.sh"
source "$source_root/lib/host.sh"
prepare_project_host project-a example/one example/two example/third
DRIVER
run() { /bin/bash "$test_dir/driver" "$root" "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; }
deny() {
 cp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/shared-before"
 if run; then echo 'unexpected success'; exit 1; fi
 [[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/old ]]
 [[ $(cat "$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv") == 'old shell' ]]
 [[ $(cat "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh") == 'old bash' ]]
 cmp "$test_dir/shared-before" "$TEMPLATE_AGENT_HOME/allowed-repos"
 [[ -z $(find "$test_dir/package/tmp" -maxdepth 1 -name 'guard-check.*' -print) ]]
 grep -q '従来の許可とシェル起動ファイルを保って停止' "$test_dir/err"
}
reset_guards
for status in 401 403 404 500 empty bad-json 201; do
 TEST_GUARD_RESPONSE=$status deny
 grep -Eq '入力検証まで届きませんでした|想定外に成功' "$test_dir/err"
 grep -q '確認' "$test_dir/err"
done
echo 'PASS guard-check: 認証・権限・不明な応答・接続失敗・想定外の成功では止まり、従来の許可と起動ファイルを保つ'

reset_guards
sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
deny
[[ ! -s $TEST_GUARD_CALLS ]]
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
echo 'PASS guard-check: 共有の固定許可だけを読む古い関所は、起動ファイルを用意しただけで成功とせず拒否を検出する'

# 共有許可に選択全件があっても、空のプロジェクト許可で拒否しなければならない。
printf 'example/one\nexample/two\nexample/third\nexample/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
for fixed in gh push both; do
 reset_guards
 if [[ $fixed == gh || $fixed == both ]]; then
  sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
 fi
 if [[ $fixed == push || $fixed == both ]]; then
  sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 fi
 cp "$TEMPLATE_AGENT_HOME/bin/gh" "$test_dir/expected-gh"
 cp "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "$test_dir/expected-push"
 deny
 cmp "$test_dir/expected-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
 cmp "$test_dir/expected-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 grep -q '空の許可' "$test_dir/err"
 grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
 grep -q '管理者' "$test_dir/err"
 echo "PASS guard-check: $fixed が共有の全選択と選択外の許可を固定で読んでも、空の許可で検出し従来の設定を保つ"
done
printf 'example/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"

# 先の二つだけでは成功にしない。三つ目を拒否する既存 gh を使う。
reset_guards
cp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/previous-gh"
chmod +x "$TEMPLATE_AGENT_HOME/bin/previous-gh"
{
 printf '#!/bin/bash\nif [[ " $* " == *" repos/example/third/git/refs "* ]]; then echo "existing gh denied third" >&2; exit 72; fi\n'
 printf 'exec %q "$@"\n' "$TEMPLATE_AGENT_HOME/bin/previous-gh"
} >"$TEMPLATE_AGENT_HOME/bin/gh"
cp "$TEMPLATE_AGENT_HOME/bin/gh" "$test_dir/expected-gh"
deny
cmp "$test_dir/expected-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
grep -q 'existing gh denied third' "$test_dir/err"
grep -q 'example/third' "$test_dir/err"
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 4 ]]
echo 'PASS guard-check: 印のない既存 gh が三つ目を拒否すると、その理由と直し方を出して全選択の反映前に止まる'

reset_guards
cp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
chmod +x "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
{
 printf '#!/bin/bash\nif [[ $2 == https://github.com/example/third.git ]]; then echo "existing push denied third" >&2; exit 73; fi\n'
 printf 'exec %q "$@"\n' "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
} >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cp "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "$test_dir/expected-push"
deny
cmp "$test_dir/expected-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
grep -q 'existing push denied third' "$test_dir/err"
grep -q 'pre-push が選択先を拒否' "$test_dir/err"
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 5 ]]
echo 'PASS guard-check: 印のない既存 pre-push が後ろの選択を拒否しても、既存ファイルを変えず対処を案内する'

reset_guards
run
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 3 ]]
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 6 ]]
for repo in one two third; do
 [[ $(grep -c "repos/example/$repo/git/refs" "$TEST_GUARD_CALLS") == 2 ]]
done
cmp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos") == example/neighbor ]]
printf 'example/one\nexample/two\nexample/third\n' >"$test_dir/expected-allowed"
cmp "$test_dir/expected-allowed" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
echo 'PASS guard-check: 印のない実際の関所を bash・zsh と起動ファイルから通し、全三リポジトリの確認後に許可を反映する'
TEST_GUARD_RESPONSE=409 run
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 3 ]]
echo 'PASS guard-check: 空リポジトリなどの GitHub の409応答も関所通過として確認し、参照を作らない'

# PATH を直さない古い起動ファイルでは、絶対パスの関所だけを確かめて成功にしない。
for file in .zshenv env.sh; do
 head -n 2 "$root/common/shell/$file" >"$test_dir/package/common/shell/$file"
done
printf 'example/old\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
printf 'old shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
printf 'old bash\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh"
reset_guards
deny
grep -q '通常の gh が関所を選びません' "$test_dir/err"
[[ ! -s $TEST_GUARD_CALLS ]]
echo 'PASS guard-check: 通常の gh が本物を先に選ぶと、通信せず既存の許可と起動ファイルを保って止まる'
