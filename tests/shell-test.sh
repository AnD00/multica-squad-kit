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

# Claude Code の順序をまねて、起動ファイルのあとにスナップショット、CLAUDE_ENV_FILE を読む。
mkdir -p "$test_dir/bin" "$test_dir/other"
commands=(gh)
for file in "$root/common/monitor/"squad-*; do commands+=("${file##*/}"); done
for cmd in "${commands[@]}"; do
	printf '#!/bin/sh\nexit 99\n' >"$test_dir/bin/$cmd"
	chmod +x "$test_dir/bin/$cmd"
done
cp "$test_dir/bin/gh" "$test_dir/other/gh"
export CLAUDE_TEST_PATH="$test_dir/other:/usr/bin:/bin"
printf 'export PATH="$CLAUDE_TEST_PATH"\n' >"$test_dir/snapshot"
export CLAUDE_ENV_FILE="$test_dir/shell files/env.sh"
for shell in /bin/zsh /bin/bash; do
	"$shell" -c '
		set -eu
		. "$1"
		expected_bin=$2
		shift 2
		[[ $(command -v gh) != "$expected_bin/gh" ]]
		. "$CLAUDE_ENV_FILE"
		[[ $PATH == "$expected_bin:$CLAUDE_TEST_PATH" ]]
		for cmd in "$@"; do [[ $(command -v "$cmd") == "$expected_bin/$cmd" ]]; done
		. "$CLAUDE_ENV_FILE"
		[[ $PATH == "$expected_bin:$CLAUDE_TEST_PATH" ]]
	' shell-test "$test_dir/snapshot" "$test_dir/bin" "${commands[@]}"
done
echo 'PASS Claude shell: zsh と bash がスナップショット後に env.sh を読み、関所と全見張りを名前で解決し、PATH を重ねない'
