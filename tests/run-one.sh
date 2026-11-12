#!/usr/bin/env bash
# テスト 1 本を、新しいセッションで起こして流す。tests/run.sh から xargs が呼ぶ。
#
# 時間の上限: SQUAD_KIT_TEST_TIMEOUT 秒（run.sh が検証して渡す。なければ 450 秒）を超えたら、
# テストをセッションごと止め、時間切れの失敗として結果に残す。テストが別のプロセスグループで
# 起こした子も同じセッションに残るので、セッションごと止めれば子を残さない。止め方は、
# まず TERM、5 秒（0.2 秒ごとに確かめる）待っても残っていれば KILL。セッションを引くのは tests/stop-session.py
# （pkill -s は macOS にないため、python3 の os.getsid() を使う）。
# 新しいセッションは python3 の os.setsid() で作り、そのまま os.execvp で env に置き換える。
# テストのプロセスの ID が、そのままセッションの ID になる。
# 子は、session に ID が書かれるまで元のグループにとどまって待ち、書かれてから新しいセッションへ移る。
# 移ったあとに割り込まれても、run.sh が session の ID でテストを止められるようにするため。
# 待っている間に run-one.sh が割り込みで終わったら（親の ID が変わったら）、テストを起こさずに終わる。
# テスト用の環境変数は env に渡し、python3 自身には渡さない。HOME の設定から
# バージョンを決める python3 の shim が、空の HOME で動かなくなるのを避けるため。
#
# 結果の記録: result に「終了コード 秒数」を 1 行で書く。時間切れのときは、終了コードを 124 にし、
# 3 つ目に上限の秒数を足す。session には、止めるセッションの ID を、テストが動いている間だけ書く。
# run.sh が割り込まれたときに、残ったテストを止めるために読む。
set -euo pipefail
root=$1 run_dir=$2 id=$3 test=$4
work="$run_dir/$id"
limit=${SQUAD_KIT_TEST_TIMEOUT:-450}
cd "$root"
started=$(date +%s)
status=0
timed_out=no
test_pid=
stop_session() {
	python3 -I "$root/tests/stop-session.py" "$test_pid" "$1" 2>/dev/null
}
# 割り込まれたら、セッションのテストを残さず、結果を残さずに終わる。
trap 'if [[ -n $test_pid ]]; then stop_session KILL || :; fi; exit 143' HUP INT TERM
python3 -c '
import os, sys, time
registered, parent = sys.argv[1], int(sys.argv[2])
while not os.path.exists(registered):
    if os.getppid() != parent:
        sys.exit(143)
    time.sleep(0.01)
os.setsid()
os.execvp(sys.argv[3], sys.argv[3:])' \
	"$work/session" "$$" \
	env HOME="$work/home" TMPDIR="$work/tmp/" BASH_ENV="$root/tests/run-hook.sh" SQUAD_KIT_TEST_ERROR_FILE="$work/error" \
	bash "$test" >"$work/log" 2>&1 &
test_pid=$!
# 読む側が書きかけを見ないよう、書いてから名前を付ける。
printf '%s\n' "$test_pid" >"$work/session.tmp"
mv "$work/session.tmp" "$work/session"
while kill -0 "$test_pid" 2>/dev/null; do
	if (($(date +%s) - started >= limit)); then
		timed_out=yes
		stop_session TERM || :
		for ((grace = 0; grace < 25; grace++)); do
			stop_session ALIVE || break
			sleep 0.2
		done
		stop_session KILL || :
		break
	fi
	sleep 0.2
done
wait "$test_pid" 2>/dev/null || status=$?
rm -f "$work/session"
elapsed=$(($(date +%s) - started))
if [[ $timed_out == yes ]]; then
	printf '124 %s %s\n' "$elapsed" "$limit" >"$work/result"
	printf 'done TIMEOUT %s %ss\n' "$test" "$limit"
	exit 0
fi
printf '%s %s\n' "$status" "$elapsed" >"$work/result"
outcome=FAIL
if [[ $status == 0 ]]; then outcome=PASS; fi
printf 'done %s %s %ss\n' "$outcome" "$test" "$elapsed"
# テストの失敗によって xargs が残りを起こさなくなるのを防ぐ。
exit 0
