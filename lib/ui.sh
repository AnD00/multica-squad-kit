# セットアップの画面の色を一か所で決める。bash 3.2 で動かす。
# 色の種類と範囲は manual.md の「表示の色と印」に従う。色の制御文字は、この
# ファイルの関数だけが作る。

ui_color_out=no
ui_color_err=no

# 種類ごとの「太字か（1 か 0）」と「xterm の 256 色の番号」。色を付けない種類は -。
ui_kinds='question description choice default success warning error done'
ui_spec() {
	case $1 in
	question) printf '%s\n' '1 32' ;;
	description) printf '%s\n' '0 -' ;;
	choice) printf '%s\n' '1 98' ;;
	default) printf '%s\n' '0 244' ;;
	success) printf '%s\n' '0 28' ;;
	warning) printf '%s\n' '1 166' ;;
	error) printf '%s\n' '1 196' ;;
	done) printf '%s\n' '1 30' ;;
	*) return 1 ;;
	esac
}

# 出す先ごとに、色を付けるかを一度だけ決める。標準出力と標準エラー出力は別に
# 判定し、結果を ui_color_out と ui_color_err（yes か no）に置く。
ui_init() {
	local colors
	ui_color_out=no
	ui_color_err=no
	[[ -z ${NO_COLOR+x} ]] || return 0
	case ${TERM:-} in '' | dumb) return 0 ;; esac
	colors=$(tput colors 2>/dev/null) || return 0
	[[ $colors =~ ^[0-9]+$ ]] && ((colors >= 256)) || return 0
	if [[ -t 1 ]]; then ui_color_out=yes; fi
	if [[ -t 2 ]]; then ui_color_err=yes; fi
	return 0
}

# ui_paint <out|err> <種類> <文字>: 文字を、その出す先の判定どおりに色を付けて
# 改行なしで出す。色を付けないときは文字だけを出す。
ui_paint() {
	local target=$1 kind=$2 text=$3 spec bold color enabled
	spec=$(ui_spec "$kind") || return 1
	bold=${spec% *}
	color=${spec#* }
	case $target in
	out) enabled=$ui_color_out ;;
	err) enabled=$ui_color_err ;;
	*) return 1 ;;
	esac
	if [[ $enabled != yes || $color == - ]]; then
		printf '%s' "$text"
	elif [[ $bold == 1 ]]; then
		printf '\033[1;38;5;%sm%s\033[0m' "$color" "$text"
	else
		printf '\033[38;5;%sm%s\033[0m' "$color" "$text"
	fi
}
