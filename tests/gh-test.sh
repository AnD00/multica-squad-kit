#!/usr/bin/env bash
# ZIP のルートで bash tests/gh-test.sh を実行する。
# 本物の gh は呼ばず、マージの許可と拒否、元の引数の受け渡しを確かめる。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
guard="$root/common/guard/gh"
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/gh-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export GH_GUARD_TEST_DIR="$test_dir"
export SQUAD_KIT_ALLOWED_REPOS="$test_dir/allowed-repos"
printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
mkdir -p "$test_dir/bin"
export PATH="$test_dir/bin:$PATH"
unset SQUAD_KIT_GH_DEPENDABOT_MERGE GH_HOST

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$GH_GUARD_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
if [[ ${*: -1} == --help ]]; then
	case "$1 ${2:-}" in
	'pr merge')
		cat <<'HELP'
FLAGS
      --admin                   Use administrator privileges
      --auto                    Automatically merge
      --match-head-commit SHA   Commit SHA
  -m, --merge                   Merge commits
  -b, --body text               Commit body

INHERITED FLAGS
  -R, --repo [HOST/]OWNER/REPO   Select repository
HELP
		;;
	'pr comment')
		echo 'FLAGS'
		if [[ ! -f $dir/no-attach ]]; then
			echo "      --attach file            Attach an image or video file, in '<file>#<image alt text>' format"
		fi
		cat <<'HELP'
  -b, --body text               Comment body
  -F, --body-file file          Read body text from file (use "-" to read from standard input)

INHERITED FLAGS
  -R, --repo [HOST/]OWNER/REPO   Select repository
HELP
		;;
	'api --help' | 'api '* )
		cat <<'HELP'
FLAGS
  -X, --method string          HTTP method
  -f, --raw-field key=value    String parameter
      --input file            Request body
      --hostname string       Host
HELP
		;;
	*) echo "Unexpected help: $*" >&2; exit 1 ;;
	esac
	exit
fi
case "$1 ${2:-}" in
'repo view') echo example/template ;;
'pr view')
	[[ ! -f $dir/fail-author ]] || exit 1
	# 模倣している --jq と同じく、bot の作者だけを返す。
	jq -r '.author | select(.is_bot == true) | .login' "$dir/pr.json"
	;;
'pr merge' | 'pr comment' | 'api '*)
	jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/writes.jsonl"
	echo 'mock success'
	;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/gh"

reset_calls() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/writes.jsonl"
}

allow() {
	reset_calls
	bash "$guard" "$@" >"$test_dir/output" 2>"$test_dir/error"
	jq -se --argjson expected "$(jq -cn --args '$ARGS.positional' -- "$@")" \
		'. == [$expected]' "$test_dir/writes.jsonl" >/dev/null
	[[ ! -s $test_dir/error ]]
}

block() {
	local reason=$1
	shift
	reset_calls
	if bash "$guard" "$@" >"$test_dir/output" 2>"$test_dir/error"; then
		echo "拒否されなかった: $*" >&2
		exit 1
	fi
	[[ ! -s $test_dir/writes.jsonl && ! -s $test_dir/output ]]
	grep -qF -- "$reason" "$test_dir/error"
}

printf '%s\n' '{"author":{"is_bot":true,"login":"app/dependabot"}}' >"$test_dir/pr.json"
block '専用エージェントだけ' pr merge 367 --merge --match-head-commit abc123
SQUAD_KIT_GH_DEPENDABOT_MERGE=0 block '専用エージェントだけ' pr merge 367 --merge --match-head-commit abc123
echo 'PASS merge: 環境変数なし・1 以外は拒否'

export SQUAD_KIT_GH_DEPENDABOT_MERGE=1
allow pr merge 367 --merge --match-head-commit abc123
jq -se 'any(.[]; . == ["pr", "view", "367", "--repo", "example/template",
	"--json", "author", "--jq", ".author | select(.is_bot == true) | .login"])' "$test_dir/calls.jsonl" >/dev/null
allow pr merge 367 -Rexample/template --merge --match-head-commit=abc123
allow pr merge https://github.com/example/template/pull/367 --repo example/template --merge --match-head-commit abc123
allow pr merge dependabot/go_modules/example --merge --match-head-commit abc123
allow pr merge --merge --match-head-commit abc123
jq -se 'any(.[]; .[0:4] == ["pr", "view", "--repo", "example/template"])' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS merge: 番号・URL・ブランチ・省略、短い repo フラグ、SHA の = 形式を元の引数で実行'

block '--match-head-commit が必要' pr merge 367 --merge
block '--match-head-commit が必要' pr merge 367 --merge --match-head-commit=
block '--match-head-commit が必要' pr merge 367 --match-head-commit abc123 --match-head-commit=
block '値がない' pr merge 367 --match-head-commit
for flag in --admin --auto --admin=true --auto=false; do
	block 'は使えない' pr merge 367 --merge --match-head-commit abc123 "$flag"
done
block '一意に判定できない' pr merge 367 368 --merge --match-head-commit abc123
echo 'PASS merge: SHA なし・空、禁止フラグ（= 形式を含む）、複数 PR は拒否'

printf '%s\n' '{"author":{"is_bot":false,"login":"human"}}' >"$test_dir/pr.json"
block 'Dependabot 以外' pr merge 367 --merge --match-head-commit abc123
printf '%s\n' '{"author":{"is_bot":true,"login":"app/other"}}' >"$test_dir/pr.json"
block 'Dependabot 以外' pr merge 367 --merge --match-head-commit abc123
printf '%s\n' '{"author":{"is_bot":false,"login":"app/dependabot"}}' >"$test_dir/pr.json"
block 'Dependabot 以外' pr merge 367 --merge --match-head-commit abc123
printf '%s\n' '{"author":null}' >"$test_dir/pr.json"
block 'Dependabot 以外' pr merge 367 --merge --match-head-commit abc123
touch "$test_dir/fail-author"
block '作者を確認できない' pr merge 367 --merge --match-head-commit abc123
rm "$test_dir/fail-author"
echo 'PASS merge: 人間・別 bot・作者不明・取得失敗は拒否'

printf '%s\n' '{"author":{"is_bot":true,"login":"app/dependabot"}}' >"$test_dir/pr.json"
block 'への gh pr merge は止めた' pr merge https://github.com/other/repo/pull/1 --repo example/template --merge --match-head-commit abc123
block 'への gh pr merge は止めた' pr merge 367 --repo other/repo --merge --match-head-commit abc123
GH_HOST=example.com block 'github.com 以外' pr merge 367 --merge --match-head-commit abc123
echo 'PASS merge: 専用の許可があっても、URL 優先・許可先・ホストの制限を守る'

for endpoint in repos/example/template/pulls/367/merge /repos/example/template/pulls/367/merge \
	'repos/example/template/pulls/367/merge?x=1' 'repos/{owner}/{repo}/pulls/367/merge' \
	repos/example/template/pulls/367/merge/; do
	block 'API でのマージは止めた' api -X PUT "$endpoint" -f sha=abc123
done
SQUAD_KIT_GH_DEPENDABOT_MERGE=0 block 'API でのマージは止めた' api repos/example/template/pulls/367/merge --method=put --input body.json
block 'mutation は止めた' api graphql -f 'query=mutation { mergePullRequest(input: {}) { clientMutationId } }'
echo 'PASS api: マージは許可変数によらず拒否（先頭 /・query・プレースホルダー・GraphQL も含む）'

for permission in 0 1; do
	for author in '{"is_bot":true,"login":"app/dependabot"}' '{"is_bot":false,"login":"human"}'; do
		jq -n --argjson author "$author" '{author:$author}' >"$test_dir/pr.json"
		for endpoint in 'repos/example/template/pulls/367/merge#review-proof' \
			'/repos/example/template/pulls/367/merge#' \
			'repos/example/template/pulls/367/merge/#review-proof' \
			'repos/example/template/pulls/367/merge?x=1#review-proof' \
			'repos/{owner}/{repo}/pulls/367/merge#review-proof'; do
			SQUAD_KIT_GH_DEPENDABOT_MERGE=$permission block '正規化できない endpoint' api -X PUT "$endpoint" -f sha=abc123
		done
	done
done
echo 'PASS api: フラグメント付きのマージは、専用の許可や作者によらず本物の gh へ渡さない'

allow api repos/example/template/pulls/367/merge
allow api -X HEAD repos/example/template/pulls/367/merge
allow api repos/example/template/issues/367/comments -f body=test
allow pr comment 367 --body '--admin --auto --match-head-commit'
block 'への 書き込み' api -X POST repos/other/repo/issues -f title=test
echo 'PASS 既存操作: マージ済みかの取得、コメント、許可先以外への書き込みの拒否'

allow pr comment 367 --body-file body.md --attach './shot.png#説明'
allow pr comment https://github.com/example/template/pull/367 --attach shot.png
allow pr comment https://github.com/example/template/pull/367 --attach=shot.png
echo 'PASS attach: 本文ファイル・画像の説明・PR の URL・= 形式を元の引数で実行'

block 'other/repo への gh pr comment は止めた' pr comment https://github.com/other/repo/pull/1 --attach shot.png
block 'other/repo への gh pr comment は止めた' pr comment 367 --repo other/repo --attach shot.png
block '値がない' pr comment 367 --attach
echo 'PASS attach: URL・repo フラグの許可先以外と、値なしは拒否'

touch "$test_dir/no-attach"
block 'フラグの型が分からない' pr comment 367 --attach shot.png
rm "$test_dir/no-attach"
echo 'PASS attach: 古い gh のヘルプでは拒否し、本物に書き込まない'

# ランタイムが本物の gh を先に置いた PATH を渡しても、通常のシェルから拒否する。
# 関所を絶対パスで呼ぶテストだけでは、この抜け道を見つけられない。
guard_bin="$test_dir/agent's home/bin"
shell_dir="$test_dir/project shell"
mkdir -p "$guard_bin" "$shell_dir"
cp "$guard" "$guard_bin/gh"
chmod +x "$guard_bin/gh"
escaped_bin=${guard_bin//\'/\'\\\'\'}
for file in .zshenv env.sh; do
	content=$(cat "$root/common/shell/$file")
	content=${content//\{\{ALLOWED_REPOS_FILE\}\}/$SQUAD_KIT_ALLOWED_REPOS}
	content=${content//\{\{AGENT_BIN_DIR\}\}/$escaped_bin}
	printf '%s\n' "$content" >"$shell_dir/$file"
done
for shell in /bin/bash /bin/zsh; do
	reset_calls
	PATH="$test_dir/bin:$guard_bin:$PATH" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c 'command -v gh' >"$test_dir/selected-gh"
	[[ $(cat "$test_dir/selected-gh") == "$guard_bin/gh" ]]
	PATH="$test_dir/bin:$guard_bin:$PATH" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c 'gh api -X POST repos/example/template/issues -f title=test' >"$test_dir/output" 2>"$test_dir/error"
	jq -se 'length==1' "$test_dir/writes.jsonl" >/dev/null
	reset_calls
	if PATH="$test_dir/bin:$guard_bin:$PATH" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c 'gh api -X POST repos/other/repo/issues -f title=test' >"$test_dir/output" 2>"$test_dir/error"; then
		echo "通常の $shell からの許可外の書き込みが拒否されなかった" >&2
		exit 1
	fi
	[[ ! -s $test_dir/writes.jsonl && ! -s $test_dir/output ]]
	grep -q '^gh の関所:.*other/repo.*への 書き込み' "$test_dir/error"
done
echo 'PASS PATH: 本物の gh が先でも bash・zsh の起動時に関所が先になり、許可先だけを本物へ渡す'

# Claude Code は起動ファイルのあとに snapshot の PATH を書き戻し、
# CLAUDE_ENV_FILE の中身をコマンドの直前へ && でつなぐ。
runtime_path="$test_dir/bin:$guard_bin:$PATH"
printf 'export PATH=%q\n' "$runtime_path" >"$test_dir/claude-snapshot.sh"
snapshot_command=$(printf 'source %q' "$test_dir/claude-snapshot.sh")
export CLAUDE_ENV_FILE="$shell_dir/env.sh"
claude_env=$(cat "$CLAUDE_ENV_FILE")
for shell in /bin/bash /bin/zsh; do
	reset_calls
	PATH="$runtime_path" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c "$snapshot_command && command -v gh" >"$test_dir/selected-gh"
	[[ $(cat "$test_dir/selected-gh") == "$test_dir/bin/gh" ]]
	echo "PASS Claude PATH ($shell): env の中身なしでは snapshot が本物の gh を先に戻す"

	PATH="$runtime_path" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c "$snapshot_command && $claude_env && command -v gh" >"$test_dir/selected-gh"
	[[ $(cat "$test_dir/selected-gh") == "$guard_bin/gh" ]]
	echo "PASS Claude PATH ($shell): snapshot のあとに env の中身を流すと関所を選ぶ"

	: >"$SQUAD_KIT_ALLOWED_REPOS"
	reset_calls
	if PATH="$runtime_path" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c "$snapshot_command && $claude_env && gh api -X POST repos/example/template/issues -f title=test" >"$test_dir/output" 2>"$test_dir/error"; then
		echo "Claude の順の $shell からの空の許可での書き込みが拒否されなかった" >&2
		exit 1
	fi
	[[ ! -s $test_dir/writes.jsonl && ! -s $test_dir/output ]]
	grep -q '^gh の関所:.*example/template.*への 書き込み' "$test_dir/error"
	echo "PASS Claude PATH ($shell): 空の許可では関所の文言で拒否し、本物に書き込まない"

	printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
	reset_calls
	PATH="$runtime_path" ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" \
		"$shell" -c "$snapshot_command && $claude_env && gh api -X POST repos/example/template/issues -f title=test" >"$test_dir/output" 2>"$test_dir/error"
	jq -se '. == [["api","-X","POST","repos/example/template/issues","-f","title=test"]]' "$test_dir/writes.jsonl" >/dev/null
	[[ ! -s $test_dir/error ]]
	echo "PASS Claude PATH ($shell): 許可先への書き込みを本物に 1 回だけ渡す"
done
