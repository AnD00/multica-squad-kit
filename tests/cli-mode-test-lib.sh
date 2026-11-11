#!/usr/bin/env bash
# 同じケースを整形の前後で流し、結果と外部 CLI への呼び出しを比べる。
cli_test_compare_modes() (
	set -euo pipefail
	local script=$1 work mode
	shift
	work=$(mktemp -d "$PWD/tmp/cli-modes.XXXXXX")
	trap 'rm -rf -- "$work"' EXIT
	for mode in 0 1; do
		: >"$work/$mode.trace"
		if SQUAD_CLI_TEST_COMPARING=1 SQUAD_CLI_TEST_KEEP_FIELDS=$mode SQUAD_CLI_TEST_TRACE_FILE="$work/$mode.trace" \
			bash "$script" "$@" >"$work/$mode.out" 2>"$work/$mode.err"; then :
		else cat "$work/$mode.out" "$work/$mode.err" >&2; return 1; fi
	done
	diff -u "$work/0.out" "$work/1.out"
	diff -u "$work/0.trace" "$work/1.trace"
	cat "$work/0.out"
	echo 'PASS modes: 整形前後の終了コード・標準出力・CLI のコマンドと引数が一致'
)

# 各ケースの終了コードと標準出力も、スタブの呼び出しと同じ記録に残す。
cli_test_wrap_monitor() {
	export SQUAD_CLI_TEST_ACTUAL_SCRIPT=$1 SQUAD_CLI_TEST_WORK=$2
	export SQUAD_CLI_TEST_TRACE_HELPER="$root/tests/cli-test-trace.py"
	cat >"$2/monitor" <<'MONITOR'
#!/usr/bin/env bash
set -euo pipefail
out=$(mktemp "$SQUAD_CLI_TEST_WORK/result-out.XXXXXX")
err=$(mktemp "$SQUAD_CLI_TEST_WORK/result-err.XXXXXX")
trap 'rm -f "$out" "$err"' EXIT
if bash "$SQUAD_CLI_TEST_ACTUAL_SCRIPT" "$@" >"$out" 2>"$err"; then status=0; else status=$?; fi
python3 "$SQUAD_CLI_TEST_TRACE_HELPER" "$SQUAD_CLI_TEST_WORK" result "$SQUAD_CLI_TEST_ACTUAL_SCRIPT" "$status" "$out" "$@"
cat "$out"
cat "$err" >&2
exit "$status"
MONITOR
	script=$2/monitor
}
