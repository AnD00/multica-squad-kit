#!/usr/bin/env bash
# チェックリスト（lib/ui.sh の ui_steps_*、ui_step_*）の描き方を、疑似端末の記録と、
# 記録から読み直した最後の画面で確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/ui-steps-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
esc=$'\033'

# 疑似端末で流し、標準出力の記録を $test_dir/out、標準エラー出力の記録を $test_dir/err に置く。
# 第 1 引数は端末につなぐ出力（out か err か both か none）、第 2 引数は流すスクリプト。
# 残りは ui-pty.py の指定と環境変数。画面の大きさは 100 桁・40 行で、変えたいときは --resize-on を渡す。
run_steps() {
	local mode=$1 script=$2
	shift 2
	local args=() env_args=(TERM=xterm-256color)
	while (($#)); do
		case $1 in
		--resize-on) args+=("$1" "$2" "$3" "$4"); shift 4 ;;
		*=*) env_args+=("$1"); shift ;;
		*) printf 'run_steps: %s\n' "$1" >&2; exit 2 ;;
		esac
	done
	env -i PATH="$PATH" HOME="$test_dir" "${env_args[@]}" python3 "$root/tests/ui-pty.py" "$mode" "$test_dir/out" "$test_dir/err" ${args[@]+"${args[@]}"} -- bash "$script" "$root"
}
# 記録から、最後の画面の文字を読む。
screen() { python3 "$root/tests/ansi-to-png.py" "$1" --text; }
# 記録から、制御文字を除いた行を読む。
stripped() { python3 - "$1" <<'PY'
from pathlib import Path
import re
import sys
print(re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', Path(sys.argv[1]).read_bytes().decode()).replace('\r', ''), end='')
PY
}

# 一覧の通常の流れ。スピナーと値、ゲージ、経過、続きの行、失敗を、同じ行の書き換えで出す。
cat >"$test_dir/flow.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin out 2 "push" "draft を作る" "確認"
ui_step_start 1
sleep 0.35
ui_step_done "1.2.3"
ui_step_start 2
ui_step_progress 3 10 "名前"
sleep 0.35
ui_step_wait 75
ui_step_line - "補足の行" "値"
sleep 0.25
pid=$ui_spinner_pid
kill -0 "$pid"
ui_step_done "PR #1"
if kill -0 "$pid" 2>/dev/null; then echo "spinner-left"; fi
ui_step_start 3
ui_step_fail "確認"
printf 'end pid=[%s]\n' "$ui_spinner_pid"
SH
run_steps out "$test_dir/flow.sh"
screen "$test_dir/out" >"$test_dir/screen"
printf '  ✔ push          1.2.3\n  ✔ draft を作る  PR #1\n      補足の行  値\n  ✖ 確認          確認\nend pid=[]\n' >"$test_dir/expected"
cmp "$test_dir/screen" "$test_dir/expected"
# スピナーは 0.1 秒ごとにコマ送りし、色は active の青、ゲージは青と灰、値と名前は灰、✖ は太字の赤。
python3 - "$test_dir/out" <<'PY'
from pathlib import Path
import re
import sys
data = Path(sys.argv[1]).read_bytes().decode()
esc = '\x1b'
frames = set(re.findall(esc + r'\[38;5;32m([⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏])', data))
assert len(frames) >= 4, frames
assert f'{esc}[38;5;32m━━━━━{esc}[0m{esc}[38;5;244m─────────────{esc}[0m{esc}[38;5;244m 3/10{esc}[0m  {esc}[38;5;244m名前{esc}[0m' in data
assert f'{esc}[38;5;244m1m15s{esc}[0m' in data
assert f'{esc}[1;38;5;196m✖{esc}[0m' in data
assert f'{esc}[38;5;28m✔{esc}[0m push' in data
assert 'spinner-left' not in data
# 上へ戻る行の数は、その時点で描いた行の数を超えない。
total = 0
for match in re.finditer(esc + r'\[(\d+)A', data):
    assert 1 <= int(match.group(1)) <= 4, match.group(0)
assert esc + '[2K' not in data and esc + '[J' in data
PY
[[ ! -s $test_dir/err ]]
echo 'PASS ui-steps: スピナーとゲージ、経過、続きの行、失敗の ✖ を、同じ行の書き換えで出し、終わるとスピナーが残らない'

# 終わった手順の下に続きの行を足しても、画面に残した行の順を保つ。
cat >"$test_dir/insert.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin out 0 s1 s2 s3
ui_step_start 1
ui_step_done v1
ui_step_line - URL x
ui_step_start 2
ui_step_line - 中の行
sleep 0.15
ui_step_done v2
ui_step_start 3
ui_step_done v3
SH
run_steps out "$test_dir/insert.sh"
screen "$test_dir/out" >"$test_dir/screen"
printf '✔ s1  v1\n    URL  x\n✔ s2  v2\n    中の行\n✔ s3  v3\n' >"$test_dir/expected"
cmp "$test_dir/screen" "$test_dir/expected"
echo 'PASS ui-steps: 終わった手順の下の続きの行は、画面の行を重ねたり落としたりせず、手順の並びのとおりに残る'

# 幅が狭いとき、書き換える範囲の行は幅 - 1 に切って灰の … を付け、終わった行は切らずに残す。
cat >"$test_dir/narrow.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
printf 'go\n'
sleep 0.5
ui_steps_begin out 0 "とても長い名前の手順その一その二その三" "短い手順"
ui_step_start 1
sleep 0.35
ui_step_done "とても長い値の文字がここに続く"
ui_step_start 2
sleep 0.15
ui_step_done 値
SH
run_steps out "$test_dir/narrow.sh" --resize-on go 40 10
python3 - "$test_dir/out" <<'PY'
from pathlib import Path
import re
import sys
import unicodedata
esc = '\x1b'
data = Path(sys.argv[1]).read_bytes().decode()
def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text)
clipped = 0
for line in data.split('\r\n'):
    plain = re.sub(esc + r'\[[0-9;]*[A-Za-z]', '', line).replace('\r', '')
    if re.search(r'[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]', plain):
        assert width(plain) <= 39, (width(plain), plain)
        if plain.endswith('…'):
            clipped += 1
            assert f'{esc}[38;5;244m…{esc}[0m' in line, line
assert clipped >= 3, clipped
# 終わった行は、幅より長くても切らずに出す。
assert 'とても長い名前の手順その一その二その三  とても長い値の文字がここに続く' in re.sub(esc + r'\[[0-9;]*[A-Za-z]', '', data)
PY
echo 'PASS ui-steps: 幅 40 の端末で、書き換える範囲の行は幅 - 1 の 39 桁以内に切って灰の … を付け、終わった行は切らない'

# 範囲が高さ - 1 を超えるときは、一覧を切らずに 1 回だけ出し、上へ戻らずに行を足していく。
cat >"$test_dir/tall.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
printf 'go\n'
sleep 0.5
names=()
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do names+=("手順 $i"); done
ui_steps_begin out 0 "${names[@]}"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
	ui_step_start "$i"
	if ((i == 3)); then ui_step_line - "中の行" "$i"; fi
	ui_step_done "v$i"
done
SH
run_steps out "$test_dir/tall.sh" --resize-on go 100 10
python3 - "$test_dir/out" <<'PY'
from pathlib import Path
import re
import sys
esc = '\x1b'
data = Path(sys.argv[1]).read_bytes().decode()
assert not re.search(esc + r'\[\d+A', data), '上へ戻ってはならない'
plain = re.sub(esc + r'\[[0-9;]*[A-Za-z]', '', data).replace('\r', '').split('\n')
assert plain[0] == 'go'
expected = [f'○ 手順 {i}' for i in range(1, 13)]
done = []
for i in range(1, 13):
    done.append(f'✔ 手順 {i:<2}  v{i}')
    if i == 3:
        done.append('    中の行  3')
assert plain[1:] == expected + done + [''], plain
PY
echo 'PASS ui-steps: 高さ 10 に収まらない一覧は、切らずに 1 回出し、そのあと上へ戻らずに終わった行を順に足す'

# 動かしている途中で端末の大きさが変わると、スピナーが読み取って書き換えをやめ、以後は一覧を切らずに
# 上へ戻らずに出し、終わった行を足す。
cat >"$test_dir/resize.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin out 0 "手順 一" "手順 二" "手順 三"
ui_step_start 1
sleep 0.25
ui_step_progress 1 4 RESIZE
sleep 0.8
pid=$ui_spinner_pid
if kill -0 "$pid" 2>/dev/null; then echo "spinner-still-running"; fi
ui_step_done 値1
ui_step_start 2
sleep 0.15
ui_step_done 値2
ui_step_start 3
ui_step_done 値3
SH
run_steps out "$test_dir/resize.sh" --resize-on RESIZE 50 20
python3 - "$test_dir/out" <<'PY'
from pathlib import Path
import re
import sys
esc = '\x1b'
data = Path(sys.argv[1]).read_bytes().decode()
assert 'spinner-still-running' not in data
rewinds = [m.end() for m in re.finditer(esc + r'\[\d+A\r' + esc + r'\[J', data)]
assert rewinds
tail = data[rewinds[-1]:]
# 大きさが変わったあとは、上へ戻らない。
assert not re.search(esc + r'\[\d+A', tail)
plain = re.sub(esc + r'\[[0-9;]*[A-Za-z]', '', tail).replace('\r', '').split('\n')
assert plain[-6:] == ['✔ 手順 一  値1', '○ 手順 二', '○ 手順 三', '✔ 手順 二  値2', '✔ 手順 三  値3', ''], plain
# スピナーの行は、大きさが変わったあとの出力に残らない。
assert not re.search(r'[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]', '\n'.join(plain[-6:]))
PY
echo 'PASS ui-steps: 端末の大きさが変わったら、スピナーが読み取って止まり、以後は上へ戻らずに一覧を出し直して行を足す'

# 片付け: 終わらずに止まっても、スピナーの裏のプロセスが残らず、メッセージも出ない。
cat >"$test_dir/cleanup.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
trap ui_steps_cleanup EXIT
ui_steps_begin out 0 a b
ui_step_start 1
printf '%s\n' "$ui_spinner_pid" >"$2.pid"
sleep 0.3
exit 3
SH
cat >"$test_dir/abandon.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin out 0 a b
ui_step_start 1
printf '%s\n' "$ui_spinner_pid" >"$2.pid"
sleep 0.3
SH
for name in cleanup abandon; do
	env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" both "$test_dir/out" "$test_dir/err" -- bash "$test_dir/$name.sh" "$root" "$test_dir/$name" || true
	pid=$(cat "$test_dir/$name.pid")
	sleep 0.5
	if kill -0 "$pid" 2>/dev/null; then
		printf '%s: スピナー %s が残った\n' "$name" "$pid" >&2
		kill "$pid" 2>/dev/null || true
		exit 1
	fi
	[[ ! -s $test_dir/err ]]
	! grep -q 'Terminated' "$test_dir/out"
done
echo 'PASS ui-steps: 片付けか親の終了で、スピナーの裏のプロセスが残らず、Terminated も出ない'

# 書き換えないとき（NO_COLOR、端末でない出力）は、○ の一覧と書き換えの制御文字を出さず、終わった行を順に出す。
cat >"$test_dir/plain.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin out 2 "push" "draft を作る" "確認"
ui_step_start 1
ui_step_done "1.2.3"
ui_step_start 2
ui_step_progress 3 10 "名前"
ui_step_wait 10
ui_step_wait 40
ui_step_wait 45
ui_step_line - "補足の行" "値"
ui_step_line warn "警告の行"
ui_step_wait 75
ui_step_done "PR #1"
ui_step_line - "後から足した行"
ui_step_start 3
ui_step_fail "確認"
ui_steps_begin err 0 x y
ui_step_start 1
ui_step_done a
ui_steps_show
SH
expected_plain=$'  ✔ push          1.2.3\n  … draft を作る  40s\n  … draft を作る  1m15s\n  ✔ draft を作る  PR #1\n      補足の行  値\n      ! 警告の行\n      後から足した行\n  ✖ 確認          確認\n'
plain_run() {
	env -i PATH="$PATH" HOME="$test_dir" "$@" bash "$test_dir/plain.sh" "$root" >"$test_dir/plain-out" 2>"$test_dir/plain-err"
}
plain_run TERM=xterm-256color
cmp "$test_dir/plain-out" <(printf '%s' "$expected_plain")
printf '✔ x  a\n✔ x  a\n○ y\n' >"$test_dir/expected"
cmp "$test_dir/plain-err" "$test_dir/expected"
! grep -qF "$esc" "$test_dir/plain-out" "$test_dir/plain-err"
echo 'PASS ui-steps: 端末でない出力では、終わった行を順に出し、30 秒おきの経過の行と続きの行も制御文字なしで順に出す'

# 色を付けない端末（NO_COLOR）でも書き換えない。
run_steps both "$test_dir/flow.sh" NO_COLOR=1
stripped "$test_dir/out" >"$test_dir/screen"
printf '  ✔ push          1.2.3\n  ✔ draft を作る  PR #1\n      補足の行  値\n  ✖ 確認          確認\nend pid=[]\n' >"$test_dir/expected"
! grep -qF "$esc" "$test_dir/out"
cmp <(grep -v '…' "$test_dir/screen") "$test_dir/expected"
echo 'PASS ui-steps: NO_COLOR の端末では書き換えの制御文字を出さず、行の並びだけで進みが分かる'
