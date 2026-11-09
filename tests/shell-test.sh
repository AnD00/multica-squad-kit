#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/shell.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir "$test_dir/shell files"
allowed="$test_dir/project repos"
printf '%s\n' example/template >"$allowed"
for file in .zshenv env.sh; do
	grep -qx '# multica-squad-kit-managed' "$root/common/shell/$file"
	[[ $(grep -c '^export SQUAD_KIT_ALLOWED_REPOS=' "$root/common/shell/$file") == 1 ]]
	sed -e "s|{{ALLOWED_REPOS_FILE}}|$allowed|g" -e "s|{{AGENT_BIN_DIR}}|$test_dir/bin|g" "$root/common/shell/$file" >"$test_dir/shell files/$file"
done
cmp "$test_dir/shell files/.zshenv" "$test_dir/shell files/env.sh"
# 親が別の値を持っていても、シェルの起動時にプロジェクトの値になる。
export SQUAD_KIT_ALLOWED_REPOS=parent-value
export ZDOTDIR="$test_dir/shell files" BASH_ENV="$test_dir/shell files/env.sh"
for shell in /bin/zsh /bin/bash; do
	[[ $("$shell" -c 'printf "%s" "$SQUAD_KIT_ALLOWED_REPOS"') == "$allowed" ]]
	# シェルのさらに先の子プロセスにも渡る。
	[[ $("$shell" -c '/usr/bin/printenv SQUAD_KIT_ALLOWED_REPOS') == "$allowed" ]]
done
echo 'PASS shell: zsh と bash が起動時に読み、子プロセスにも渡す'
# bash のスクリプト（関所）も BASH_ENV を読む。
if /bin/bash "$root/common/guard/pre-push" origin https://github.com/other/repo.git >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q 'example/template' "$test_dir/err"
echo 'PASS shell: pre-push がプロジェクトのファイルを読む'
