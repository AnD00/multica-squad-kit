#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-read-test.sh で実行する。
# CLI は偽物にして、実際のモデル・アカウント・Multica を呼ばない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export USAGE_FIXTURE_NOW=$(date '+%s')
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/usage-read-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export USAGE_FIXTURE_ROOT=$root
script=$root/common/monitor/squad-usage-read
source "$script"
export TZ=UTC

now=1793059200
assert_reset() {
	local actual
	actual=$(epoch_rfc3339 "$(claude_reset_epoch "$1" "$2")")
	[[ "$actual" == "$3" ]] || { echo "FAIL reset: $1 -> $actual (expected $3)" >&2; exit 1; }
}
assert_reset 'Oct 31 at 4:59am (Asia/Tokyo)' "$now" '2026-10-30T19:59:00+00:00'
assert_reset 'Oct 31 at 5am (Asia/Tokyo)' "$now" '2026-10-30T20:00:00+00:00'
assert_reset '12:29pm (Asia/Tokyo)' "$now" '2026-10-27T03:29:00+00:00'
assert_reset '5am (Asia/Tokyo)' "$now" '2026-10-27T20:00:00+00:00'
assert_reset '12am (UTC)' "$now" '2026-10-27T00:00:00+00:00'
year_end=1798718400
assert_reset 'Jan 2 at 5am (Asia/Tokyo)' "$year_end" '2027-01-01T20:00:00+00:00'
assert_reset '1am (UTC)' "$year_end" '2027-01-01T01:00:00+00:00'
for reset in '読めない' 'Oct 31 at 25:00pm (Asia/Tokyo)' 'Oct 31 at 5:99am (UTC)'; do
	if claude_reset_epoch "$reset" "$now" >/dev/null 2>&1; then
		echo "FAIL reset: 読めない表示を受け入れた: $reset" >&2
		exit 1
	fi
done
echo 'PASS reset: 分の有無・時間帯・今日と明日・年越し・不正な表示'
[[ $(TZ=Asia/Tokyo epoch_rfc3339 "$now") == '2026-10-27T09:00:00+09:00' ]]
[[ $(TZ=UTC usage_epoch_format "$now" '%m/%d %H:%M') == '10/27 00:00' ]]
[[ $(TZ=Asia/Tokyo usage_epoch_format "$now" '%m/%d %H:%M') == '10/27 09:00' ]]
echo 'PASS time zone: ホストの UTC と Asia/Tokyo の表示は同じ秒数を表す'

# PATH を閉じ、コマンド欠落のテストでも実物へ抜けないようにする。
mkdir -p "$test_dir/bin"
for cmd in python3 bash jq sed mktemp cat rm grep seq head dirname mkdir; do
	ln -s "$(command -v "$cmd")" "$test_dir/bin/$cmd"
done
cat >"$test_dir/bin/date" <<'MOCK'
#!/bin/bash
[[ "$*" == '+%s' ]] || exit 99
echo "$USAGE_FIXTURE_NOW"
MOCK
chmod +x "$test_dir/bin/date"
cat >"$test_dir/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$*" == '-p /usage --output-format json' ]]
python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "$USAGE_TEST_DIR" claude - emit claude-usage "$USAGE_TEST_DIR/claude.json" -- "$@"
cat "$USAGE_TEST_DIR/claude.stderr" >&2
exit "$(cat "$USAGE_TEST_DIR/claude.status")"
MOCK
cat >"$test_dir/bin/codex" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "$*" == --version ]]; then
	jq -r '.versions.codex' "$USAGE_FIXTURE_ROOT/tests/fixtures/cli/USAGE-CAPTURE.json"
	exit 0
fi
[[ "$*" == app-server ]]
stub_args=("$@")
stub() { recorded=1; python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "$USAGE_TEST_DIR" codex - "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
cat "$USAGE_TEST_DIR/codex.stderr" >&2
for _ in 1 2 3; do IFS= read -r request; done
[[ "$request" == '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}' ]]
if [[ -f "$USAGE_TEST_DIR/codex-defect.json" ]]; then
	jq -cn --slurpfile result "$USAGE_TEST_DIR/codex-defect.json" '{id:2,result:$result[0]}'
else
	stub emit codex-rate-limits "$USAGE_TEST_DIR/codex.jsonl"
fi
cat >/dev/null
MOCK
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/bin/bash
/bin/sleep 0.01
MOCK
cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
echo called >"$USAGE_TEST_DIR/multica-called"
exit 99
MOCK
chmod +x "$test_dir/bin/claude" "$test_dir/bin/codex" "$test_dir/bin/sleep" "$test_dir/bin/multica"
export USAGE_TEST_DIR=$test_dir
future_epoch=$(( (USAGE_FIXTURE_NOW / 60 + 2880) * 60 ))
reset=$(LC_ALL=C usage_epoch_format "$future_epoch" '%b %d at %I:%M%p (UTC)' | sed -e 's/AM /am /' -e 's/PM /pm /')
resets_at=$(epoch_rfc3339 "$future_epoch")

fixtures() {
	echo 0 >"$test_dir/claude.status"
	: >"$test_dir/claude.stderr"
	: >"$test_dir/codex.stderr"
	jq -cn --arg reset "$reset" '{is_error: false, result:
		("Current session: 20% used · resets " + $reset + "\nCurrent week (all models): 27% used · resets " + $reset
		+ "\nCurrent week (Fable): 99% used · resets 不明")}' >"$test_dir/claude.json"
	jq -cn --argjson epoch "$future_epoch" '{id: 2, result: {ordinaryUsageAllowed: true,
		rateLimitsByLimitId: {codex: {primary: {windowDurationMins: 300, usedPercent: 91, resetsAt: $epoch},
		secondary: {windowDurationMins: 10080, usedPercent: 28.9, resetsAt: $epoch}}}}}' >"$test_dir/codex.jsonl"
}
run_read() {
	local status=0
	# source の位置が作業ディレクトリに依存しないことも確認する。
	(cd "$test_dir"; PATH="$test_dir/bin" USAGE_CHECK_STATE="$test_dir/state.json" /bin/bash "$script") \
		>"$test_dir/out.json" 2>"$test_dir/err" || status=$?
	if [[ "$status" != "$1" ]]; then
		echo "FAIL read: status=$status (expected $1)" >&2
		cat "$test_dir/out.json" "$test_dir/err" >&2
		return 1
	fi
	if [[ -s "$test_dir/err" ]]; then
		echo 'FAIL read: 予期しない標準エラー' >&2
		cat "$test_dir/err" >&2
		return 1
	fi
	test ! -e "$test_dir/state.json"
	test ! -e "$test_dir/multica-called"
	jq -se --argjson now "$USAGE_FIXTURE_NOW" '(.[0].read_at | sub("\\+00:00$"; "Z") | fromdateiso8601) as $read
		| length == 1 and $read == $now' "$test_dir/out.json" >/dev/null
}
assert_error() {
	jq -e --arg tool "$1" --arg reason "$2" '.[$tool].error == $reason' "$test_dir/out.json" >/dev/null
}
fixtures
equivalent_claude=$(jq -r '.[0].result | capture("Current week \\(all models\\): (?<percent>[0-9]+)%").percent' "$root/tests/fixtures/cli/claude-usage.json")
jq -c '.[0]' "$root/tests/fixtures/cli/claude-usage.json" >"$test_dir/claude.json"
jq -c '.[0] | {id:2,result:.}' "$root/tests/fixtures/cli/codex-rate-limits.json" >"$test_dir/codex.jsonl"
run_read 0
jq -e --argjson percent "$equivalent_claude" '.claude.week.used_percent == $percent
	and .claude.session == {used_percent:0,resets_at:null}' "$test_dir/out.json" >/dev/null
echo 'PASS 実物: 匿名化した CLI の見本をそのまま読み、リセット表示のない session を保つ'

fixtures
run_read 0
jq -e --arg resets "$resets_at" '.claude == {week: {used_percent: 27, resets_at: $resets},
	session: {used_percent: 20, resets_at: $resets}}
	and .codex == {week: {used_percent: 28, resets_at: $resets}, allowed: true}' "$test_dir/out.json" >/dev/null
echo 'PASS JSON: 値・リセット時刻・読んだ時刻、週の選択・切り捨て、状態と Multica に触れない'

jq '.result |= sub("27%"; "31%")' "$test_dir/claude.json" >"$test_dir/changed"
mv "$test_dir/changed" "$test_dir/claude.json"
jq '.result.rateLimitsByLimitId.codex.secondary.usedPercent = 32' "$test_dir/codex.jsonl" >"$test_dir/changed"
mv "$test_dir/changed" "$test_dir/codex.jsonl"
run_read 0
jq -e '.claude.week.used_percent == 31 and .codex.week.used_percent == 32' "$test_dir/out.json" >/dev/null
echo 'PASS fresh: 呼ぶたびに両方を読み直し、前の値を返さない'

fixtures
jq '.result |= split("\n") | .result |= map(select(startswith("Current session:") | not)) | .result |= join("\n")' \
	"$test_dir/claude.json" >"$test_dir/changed"
mv "$test_dir/changed" "$test_dir/claude.json"
run_read 0
jq -e '.claude.session == {used_percent: 0, resets_at: null} and .claude.week.used_percent == 27' "$test_dir/out.json" >/dev/null
echo 'PASS Claude: 表示から消えた session は 0 と null'

for failure in exit is_error no_rows reset; do
	fixtures
	case "$failure" in
	exit) echo 1 >"$test_dir/claude.status"; reason='claude の使用率の問い合わせに失敗した' ;;
	is_error) echo '{"is_error":true,"result":"ログインが必要"}' >"$test_dir/claude.json"; reason='claude がエラー応答を返した' ;;
	no_rows) echo '{"is_error":false,"result":"使用率なし"}' >"$test_dir/claude.json"; reason='claude の表示から使用率を読めなかった' ;;
	reset) echo '{"is_error":false,"result":"Current session: 20% used · resets 不明"}' >"$test_dir/claude.json"; reason='claude のリセットの時刻を読めなかった' ;;
	esac
	run_read 1
	assert_error claude "$reason"
	jq -e '.codex.week.used_percent == 28 and (.claude | keys) == ["error"]' "$test_dir/out.json" >/dev/null
done
echo 'PASS Claude error: コマンド失敗・エラー応答・使用率なし・時刻不明でも Codex は返す'

for failure in no_response error no_week; do
	fixtures
	case "$failure" in
	no_response) : >"$test_dir/codex.jsonl"; reason='codex から使用量の応答がなかった' ;;
	error) echo '{"id":2,"error":{"message":"ログインが必要"}}' >"$test_dir/codex.jsonl"; reason='codex がエラー応答を返した' ;;
	no_week) echo '{"id":2,"result":{"rateLimitsByLimitId":{},"ordinaryUsageAllowed":true}}' >"$test_dir/codex.jsonl"; reason='codex の応答に週の枠がない' ;;
	esac
	run_read 1
	assert_error codex "$reason"
	jq -e '.claude.week.used_percent == 27 and (.codex | keys) == ["error"]' "$test_dir/out.json" >/dev/null
done
echo 'PASS Codex error: 無応答・エラー応答・週の枠なしでも Claude は返す'

fixtures
jq '.result.ordinaryUsageAllowed = false | .result.rateLimitsByLimitId.codex |= {primary: .secondary, secondary: null}' \
	"$test_dir/codex.jsonl" >"$test_dir/changed"
mv "$test_dir/changed" "$test_dir/codex.jsonl"
run_read 0
jq -e '.codex.allowed == false and .codex.week.used_percent == 28' "$test_dir/out.json" >/dev/null
echo 'PASS Codex: primary の週と、使用率と別の利用不可の情報を返す'

fixtures
for field in ordinaryUsageAllowed rateLimitsByLimitId rateLimits.rateLimitReachedType \
	rateLimitsByLimitId.codex.primary rateLimitsByLimitId.codex.secondary \
	rateLimitsByLimitId.codex.primary.windowDurationMins rateLimitsByLimitId.codex.primary.usedPercent \
	rateLimitsByLimitId.codex.primary.resetsAt; do
	jq --arg path "$field" '.[0] | delpaths([$path | split(".")])' \
		"$root/tests/fixtures/cli/codex-rate-limits.json" >"$test_dir/codex-defect.json"
	run_read 1
	jq -e --arg field "${field##*.}" '.codex.error | contains($field)' "$test_dir/out.json" >/dev/null || {
		echo "FAIL Codex 欠落: $field" >&2; cat "$test_dir/out.json" >&2; exit 1;
	}
	jq -e '.claude.week.used_percent == 27' "$test_dir/out.json" >/dev/null
done
rm "$test_dir/codex-defect.json"
echo 'PASS Codex 欠落: 必須・条件付きの欄名を固定の理由に残し、Claude の読み取りを続ける'

for tool in claude codex; do
	fixtures
	mv "$test_dir/bin/$tool" "$test_dir/bin/$tool.off"
	run_read 1
	assert_error "$tool" "$tool が見つからない"
	mv "$test_dir/bin/$tool.off" "$test_dir/bin/$tool"
done
fixtures
echo 1 >"$test_dir/claude.status"
echo '{"id":2,"error":{"message":"Codex も失敗"}}' >"$test_dir/codex.jsonl"
run_read 1
jq -e '.claude.error != null and .codex.error == "codex がエラー応答を返した"' "$test_dir/out.json" >/dev/null
echo 'PASS unavailable: コマンド欠落と両側の失敗を JSON にする'

# 診断の出所や形式にかかわらず、模擬秘密値を stdout/stderr に出さない。
secret='mock-private-token-DO-NOT-PRINT'
for failure in claude_exit claude_error claude_no_rows claude_reset claude_parse codex_error codex_parse; do
	fixtures
	printf '%s\n' "$secret" >"$test_dir/claude.stderr"
	printf '%s\n' "$secret" >"$test_dir/codex.stderr"
	tool=claude
	case "$failure" in
	claude_exit)
		echo 1 >"$test_dir/claude.status"
		printf '%s\n' "$secret" >"$test_dir/claude.json"
		reason='claude の使用率の問い合わせに失敗した' ;;
	claude_error)
		jq -cn --arg secret "$secret" '{is_error: true, result: $secret}' >"$test_dir/claude.json"
		reason='claude がエラー応答を返した' ;;
	claude_no_rows)
		jq -cn --arg secret "$secret" '{is_error: false, result: $secret}' >"$test_dir/claude.json"
		reason='claude の表示から使用率を読めなかった' ;;
	claude_reset)
		jq -cn --arg secret "$secret" '{is_error: false, result: ("Current session: 20% used · resets " + $secret)}' >"$test_dir/claude.json"
		reason='claude のリセットの時刻を読めなかった' ;;
	claude_parse)
		jq -cn --arg secret "$secret" '{is_error: false, result: {private: $secret}}' >"$test_dir/claude.json"
		reason='使用率の読み取りに失敗した' ;;
	codex_error)
		tool=codex
		jq -cn --arg secret "$secret" '{id: 2, error: {message: $secret}}' >"$test_dir/codex.jsonl"
		reason='codex がエラー応答を返した' ;;
	codex_parse)
		tool=codex
		jq -cn --arg secret "$secret" '{id: 2, result: {rateLimitsByLimitId: {codex: $secret}}}' >"$test_dir/codex.jsonl"
		reason='使用率の読み取りに失敗した' ;;
	esac
	run_read 1
	assert_error "$tool" "$reason"
	if grep -Fq "$secret" "$test_dir/out.json" "$test_dir/err"; then
		echo "FAIL private diagnostics: $failure" >&2
		exit 1
	fi
	jq -e --arg tool "$tool" 'if $tool == "claude" then .codex.week.used_percent == 28 else .claude.week.used_percent == 27 end' \
		"$test_dir/out.json" >/dev/null
done
echo 'PASS private diagnostics: CLI の出力・診断・応答・時刻表示・未知の解析エラーを固定文言にする'

mv "$test_dir/bin/jq" "$test_dir/bin/jq.off"
if PATH="$test_dir/bin" /bin/bash "$script" >"$test_dir/out.json" 2>"$test_dir/err"; then exit 1; fi
test ! -s "$test_dir/out.json"
grep -qx 'jq が見つからない' "$test_dir/err"
echo 'PASS jq: JSON を作れないときだけ標準出力を空にして失敗する'
