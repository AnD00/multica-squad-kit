#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/ui-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
esc=$'\033'
probe='source "$1/lib/ui.sh"; ui_init; ui_paint out error 標準出力; ui_paint err warning 標準エラー出力 >&2'

# 疑似端末は、tty の出力、環境、環境変数を引数にして流す。余計な環境変数を渡さない。
run_pty() {
	local mode=$1
	shift
	env -i PATH="$PATH" HOME="$test_dir" "$@" python3 "$root/tests/ui-pty.py" "$mode" "$test_dir/out" "$test_dir/err" -- bash -c "$probe" _ "$root"
}
has_escape() { grep -qF "$esc[" "$1"; }
colored() { has_escape "$test_dir/$1"; }
plain() { ! grep -qF "$esc" "$test_dir/$1"; }

# 端末のとき、標準出力と標準エラー出力が、それぞれの出す先で判定される。
run_pty both TERM=xterm-256color
colored out
colored err
grep -qF "$esc[1;38;5;196m標準出力$esc[0m" "$test_dir/out"
grep -qF "$esc[1;38;5;166m標準エラー出力$esc[0m" "$test_dir/err"
run_pty out TERM=xterm-256color
colored out
plain err
grep -qF 標準エラー出力 "$test_dir/err"
run_pty err TERM=xterm-256color
plain out
colored err
echo 'PASS ui: 端末につないだ出力だけに色が付く（標準出力と標準エラー出力を別に判定する）'

# 色を付けない条件。出す先が端末でも、制御文字が一つも入らず、文字は残る。
run_pty none TERM=xterm-256color
plain out
plain err
no_color() {
	run_pty both "$@"
	plain out
	plain err
	grep -qF 標準出力 "$test_dir/out"
	grep -qF 標準エラー出力 "$test_dir/err"
}
no_color TERM=xterm-256color NO_COLOR=1
no_color TERM=xterm-256color NO_COLOR=
no_color TERM=dumb
no_color TERM=
no_color
no_color TERM=vt100
no_color TERM=ansi
echo 'PASS ui: 出す先が端末でない、NO_COLOR（空でも）、TERM が dumb・空・未設定、256 色に未対応のときは制御文字を出さない'

# 種類ごとの色。説明は色を付けず、ほかは表の番号どおりに付く。
kinds=$(env -i PATH="$PATH" bash -c 'source "$1/lib/ui.sh"; for kind in $ui_kinds; do printf "%s " "$kind"; ui_spec "$kind"; done' _ "$root")
[[ $(printf '%s\n' "$kinds" | wc -l | tr -d ' ') == 10 ]]
paint='source "$1/lib/ui.sh"; ui_init; for kind in $ui_kinds; do ui_paint out "$kind" "[$kind]"; echo; done'
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" out "$test_dir/out" "$test_dir/err" -- bash -c "$paint" _ "$root"
tr -d '\r' <"$test_dir/out" >"$test_dir/kinds"
while read -r kind bold color; do
	if [[ $color == - && $bold == 1 ]]; then
		grep -qxF "$esc[1m[$kind]$esc[0m" "$test_dir/kinds"
	elif [[ $color == - ]]; then
		grep -qxF "[$kind]" "$test_dir/kinds"
	elif [[ $bold == 1 ]]; then
		grep -qxF "$esc[1;38;5;${color}m[$kind]$esc[0m" "$test_dir/kinds"
	else
		grep -qxF "$esc[38;5;${color}m[$kind]$esc[0m" "$test_dir/kinds"
	fi
done <<<"$kinds"
# 初期化の前と、知らない種類・出す先は、色を付けず、知らないものは失敗にする。
[[ $(bash -c 'source "$1/lib/ui.sh"; ui_paint out error 文字' _ "$root") == 文字 ]]
if bash -c 'source "$1/lib/ui.sh"; ui_paint out unknown 文字' _ "$root" >/dev/null 2>&1; then exit 1; fi
if bash -c 'source "$1/lib/ui.sh"; ui_paint file error 文字' _ "$root" >/dev/null 2>&1; then exit 1; fi
# ui_line は改行まで付け、err は標準エラー出力へだけ出す。
bash -c 'source "$1/lib/ui.sh"; ui_line out error 一行目; ui_line err warning 二行目' _ "$root" >"$test_dir/line-out" 2>"$test_dir/line-err"
[[ $(cat "$test_dir/line-out") == 一行目 && $(cat "$test_dir/line-err") == 二行目 ]]
[[ $(wc -l <"$test_dir/line-out" | tr -d ' ') == 1 && $(wc -l <"$test_dir/line-err" | tr -d ' ') == 1 ]]
echo 'PASS ui: 種類ごとの色と太字が表のとおりに付き、説明は色なし'

# どの色も、黒と白の背景のどちらに対しても読める（コントラスト比 3.5 以上）。
printf '%s\n' "$kinds" | python3 -I "$root/tests/ui-contrast.py" "$root/manual.md" >"$test_dir/contrast"
[[ $(wc -l <"$test_dir/contrast" | tr -d ' ') == 8 ]]
echo 'PASS ui: 各色の黒・白の背景とのコントラスト比が 3.5 以上で、manual.md の表と一致する'

# 色のない太字も、色を付けない条件では制御文字を出さない。
probe='source "$1/lib/ui.sh"; ui_init; ui_paint out active 標準出力; ui_paint out strong 太字; ui_paint err strong 標準エラー出力 >&2'
run_pty both TERM=xterm-256color
grep -qF "$esc[38;5;32m標準出力$esc[0m$esc[1m太字$esc[0m" "$test_dir/out"
grep -qF "$esc[1m標準エラー出力$esc[0m" "$test_dir/err"
run_pty none TERM=xterm-256color
plain out
plain err
no_color TERM=xterm-256color NO_COLOR=1
no_color TERM=xterm-256color NO_COLOR=
no_color TERM=dumb
no_color TERM=
no_color
no_color TERM=vt100
no_color TERM=ansi
echo 'PASS ui: active は太字なしの青、strong は色なしの太字。色を付けない条件では両方とも文字だけになる'

probe='source "$1/lib/ui.sh"; ui_init; for mark in ok fail add change keep warn drop todo; do ui_mark out "$mark" 手順 値; done; ui_mark err fail エラー側; ui_mark out ok 値なし ""'
run_pty both TERM=xterm-256color
python3 - "$test_dir/out" "$test_dir/err" <<'PY'
from pathlib import Path
import sys
esc='\x1b['
value=f'  {esc}38;5;244m値{esc}0m\n'
expected=[
    f'{esc}38;5;28m✔{esc}0m 手順',
    f'{esc}1;38;5;196m✖{esc}0m 手順',
    f'{esc}38;5;28m+{esc}0m 手順',
    '~ 手順',
    f'{esc}38;5;244m·{esc}0m {esc}38;5;244m手順{esc}0m',
    f'{esc}1;38;5;166m!{esc}0m 手順',
    f'{esc}38;5;244m-{esc}0m 手順',
    f'{esc}38;5;244m○{esc}0m {esc}38;5;244m手順{esc}0m',
]
out=Path(sys.argv[1]).read_text()
assert out==''.join(line+value for line in expected)+f'{esc}38;5;28m✔{esc}0m 値なし\n',repr(out)
assert Path(sys.argv[2]).read_text()==f'{esc}1;38;5;196m✖{esc}0m エラー側\n'
PY
# 出力先ごとの色の判定と、色を付けないときも同じ記号・配置が残ること。
for mode in none out err; do
	run_pty "$mode" TERM=xterm-256color
	python3 - "$test_dir/out" >"$test_dir/marks" <<'PY'
from pathlib import Path
import re
import sys
print(re.sub(r'\x1b\[[0-9;]*m', '', Path(sys.argv[1]).read_text()), end='')
PY
	printf '✔ 手順  値\n✖ 手順  値\n+ 手順  値\n~ 手順  値\n· 手順  値\n! 手順  値\n- 手順  値\n○ 手順  値\n✔ 値なし\n' >"$test_dir/expected"
	cmp "$test_dir/marks" "$test_dir/expected"
	case $mode in none) plain out; plain err ;; out) colored out; plain err ;; err) plain out; colored err ;; esac
done
run_pty both TERM=xterm-256color NO_COLOR=1
plain out
plain err
grep -qF '✖ エラー側' "$test_dir/err"
if bash -c 'source "$1/lib/ui.sh"; ui_mark out unknown 本文' _ "$root" >"$test_dir/unknown"; then exit 1; fi
[[ ! -s $test_dir/unknown ]]
if bash -c 'source "$1/lib/ui.sh"; ui_mark file ok 本文' _ "$root" >/dev/null; then exit 1; fi
echo 'PASS ui: 8つの印、本文、灰の値、値のない行と、出力先ごとの色の判定を確かめた'

# jq を含む外の道具のない PATH で、ASCII、全角の範囲、4バイト、壊れた UTF-8 を読む。
mkdir "$test_dir/bin"
python3 - "$test_dir/width-cases" <<'PY'
from pathlib import Path
import sys
cases=[(0,b''),(3,b'abc'),(6,'日本語'.encode()),(5,'a界bc'.encode()),
       (6,'✔●│━⠋○'.encode()),(2,'𠀀'.encode()),(2,'😀'.encode()),
       (1,b'\x80'),(2,b'\xc0\xaf'),(1,b'\xe3'),(3,b'\xe3\x81A'),
       (3,b'\xe0\x80\x80'),(3,b'\xed\xa0\x80'),(4,b'\xf4\x90\x80\x80'),
       (4,b'\xf5\x80\x80\x80')]
ranges=[(0x1100,0x115f),(0x2e80,0xa4cf),(0xac00,0xd7a3),(0xf900,0xfaff),
        (0xfe30,0xfe4f),(0xff00,0xff60),(0xffe0,0xffe6)]
for start,end in ranges:
    for code,width in [(start-1,1),(start,2),(end,2),(end+1,1)]:
        cases.append((width,chr(code).encode()))
cases.extend([(2,chr(0x10000).encode()),(2,chr(0x10ffff).encode())])
Path(sys.argv[1]).write_bytes(b''.join(str(width).encode()+b'|'+text+b'\n' for width,text in cases))
PY
PATH="$test_dir/bin" /bin/bash -euo pipefail -c '
source "$1/lib/ui.sh"
if command -v jq; then exit 1; fi
while IFS="|" read -r expected value; do
    actual=$(ui_width "$value")
    [[ $actual == "$expected" ]] || { printf "width: %s != %s\n" "$actual" "$expected"; exit 1; }
done <"$2/width-cases"
LC_ALL=POSIX
ui_width abc >/dev/null
[[ $LC_ALL == POSIX ]]
[[ $(ui_pad 8 日本語) == "日本語  " ]]
[[ $(ui_pad 3 日本語) == 日本語 ]]
[[ $(ui_pad 6 日本語) == 日本語 ]]
[[ $(ui_pad 3 "") == "   " ]]
' _ "$root" "$test_dir"
echo 'PASS ui: 外の道具なしでUTF-8の幅を数え、全角の範囲と読めないバイト、文字を切らない空白埋めを確かめた'

cat >"$test_dir/bin/tput" <<'SH'
#!/bin/bash
[[ $1 == cols ]] || exit 1
printf '%s\n' "${UI_TEST_COLS-}"
exit "${UI_TEST_COLS_STATUS:-0}"
SH
chmod +x "$test_dir/bin/tput"
PATH="$test_dir/bin" /bin/bash -euo pipefail -c '
source "$1/lib/ui.sh"
export UI_TEST_COLS=3 COLUMNS=20
[[ $(ui_rows ab界) == 2 ]]
[[ $(ui_rows abc) == 1 ]]
[[ $(ui_rows "") == 0 ]]
export UI_TEST_COLS=0010 COLUMNS=1
[[ $(ui_rows abc) == 1 ]]
export UI_TEST_COLS_STATUS=1 COLUMNS=2
[[ $(ui_rows ab界) == 2 ]]
export UI_TEST_COLS_STATUS=0 UI_TEST_COLS=0 COLUMNS=3
[[ $(ui_rows ab界) == 2 ]]
export UI_TEST_COLS=unknown COLUMNS=2
[[ $(ui_rows abc) == 2 ]]
unset COLUMNS
printf -v long "%081d" 0
[[ $(ui_rows "$long") == 2 ]]
export COLUMNS=0
[[ $(ui_rows "$long") == 2 ]]
export COLUMNS=bad
[[ $(ui_rows "$long") == 2 ]]
' _ "$root"
echo 'PASS ui: 行の数は端末の幅、COLUMNS、80桁の順に求め、幅が割り切れないときは切り上げる'
