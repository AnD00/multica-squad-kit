#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-check-test.sh で実行する。
# 実際の使用量の取得と issue 作成は行わず、出力と状態の変化を CLI のモックで確かめる。
set -euo pipefail
unset USAGE_CHECK_RUNTIMES
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/usage-check-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
script=$root/common/monitor/squad-usage-check
source "$(dirname "$script")/squad-usage-lib"
awk '/^[a-z_]+\(\) \{/ {inside=1} inside {print} /^}$/ {inside=0}' "$script" >"$test_dir/functions.sh"
source "$test_dir/functions.sh"

USAGE_CHECK_ASSIGNEE='テスト担当者 名前'
USAGE_CHECK_PROJECT=test-project
USAGE_CHECK_MEMBER=member-a
STATE_FILE=$test_dir/state.json
LABEL_NAME=運用
label_failed=false
USAGE_WARN_PERCENT=80

# 読み取りだけを偽物にし、行のキー・状態・表示を現行の出力に固定する。
mkdir -p "$test_dir/bin"
export USAGE_TEST_DIR=$test_dir
export PATH="$test_dir/bin:$PATH"
export TZ=UTC
cat >"$test_dir/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-p /usage --output-format json' ]]
printf 'claude\n' >>"$USAGE_TEST_DIR/runtime-calls"
cat "$USAGE_TEST_DIR/claude.json"
cat "$USAGE_TEST_DIR/claude.err" >&2
exit "$(cat "$USAGE_TEST_DIR/claude.status")"
MOCK
cat >"$test_dir/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == app-server ]]
printf 'codex\n' >>"$USAGE_TEST_DIR/runtime-calls"
for _ in 1 2 3; do
	IFS= read -r request
	printf '%s\n' "$request" >>"$USAGE_TEST_DIR/requests.jsonl"
done
cat "$USAGE_TEST_DIR/codex.jsonl"
cat >/dev/null
MOCK
chmod +x "$test_dir/bin/claude" "$test_dir/bin/codex"
: >"$test_dir/claude.err"
echo 0 >"$test_dir/claude.status"

assert_fetch() {
	"fetch_$1" >"$test_dir/actual" 2>"$test_dir/err"
	diff -u "$test_dir/expected" "$test_dir/actual"
	test ! -s "$test_dir/err"
}

assert_fetch_error() {
	if "fetch_$1" >"$test_dir/actual" 2>"$test_dir/err"; then
		echo "FAIL $1: 読み取りが失敗していない" >&2
		exit 1
	fi
	test ! -s "$test_dir/actual"
	diff -u "$test_dir/expected" "$test_dir/err"
}

jq -cn --arg result '使用量:
Current session: 79% used · resets Oct 27 at 12:29pm (Asia/Tokyo)
Current week (all models): 80% used · resets Oct 31 at 4:59am (Asia/Tokyo)
Current week (Fable): 100% used · resets Oct 31 at 5am (Asia/Tokyo)' \
	'{is_error: false, result: $result}' >"$test_dir/claude.json"
cat >"$test_dir/expected" <<'EXPECTED'
claude:Current session	ok	Claude の Current session	79%（Oct 27 at 12:29pm (Asia/Tokyo) にリセット）
claude:Current week (all models)	warn	Claude の Current week (all models)	80%（Oct 31 at 4:59am (Asia/Tokyo) にリセット）
claude:Current week (Fable)	limited	Claude の Current week (Fable)	100%（Oct 31 at 5am (Asia/Tokyo) にリセット）
EXPECTED
echo '設定の警告' >"$test_dir/claude.err"
assert_fetch claude
echo 'PASS Claude: 枠のキー・表示と 79/80/100% の判定、stderr の分離'

echo 1 >"$test_dir/claude.status"
echo '失敗' >"$test_dir/claude.json"
echo 'claude -p /usage が失敗した: 失敗 設定の警告' >"$test_dir/expected"
assert_fetch_error claude
echo 0 >"$test_dir/claude.status"
: >"$test_dir/claude.err"
echo '{"is_error":true,"result":"ログインが必要"}' >"$test_dir/claude.json"
echo 'claude -p /usage がエラーを返した: ログインが必要' >"$test_dir/expected"
assert_fetch_error claude
echo '{"is_error":false,"result":"使用率の表示がない"}' >"$test_dir/claude.json"
echo '/usage の表示から使用率を読めなかった: 使用率の表示がない' >"$test_dir/expected"
assert_fetch_error claude
echo 'PASS Claude: コマンド失敗・エラー応答・使用率なしの理由と終了コード'

cat >"$test_dir/codex.jsonl" <<'MOCK'
{"id":1,"result":{}}
{"method":"account/rateLimits/updated","params":{}}
{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80.9,"resetsAt":604800},"secondary":{"windowDurationMins":300,"usedPercent":79.9,"resetsAt":0}},"extra":{"primary":{"windowDurationMins":60,"usedPercent":100,"resetsAt":0},"secondary":null}}}}
MOCK
cat >"$test_dir/expected" <<'EXPECTED'
codex:codex:10080	warn	Codex の codex の週の枠	80%（01/08 00:00 にリセット）
codex:codex:300	ok	Codex の codex の5 時間の枠	79%（01/01 00:00 にリセット）
codex:extra:60	limited	Codex の extra の60 分の枠	100%（01/01 00:00 にリセット）
codex:allowed	ok	Codex を使えるか	使える
EXPECTED
assert_fetch codex
jq -se 'length == 3 and .[0].method == "initialize"
	and .[0].params.clientInfo == {name: "squad-usage-check", version: "1.0.0"}
	and .[1].method == "initialized"
	and .[2] == {jsonrpc: "2.0", id: 2, method: "account/rateLimits/read"}' \
	"$test_dir/requests.jsonl" >/dev/null
echo 'PASS Codex: 枠のキー・表示・切り捨て・null 枠と問い合わせ'

for reason in credit_limit unknown; do
	jq -cn --arg reason "$reason" '{id: 2, result: {ordinaryUsageAllowed: false,
		rateLimitsByLimitId: {}, rateLimits: (if $reason == "unknown" then {} else {rateLimitReachedType: $reason} end)}}' \
		>"$test_dir/codex.jsonl"
	if [[ "$reason" == unknown ]]; then reason='理由は不明'; fi
	printf 'codex:allowed\tlimited\tCodex を使えるか\t使えない（%s）\n' "$reason" >"$test_dir/expected"
	assert_fetch codex
done
echo 'PASS Codex: 利用不可の理由と理由なしの表示'

echo '{"id":2,"error":{"message":"ログインが必要"}}' >"$test_dir/codex.jsonl"
echo 'codex app-server がエラーを返した: ログインが必要' >"$test_dir/expected"
assert_fetch_error codex
# 応答なしの 30 回の待機は、テストでは待たない。
(
	sleep() { :; }
	: >"$test_dir/codex.jsonl"
	echo 'codex app-server から使用量の応答がなかった' >"$test_dir/expected"
	assert_fetch_error codex
)
echo 'PASS Codex: エラー応答・応答なしの理由と終了コード'

multica() {
	jq -cn --args '$ARGS.positional' -- "$@" >>"$test_dir/calls.jsonl"
	case "$1 $2" in
	'issue create')
		local file
		while (($#)); do
			if [[ $1 == --description-file ]]; then file=$2; break; fi
			shift
		done
		cat "$file" >"$test_dir/description.md"
		echo '{"id":"test-issue"}'
		;;
	'issue comment')
		if [[ -f $test_dir/fail-comment ]]; then echo 'mock comment failure' >&2; return 1; fi
		local file
		while (($#)); do
			if [[ $1 == --content-file ]]; then file=$2; break; fi
			shift
		done
		jq -Rs '{body:.}' <"$file" >>"$test_dir/comments.jsonl"
		;;
	'issue status') test "$4" == done ;;
	'label list') echo '[{"id":"operations-label","name":"運用"}]' ;;
	'issue label') test "$3 $4 $5" = 'add test-issue operations-label' ;;
	*) echo "Unexpected mock call: $*" >&2; return 1 ;;
	esac
}

# 警告・上限到達・取得エラーのどの場合も、作成時点でプロジェクトを渡す。
for level in warn limited error; do
	state='{}'
	: >"$test_dir/calls.jsonl"
	apply test-key "$level" 'テスト枠' '詳細'
	jq -se --arg project "$USAGE_CHECK_PROJECT" --arg assignee "$USAGE_CHECK_ASSIGNEE" '
		def value($flag): . as $args | index($flag) as $i | $args[$i + 1];
		[.[] | select(.[0:2] == ["issue", "create"])] as $creates
		| ($creates | length) == 1
		and ($creates[0] | value("--project") == $project and value("--assignee") == $assignee)
		and ([.[] | select(.[0:3] == ["issue", "label", "add"])] | length) == 1
	' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg level "$level" '."test-key" == {level: $level, issue: "test-issue"}' "$STATE_FILE" >/dev/null
	echo "PASS $level: issue の作成時にプロジェクトと担当を渡し、状態を保存"
done

# 本体も別の作業ディレクトリから動かし、80% の警告と保存済みのキーを確かめる。
echo '{"is_error":false,"result":"Current session: 80% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
: >"$test_dir/calls.jsonl"
(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	state_file=$(usage_check_state_path)
	export USAGE_WARN_PERCENT
	cd "$test_dir"
	bash "$script"
	jq -e '. == {"claude:Current session": {level: "warn", issue: "test-issue"},
		"codex:codex:10080": {level: "warn", issue: "test-issue"}}' "$state_file" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "create"])] | length == 2' "$test_dir/calls.jsonl" >/dev/null
	: >"$test_dir/calls.jsonl"
	USAGE_CHECK_RUNTIMES='claude codex' bash "$script"
	test ! -s "$test_dir/calls.jsonl"
)
# 同じ root でもプロジェクトかメンバーが違えば、それぞれ初回の通知を作る。
(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	export USAGE_WARN_PERCENT
	for pair in test-project:member-b other-project:member-a; do
		export USAGE_CHECK_PROJECT=${pair%:*} USAGE_CHECK_MEMBER=${pair#*:}
		: >"$test_dir/calls.jsonl"
		(cd "$test_dir" && bash "$script")
		jq -se '[.[] | select(.[0:2] == ["issue", "create"])] | length == 2' "$test_dir/calls.jsonl" >/dev/null
		[[ -s $(usage_check_state_path) ]]
	done
	export USAGE_CHECK_PROJECT=test-project USAGE_CHECK_MEMBER=member-a
	: >"$test_dir/calls.jsonl"
	(cd "$test_dir" && bash "$script")
	[[ ! -s $test_dir/calls.jsonl ]]
	[[ -s $USAGE_CHECK_STATE_ROOT/test-project/member-a.state
		&& -s $USAGE_CHECK_STATE_ROOT/test-project/member-b.state
		&& -s $USAGE_CHECK_STATE_ROOT/other-project/member-a.state ]]
	unset USAGE_CHECK_STATE_ROOT
	[[ $(usage_check_state_path) == "$HOME/.multica-agent/template/usage-check/test-project/member-a.state" ]]
)
echo 'PASS 記録の分離: プロジェクト・メンバーごとに通知し、元の組み合わせへ戻しても重複しない'

(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	state_file=$(usage_check_state_path)
	: >"$test_dir/comments.jsonl"
	echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	touch "$test_dir/fail-comment"
	if (cd "$test_dir" && bash "$script") >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -q 'mock comment failure' "$test_dir/err"
	jq -e '."claude:Current session".level == "warn"' "$state_file" >/dev/null
	[[ ! -s $test_dir/comments.jsonl ]]
	rm "$test_dir/fail-comment"
	(cd "$test_dir" && bash "$script")
	(cd "$test_dir" && bash "$script")
	jq -se 'length == 1 and (.[0].body | contains("上限に達した"))' "$test_dir/comments.jsonl" >/dev/null
	jq -e '."claude:Current session".level == "limited"' "$state_file" >/dev/null
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	(cd "$test_dir" && bash "$script")
	jq -e '."claude:Current session" == {level:"ok",issue:""}' "$state_file" >/dev/null
	for other in "$USAGE_CHECK_STATE_ROOT/test-project/member-b.state" "$USAGE_CHECK_STATE_ROOT/other-project/member-a.state"; do
		jq -e '."claude:Current session".level == "warn"' "$other" >/dev/null
	done
)
echo 'PASS 通知の失敗と復旧: 状態を進めず、再実行で一度通知し、ほかの組み合わせの記録を保つ'

echo 'PASS 本体: 別の作業ディレクトリから共通関数を読み、80% で警告し、同じ状態では issue を増やさない'

# 片方だけの PATH で本体を動かす。使わない側の警告を復旧扱いにしない。
for selected in claude codex; do
 (
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_RUNTIMES=$selected USAGE_CHECK_STATE_ROOT="$test_dir/$selected-states"
	selected_bin="$test_dir/$selected-bin"
	mkdir "$selected_bin"
	for tool in bash dirname mkdir mktemp jq python3 cat rm head seq grep cut date sleep; do
		ln -s "$(command -v "$tool")" "$selected_bin/$tool"
	done
	ln -s "$test_dir/bin/$selected" "$selected_bin/$selected"
	if [[ $selected == claude ]]; then disabled_key='codex:allowed'; else disabled_key='claude:Current session'; fi
	state_file=$(usage_check_state_path)
	mkdir -p "${state_file%/*}"
	jq -n --arg key "$disabled_key" '{($key):{level:"warn",issue:"disabled-issue"}}' >"$state_file"
	echo '{"is_error":false,"result":"Current session: 80% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"
	cd "$test_dir"
	PATH="$selected_bin" /bin/bash "$script"
	grep -qx "$selected" "$test_dir/runtime-calls"
	[[ $(jq -Rsc 'split("\n")|map(select(length>0))|unique|length' "$test_dir/runtime-calls") == 1 ]]
	jq -se '[.[]|select(.[0:2]==["issue","create"])]|length==1' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue:"disabled-issue"}' "$state_file" >/dev/null
	: >"$test_dir/calls.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	[[ ! -s $test_dir/calls.jsonl ]]
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{}}}' >"$test_dir/codex.jsonl"
	: >"$test_dir/comments.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue:"disabled-issue"} and all(to_entries[]|select(.key!=$key); .value.level=="ok" and .value.issue=="")' "$state_file" >/dev/null
	jq -se '[.[]|select(.[0:2]==["issue","status"])]==[["issue","status","test-issue","done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null

	# 選んだ側がなければ、使用量や CLI を呼ぶ前に失敗する。
	rm "$selected_bin/$selected"
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"
	state_before=$(cat "$state_file")
	if PATH="$selected_bin" /bin/bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "$selected が見つからない" "$test_dir/err"
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/runtime-calls && $(cat "$state_file") == "$state_before" ]]
 )
 echo "PASS ランタイムの選択: $selected だけのコマンドで警告・復旧し、使わない側の状態を保ち、選んだ側の不足は事前に拒否する"
done

for invalid in '' other 'claude claude' 'claude codex other'; do
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"
	if USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT="$USAGE_CHECK_PROJECT" USAGE_CHECK_MEMBER="$USAGE_CHECK_MEMBER" USAGE_CHECK_RUNTIMES="$invalid" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -q 'USAGE_CHECK_RUNTIMES は' "$test_dir/err"
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/runtime-calls ]]
done
echo 'PASS ランタイムの指定: 空・未知・重複した指定では、使用量とCLIを呼ぶ前に止まる'

# 未指定または空のプロジェクトでは、CLI や使用量の取得より前に止まる。
for project in unset empty; do
	if [[ $project == unset ]]; then
		if env -u USAGE_CHECK_PROJECT USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	else
		if USAGE_CHECK_PROJECT='' USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	fi
	grep -q 'USAGE_CHECK_PROJECT に、作る issue を入れるプロジェクトの ID を渡す' "$test_dir/err"
	echo "PASS $project: プロジェクトがなければ実行前にエラー"
done

for member in unset empty; do
	if [[ $member == unset ]]; then
		if env -u USAGE_CHECK_MEMBER USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT=test-project bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	else
		if USAGE_CHECK_MEMBER='' USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT=test-project bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	fi
	grep -q 'USAGE_CHECK_MEMBER に、メンバーの区別を渡す' "$test_dir/err"
done
echo 'PASS メンバー: 未指定・空では記録や CLI の呼び出し前に止まる'
