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
[[ $(printf '%s\n' "$kinds" | wc -l | tr -d ' ') == 8 ]]
paint='source "$1/lib/ui.sh"; ui_init; for kind in $ui_kinds; do ui_paint out "$kind" "[$kind]"; echo; done'
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" out "$test_dir/out" "$test_dir/err" -- bash -c "$paint" _ "$root"
tr -d '\r' <"$test_dir/out" >"$test_dir/kinds"
while read -r kind bold color; do
	if [[ $color == - ]]; then
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
[[ $(wc -l <"$test_dir/contrast" | tr -d ' ') == 7 ]]
echo 'PASS ui: 各色の黒・白の背景とのコントラスト比が 3.5 以上で、manual.md の表と一致する'
