#!/usr/bin/env bash
# CLI と API と時計を差し替え、実際のタスク・PR には触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-link-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export PR_LINK_TEST_DIR=$test_dir
script=$root/common/monitor/squad-pr-link
mkdir -p "$test_dir/bin" "$test_dir/work/tmp"
# curl がないケースも、ホストの実物を呼ばない。
for cmd in bash dirname jq tr cat; do
	ln -s "$(command -v "$cmd")" "$test_dir/bin/$cmd"
done
cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/multica.jsonl"
if [[ $1 == issue && $2 == get ]]; then
	[[ $3 == TASK-7 || $3 == task-id ]]
	[[ $4 == --output && $5 == json ]]
	if [[ -f $dir/get-fail ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
	cat "$dir/issue.json"
elif [[ $1 == issue && $2 == metadata && $3 == set ]]; then
	[[ $4 == task-id && $5 == --key && $6 == pr_url && $7 == --value ]]
	[[ $9 == --type && ${10} == string ]]
	if [[ -f $dir/set-fail ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
	jq --arg url "$8" '.metadata.pr_url = $url' "$dir/issue.json" >"$dir/next.json"
	/bin/mv "$dir/next.json" "$dir/issue.json"
else
	exit 99
fi
MOCK
cat >"$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/curl.jsonl"
[[ $1 == -q && $2 == --config && $3 == - ]]
config=$(cat)
[[ $config == "header = \"Authorization: Bearer $MULTICA_TOKEN\"" ]]
echo verified >"$dir/config-verified"
[[ " $* " == *' -o /dev/null '* && " $* " == *' -w %{http_code} '* ]]
if [[ -f $dir/transport-fail ]]; then
	echo "$MULTICA_TOKEN" >&2
	exit 7
fi
calls=$(<"$dir/curl-count")
args=("$@")
max_time=0
for ((i = 0; i < ${#args[@]}; i++)); do
	if [[ ${args[i]} == --max-time ]]; then max_time=${args[i+1]}; fi
done
[[ $max_time -gt 0 && $max_time -le 30 ]]
duration=$(jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/durations.json")
echo "$(<"$dir/now")" >>"$dir/curl-starts"
echo "$((calls + 1))" >"$dir/curl-count"
if (( duration >= max_time )) && [[ ! -f $dir/ignore-timeout ]]; then
	echo "$(($(<"$dir/now") + max_time))" >"$dir/now"
	printf '000'
	exit 28
fi
echo "$(($(<"$dir/now") + duration))" >"$dir/now"
jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/statuses.json"
MOCK
cat >"$test_dir/bin/date" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ $* == +%s ]]
cat "$PR_LINK_TEST_DIR/now"
MOCK
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ $# == 1 && $1 -gt 0 && $1 -le 10 ]]
dir=$PR_LINK_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/now") + $1))" >"$dir/now"
MOCK
chmod +x "$test_dir/bin/multica" "$test_dir/bin/curl" "$test_dir/bin/date" "$test_dir/bin/sleep"
test_token=pr-link-test-secret-token
export MULTICA_TOKEN=$test_token
export MULTICA_SERVER_URL=https://multica.invalid/
export MULTICA_WORKSPACE_ID=workspace-id
url=https://github.com/Example/Template/pull/33

fixture() {
	printf '{"id":"task-id","identifier":"TASK-7","metadata":{"repository":"example/template"}}\n' >"$test_dir/issue.json"
	printf '[200]\n' >"$test_dir/statuses.json"
	printf '[0]\n' >"$test_dir/durations.json"
	echo 1000 >"$test_dir/now"
	echo 0 >"$test_dir/curl-count"
	: >"$test_dir/multica.jsonl"
	: >"$test_dir/curl.jsonl"
	: >"$test_dir/curl-starts"
	: >"$test_dir/sleeps"
	rm -f "$test_dir/get-fail" "$test_dir/set-fail" "$test_dir/transport-fail" "$test_dir/config-verified" "$test_dir/ignore-timeout"
}
run_link() {
	local expected=$1 status=0
	shift
	(cd "$test_dir/work"; PATH="$test_dir/bin" /bin/bash "$script" "$@") \
		>"$test_dir/out" 2>"$test_dir/err" || status=$?
	if [[ $status != "$expected" ]]; then
		echo "FAIL pr-link: status=$status, expected=$expected" >&2
		cat "$test_dir/out" "$test_dir/err" >&2
		return 1
	fi
	# トークンは引数・出力・一時ファイルのどこにも保存されない。
	if grep -rlF -- "$test_token" "$test_dir"; then
		echo 'FAIL pr-link: トークンがファイルに残った' >&2
		return 1
	fi
}
assert_warning() {
	[[ ! -s $test_dir/out ]]
	grep -F "タスク TASK-7 に PR $url を紐付けられませんでした" "$test_dir/err" >/dev/null
	grep -F 'タスクの画面の PR の欄で、この URL を指定して紐付けてください。' "$test_dir/err" >/dev/null
	jq -e '.metadata | has("pr_url") | not' "$test_dir/issue.json" >/dev/null
}
assert_no_write() {
	jq -se 'all(.[]; .[0:3] != ["issue","metadata","set"])' "$test_dir/multica.jsonl" >/dev/null
}

fixture
run_link 0 TASK-7 "$url"
[[ $(cat "$test_dir/out") == "TASK-7 $url" && ! -s $test_dir/err ]]
[[ $(cat "$test_dir/config-verified") == verified ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
jq -se --arg url "$url" 'length == 1 and (.[0] | .[-1] == "https://multica.invalid/api/issues/task-id/pull-requests"
	and (index("POST") != null) and (index("Content-Type: application/json") != null)
	and (index("X-Workspace-ID: workspace-id") != null)
	and (.[index("--data")+1] | fromjson) == {url:$url})' "$test_dir/curl.jsonl" >/dev/null
jq -se --arg url "$url" '.[1] == ["issue","metadata","set","task-id","--key","pr_url","--value",$url,"--type","string"]' "$test_dir/multica.jsonl" >/dev/null
[[ ! -s $test_dir/sleeps ]]
echo 'PASS link: ID・API の URL・本文・見出し・metadata・出力、トークンは標準入力だけ'

fixture
unset MULTICA_WORKSPACE_ID
run_link 0 task-id "$url"
jq -se '.[0] | index("-H") != null and index("X-Workspace-ID: workspace-id") == null' "$test_dir/curl.jsonl" >/dev/null
export MULTICA_WORKSPACE_ID=workspace-id
echo 'PASS link: タスクの ID も受け取り、workspace がなくても紐付ける'

for existing in "$url" https://github.com/Example/Template/pull/44; do
	fixture
	jq --arg url "$existing" '.metadata.pr_url = $url' "$test_dir/issue.json" >"$test_dir/next.json"
	mv "$test_dir/next.json" "$test_dir/issue.json"
	cp "$test_dir/issue.json" "$test_dir/before.json"
	# 紐付け済みの判定は、認証の確認より先に行う。
	MULTICA_TOKEN='' run_link 0 TASK-7 "$url"
	cmp "$test_dir/issue.json" "$test_dir/before.json"
	[[ ! -s $test_dir/curl.jsonl && $(cat "$test_dir/out") == "TASK-7 $existing" ]]
	assert_no_write
	if [[ $existing == "$url" ]]; then [[ ! -s $test_dir/err ]]; else
		[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 1 ]]
		grep -F '違うため、紐付けは変えません' "$test_dir/err" >/dev/null
	fi
done
echo 'PASS skip: pr_url があれば API と書き込みを飛ばし、別の URL なら 1 行知らせる'

fixture
printf '[404,404,200]\n' >"$test_dir/statuses.json"
run_link 0 TASK-7 "$url"
[[ $(cat "$test_dir/curl-count") == 3 && $(cat "$test_dir/now") == 1020 ]]
[[ $(wc -l <"$test_dir/sleeps" | tr -d ' ') == 2 ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
echo 'PASS retry: 404 の間は 10 秒ごとに待ち、200 になってから metadata を書く'

fixture
printf '[404,404,404,200]\n' >"$test_dir/statuses.json"
printf '[29,29,29,29]\n' >"$test_dir/durations.json"
run_link 1 TASK-7 "$url"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1120 ]]
jq -se 'map(.[index("--max-time")+1]) == ["30","30","30","3"]' "$test_dir/curl.jsonl" >/dev/null
[[ $(cat "$test_dir/curl-starts") == $'1000\n1039\n1078\n1117' ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
echo 'PASS HTTP timeout: 通信の時間を含めて 120 秒で打ち切り、最後の通信は残り 3 秒に制限する'

for duration in 3 4; do
	for code in 200 404; do
		fixture
		printf '[404,404,404,%s]\n' "$code" >"$test_dir/statuses.json"
		printf '[29,29,29,%s]\n' "$duration" >"$test_dir/durations.json"
		# curl の制限を超えて応答が返っても、期限後は採用しない。
		touch "$test_dir/ignore-timeout"
		run_link 1 TASK-7 "$url"
		assert_warning
		assert_no_write
		[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == $((1117 + duration)) ]]
		grep -F '120 秒待った' "$test_dir/err" >/dev/null
	done
done
echo 'PASS late response: 期限ちょうど・期限後の 200 と 404 では、成功扱いも metadata の書き込みもしない'

fixture
printf '[404,404,404,200]\n' >"$test_dir/statuses.json"
printf '[29,29,29,2]\n' >"$test_dir/durations.json"
run_link 0 TASK-7 "$url"
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1119 ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
echo 'PASS slow success: 通信に時間がかかっても期限内の 200 なら metadata を書く'

fixture
printf '[404]\n' >"$test_dir/statuses.json"
printf '[29,29,29,2]\n' >"$test_dir/durations.json"
run_link 1 TASK-7 "$url"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1120 ]]
[[ $(cat "$test_dir/sleeps") == $'10\n10\n10\n1' ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
echo 'PASS short sleep: 残り 1 秒なら待ちも 1 秒に制限し、期限以降は通信しない'

fixture
printf '[404]\n' >"$test_dir/statuses.json"
run_link 1 TASK-7 "$url"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 12 && $(cat "$test_dir/now") == 1120 ]]
[[ $(wc -l <"$test_dir/sleeps" | tr -d ' ') == 12 ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
echo 'PASS timeout: 120 秒で打ち切り、警告と画面の手順を返し、metadata は書かない'

for code in 201 400 401 403 422 500; do
	fixture
	printf '[%s]\n' "$code" >"$test_dir/statuses.json"
	run_link 1 TASK-7 "$url"
	assert_warning
	assert_no_write
	[[ $(cat "$test_dir/curl-count") == 1 && ! -s $test_dir/sleeps ]]
	grep -F "応答の状態コード $code" "$test_dir/err" >/dev/null
done
echo 'PASS HTTP error: 200 と 404 以外では待たず、警告して失敗を返す'

for missing in token server curl; do
	fixture
	case $missing in
	token) MULTICA_TOKEN='' run_link 1 TASK-7 "$url" ;;
	server) MULTICA_SERVER_URL='' run_link 1 TASK-7 "$url" ;;
	curl)
		mv "$test_dir/bin/curl" "$test_dir/curl-stub"
		run_link 1 TASK-7 "$url"
		mv "$test_dir/curl-stub" "$test_dir/bin/curl"
		;;
	esac
	assert_warning
	assert_no_write
	[[ ! -s $test_dir/curl.jsonl && ! -s $test_dir/sleeps ]]
done
echo 'PASS missing: トークン・サーバーの URL・curl がなくても警告して失敗を返す'

for failure in get set transport; do
	fixture
	touch "$test_dir/$failure-fail"
	run_link 1 TASK-7 "$url"
	assert_warning
	[[ ! -s $test_dir/sleeps ]]
	if [[ $failure != set ]]; then assert_no_write; fi
done
echo 'PASS failures: タスクの読み取り・通信・metadata の失敗の診断を漏らさない'

for invalid in 'null' '[]' '{}' '{"id":"task-id","identifier":"TASK-7","metadata":[]}'; do
	fixture
	printf '%s\n' "$invalid" >"$test_dir/issue.json"
	run_link 1 TASK-7 "$url"
	[[ ! -s $test_dir/curl.jsonl ]]
	grep -F 'タスクを読めない' "$test_dir/err" >/dev/null
	assert_no_write
done
echo 'PASS issue: タスクの応答が読めない場合は紐付けない'

fixture
run_link 1 TASK-7 https://github.com/Other/Template/pull/33
[[ ! -s $test_dir/curl.jsonl ]]
assert_no_write
grep -F 'metadata の repository と違う' "$test_dir/err" >/dev/null
fixture
printf '{"id":"task-id","identifier":"TASK-7","metadata":{}}\n' >"$test_dir/issue.json"
run_link 0 TASK-7 "$url"
echo 'PASS repository: 大文字小文字を区別せず照合し、値がなければ紐付ける'

for invalid in http://github.com/Example/Template/pull/33 https://example.com/Example/Template/pull/33 \
	"$url/files" "$url/" "$url?x=1" "$url#diff" https://github.com/Example/Template/pull/abc; do
	fixture
	run_link 2 TASK-7 "$invalid"
	[[ ! -s $test_dir/multica.jsonl && ! -s $test_dir/curl.jsonl ]]
	grep -F '使い方:' "$test_dir/err" >/dev/null
done
fixture
run_link 2
run_link 2 TASK-7
run_link 2 TASK-7 "$url" extra
run_link 2 '' "$url"
[[ ! -s $test_dir/multica.jsonl && ! -s $test_dir/curl.jsonl ]]
echo 'PASS arguments: 個数・空のタスク・URL の形が違えば、使い方と終了コード 2'
