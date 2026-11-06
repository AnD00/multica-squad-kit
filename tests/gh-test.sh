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
		cat <<'HELP'
FLAGS
  -b, --body text               Comment body

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
