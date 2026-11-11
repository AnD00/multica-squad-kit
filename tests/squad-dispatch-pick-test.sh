#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-dispatch-pick-test.sh で実行する。
# 通常の読み取りは本体を使い、CLI だけを差し替える。故障の再現だけ読み取りを差し替える。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/dispatch-pick-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export USAGE_FIXTURE_ROOT=$root
mkdir -p "$test_dir/monitor" "$test_dir/bin"
cp "$root/common/monitor/squad-dispatch-pick" "$test_dir/monitor/"
script=$test_dir/monitor/squad-dispatch-pick
export DISPATCH_TEST_DIR=$test_dir
for cmd in python3 bash dirname mkdir mktemp jq cat rm sed grep seq head; do
	ln -s "$(command -v "$cmd")" "$test_dir/bin/$cmd"
done
cat >"$test_dir/bin/date" <<'MOCK'
#!/bin/bash
if [[ "$*" == '+%s' ]]; then echo 1793059200; else exec /bin/date "$@"; fi
MOCK
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/bin/bash
[[ "$*" == 1 ]] || exit 99
# usage-lib が応答を待つときは、Codex stub が書き終えるまで同期する。
IFS= read -r ready <&9
[[ "$ready" == ready ]]
MOCK
cat >"$test_dir/synchronize.sh" <<'DRIVER'
#!/bin/bash
# 対象の起動時だけ sleep を差し替える。子の CLI・読み取りには適用しない。
# 本体は source せず直接実行し、コマンドとしての入口も検査する。
if [[ ${DISPATCH_TEST_INITIALIZE:-} == yes ]]; then
export DISPATCH_TEST_INITIALIZE=no
set -euo pipefail
exec 9<>"$DISPATCH_TEST_DIR/usage-ready"
slow_ticks=0
sleep() {
[[ "$*" == 1 ]] || return 99
if [[ -e "$DISPATCH_TEST_DIR/hang" ]]; then
	# 意図的な時間切れだけを仮想的に進める。子の準備は FIFO で同期する。
	if [[ ! -e "$DISPATCH_TEST_DIR/timeout-ready" ]]; then
		IFS= read -r ready <"$DISPATCH_TEST_DIR/timeout-fifo"
		[[ "$ready" == ready ]] || exit 98
		: >"$DISPATCH_TEST_DIR/timeout-ready"
	fi
	printf 'tick\n' >>"$DISPATCH_TEST_DIR/timeout-ticks"
elif [[ -e "$DISPATCH_TEST_DIR/slow" ]]; then
	if ((slow_ticks == 0)); then
		IFS= read -r ready <"$DISPATCH_TEST_DIR/slow-ready"
		[[ "$ready" == ready ]] || return 98
	fi
	slow_ticks=$((slow_ticks+1))
	printf 'tick\n' >>"$DISPATCH_TEST_DIR/slow-ticks"
	if ((slow_ticks == 5)); then
		printf 'resume\n' >"$DISPATCH_TEST_DIR/slow-release"
		wait "$reader_pid" 2>/dev/null || true
	fi
else
	# 本体が始めた読み取りの完了まで待つ。時間を待つ必要はない。
	wait "$reader_pid" 2>/dev/null || true
fi
}
fi
DRIVER
# 使用率の読み取りと共通関数は本体を使う。
cp "$root/common/monitor/squad-usage-read" "$root/common/monitor/squad-usage-lib" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
cat >"$test_dir/bin/cli-reset" <<'MOCK'
#!/bin/bash
set -euo pipefail
# 表示だけの Claude CLI を模倣するため、fixture の時差付きの時刻を表示にする。
reset=$(jq -r '.claude.week.resets_at' "$DISPATCH_TEST_DIR/usage.json" | sed -E 's/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
LC_ALL=C python3 - "$reset" <<'PYTIME'
import sys
from datetime import datetime, timezone
reset = datetime.fromisoformat(sys.argv[1]).astimezone(timezone.utc)
print(reset.strftime('%b %d at %I:%M%p (UTC)').replace('AM ', 'am ').replace('PM ', 'pm '))
PYTIME
MOCK
cat >"$test_dir/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$*" == '-p /usage --output-format json' ]]
stub_args=("$@")
stub() { recorded=1; python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "$DISPATCH_TEST_DIR" claude - "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
echo read >>"$DISPATCH_TEST_DIR/calls"
reset=$("$DISPATCH_TEST_DIR/bin/cli-reset")
jq -c --arg reset "$reset" '{is_error:false,result:
	("Current session: " + (.claude.session.used_percent | tostring) + "% used · resets Oct 27 at 1am (UTC)\n"
	+ "Current week (all models): " + (.claude.week.used_percent | tostring) + "% used · resets " + $reset)}' "$DISPATCH_TEST_DIR/usage.json" >"$DISPATCH_TEST_DIR/claude.json"
stub emit claude-usage "$DISPATCH_TEST_DIR/claude.json"
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
stub() { recorded=1; python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "${USAGE_TEST_DIR:-$DISPATCH_TEST_DIR}" codex - "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
for _ in 1 2 3; do IFS= read -r request; done
jq -c '
	def timestamp:
		capture("^(?<date>[0-9T:-]+)(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$")
		| (.date + "Z" | fromdateiso8601) as $utc
		| if .zone == "Z" then $utc else
			((.zone[1:3] | tonumber)*3600 + (.zone[4:6] | tonumber)*60) as $offset
			| $utc - ($offset * (if .zone[0:1] == "-" then -1 else 1 end)) end;
	{id:2,result:{ordinaryUsageAllowed:.codex.allowed,rateLimitsByLimitId:{codex:{primary:{
		windowDurationMins:10080,usedPercent:.codex.week.used_percent,resetsAt:(.codex.week.resets_at | timestamp)}}}}}' "$DISPATCH_TEST_DIR/usage.json" >"$DISPATCH_TEST_DIR/codex.jsonl"
stub emit codex-rate-limits "$DISPATCH_TEST_DIR/codex.jsonl"
printf 'ready\n' >&9
cat >/dev/null
MOCK
chmod +x "$test_dir/bin/cli-reset" "$test_dir/bin/claude" "$test_dir/bin/codex"
chmod +x "$test_dir/bin/date" "$test_dir/bin/sleep"

fixtures() {
	echo 0 >"$test_dir/status"
	cat >"$test_dir/usage.json" <<'JSON'
{
  "read_at": "2026-10-27T00:00:00Z",
  "claude": {
    "week": {"used_percent": 20, "resets_at": "2026-10-30T12:00:00Z"},
    "session": {"used_percent": 10, "resets_at": null}
  },
  "codex": {"week": {"used_percent": 50, "resets_at": "2026-10-30T12:00:00Z"}, "allowed": true}
}
JSON
}
change() {
	jq "$1" "$test_dir/usage.json" >"$test_dir/changed"
	mv "$test_dir/changed" "$test_dir/usage.json"
}
run_pick() {
	local expected_status=$1 expected_role=$2 status=0
	shift 2
	# 別の作業ディレクトリから呼び、PATH も閉じる。
	rm -f "$test_dir/usage-ready"
	mkfifo "$test_dir/usage-ready"
	(cd "$test_dir"; PATH="$test_dir/bin" BASH_ENV="$test_dir/synchronize.sh" DISPATCH_TEST_INITIALIZE=yes /bin/bash "$script" "$@") \
		>"$test_dir/out" 2>"$test_dir/err" || status=$?
	python3 "$root/tests/cli-test-trace.py" "$test_dir" result "$script" "$status" "$test_dir/out" "$@"
	if [[ "$status" != "$expected_status" ]] \
		|| [[ $(head -n 1 "$test_dir/out") != "役: $expected_role" ]] \
		|| [[ $(wc -l <"$test_dir/out" | tr -d ' ') != 2 ]] \
		|| [[ -s "$test_dir/err" ]]; then
		echo "FAIL: $* status=$status (expected $expected_status), role=$expected_role" >&2
		cat "$test_dir/out" "$test_dir/err" >&2
		exit 1
	fi
	grep -q '^振り分け: ' "$test_dir/out"
	if compgen -G "$test_dir/tmp/dispatch-pick.*" >/dev/null; then
		echo 'FAIL: 一時ファイルが残った' >&2; exit 1
	fi
}
assert_line() {
	grep -Fq -- "$1" "$test_dir/out" || { cat "$test_dir/out" >&2; exit 1; }
}

for kind in implement fix; do
	for size in 大きな 小さな; do
		args=("$kind")
		[[ "$kind" == fix ]] || args+=("$size")
		role=implementer
		[[ "$kind" != fix ]] || role=fixer
		fixtures
		run_pick 0 "claude-$role" "${args[@]}"
		assert_line '振り分け: Claude。Claude 週 20%（使ってよい量 40%）・5 時間 10%、Codex 週 50%（使ってよい量 40%）'
		change '.claude.week.used_percent = 50 | .codex.week.used_percent = 20'
		run_pick 0 "codex-$role" "${args[@]}"
	done
done
[[ $(wc -l <"$test_dir/calls" | tr -d ' ') == 8 ]]
echo 'PASS 余裕: 実装の大きさと修正によらず選び、依頼ごとに読み直す'

for exclusion in session claude_week codex_week allowed both session_and_codex; do
	fixtures
	case "$exclusion" in
	session) change '.claude.session.used_percent = 80'; chosen=codex ;;
	claude_week) change '.claude.week.used_percent = 80'; chosen=codex ;;
	codex_week) change '.codex.week.used_percent = 80 | .claude.week.used_percent = 79'; chosen=claude ;;
	allowed) change '.codex.allowed = false | .claude.week.used_percent = 79'; chosen=claude ;;
	both) change '.claude.week.used_percent = 80 | .codex.week.used_percent = 80'; chosen=なし ;;
	session_and_codex) change '.claude.session.used_percent = 80 | .codex.allowed = false'; chosen=なし ;;
	esac
	if [[ "$chosen" == なし ]]; then
		run_pick 2 なし fix
		assert_line '振り分け: なし（Claude は'
		assert_line 'Codex は'
	else
		run_pick 0 "$chosen-implementer" implement 小さな
	fi
	case "$exclusion" in
	session) assert_line 'Claude は 5 時間の枠が 80% 以上' ;;
	claude_week) assert_line 'Claude は週の使用率が 80% 以上' ;;
	codex_week) assert_line 'Codex は週の使用率が 80% 以上' ;;
	allowed) assert_line 'Codex は利用不可' ;;
	esac
done
echo 'PASS 読み取り本体: CLI だけを差し替え、本体の usage-read と usage-lib から振り分ける'

# CLI が表示しない小数の比較と、出力破損・異常終了・時間切れは、読み取りを差し替えて試験する。
cat >"$test_dir/monitor/squad-usage-read" <<'MOCK'
#!/bin/bash
set -euo pipefail
echo read >>"$DISPATCH_TEST_DIR/calls"
[[ "$#" == 0 ]]
if [[ -e "$DISPATCH_TEST_DIR/hang" ]]; then
	# 子も壁時計では終わらず、読み取りのプロセスグループと一緒に止まる。
	cat "$DISPATCH_TEST_DIR/timeout-hold" >/dev/null &
	printf '%s\n' "$$" "$!" >"$DISPATCH_TEST_DIR/pids"
	printf 'ready\n' >"$DISPATCH_TEST_DIR/timeout-fifo"
	wait
fi
if [[ -e "$DISPATCH_TEST_DIR/slow" ]]; then
	printf 'ready\n' >"$DISPATCH_TEST_DIR/slow-ready"
	IFS= read -r resume <"$DISPATCH_TEST_DIR/slow-release"
	[[ "$resume" == resume ]]
fi
echo mock-private-diagnostic >&2
cat "$DISPATCH_TEST_DIR/usage.json"
exit "$(cat "$DISPATCH_TEST_DIR/status")"
MOCK
fixtures
mkfifo "$test_dir/slow-ready" "$test_dir/slow-release"
touch "$test_dir/slow"
run_pick 0 claude-implementer implement 大きな
assert_line '振り分け: Claude。Claude 週 20%'
[[ $(wc -l <"$test_dir/slow-ticks" | tr -d ' ') == 5 ]]
rm "$test_dir/slow" "$test_dir/slow-ready" "$test_dir/slow-release" "$test_dir/slow-ticks"
echo 'PASS 遅い読み取り: 仮想の 5 秒後の応答を時間切れにせず待つ'

fixtures
change '.claude.week.used_percent = 79.99 | .claude.session.used_percent = 79.99 | .codex.week.used_percent = 80'
run_pick 0 claude-implementer implement
echo 'PASS 除外: 週・5 時間・利用不可、80% の境界、両方に回せないときの終了コード 2'

fixtures
change '.codex.week.used_percent = 20'
run_pick 0 claude-implementer implement 小さな
change '.claude.week.used_percent = 20.4 | .codex.week.used_percent = 20.2'
run_pick 0 codex-implementer implement 大きな
assert_line 'Claude 週 20%（使ってよい量 40%）'
change '.claude.week.used_percent = 20.2 | .codex.week.used_percent = 20.4'
run_pick 0 claude-implementer implement 小さな
fixtures
change '.codex.week.used_percent = 20 | .claude.week.resets_at = "2026-10-31T09:00:00+09:00" | .codex.week.resets_at = "2026-10-29T17:00:00-07:00"'
run_pick 0 codex-implementer implement 大きな
assert_line 'Claude 週 20%（使ってよい量 34%）'
assert_line 'Codex 週 20%（使ってよい量 46%）'
echo 'PASS 計算: 同点は Claude、小数のまま比較して表示を丸め、各側のリセット時刻と時差を使う'

for reset in '2026-11-04T00:00:00Z' '2026-11-02T23:59:59Z' '2026-10-26T00:00:00Z'; do
	fixtures
	change ".claude.week.resets_at = \"$reset\" | .codex.week.resets_at = \"$reset\""
	run_pick 0 claude-implementer implement
	if [[ "$reset" == 2026-10-26* ]]; then budget=80; else budget=10; fi
	assert_line "使ってよい量 $budget%"
done
echo 'PASS 週の割合: 0〜1 に収め、使ってよい量は最小 10%'

for failure in exit claude_error codex_error both_error invalid_json multiple_json stale bad_time bad_shape; do
	fixtures
	case "$failure" in
	exit) echo 1 >"$test_dir/status"; reason='使用率の読み取りに失敗した' ;;
	claude_error) change '.claude = {error: "claude が見つからない"}'; reason='Claude: claude が見つからない' ;;
	codex_error) change '.codex = {error: "codex が見つからない"}'; reason='Codex: codex が見つからない' ;;
	both_error) change '.claude = {error: "claude が見つからない"} | .codex = {error: "codex が見つからない"}'
		echo 1 >"$test_dir/status"; reason='Codex: codex が見つからない' ;;
	invalid_json) echo mock-private-diagnostic >"$test_dir/usage.json"; reason='使用率の出力を JSON として読めなかった' ;;
	multiple_json) echo '{}' >>"$test_dir/usage.json"; reason='使用率の出力を JSON として読めなかった' ;;
	stale) change '.read_at = "2026-10-26T23:29:59Z" | .claude.week.used_percent = 99 | .codex.week.used_percent = 99'
		reason='使用率が 30 分より古い' ;;
	bad_time) change '.read_at = "読めない"'; reason='使用率を読んだ時刻を読めなかった' ;;
	bad_shape) change '.claude.week = "不正"'; reason='Claude: 使用率・リセット時刻・利用可否を読めなかった' ;;
	esac
	for size in 小さな 大きな 未知 ''; do
		chosen=claude
		[[ "$size" != 小さな ]] || chosen=codex
		run_pick 0 "$chosen-implementer" implement "$size"
		assert_line '使用率を読めないため、大きさ「'
		assert_line "$reason"
	done
	run_pick 0 codex-fixer fix
	assert_line '使用率を読めないため、修正の代わりの決まりで決めた'
	assert_line "$reason"
	if grep -q 'mock-private-diagnostic' "$test_dir/out" "$test_dir/err"; then exit 1; fi
done
echo 'PASS 読めない: 終了 1・片側/両側 error・不正 JSON・古い時刻・不正な形、代わりの決まりと理由'

fixtures
change '.read_at = "2026-10-26T23:30:00Z"'
run_pick 0 claude-implementer implement 小さな
if grep -q '読めない' "$test_dir/out"; then exit 1; fi
fixtures
change '.claude = {error: "claude が見つからない"} | .codex.allowed = false'
echo 1 >"$test_dir/status"
run_pick 0 claude-fixer fix
assert_line 'Claude: claude が見つからない'
assert_line 'Codex は利用不可'
fixtures
change '.codex = {error: "codex が見つからない"} | .claude.session.used_percent = 90'
echo 1 >"$test_dir/status"
run_pick 0 codex-implementer implement 大きな
assert_line 'Codex: codex が見つからない'
assert_line 'Claude は 5 時間の枠が 80% 以上'
echo 'PASS 部分的な読み取り: 30 分ちょうどは有効、読めた側が使用上限なら代わりの決まりより優先して除く'

fixtures
mkfifo "$test_dir/timeout-fifo"
mkfifo "$test_dir/timeout-hold"
touch "$test_dir/hang"
run_pick 0 codex-implementer implement 小さな
assert_line '使用率の読み取りが 90 秒で終わらなかった'
[[ $(wc -l <"$test_dir/timeout-ticks" | tr -d ' ') == 90 ]]
while IFS= read -r pid; do
	state=$(ps -o stat= -p "$pid" || true)
	if [[ -n "$state" && "$state" != *Z* ]]; then
		echo "FAIL: 時間切れの子が動いている: $pid $state" >&2; exit 1
	fi
done <"$test_dir/pids"
rm "$test_dir/hang" "$test_dir/timeout-fifo" "$test_dir/timeout-hold" "$test_dir/timeout-ready" "$test_dir/timeout-ticks"
echo 'PASS 時間切れ: 子の準備後に仮想の 90 回を進め、読み取りとその子を残さない'

for args in '' 'other' 'fix 小さな' 'implement 小さな extra'; do
	status=0
	# ここだけは意図的に引数を空白で分ける。
	PATH="$test_dir/bin" /bin/bash "$script" $args >"$test_dir/out" 2>"$test_dir/err" || status=$?
	[[ "$status" == 1 && ! -s "$test_dir/out" && -s "$test_dir/err" ]]
done
mv "$test_dir/bin/jq" "$test_dir/bin/jq.off"
status=0
PATH="$test_dir/bin" /bin/bash "$script" fix >"$test_dir/out" 2>"$test_dir/err" || status=$?
[[ "$status" == 1 && ! -s "$test_dir/out" ]]
grep -qx 'jq が見つからない' "$test_dir/err"
echo 'PASS 使い方: 不正な引数と jq 欠落は標準エラーと終了コード 1'
