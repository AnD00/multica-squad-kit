#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/preflight.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/guard bin" "$test_dir/tools" "$test_dir/other"
guard_bin="$test_dir/guard bin"
cp "$root/common/monitor/squad-preflight" "$guard_bin/squad-preflight"
chmod +x "$guard_bin/squad-preflight"
# PATH を閉じ、ホストの gh や見張りへ抜けないようにする。
for cmd in bash dirname cat jq python3; do
	ln -s "$(command -v "$cmd")" "$test_dir/tools/$cmd"
done
cat >"$test_dir/stub" <<'STUB'
#!/bin/bash
echo called >>"$PREFLIGHT_TEST_CALLED"
exit 99
STUB
export PREFLIGHT_TEST_CALLED="$test_dir/called"
export PREFLIGHT_TEST_DIR=$test_dir PREFLIGHT_TEST_ROOT=$root MULTICA_AGENT_ID=fixture-agent
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
mkdir -p "$test_dir/responses"
reset_responses() {
	local name
	for name in squad-list agent-get issue-get issue-comments issue-runs issue-wakeups; do
		jq '.[0]' "$root/tests/fixtures/cli/$name.json" >"$test_dir/responses/$name.json"
	done
	rm -f "$test_dir/allow-missing-fields" "$test_dir/cli-fail"
}
reset_responses
head -n 1 "$root/tests/fixtures/cli/VERSION" >"$test_dir/version"
cat >"$test_dir/tools/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
work=$PREFLIGHT_TEST_DIR
stub_args=("$@")
stub() { recorded=1; python3 "$PREFLIGHT_TEST_ROOT/tests/cli-stub.py" multica "$work" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ "$*" == version ]]; then stub record; cat "$work/version"; exit 0; fi
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
case "${1-} ${2-} ${3-}" in
'squad list --output') name=squad-list ;;
'agent get fixture-agent') name=agent-get ;;
'issue get fixture-issue') name=issue-get ;;
'issue comment list') name=issue-comments ;;
'issue runs fixture-issue') name=issue-runs ;;
'issue wakeup list') name=issue-wakeups ;;
*) echo "Unexpected mock call: $*" >&2; exit 99 ;;
esac
if [[ -f $work/cli-fail && $(cat "$work/cli-fail") == "$name" ]]; then
	echo 'mock CLI failure' >&2; exit 19
fi
stub emit "$name" "$work/responses/$name.json"
STUB
chmod +x "$test_dir/tools/multica"
monitors=()
for file in "$root/common/monitor/"squad-*; do
	cmd=${file##*/}
	[[ $cmd != squad-preflight ]] || continue
	monitors+=("$cmd")
done
for cmd in gh "${monitors[@]}"; do
	cp "$test_dir/stub" "$guard_bin/$cmd"
	chmod +x "$guard_bin/$cmd"
done

# 本物のセットアップの関数で、採取バージョンを埋めたライブラリを作る。
source "$root/lib/host.sh"
agent_home="$test_dir/installed"
mkdir -p "$agent_home/bin"
host_cli_library
cp "$agent_home/bin/squad-cli-lib" "$guard_bin/squad-cli-lib"

run_preflight() {
	local expected=$1 test_path=$2 status=0
	shift 2
	: >"$test_dir/calls.jsonl"
	BASH_ENV= PATH="$test_path" /bin/bash -c 'squad-preflight "$@"' -- "$@" \
		>"$test_dir/out" 2>"$test_dir/err" || status=$?
	if [[ $status != "$expected" ]]; then
		cat "$test_dir/out" "$test_dir/err" >&2
		echo "FAIL preflight: status=$status (expected $expected)" >&2
		exit 1
	fi
	[[ ! -e $PREFLIGHT_TEST_CALLED ]]
}
assert_failure() {
	local cmd=$1 actual=$2
	[[ ! -s $test_dir/out ]]
	[[ ! -s $test_dir/calls.jsonl ]]
	grep -Fq "squad-preflight: $cmd が使えません。実際の解決先: ${actual}（期待: $guard_bin/${cmd}）" "$test_dir/err"
	grep -q '動いているタスクがないときに、同じプロジェクトでセットアップを流し直' "$test_dir/err"
}

run_preflight 0 "$guard_bin:$test_dir/tools"
[[ $(wc -l <"$test_dir/out") -eq 3 && ! -s $test_dir/err ]]
grep -q 'すべての見張りが使えます' "$test_dir/out"
jq -se 'map(select(.[0]!="version")) == [["squad","list","--output","json"],["agent","get","fixture-agent","--output","json"]]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS preflight: 正常時は関所を確認してから2種類を読み、gh と見張り本体は実行しない'

run_preflight 0 "$guard_bin:$test_dir/tools" fixture-issue
[[ $(wc -l <"$test_dir/out") -eq 7 && ! -s $test_dir/err ]]
jq -se 'map(select(.[0]!="version")) == [
 ["squad","list","--output","json"], ["agent","get","fixture-agent","--output","json"],
 ["issue","get","fixture-issue","--output","json"],
 ["issue","comment","list","fixture-issue","--full","--output","json"],
 ["issue","runs","fixture-issue","--output","json"],
 ["issue","wakeup","list","fixture-issue","--output","json"]]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS preflight: タスクありでは6種類を読み、正常な省略と null を受け入れる'

cat >"$test_dir/child-env.sh" <<'STUB'
echo repaired >"$PREFLIGHT_TEST_DIR/repaired"
export PATH="$PREFLIGHT_TEST_DIR/other:$PATH"
STUB
status=0
BASH_ENV="$test_dir/child-env.sh" PATH="$guard_bin:$test_dir/tools" /bin/sh "$guard_bin/squad-preflight" fixture-issue \
	>"$test_dir/out" 2>"$test_dir/err" || status=$?
[[ $status == 0 && ! -e $test_dir/repaired && ! -s $test_dir/err ]]
echo 'PASS preflight: 欄を読む子のBashも、BASH_ENVを読み直してPATHを変えない'

for name in squad-list issue-comments issue-runs issue-wakeups; do echo '[]' >"$test_dir/responses/$name.json"; done
run_preflight 0 "$guard_bin:$test_dir/tools" fixture-issue
[[ $(grep -c '確かめられない（空）' "$test_dir/out") == 4 ]]
reset_responses
echo 'PASS preflight: 空の一覧は確かめられないことを知らせ、失敗にしない'

for pair in squad-list:id agent-get:name issue-get:metadata issue-comments:source_task_id issue-runs:trigger_comment_id issue-wakeups:condition.type; do
	reset_responses
	name=${pair%%:*}; field=${pair#*:}
	case $name in
	 squad-list) expression='map(del(.id))' ;;
	 agent-get) expression='del(.name)' ;;
	 issue-get) expression='del(.metadata)' ;;
	 issue-comments) expression='map(if .author_type=="agent" then del(.source_task_id) else . end)' ;;
	 issue-runs) expression='map(if .kind=="comment" then del(.trigger_comment_id) else . end)' ;;
	 issue-wakeups) expression='map(if .condition!=null then del(.condition.type) else . end)' ;;
	esac
	jq "$expression" "$test_dir/responses/$name.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/responses/$name.json"
	: >"$test_dir/allow-missing-fields"
	run_preflight 1 "$guard_bin:$test_dir/tools" fixture-issue
	grep -qF "$name の $field" "$test_dir/err"
	grep -qF "$(head -n 1 "$test_dir/version")" "$test_dir/err"
done
reset_responses
echo 'PASS preflight: 6種類の必須・条件付きの欠落で、欄名・CLIのバージョンを出して終了1'

echo 'multica fixture-upgrade' >"$test_dir/version"
run_preflight 0 "$guard_bin:$test_dir/tools" fixture-issue
grep -qF 'CLI のバージョンが見本と違います' "$test_dir/out"
grep -qF "$(head -n 1 "$root/tests/fixtures/cli/VERSION")" "$test_dir/out"
head -n 1 "$root/tests/fixtures/cli/VERSION" >"$test_dir/version"
echo 'PASS preflight: 採取時と違うバージョンは知らせるだけで、欄が正しければ成功する'

echo squad-list >"$test_dir/cli-fail"
run_preflight 1 "$guard_bin:$test_dir/tools"
grep -qF 'mock CLI failure' "$test_dir/err"
reset_responses
echo 'PASS preflight: CLI自体の失敗では、検証成功に進めない'

unset MULTICA_AGENT_ID
run_preflight 1 "$guard_bin:$test_dir/tools"
grep -qF MULTICA_AGENT_ID "$test_dir/err"
[[ ! -s "$test_dir/calls.jsonl" ]]
export MULTICA_AGENT_ID=fixture-agent
run_preflight 2 "$guard_bin:$test_dir/tools" first second
grep -qF '使い方: squad-preflight [<タスク>]' "$test_dir/err"
[[ ! -s "$test_dir/calls.jsonl" ]]
echo 'PASS preflight: エージェントID不足と余分な引数を明示して失敗する'


cp "$test_dir/stub" "$test_dir/other/gh"
chmod +x "$test_dir/other/gh"
run_preflight 1 "$test_dir/other:$guard_bin:$test_dir/tools"
assert_failure gh "$test_dir/other/gh"
grep -q 'CLAUDE_ENV_FILE（Claude）か custom_args（Codex）' "$test_dir/err"
echo 'PASS preflight: 別の gh が先にあると、解決先とランタイムの直し方を出す'

mv "$guard_bin/gh" "$test_dir/gh.saved"
run_preflight 1 "$guard_bin:$test_dir/tools"
assert_failure gh 見つからない
mv "$test_dir/gh.saved" "$guard_bin/gh"
echo 'PASS preflight: gh の欠落を報告する'

for cmd in "${monitors[@]}"; do
	mv "$guard_bin/$cmd" "$test_dir/monitor.saved"
	run_preflight 1 "$guard_bin:$test_dir/tools"
	assert_failure "$cmd" 見つからない
	grep -q '見張りを置き直してください' "$test_dir/err"
	[[ $(grep -c 'が使えません' "$test_dir/err") == 1 ]]
	mv "$test_dir/monitor.saved" "$guard_bin/$cmd"
done
echo 'PASS preflight: 配布する見張りをそれぞれ欠落させ、確認の一覧の書き忘れを検出する'

cp "$test_dir/stub" "$test_dir/other/squad-pr-watch"
chmod +x "$test_dir/other/squad-pr-watch"
run_preflight 1 "$test_dir/other:$guard_bin:$test_dir/tools"
assert_failure squad-pr-watch "$test_dir/other/squad-pr-watch"
assert_failure gh "$test_dir/other/gh"
[[ $(grep -c 'が使えません' "$test_dir/err") == 2 ]]
echo 'PASS preflight: 別の見張りが先にある場合と、複数の不一致をまとめて報告する'

# 親の起動後に PATH が崩れた場合も、確認用シェルだけが修復して成功してはいけない。
sed -e "s|{{AGENT_BIN_DIR}}|$guard_bin|g" -e "s|{{ALLOWED_REPOS_FILE}}|$test_dir/allowed|g" \
	"$root/common/shell/env.sh" >"$test_dir/env.sh"
for shell in /bin/bash /bin/zsh; do
	BASH_ENV="$test_dir/env.sh" "$shell" -c '
		export PATH="$1"
		command -v gh >"$2/before"
		preflight_status=0
		squad-preflight >"$2/out" 2>"$2/err" || preflight_status=$?
		command -v gh >"$2/after"
		test "$preflight_status" = 1
	' preflight-test "$test_dir/other:$guard_bin:$test_dir/tools" "$test_dir"
	grep -qxF "$test_dir/other/gh" "$test_dir/before"
	cmp "$test_dir/before" "$test_dir/after"
	assert_failure gh "$test_dir/other/gh"
	assert_failure squad-pr-watch "$test_dir/other/squad-pr-watch"
	[[ $(grep -c 'が使えません' "$test_dir/err") == 2 ]]
	[[ ! -e $PREFLIGHT_TEST_CALLED ]]
done
echo 'PASS preflight: BASH_ENV が有効でも、bash と zsh の親が渡した PATH の不一致を検出する'

# すべて外した結果と配布元を照合し、余分な確認対象も検出する。
for cmd in gh "${monitors[@]}"; do mv "$guard_bin/$cmd" "$test_dir/$cmd.saved"; done
run_preflight 1 "$guard_bin:$test_dir/tools"
for cmd in gh "${monitors[@]}"; do assert_failure "$cmd" 見つからない; done
[[ $(grep -c 'が使えません' "$test_dir/err") == $((${#monitors[@]} + 1)) ]]
echo 'PASS preflight: 確認する一覧が配布する全見張りと一致する'

run_preflight 127 "$test_dir/tools"
echo 'PASS preflight: PATH に関所のディレクトリがなければ、名前での呼び出しが 127 で失敗する'
